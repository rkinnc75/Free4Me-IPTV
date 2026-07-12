import 'dart:async' show Completer;
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/db_factory.dart';
import 'package:open_tv/backend/epg_matcher.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/xmltv_parser.dart';
import 'package:open_tv/backend/xtream_epg.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:workmanager/workmanager.dart';

// finding 41: `_matchInIsolate` (the compute() entrypoint) was removed — the
// matcher now builds the EPG index once and matches each batch synchronously
// on the calling isolate (see matchChannels), so no per-batch isolate spawn
// or channelMap deep-copy occurs.

// How many channels to process per batch. Larger batches mean fewer progress
// callbacks; 2000 keeps the UI progress granular. At 2000, a 90k-channel
// source produces ~45 batches.
const _matchBatchSize = 2000;

/// Task name registered with WorkManager for background EPG refresh.
const epgBackgroundTask = 'epg_refresh';

/// Top-level WorkManager callback dispatcher.
/// Must be annotated with `@pragma('vm:entry-point')` so tree-shaking
/// doesn't remove it in release builds.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == epgBackgroundTask) {
      await EpgService.refreshAllSources(background: true);
    }
    return true;
  });
}

class EpgService {
  /// fix600: bumped after every successful per-source EPG refresh. Views (the
  /// Live guide) listen and reload so a foreground/launch refresh becomes
  /// visible without a manual tab switch.
  static final ValueNotifier<int> epgVersion = ValueNotifier<int>(0);

  /// fix600: true when NO programme is airing right now — i.e. the EPG forecast
  /// has lapsed (stale). The onn's Workmanager auto-refresh is unreliable, so we
  /// use this to trigger a foreground refresh on launch.
  static Future<bool> isStale({List<int>? sourceIds}) async {
    try {
      final db = await EpgDbFactory.db;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      // fix629: the old form — count(*) over ALL programmes with only
      // start_utc/stop_utc predicates — could NOT use any index (the only
      // time index, idx_programs_time_range, leads with source_id) so it
      // FULL-SCANNED the ~1M-row programmes table on every launch, just to
      // learn "is anything airing". Two changes make it seek instead:
      //   1. Bound by source_id (equality on the index's leading column), one
      //      cheap probe per eligible source, early-exit the moment ONE source
      //      has something airing (the common case → touches one source).
      //   2. Floor start_utc to a recent window so the (source_id, start_utc,
      //      stop_utc) range seek is tiny (rather than reading the whole
      //      source). The floor is the MAX EPG retention window (epgPastDays
      //      caps at 3 — settings_view). deleteStalePrograms never prunes a
      //      row still airing (it keeps stop_utc > now - pastDays), and no
      //      retained airing programme can have start_utc older than that
      //      window, so a 3-day floor is provably equivalent to the old
      //      unbounded count(*) form within the data the DB actually holds.
      // stop_utc > now is covered by the third index column, so the probe is
      // index-only. LIMIT 1 — we only need existence, not a count.
      // finding 42: use the EXACT 'airing now' predicate (start_utc <= now AND
      // stop_utc > now) instead of the old 3-day start_utc floor. A multi-day
      // programme (24/7 filler, week-long container) inserted while its start
      // was in-window can still be airing days later and survives
      // deleteStalePrograms; the floor excluded it → isStale falsely true →
      // hourly re-download storm. Still seeks idx_programs_time_range (source_id
      // equality + start_utc range; stop_utc is the covered residual).
      final ids = sourceIds;
      if (ids != null && ids.isNotEmpty) {
        for (final sid in ids) {
          final rows = await db.getAll(
            'SELECT 1 FROM programmes '
            'WHERE source_id = ? AND start_utc <= ? AND stop_utc > ? LIMIT 1',
            [sid, now, now],
          );
          if (rows.isNotEmpty) return false; // something airing now → not stale
        }
        return true; // nothing airing across every eligible source
      }
      // No source list supplied: same on-now predicate, LIMIT-1 early-exit.
      final rows = await db.getAll(
        'SELECT 1 FROM programmes '
        'WHERE start_utc <= ? AND stop_utc > ? LIMIT 1',
        [now, now],
      );
      return rows.isEmpty;
    } catch (e) {
      AppLog.warn('EPG: isStale check failed — $e');
      return false; // never trigger a refresh on a check error
    }
  }

  /// fix601: minimum interval between launch stale-refreshes. A source can be
  /// "stale" (nothing airing now) yet have a perfectly fresh download — e.g. a
  /// provider whose XMLTV simply doesn't cover this instant, or a feed with
  /// gaps. Without this guard, isStale() would be true on EVERY launch and we'd
  /// re-download a 100k-programme feed each time. Cap to once per hour.
  static const int _staleRefreshMinIntervalSec = 3600;

  /// fix600: foreground EPG refresh on launch IF the forecast has lapsed. Cheap
  /// no-op when fresh or no EPG source is configured. Self-heals the onn (where
  /// the background task often never fires). fix601: debounced against the last
  /// refresh so a feed that's perpetually "stale at now" can't trigger a
  /// download storm on every launch.
  static Future<void> refreshIfStale() async {
    final eligible = (await Sql.getSources())
        .where((s) => s.enabled && resolveEpgUrl(s) != null)
        .toList(growable: false);
    if (eligible.isEmpty) return;
    // fix629: pass the eligible source IDs so isStale can seek per-source via
    // idx_programs_time_range instead of full-scanning all programmes.
    final eligibleIds = eligible.map((s) => s.id).whereType<int>().toList();
    if (!await isStale(sourceIds: eligibleIds)) return;
    final last = await Sql.getLatestEpgRefresh();
    if (last != null) {
      final ageSec =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 - last;
      if (ageSec < _staleRefreshMinIntervalSec) {
        AppLog.info('EPG: stale but last refresh was ${ageSec}s ago '
            '(< ${_staleRefreshMinIntervalSec}s) — skipping launch refresh');
        return;
      }
    }
    AppLog.info('EPG: no programme airing now — foreground refresh (stale)');
    await refreshAllSources(background: false);
  }

  /// Register (or re-register) the periodic background EPG refresh task.
  static Future<void> scheduleBackgroundRefresh() async {
    final settings = await SettingsService.getSettings();
    if (!settings.epgAutoRefresh) {
      AppLog.info('EPG: auto-refresh disabled — cancelling background task');
      await Workmanager().cancelByUniqueName(epgBackgroundTask);
      return;
    }

    AppLog.info(
      'EPG: scheduling background refresh — '
      'interval=${settings.epgRefreshHours}h '
      'refreshHour=${settings.epgRefreshHour}',
    );
    await Workmanager().registerPeriodicTask(
      epgBackgroundTask,
      epgBackgroundTask,
      frequency: Duration(hours: settings.epgRefreshHours),
      initialDelay: _delayUntilRefreshHour(settings.epgRefreshHour),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }

  /// Refresh EPG for all sources that have an EPG URL configured.
  ///
  /// fix712: sources run ONE AT A TIME (`maxConcurrent = 1`). The old
  /// `maxConcurrent = 2` assumed "HTTP fetches don't fight and the SQLite writer
  /// naturally serializes" — on-device verification disproved both: concurrent
  /// downloads starved each other's temp-XML fetch (→ 0 programs) and the
  /// concurrent DB writes exhausted the SQLITE_BUSY retries. Serial per-source is
  /// correct + gentler on providers (no burst traffic). See the maxConcurrent
  /// comment below for the full trace.
  static Future<void> refreshAllSources({bool background = false}) async {
    // Review finding 141: the BACKGROUND WorkManager pass yields to a
    // foreground catalog refresh (cross-isolate advisory lock in app_meta) —
    // two isolates must never fight for the single sqlite writer on a 2GB
    // box. Deferrable: the task re-runs on the next WorkManager cadence.
    // The foreground (user-initiated) path is NOT gated.
    if (background) {
      final ok = await Sql.tryAcquireRefreshLock('background');
      if (!ok) {
        AppLog.info(
            'EPG: skipping background refresh — a catalog refresh holds the lock');
        return;
      }
    }
    // finding 43: cross-isolate mutual exclusion between the background
    // periodic refresh and the foreground launch/manual refresh. An in-flight
    // background refresh is invisible to the foreground path (getLatestEpgRefresh
    // only advances AFTER a source completes), so both could download the same
    // feeds concurrently → doubled bandwidth/memory + cross-isolate SQLITE_BUSY
    // churn on epg.sqlite. Guard with an app_meta marker (db.sqlite, visible to
    // both isolates) carrying a start epoch, with a TTL so a crashed refresh
    // can't wedge the flag forever. This guards BOTH entry points because both
    // reach refreshAllSources.
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final busyRaw = await Sql.getAppMeta('epg_refresh_in_progress');
    final busyEpoch = int.tryParse(busyRaw ?? '');
    if (busyEpoch != null &&
        (nowSec - busyEpoch) < _staleRefreshMinIntervalSec) {
      AppLog.info('EPG: refresh already in progress — skipping');
      if (background) await Sql.releaseRefreshLock();
      return;
    }
    await Sql.setAppMeta('epg_refresh_in_progress', nowSec.toString());
    try {
    final eligible = (await Sql.getSources())
        .where((s) => s.enabled && resolveEpgUrl(s) != null)
        .toList(growable: false);
    // fix712: refresh sources ONE AT A TIME. maxConcurrent=2 was meant for
    // parallel downloads, but on-device verification (2026-07-12, onn 4K Plus, a
    // 2GB box) proved concurrent multi-source refresh RACES the download/parse
    // phase — not just the match (fix709). With Trex + A3000 refreshing at once:
    // one source's temp-XML download was starved (PathNotFoundException
    // epg_src_N.xml → "0 programs loaded"), and the epg_refresh_log / insert
    // writes exhausted the SQLITE_BUSY retries ("database is locked, code 5") —
    // BOTH sources failed. Serial per-source (download→parse→insert→match alone)
    // matches the proven-good single-source path (Trex: 185516 programs,
    // 35851/35851 matched) and is gentler on providers. Slower for N sources, but
    // this is a nightly background op where correctness >> speed. fix709's match
    // gate stays as a belt-and-suspenders invariant.
    const maxConcurrent = 1;
    for (var i = 0; i < eligible.length; i += maxConcurrent) {
      final end = i + maxConcurrent > eligible.length
          ? eligible.length
          : i + maxConcurrent;
      final chunk = eligible.sublist(i, end);
      // finding 39: isolate each source — matchChannels (SQLITE_BUSY, isolate
      // failure, checkpoint) can throw out of refreshSource; without this the
      // Future.wait rethrows, the loop dies skipping later sources, and the
      // error escapes the unawaited caller. Log + record and continue.
      await Future.wait(chunk.map((s) async {
        try {
          await refreshSource(
            s,
            epgUrl: resolveEpgUrl(s),
            background: background,
            rebuildFts: false, // finding 36: hoisted to once-after-loop below
          );
        } catch (e, st) {
          AppLog.error('EPG: refresh failed for "${s.name}": $e\n$st');
          if (s.id != null) {
            await Sql.upsertEpgRefreshLog(s.id!, 0, e.toString());
          }
        }
      }));
    }
    } finally {
      // finding 43: finally holds the post-loop work so a per-source catch (or
      // any throw) can't skip it. Order: rebuild FTS → set completion marker →
      // clear in-progress → release the background lock.
      // finding 36: programmes_fts 'rebuild' is a GLOBAL FTS5 op whose cost is
      // independent of which source parsed, so a multi-source refresh pays it
      // ONCE here instead of once per source. Idempotent when nothing changed.
      try {
        await Sql.rebuildProgrammesFts();
      } catch (e) {
        AppLog.warn('EPG: post-refresh FTS rebuild failed — $e');
      }
      // finding 38: cross-isolate completion signal. Dart statics are
      // per-isolate, so the Workmanager background isolate's epgVersion bump
      // never reaches the main-isolate guide listener. Persist a completion
      // timestamp in app_meta (db.sqlite); the main isolate polls it on
      // resume/startup and bumps its own epgVersion so TvGuideView reloads.
      await Sql.setAppMeta(
        'epg_last_completed_utc',
        (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
      );
      // finding 43: clear the in-progress marker.
      await Sql.setAppMeta('epg_refresh_in_progress', '');
      if (background) await Sql.releaseRefreshLock();
    }
  }

  /// Step 1 — Download and parse XMLTV, insert programs.
  /// Returns the EPG channel map (epgId → display names) for use in
  /// [matchChannels], or null if the source has no EPG URL or an error occurs.
  static Future<Map<String, String>?> downloadAndParseEpg(
    Source source, {
    String? epgUrl,
    bool rebuildFts = true, // finding 36: false in the multi-source path
    void Function(XmltvProgress)? onProgress,
  }) async {
    final settings = await SettingsService.getSettings();
    final url = epgUrl ?? resolveEpgUrl(source);
    if (source.id == null) return null;
    if (url == null) {
      AppLog.warn('EPG: skipping "${source.name}" — no EPG URL configured');
      return null;
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final windowStart = now - settings.epgPastDays * 86400;
    final windowEnd = now + settings.epgForecastDays * 86400;

    int inserted = 0;
    AppLog.info('EPG: downloading "${source.name}" — $url');
    // fix695: load the previous HTTP validators + body hash (conditional GET /
    // hash-skip) and the set of xmltv channel-ids we currently carry (parse
    // filter). The validator blob lives in app_meta (db.sqlite) keyed by source.
    final valKey = 'epg_val_${source.id}';
    String? priorEtag, priorLastModified, priorHash;
    try {
      final raw = await Sql.getAppMeta(valKey);
      if (raw != null) {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        priorEtag = m['etag'] as String?;
        priorLastModified = m['lastModified'] as String?;
        priorHash = m['hash'] as String?;
      }
    } catch (_) {/* corrupt blob → treat as no validators */}
    final boundEpgIds = await Sql.getBoundEpgIds(source.id!);
    try {
      // unique index on (source_id, epg_channel_id, start_utc) turns the
      // batch insert into an upsert so a mid-stream failure leaves the
      // previous EPG intact instead of emptying the table.
      final result = await XmltvParser.parse(
        url: url,
        sourceId: source.id!,
        windowStartEpoch: windowStart,
        windowEndEpoch: windowEnd,
        priorEtag: priorEtag,
        priorLastModified: priorLastModified,
        priorHash: priorHash,
        boundEpgIds: boundEpgIds,
        onBatch: (batch) async {
          await Sql.insertProgramsBatch(batch);
          inserted += batch.length;
        },
        onProgress: onProgress,
      );

      // fix695: persist the new validators for the next conditional request
      // (do this whether or not the body changed — a 304/hash-skip can still
      // carry a refreshed etag/last-modified).
      await Sql.setAppMeta(
          valKey,
          jsonEncode({
            'etag': result.etag,
            'lastModified': result.lastModified,
            'hash': result.bodyHash,
          }));

      // fix695: feed unchanged (304 or identical body) — nothing was inserted;
      // keep existing programmes + matches, mark the source cleanly refreshed
      // (so the launch-refresh debounce, finding 37, counts it), and skip the
      // delete/FTS-rebuild/checkpoint/match tail entirely. Returning null makes
      // the caller skip matchChannels (existing assignments stand).
      if (result.notModified) {
        AppLog.info('EPG: "${source.name}" unchanged — skipped parse/insert'
            ' (saved the write+checkpoint+match tail)');
        await Sql.upsertEpgRefreshLog(source.id!, 0, null);
        return null;
      }
      final channelMap = result.channelMap;

      // Force a WAL checkpoint before returning to the caller. Without
      // this, SQLite's automatic PASSIVE checkpoint runs concurrently
      // with the user's first searches after EPG completes. For a large
      // source (100k+ programs → ~100MB WAL), this checkpoint takes
      // 90–150 seconds on phone flash and blocks every read query during
      //
      // Running the checkpoint here while the progress dialog is still
      // visible hides the cost entirely.
      // explicit flush covers both the fresh inserts and the stale deletes.
      // Previously deleteStalePrograms ran after the checkpoint, creating a
      // fresh WAL that could reintroduce an auto-checkpoint stall on the
      // next UI read. Order: insert → delete stale → show progress → checkpoint.
      // finding 46: on a truncated (stalled) feed, do NOT delete stale
      // programmes — the partial download would otherwise drop still-valid rows.
      if (!result.truncated) {
        await Sql.deleteStalePrograms(source.id!, windowStart);
      }

      // fix502: rebuild the programme-title FTS index once after the batch
      // refresh (trigger-free design — no per-row cost on the bulk insert).
      // finding 36: skipped in the multi-source path — hoisted to
      // refreshAllSources so a multi-source refresh pays the global rebuild once.
      if (rebuildFts) {
        await Sql.rebuildProgrammesFts();
      }

      onProgress?.call(XmltvProgress(
        programsInserted: inserted,
        statusMessage: 'Optimising database…',
      ));
      // fix615: this path wrote epg.sqlite (TRUNCATE is correct and cheap — the
      // log showed 8ms). db.sqlite was NOT written here; downgrade its
      // checkpoint to PASSIVE so a large stale sources-refresh WAL is never
      // hard-TRUNCATEd mid-EPG-refresh (the sms938u crash site).
      await Sql.checkpointAndTruncateWal(dbMode: WalCheckpointMode.passive);

      AppLog.info('EPG: downloaded "${source.name}" — $inserted programs'
          '${result.truncated ? " (partial/timeout)" : ""}');
      // finding 46: record a partial refresh with an error tag so it is NOT
      // counted as a clean success by the launch-refresh debounce (finding 37).
      await Sql.upsertEpgRefreshLog(
          source.id!, inserted, result.truncated ? 'partial/timeout' : null);
      return channelMap;
    } catch (e, st) {
      AppLog.error('EPG: download failed for "${source.name}": $e\n$st');
      await Sql.upsertEpgRefreshLog(source.id!, 0, e.toString());
      return null;
    }
  }

  /// Step 2 — Match channels against the EPG channel map.
  ///
  /// By default (incremental mode) only channels with no existing
  /// [Channel.epgChannelId] are processed — already-matched channels are
  /// skipped entirely, making background refreshes much faster on sources
  /// with large channel lists (e.g. 90k+ channels).
  ///
  /// Pass [forceAll] = true to re-evaluate every channel regardless of
  /// existing assignments (used by the "Re-match all channels" button in
  /// Settings or after the matcher algorithm is updated).
  ///
  /// Manual-override channels ([Channel.epgManualOverride] IS NOT NULL) are
  /// excluded by the feeder queries, so they are never re-matched (their
  /// existing assignment is left untouched).
  static Future<void> matchChannels(
    Source source,
    Map<String, String> channelMap, {
    bool forceAll = false,
    void Function(XmltvProgress)? onProgress,
  }) async {
    if (source.id == null) return;

    // Review finding 131: stream keyset pages instead of materializing an
    // entire source's live rows (SELECT *) into one list — bounds peak Dart
    // heap to one page (+ the shared channelMap) on 100k+-channel sources.
    // Page size == _pageSize; within each page the existing isolate batching
    // applies unchanged. Total is pre-counted for the progress message.
    const pageSize = 5000;

    // finding 44: the old manual-override map + loop here were dead — both
    // feeders exclude override rows (forceAll filters epgManualOverride==null;
    // getChannelsNeedingEpgMatch requires epg_manual_override IS NULL), so
    // toMatch never contains one and the map was always empty. Overrides are
    // preserved simply by not being re-matched (their epg_channel_id is left
    // untouched).
    var totalToMatch = 0;
    final allMatched = <int, String>{};
    final tierCounts = <MatchTier, int>{};
    final sampleUnmatched = <String>[];
    var matchedSoFar = 0;
    var afterId = 0;
    var firstPage = true;

    // finding 41: build the EPG inverted index ONCE up front instead of
    // rebuilding byNormalizedName/byStrippedId/epgNorms/epgTokens/tokenIndex
    // (and deep-copying the whole channelMap across an isolate boundary) for
    // every 2000-channel batch. The old `compute(_matchInIsolate, ...)` per
    // batch was O(batches × |EPG map|). Main-isolate fallback per spec: match
    // work now runs on the UI isolate against the prebuilt index. Acceptable
    // on a 2GB TV box with modal-refresh D-pad UX (no scroll-jank concern).
    final epgIndex = EpgMatcher.buildIndex(channelMap);

    while (true) {
      var page = forceAll
          ? (await Sql.getChannelsForEpgMatchingPage(source.id!,
                  afterId: afterId, limit: pageSize))
              .where((c) => c.epgManualOverride == null)
              .toList()
          : await Sql.getChannelsNeedingEpgMatchPage(source.id!,
              afterId: afterId, limit: pageSize);
      if (firstPage) {
        firstPage = false;
        AppLog.info(
          'EPG: matching (paged, pageSize=$pageSize)'
          ' (${forceAll ? "full re-match" : "unmatched only"})'
          ' for "${source.name}"'
          ' channelMap=${channelMap.length}',
        );
        if (page.isEmpty) {
          AppLog.info('EPG: no unmatched channels — skipping matcher');
          onProgress?.call(XmltvProgress(
            programsInserted: 0,
            matchingChannelsDone: 0,
            matchingChannelsTotal: 0,
            statusMessage: 'All channels already matched',
          ));
          return;
        }
      }
      if (page.isEmpty) break;
      // Keyset cursor: the paged queries ORDER BY id ASC, so the last row's id
      // is the next cursor even after the override filter above.
      final lastId = page.last.id;
      totalToMatch += page.length;

      for (int i = 0; i < page.length; i += _matchBatchSize) {
        final end = min(i + _matchBatchSize, page.length);
        final batch = page.sublist(i, end);

        // finding 41: match against the once-built index (was compute()).
        final (batchMatched, batchReport) =
            EpgMatcher.matchAgainst(epgIndex, batch);

        allMatched.addAll(batchMatched);
        for (final e in batchReport.counts.entries) {
          tierCounts[e.key] = (tierCounts[e.key] ?? 0) + e.value;
        }
        if (sampleUnmatched.length < 10) {
          sampleUnmatched.addAll(
            batchReport.sampleUnmatched.take(10 - sampleUnmatched.length),
          );
        }

        matchedSoFar = totalToMatch - (page.length - end);
        onProgress?.call(XmltvProgress(
          programsInserted: 0,
          matchingChannelsDone: matchedSoFar,
          matchingChannelsTotal: totalToMatch,
          statusMessage: 'Matching channels: $matchedSoFar…',
        ));
      }
      if (page.length < pageSize || lastId == null) break;
      afterId = lastId;
    }

    // finding 44: merged == matched (no overrides in toMatch, see above).
    final merged = allMatched;
    AppLog.info('EPG: matchChannels write: merged=${merged.length}');
    if (merged.isNotEmpty) {
      await Sql.setChannelEpgIds(merged);
      // fix615: this wrote db.sqlite (channel epg_id mapping), so db.sqlite is
      // the legitimate target; epg.sqlite was not written here. The mapping is
      // a small write, so TRUNCATE is fine.
      await Sql.checkpointAndTruncateWal(epg: false);
    }

    final report = MatchReport(
      counts: tierCounts,
      sampleUnmatched: sampleUnmatched,
      totalChannels: totalToMatch,
    );
    AppLog.info('EPG: match done "${source.name}" — $report');
    if (report.sampleUnmatched.isNotEmpty) {
      AppLog.info(
        'EPG: sample unmatched — '
        '${report.sampleUnmatched.map((n) => '"$n"').join(", ")}',
      );
    }
  }

  // fix709: serialize the channel-MATCH phase across concurrently-refreshing
  // sources. refreshAllSources runs sources maxConcurrent=2, and each
  // refreshSource does download → match. Two matchChannels running at once
  // collide on db.sqlite: setChannelEpgIds + the WAL **TRUNCATE** checkpoint
  // (matchChannels line ~517 — TRUNCATE needs an EXCLUSIVE lock). The
  // SQLITE_BUSY retries (5×, ~5s) exhaust under sustained contention →
  // matchChannels throws → the per-source catch in refreshAllSources swallows
  // it → that source's channels are left silently UNMATCHED (the "guide empty
  // on every channel" bug; a single-source refresh has no concurrency and
  // matched 35851/35851). The DOWNLOAD phase stays parallel — it is already
  // contention-tolerant (epg.sqlite writes retry; its db.sqlite checkpoint is
  // PASSIVE, line 378). Only the match (db.sqlite TRUNCATE) must serialize.
  //
  // In-isolate mutex: a chained-Future gate. This covers the maxConcurrent=2
  // concurrency, which lives WITHIN one refreshAllSources call in one isolate.
  // Cross-isolate (foreground vs Workmanager background) is separately guarded
  // by the app_meta refresh lock + the SQLITE_BUSY retries. The gate never
  // completes with an error (finally), so awaiting it can't throw or wedge.
  static Future<void> _matchGate = Future<void>.value();

  static Future<void> _serializeMatch(Future<void> Function() body) async {
    final prev = _matchGate;
    final done = Completer<void>();
    _matchGate = done.future;
    await prev; // wait for any in-flight match to finish (prev never errors)
    try {
      await body();
    } finally {
      done.complete();
    }
  }

  /// Combined refresh (download + incremental match).
  ///
  /// Pass [forceRematch] = true to re-match every channel, not just
  /// unmatched ones (e.g. after an EPG feed change or matcher update).
  static Future<void> refreshSource(
    Source source, {
    String? epgUrl,
    bool background = false,
    bool forceRematch = false,
    bool rebuildFts = true, // finding 36: false from the multi-source path
    void Function(XmltvProgress)? onProgress,
  }) async {
    final channelMap = await downloadAndParseEpg(
      source,
      epgUrl: epgUrl,
      rebuildFts: rebuildFts,
      onProgress: onProgress,
    );
    if (channelMap == null) return;
    // fix709: serialize the match so two concurrently-refreshing sources can't
    // collide on the db.sqlite writer + TRUNCATE checkpoint (the SQLITE_BUSY-→
    // silently-unmatched bug). Downloads above already ran in parallel.
    await _serializeMatch(() => matchChannels(
          source,
          channelMap,
          forceAll: forceRematch,
          onProgress: onProgress,
        ));
    epgVersion.value++; // fix600: notify listeners (guide) to reflect new EPG
    // finding 38: bridge the per-isolate epgVersion gap. The in-process bump
    // above only reaches listeners in THIS isolate; a Workmanager background
    // refresh (or a direct single-source refresh) must also leave a durable
    // cross-isolate signal. Persist a completion timestamp in app_meta
    // (db.sqlite) that the main isolate polls on resume/startup and, if it
    // advanced, bumps its own epgVersion so TvGuideView reloads. Harmless in
    // the foreground path (the ValueNotifier already fired). refreshAllSources
    // also writes this once after its loop; a per-source write here keeps the
    // signal correct for direct refreshSource callers (settings/setup).
    await Sql.setAppMeta(
      'epg_last_completed_utc',
      (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
    );
  }

  /// Determines the EPG URL to use for a source:
  /// - Manual override (source.epgUrl) wins
  /// - Xtream sources fall back to their built-in XMLTV endpoint
  /// - M3U sources have no automatic EPG URL
  static String? resolveEpgUrl(Source source) {
    if (source.epgUrl != null && source.epgUrl!.isNotEmpty) {
      return source.epgUrl;
    }
    if (source.sourceType == SourceType.xtream) {
      return XtreamEpg.xmltvUrl(source);
    }
    return null;
  }

  /// Computes how long to wait until the next occurrence of [targetHour] (local time).
  static Duration _delayUntilRefreshHour(int targetHour) {
    final now = DateTime.now();
    var next = DateTime(now.year, now.month, now.day, targetHour);
    if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
    return next.difference(now);
  }
}
