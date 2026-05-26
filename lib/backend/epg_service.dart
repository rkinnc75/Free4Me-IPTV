import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/epg_matcher.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/xmltv_parser.dart';
import 'package:open_tv/backend/xtream_epg.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:workmanager/workmanager.dart';

// Top-level function required by compute() — closures are not allowed.
// Matches a single batch of channels against the full EPG map in an isolate.
(Map<int, String>, MatchReport) _matchInIsolate(
  (Map<String, String>, List<Channel>) args,
) =>
    EpgMatcher.matchWithReport(args.$1, args.$2);

// How many channels to process per isolate invocation. `compute()` spawns a
// fresh isolate AND deep-copies the channelMap across the boundary for every
// call, so larger batches mean fewer spawns and fewer Map copies. At 2000,
// a 90k-channel source produces ~45 batches — still plenty of progress
// granularity for the UI.
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
  /// Sources run in chunks of [maxConcurrent] (default 2) so two providers
  /// can download in parallel — HTTP fetches don't fight each other and the
  /// SQLite writer naturally serializes the DB-write phase. Matches the
  /// `Utils.refreshAllSources` cadence so we don't surprise providers with
  /// burst traffic.
  static Future<void> refreshAllSources({bool background = false}) async {
    final eligible = (await Sql.getSources())
        .where((s) => s.enabled && resolveEpgUrl(s) != null)
        .toList(growable: false);
    const maxConcurrent = 2;
    for (var i = 0; i < eligible.length; i += maxConcurrent) {
      final end = i + maxConcurrent > eligible.length
          ? eligible.length
          : i + maxConcurrent;
      final chunk = eligible.sublist(i, end);
      await Future.wait(chunk.map(
        (s) => refreshSource(
          s,
          epgUrl: resolveEpgUrl(s),
          background: background,
        ),
      ));
    }
  }

  /// Step 1 — Download and parse XMLTV, insert programs.
  /// Returns the EPG channel map (epgId → display names) for use in
  /// [matchChannels], or null if the source has no EPG URL or an error occurs.
  static Future<Map<String, String>?> downloadAndParseEpg(
    Source source, {
    String? epgUrl,
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
    try {
      // Idempotent insert path (fix29.5): no upfront wipe. The schema-v8
      // unique index on (source_id, epg_channel_id, start_utc) turns the
      // batch insert into an upsert so a mid-stream failure leaves the
      // previous EPG intact instead of emptying the table.
      final channelMap = await XmltvParser.parse(
        url: url,
        sourceId: source.id!,
        windowStartEpoch: windowStart,
        windowEndEpoch: windowEnd,
        onBatch: (batch) async {
          await Sql.insertProgramsBatch(batch);
          inserted += batch.length;
        },
        onProgress: onProgress,
      );

      // Force a WAL checkpoint before returning to the caller. Without
      // this, SQLite's automatic PASSIVE checkpoint runs concurrently
      // with the user's first searches after EPG completes. For a large
      // source (100k+ programs → ~100MB WAL), this checkpoint takes
      // 90–150 seconds on phone flash and blocks every read query during
      // that time (see fix52.md, free4me_log_1779765900144.txt).
      //
      // Running the checkpoint here while the progress dialog is still
      // visible hides the cost entirely.
      onProgress?.call(XmltvProgress(
        programsInserted: inserted,
        statusMessage: 'Optimising database…',
      ));
      await Sql.checkpointAndTruncateWal();

      // GC rows whose stop time is before the configured window so the
      // table stays bounded across refreshes.
      await Sql.deleteStalePrograms(source.id!, windowStart);

      AppLog.info(
          'EPG: downloaded "${source.name}" — $inserted programs');
      await Sql.upsertEpgRefreshLog(source.id!, inserted, null);
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
  /// Manual overrides ([Channel.epgManualOverride] IS NOT NULL) are always
  /// preserved and never re-matched.
  static Future<void> matchChannels(
    Source source,
    Map<String, String> channelMap, {
    bool forceAll = false,
    void Function(XmltvProgress)? onProgress,
  }) async {
    if (source.id == null) return;

    final toMatch = forceAll
        ? (await Sql.getChannelsForEpgMatching(source.id!))
              .where((c) => c.epgManualOverride == null)
              .toList()
        : await Sql.getChannelsNeedingEpgMatch(source.id!);

    final manualOverrides = <int, String>{};
    for (final ch in toMatch) {
      if (ch.epgManualOverride != null && ch.id != null) {
        manualOverrides[ch.id!] = ch.epgManualOverride!;
      }
    }

    AppLog.info(
      'EPG: matching ${toMatch.length} channels'
      ' (${forceAll ? "full re-match" : "unmatched only"})'
      ' for "${source.name}"'
      ' channelMap=${channelMap.length}'
      ' manualOverrides=${manualOverrides.length}',
    );

    if (toMatch.isEmpty) {
      AppLog.info('EPG: no unmatched channels — skipping matcher');
      onProgress?.call(XmltvProgress(
        programsInserted: 0,
        matchingChannelsDone: 0,
        matchingChannelsTotal: 0,
        statusMessage: 'All channels already matched',
      ));
      return;
    }

    final allMatched = <int, String>{};
    final tierCounts = <MatchTier, int>{};
    final sampleUnmatched = <String>[];

    for (int i = 0; i < toMatch.length; i += _matchBatchSize) {
      final end = min(i + _matchBatchSize, toMatch.length);
      final batch = toMatch.sublist(i, end);

      final (batchMatched, batchReport) =
          await compute(_matchInIsolate, (channelMap, batch));

      allMatched.addAll(batchMatched);
      for (final e in batchReport.counts.entries) {
        tierCounts[e.key] = (tierCounts[e.key] ?? 0) + e.value;
      }
      if (sampleUnmatched.length < 10) {
        sampleUnmatched.addAll(
          batchReport.sampleUnmatched.take(10 - sampleUnmatched.length),
        );
      }

      onProgress?.call(XmltvProgress(
        programsInserted: 0,
        matchingChannelsDone: end,
        matchingChannelsTotal: toMatch.length,
        statusMessage: 'Matching channels: $end / ${toMatch.length}',
      ));
    }

    final merged = {...allMatched, ...manualOverrides};
    AppLog.info(
      'EPG: matchChannels write: merged=${merged.length}'
      ' (matched=${allMatched.length}'
      ' + manualOverrides=${manualOverrides.length})',
    );
    if (merged.isNotEmpty) {
      await Sql.setChannelEpgIds(merged);
      // Checkpoint the WAL after writing EPG assignments. Each UPDATE
      // triggers the channels_au FTS trigger (delete + insert on
      // channels_fts), so 14k assignments = ~42k WAL writes. Without
      // this checkpoint the WAL blocks all search reads for 60–130s
      // after matchChannels returns (same root cause as the programme
      // insert — see fix52.md). The progress dialog is still showing
      // at this point so the user doesn't see the flush time.
      await Sql.checkpointAndTruncateWal();
    }

    final report = MatchReport(
      counts: tierCounts,
      sampleUnmatched: sampleUnmatched,
      totalChannels: toMatch.length,
    );
    AppLog.info('EPG: match done "${source.name}" — $report');
    if (report.sampleUnmatched.isNotEmpty) {
      AppLog.info(
        'EPG: sample unmatched — '
        '${report.sampleUnmatched.map((n) => '"$n"').join(", ")}',
      );
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
    void Function(XmltvProgress)? onProgress,
  }) async {
    final channelMap = await downloadAndParseEpg(
      source,
      epgUrl: epgUrl,
      onProgress: onProgress,
    );
    if (channelMap == null) return;
    await matchChannels(
      source,
      channelMap,
      forceAll: forceRematch,
      onProgress: onProgress,
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
