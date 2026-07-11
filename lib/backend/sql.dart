import 'dart:collection';
import 'dart:convert';

import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/browse_order.dart';
import 'package:open_tv/backend/visibility_clause.dart';
import 'package:open_tv/backend/group_search_gate.dart';
import 'package:open_tv/backend/playback_analyzer.dart';
import 'package:open_tv/backend/channel_search_cache.dart';
import 'package:open_tv/backend/db_factory.dart';
import 'package:open_tv/memory.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/recording.dart';
import 'package:open_tv/models/channel_http_headers.dart';
import 'package:open_tv/models/channel_preserve.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/id_data.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/program.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:sqlite_async/sqlite3.dart';
import 'package:sqlite_async/sqlite_async.dart';

const int pageSize = 36;
const int importBatchSize = 500;
// fix174.3: bulk insert binds 13 params/row; 60×13=780 < 999 (safe on all engines)
// fix194: 60 -> 1000. Each bulk INSERT carries 1000 rows = 13,000 params,
// well under SQLite's SQLITE_MAX_VARIABLE_NUMBER (32,766). Cuts a ~271k-row
// Xtream refresh from ~4,516 INSERT statements to ~271, the dominant cost
// of the wipe-then-reinsert window. Verified via seeded 1000-row upsert test.
const int bulkInsertRows = 1000;

/// fix615: WAL checkpoint mode for [Sql.checkpointAndTruncateWal].
/// - [truncate] flushes the entire WAL to the main DB and shrinks the WAL file
///   to zero; it waits for readers and does a synchronous fsync (the heavy,
///   blocking variant).
/// - [passive] flushes whatever it can without blocking on readers and does
///   NOT shrink the file; far cheaper, no synchronous spike.
enum WalCheckpointMode { passive, truncate }

class Sql {
  static Future<void> commitWrite(
      List<Future<void> Function(SqliteWriteContext, Map<String, String>)>
          commits,
      {Map<String, String>? memory,
      void Function(int closureIndex, int millis)? onClosureTimed}) async {
    if (commits.isEmpty) return;
    var db = await DbFactory.db;
    final shared = memory ?? <String, String>{};
    await db.writeTransaction((tx) async {
      var idx = 0;
      for (var commit in commits) {
        if (onClosureTimed != null) {
          // fix222: time each closure to locate the on-device slow phase.
          final sw = Stopwatch()..start();
          await commit(tx, shared);
          sw.stop();
          onClosureTimed(idx, sw.elapsedMilliseconds);
        } else {
          await commit(tx, shared);
        }
        idx++;
      }
    });
  }

  /// Large imports (M3U/Xtream) — same [memory] across batches so sourceId persists.
  static Future<void> commitWriteBatched(
    List<Future<void> Function(SqliteWriteContext, Map<String, String>)>
        commits, {
    int batchSize = importBatchSize,
    Map<String, String>? memory,
    void Function(int committedClosures)? onBatchCommitted,
    bool Function()? shouldCancel,
  }) async {
    if (commits.isEmpty) return;
    final shared = memory ?? <String, String>{};
    // fix222: per-closure timing inside the single write transaction, to locate
    // the on-device refresh slowness. The exact SQL runs in ~5s in the real
    // sqlite_async package on a file DB, but the device takes minutes — so the
    // cost is closure/round-trip level, not the query logic. Logs every closure
    // slower than 100ms plus a per-run summary. Logging only; no behavior change.
    // (Over-instrumented on purpose for diagnosis; trim later.)
    final swTotal = Stopwatch()..start();
    var batchIndex = 0;
    var slowCount = 0;
    for (var i = 0; i < commits.length; i += batchSize) {
      // Review finding 143: cooperative cancel BETWEEN transactions only —
      // each commitWrite is its own transaction, so breaking here can never
      // leave a half-written batch. A partial-source write is recoverable
      // because the next refresh wipes+reinserts the source.
      if (shouldCancel?.call() ?? false) {
        AppLog.info(
            'Sql.commitWriteBatched: cancelled after $batchIndex batch(es)');
        break;
      }
      final end = (i + batchSize < commits.length) ? i + batchSize : commits.length;
      final swBatch = Stopwatch()..start();
      await commitWrite(commits.sublist(i, end), memory: shared,
          onClosureTimed: (idx, ms) {
        if (ms >= 100) {
          slowCount++;
          AppLog.info('Sql.commitWriteBatched: closure ${i + idx} '
              'took ${ms}ms');
        }
      });
      swBatch.stop();
      AppLog.info('Sql.commitWriteBatched: batch $batchIndex '
          'closures=${end - i} (through $end/${commits.length}) '
          'took ${swBatch.elapsedMilliseconds}ms');
      batchIndex++;
      onBatchCommitted?.call(end);
    }
    swTotal.stop();
    AppLog.info('Sql.commitWriteBatched: DONE ${commits.length} closures '
        'in $batchIndex batches, total ${swTotal.elapsedMilliseconds}ms '
        '($slowCount closures >=100ms, bulkInsertRows=$bulkInsertRows, '
        'batchSize=$batchSize)');
  }

  /// fix222: one-shot diagnostic. Logs EXPLAIN QUERY PLAN for the two
  /// index-sensitive refresh statements (the per-row restorePreserve UPDATE and
  /// the updateGroups UPDATE+correlated-subquery) so the log shows whether they
  /// use an index or do a table scan ON-DEVICE. Called once per refresh, NOT
  /// per row — does not affect timing. SQLite has EXPLAIN QUERY PLAN (index
  /// usage) but not EXPLAIN ANALYZE. Logging only.
  static Future<void> logRefreshQueryPlans(int sourceId) async {
    final db = await DbFactory.db;
    Future<void> plan(String label, String sql, List<Object?> params) async {
      try {
        final rows = await db.getAll('EXPLAIN QUERY PLAN $sql', params);
        final detail = rows.map((r) => r['detail']).join(' | ');
        AppLog.info('fix222 QUERYPLAN [$label]: $detail');
      } catch (e) {
        AppLog.warn('fix222 QUERYPLAN [$label] failed: $e');
      }
    }

    await plan(
      'restorePreserve.update',
      'UPDATE channels SET favorite = ?, last_watched = ?, '
          'epg_channel_id = COALESCE(epg_channel_id, ?), '
          'epg_manual_override = NULL, '
          'stream_validated = COALESCE(?, stream_validated) '
          'WHERE name = ? AND source_id = ?',
      [0, null, null, null, '__plan_probe__', sourceId],
    );
    await plan(
      'updateGroups.update',
      'UPDATE channels SET group_id = (SELECT id FROM groups '
          'WHERE groups.name = channels.group_name '
          'AND groups.source_id = ? LIMIT 1) WHERE source_id = ?',
      [sourceId, sourceId],
    );
    await plan(
      'updateGroups.insertSelect',
      'SELECT group_name, image, media_type FROM channels '
          'WHERE source_id = ? GROUP BY group_name',
      [sourceId],
    );
  }

  static Future<void> Function(SqliteWriteContext, Map<String, String> memory)
      insertChannel(Channel channel) {
    return (SqliteWriteContext tx, Map<String, String> memory) async {
      await tx.execute('''
        INSERT INTO channels (
          name, image, url, source_id, media_type, series_id, favorite,
          stream_id, group_name, epg_channel_id,
          catchup_type, catchup_source, catchup_days, provider_order, is_divider,
          is_adult
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT DO UPDATE SET
          url = excluded.url,
          group_name = excluded.group_name,
          media_type = excluded.media_type,
          stream_id = excluded.stream_id,
          image = excluded.image,
          series_id = excluded.series_id,
          -- preserve any user-set epg_channel_id; only fill when the new
          -- import carries one and we have nothing stored yet
          epg_channel_id = COALESCE(channels.epg_channel_id, excluded.epg_channel_id),
          catchup_type = excluded.catchup_type,
          catchup_source = excluded.catchup_source,
          catchup_days = excluded.catchup_days,
          provider_order = excluded.provider_order,
          is_divider = excluded.is_divider,
          is_adult = excluded.is_adult
          -- engine_override column deprecated (fix350), never written
          ;
      ''', [
        channel.name,
        channel.image,
        channel.url,
        channel.sourceId == -1
            ? int.parse(memory['sourceId']!)
            : channel.sourceId,
        channel.mediaType.index,
        channel.seriesId,
        channel.favorite,
        channel.streamId,
        channel.group,
        channel.epgChannelId,
        channel.catchupType,
        channel.catchupSource,
        channel.catchupDays,
        channel.providerOrder,
        channel.isDivider ? 1 : 0,
        channel.isAdult ? 1 : 0,
      ]);
      memory['lastChannelId'] =
          (await tx.get("SELECT last_insert_rowid()")).columnAt(0).toString();
    };
  }

  /// fix212: the FTS index/triggers are only needed for the FTS search methods
  /// (ftsPhrase/ftsAnd). When the active method is inMemory or likeSubstring,
  /// the per-row FTS index maintenance during a refresh is pure overhead.
  /// This reconciles the trigger state to [ftsActive]:
  ///   - ftsActive=false: drop the FTS sync triggers (inserts stay fast).
  ///   - ftsActive=true : (re)create the triggers; if they were absent, the FTS
  ///     index is stale, so rebuild it once from the content table first.
  /// Called from a one-time boot check (main) and on every settings change
  /// (SettingsService.updateSettings). Idempotent.
  /// fix361/Issue4: run [body] with the FTS sync triggers suspended, then
  /// rebuild the FTS index ONCE. A large source refresh (Dino ~148K rows on
  /// the onn 4K: DELETE 26s, commit 60s) fires channels_ad/channels_ai per
  /// row when an FTS search method is active — ~300K trigger executions of
  /// FTS trigram maintenance. Dropping the triggers around the bulk DELETE +
  /// reinsert and rebuilding once collapses that to a single index build.
  ///
  /// fix514: [refreshedSourceId], when provided, additionally lets the
  /// resync use a TARGETED re-index (this source's rows only) instead of a
  /// full-catalog 'rebuild' — see runbook for the measured ~110s case this
  /// fixes (a single 39.5K-row source refresh paying to re-tokenize a 1M+
  /// row combined catalog). A global rebuild's cost scales with TOTAL
  /// catalog size, not refreshed-source size, so targeted wins when the
  /// source is both small in absolute terms AND a small slice of the
  /// catalog (see [_ftsTargetedMaxRows] / [_ftsTargetedMaxFraction]).
  ///
  /// DELIBERATELY CONSERVATIVE THRESHOLD: a fraction-only threshold isn't
  /// sufficient — measured against a real 5-source-load log (4 sources,
  /// 149K-452K rows each, combined catalog up to ~1.17M), a source at 38.6%
  /// of the catalog (451,728 absolute rows) still lost to global rebuild
  /// despite being comfortably under a 50% fraction cap, because targeted's
  /// cost is dominated by two full passes over the source's OWN absolute
  /// row count, not just its share of the total. Sandbox timing past ~100K
  /// rows was too noisy to derive a precise combined formula, so this uses
  /// BOTH an absolute cap and a fraction cap (source must be small on BOTH
  /// axes) rather than risk picking the slower path on an unvalidated case.
  /// Everything outside the validated small-source zone falls back to the
  /// known-safe global rebuild.
  ///
  /// CORRECTNESS-CRITICAL ORDERING: external-content FTS5 can only remove an
  /// index entry while the content table (`channels`) still holds that row —
  /// once the row is gone, `DELETE FROM channels_fts WHERE rowid=?` is a
  /// silent no-op (confirmed empirically; this is NOT documented intuitively
  /// and bit the first draft of this fix). So the targeted delete MUST run
  /// BEFORE [body] (the wipe+reinsert) starts, while the old rows are still
  /// readable; the targeted insert of the NEW rows runs AFTER [body]
  /// completes. The delete also MUST use a materialized id list, not a live
  /// correlated subquery against the content table in the same statement
  /// (`WHERE rowid IN (SELECT id FROM channels WHERE...)`) — that form was
  /// separately measured to silently delete nothing despite reporting a
  /// non-zero affected-row count. Chunked at 900 ids/statement (SQLite's 999
  /// bind-parameter limit, same convention used elsewhere in this file).
  ///
  /// No-op for non-FTS users: their triggers are already absent (fix212), so
  /// [hadTriggers] is false and we neither drop nor rebuild — body runs as-is.
  /// Safe if [body] throws: the finally clause restores triggers + rebuild so
  /// search is never left stale (falls back to global rebuild on the error
  /// path regardless of [refreshedSourceId] — the targeted insert assumes
  /// [body] completed and `channels` reflects the new state, which may not
  /// hold if it threw partway through).
  static Future<void> withSuspendedFtsTriggers(
      Future<void> Function() body,
      {int? refreshedSourceId,
      // fix614: when supplied AND [body] succeeds, this replaces the global
      // end-of-batch FTS rebuild. refreshAllSources passes a closure that
      // targeted-reindexes only the sources that actually refreshed — measured
      // ~51s for the full 857K-row catalog vs ~66min for the global rebuild.
      // Ignored on the error path (body threw): a global rebuild is still the
      // only safe recovery when `channels` may be half-written. Also ignored
      // when this is a pass-through inner call (triggers already suspended) or
      // when a single-source targeted path (refreshedSourceId) already applies.
      Future<void> Function()? batchTargetedRebuild}) async {
    final db = await DbFactory.db;
    final existing = await db.getAll(
      "SELECT name FROM sqlite_master WHERE type = 'trigger' "
      "AND name IN ('channels_ai', 'channels_au', 'channels_ad')",
    );
    final hadTriggers = existing.length == 3;
    // fix521 + fix619 + fix621: re-entrancy — when an outer batch
    // (refreshAllSources) has already suspended the FTS triggers around the
    // WHOLE loop, this inner per-source call is a PASS-THROUGH.
    //
    // fix614 deferred all FTS work to one end-of-batch reindex whose
    // `DELETE FROM channels_fts` ran AFTER each source's wipe — illegal on an
    // external-content FTS5 table (deleting index rows after the backing
    // content changed corrupts the index: "database disk image is malformed",
    // code 267, sms938u). fix619 moved to per-source delete-before-wipe here,
    // which was correct but CATASTROPHICALLY slow: the chunked
    // `DELETE FROM channels_fts WHERE rowid IN (...)` degraded as segments/
    // tombstones accumulated across the interleaved loop — 78 chunks ramping
    // 1s→140s, ~86 min for Media4u ALONE (and it never even committed) on the
    // onn 4K Plus, 2026-06-30, v2.2.31.
    //
    // fix621: do NO per-source FTS work here. The outer wrapper already
    // suspended the triggers, so body()'s wipe+insert don't touch the index;
    // the index simply goes stale for the duration of the loop and is rebuilt
    // ONCE at end-of-batch via DROP+repopulate (see the batch branch in the
    // finally below) — ~10x faster (~9 min for the whole catalog, onn Run A
    // calibration) and corruption-proof (DROP discards the old shadow tables,
    // so there is no delete-after-content-change window at all).
    if (_ftsTriggersSuspended) {
      await body();
      return;
    }
    var useTargeted = false;
    if (hadTriggers) {
      await db.execute('DROP TRIGGER IF EXISTS channels_ai;');
      await db.execute('DROP TRIGGER IF EXISTS channels_au;');
      await db.execute('DROP TRIGGER IF EXISTS channels_ad;');
      _ftsTriggersSuspended = true;
      if (batchTargetedRebuild != null) {
        // fix621: in a batch refresh the FTS index is stale from the first
        // source's wipe until the end-of-batch rebuild below. Gate FTS-backed
        // search for that ENTIRE window (not just the rebuild) so a query can
        // never hit an inconsistent external-content index. Branch 2 (and the
        // else/error path) clear this flag in their finally.
        ftsRebuilding.value = true;
      }
      if (refreshedSourceId != null) {
        final counts = await db.getAll(
          'SELECT '
          '(SELECT COUNT(*) FROM channels WHERE source_id = ?) AS src, '
          '(SELECT COUNT(*) FROM channels) AS total',
          [refreshedSourceId],
        );
        final src = counts.first['src'] as int;
        final total = counts.first['total'] as int;
        if (total > 0 &&
            src <= _ftsTargetedMaxRows &&
            src / total <= _ftsTargetedMaxFraction) {
          // fix694: integrity-check HERE, not as a refresh-entry pre-flight
          // (fix620's placement). The check exists solely to protect this
          // targeted delete from hanging on a corrupt index — the big-source
          // path never needed it (its finalization now DROP+repopulates, which
          // discards any corruption), yet the old pre-flight cost a measured
          // 10.9s on EVERY refresh (onn, 2026-07-08 baseline). On a malformed
          // index, skip targeted — the finally's full rebuild restores
          // consistency without ever touching the corrupt shadow tables.
          var ftsHealthy = true;
          try {
            await db.execute(
                "INSERT INTO channels_fts(channels_fts) VALUES('integrity-check');");
          } catch (e) {
            if (!isMalformedDbError(e)) rethrow;
            ftsHealthy = false;
            AppLog.warn('Sql.withSuspendedFtsTriggers: FTS integrity-check '
                'failed ($e) — skipping targeted re-index; the end-of-refresh '
                'DROP+repopulate will rebuild it');
          }
          if (!ftsHealthy) {
            // Fall through with useTargeted=false → full rebuild in finally.
          } else {
          // Delete this source's FTS entries NOW, while `channels` still
          // holds them — see the correctness note above. Materialize the id
          // list first; chunk at 900 (SQLite's 999 bind-parameter limit).
          final idRows = await db.getAll(
            'SELECT id FROM channels WHERE source_id = ?',
            [refreshedSourceId],
          );
          final ids = idRows.map((r) => r['id'] as int).toList();
          for (var i = 0; i < ids.length; i += 900) {
            final end = i + 900 > ids.length ? ids.length : i + 900;
            final chunk = ids.sublist(i, end);
            await db.execute(
              'DELETE FROM channels_fts WHERE rowid IN '
              '(${generatePlaceholders(chunk.length)})',
              chunk,
            );
          }
          useTargeted = true;
          }
        }
      }
      AppLog.info('Sql.withSuspendedFtsTriggers: FTS triggers dropped'
          ' for bulk refresh${useTargeted ? " (targeted source=$refreshedSourceId)" : ""}');
    }
    var bodySucceeded = false;
    try {
      await body();
      bodySucceeded = true;
    } finally {
      if (hadTriggers) {
        // fix521: clear the re-entrancy flag before recreating triggers, so the
        // next refresh (or a throw-recovery) starts clean.
        _ftsTriggersSuspended = false;
        if (useTargeted && bodySucceeded) {
          // [body] has now wiped+reinserted this source's rows in `channels`;
          // insert their current state into the FTS index.
          await db.execute(
            'INSERT INTO channels_fts(rowid, name) '
            'SELECT id, name FROM channels WHERE source_id = ?',
            [refreshedSourceId],
          );
          await reconcileFtsTriggers(true, skipRebuild: true);
          AppLog.info('Sql.withSuspendedFtsTriggers: FTS triggers restored'
              ' + targeted re-index (source=$refreshedSourceId)');
        } else if (batchTargetedRebuild != null && bodySucceeded) {
          // fix621: batch refresh succeeded. FTS was NOT touched during the
          // loop (see the pass-through branch above), so the index is fully
          // stale — every source was wiped+reinserted with the triggers
          // suspended. Rebuild it ONCE from the final `channels` state via
          // DROP+repopulate: a single `INSERT ... SELECT` (~9 min on the
          // ~1M-row catalog, onn Run A calibration) vs fix619's ~86-min
          // per-source delete storm, and corruption-proof — DROP discards the
          // old shadow tables, so there is no delete-after-content-change
          // window (fix614's code-267 cause). rebuildFtsTableFromScratch also
          // recreates the sync triggers and clears _ftsTriggersSuspended, so
          // nothing further is needed here. (batchTargetedRebuild stays as the
          // batch success sentinel from refreshAllSources; its closure is a
          // no-op kept for signature stability.)
          // fix611: gate FTS-backed search off for the rebuild's duration.
          ftsRebuilding.value = true;
          try {
            // fix642: routine end-of-batch rebuild (index was intentionally
            // stale — triggers suspended for the whole batch), NOT corruption.
            // Pass a reason so it logs at INFO instead of the malformed WARN.
            await rebuildFtsTableFromScratch(
                reason: 'routine end-of-batch repopulate (fix621)');
          } finally {
            ftsRebuilding.value = false;
          }
          AppLog.info('Sql.withSuspendedFtsTriggers: FTS index rebuilt once '
              'end-of-batch via DROP+repopulate (fix621)');
        } else {
          // Either targeted wasn't applicable (large source / large
          // fraction / no sourceId given / corrupt index), or body() threw
          // before finishing its wipe+reinsert — in the latter case a
          // targeted delete may have already removed this source's OLD
          // entries with nothing reinserted yet, so a full rebuild is the
          // only safe way to leave search consistent.
          // fix694: rebuild via DROP+repopulate, NOT the fts5 'rebuild'
          // command that reconcileFtsTriggers(true) issues. Both produce an
          // identical fresh index, but on the onn baseline (2026-07-08,
          // 1.16M rows) 'rebuild' took 231s while DROP+repopulate takes
          // ~42s — 'rebuild' re-tokenizes INTO the existing segment
          // structure (merge/tombstone overhead), DROP discards the shadow
          // tables and repopulates clean. This is the same path fix621 uses
          // at end-of-batch and fix619/620 use for self-heal; it also
          // recreates the sync triggers byte-identical.
          // fix611: gate FTS-backed search off for the rebuild's duration;
          // ALWAYS clear the flag so a throw never strands search disabled.
          ftsRebuilding.value = true;
          try {
            await rebuildFtsTableFromScratch(
                reason: bodySucceeded
                    ? 'large-source refresh repopulate (fix694)'
                    : 'refresh failed mid-body — restore consistent index');
          } finally {
            ftsRebuilding.value = false;
          }
          AppLog.info('Sql.withSuspendedFtsTriggers: FTS triggers restored'
              ' + index rebuilt via DROP+repopulate (fix694)');
        }
      }
    }
  }

  /// fix514: deliberately conservative dual threshold (see the long comment
  /// above) — targeted re-index is ONLY used when the refreshed source is
  /// small on BOTH axes. A source must clear both caps; failing either one
  /// falls back to the always-safe global rebuild. 50,000 rows is comfortably
  /// inside the cleanly-validated "targeted wins big" zone (the A3000 case
  /// that motivated this fix was 39,515 rows); 20% keeps the fraction check
  /// tight enough that even a small-catalog scenario doesn't accidentally
  /// route a meaningfully-sized source through the unvalidated middle zone.
  static const int _ftsTargetedMaxRows = 50000;
  static const double _ftsTargetedMaxFraction = 0.2;

  /// fix521: re-entrancy guard for the deferred FTS rebuild — set true by the
  /// OUTER withSuspendedFtsTriggers (refreshAllSources wrapping the whole loop)
  /// so inner per-source calls pass through and the FTS index rebuilds ONCE at
  /// the end of the batch. Sibling of [_browseIndexesDropped].
  static bool _ftsTriggersSuspended = false;

  /// fix518: drop the non-unique secondary indexes on `channels` for the
  /// duration of a bulk refresh, then recreate them ONCE from their stored DDL.
  /// Maintaining ~a dozen indexes per row across a multi-hundred-thousand-row
  /// wipe+reinsert was the dominant refresh cost (a measured 101s DELETE +
  /// ~165s of inserts on a 273K-row source on the onn 4K box); rebuilding the
  /// indexes once at the end is far cheaper. UNIQUE indexes
  /// (channels_unique_stream / channels_unique_series) are KEPT — the reinsert
  /// relies on them. Reads sqlite_master so a newly-added index can never be
  /// missed, and recreates verbatim in `finally` so a failed refresh still
  /// restores them. RE-ENTRANT: when a multi-source refresh has already dropped
  /// the indexes around the whole loop, a nested per-source call is a no-op, so
  /// the catalog is reindexed once for the batch, not once per source.
  static bool _browseIndexesDropped = false;

  /// fix520: channels indexes that must survive a bulk refresh because the
  /// refresh's own statements query by them. Only index_channel_source_id
  /// qualifies — every per-source step filters `WHERE source_id = ?`, so
  /// without it each becomes a full-catalog scan. All other secondary indexes
  /// (the expensive composite/CASE browse-tier ones) are still dropped +
  /// rebuilt once.
  static const List<String> _keepIndexesDuringRefresh = [
    'index_channel_source_id',
    // Review finding 129: restorePreserve's UPDATE...FROM joins on
    // (name, source_id) via index_channel_name_source; dropping it regresses
    // the preserve merge from ~25ms to ~134s. A plain 2-column index —
    // insert-maintenance cost during the refresh is negligible vs the
    // composite CASE browse-tier indexes that stay dropped.
    'index_channel_name_source',
  ];
  /// Review finding 134: runs a getAll whose SQL contains a forced INDEXED BY;
  /// if the index was dropped between the _indexExists gate and execution
  /// (refresh index-drop burst — a TOCTOU the gate cannot close), SQLite
  /// throws 'no such index' — retry ONCE with the hint stripped. The hint is a
  /// planner nudge, never a correctness constraint, so the unhinted query is
  /// functionally identical. The narrow message match is deliberate: a wrong
  /// non-match simply rethrows the original error (no silent wrong result).
  static Future<ResultSet> _getAllHinted(SqliteWriteContext db, String hintedSql,
      String unhintedSql, List<Object?> params) async {
    try {
      return await db.getAll(hintedSql, params);
    } on SqliteException catch (e) {
      if (e.message.contains('no such index')) {
        AppLog.warn(
            'Sql: forced INDEXED BY index vanished mid-query — retrying unhinted');
        return await db.getAll(unhintedSql, params);
      }
      rethrow;
    }
  }

  /// fix526: does a named index currently exist? Gates forced `INDEXED BY`
  /// hints so a missing or mid-rebuild index never hard-crashes a query with
  /// "no such index" (which previously left the browse stuck loading).
  static Future<bool> _indexExists(String name) async {
    final db = await DbFactory.db;
    final r = await db.getOptional(
      "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
      [name],
    );
    return r != null;
  }

  static Future<void> withDroppedBrowseIndexes(
      Future<void> Function() body,
      {void Function(String)? onProgress}) async {
    if (_browseIndexesDropped) {
      // An outer (multi-source) drop already owns drop+recreate; just run.
      await body();
      return;
    }
    final db = await DbFactory.db;
    // fix520: KEEP the indexes the refresh itself queries by. Every per-source
    // `WHERE source_id = ?` (the wipe DELETE, the two COUNTs, the groups
    // GROUP BY, the group_id/cat_enabled UPDATEs, the preserve SELECT, the FTS
    // targeted SELECT) needs index_channel_source_id; dropping it turned each
    // into a ~20s full scan of the ~1.17M-row catalog on the onn 4K box
    // (measured: A3000 went 38s -> 220s). We still drop the expensive
    // composite/CASE browse-tier indexes — those are the real per-row
    // insert-maintenance cost — just not the source_id lookup the refresh
    // depends on.
    final rows = await db.getAll(
      "SELECT name, sql FROM sqlite_master "
      "WHERE type = 'index' AND tbl_name = 'channels' "
      "AND sql IS NOT NULL AND UPPER(sql) NOT LIKE 'CREATE UNIQUE%' "
      "AND name NOT IN (${generatePlaceholders(_keepIndexesDuringRefresh.length)})",
      _keepIndexesDuringRefresh,
    );
    // fix628: persist the captured CREATE DDL BEFORE dropping. If the process is
    // killed or the refresh is cancelled between here and the recreate in the
    // finally (e.g. an FTS stall + Cancel — onn 2026-06-30, which lost all 19
    // browse indexes permanently), the finally never runs, but
    // Sql.ensureBrowseIndexesPresent() replays this exact DDL on next startup.
    // Cleared once the recreate below completes.
    try {
      await db.execute(
          "INSERT OR REPLACE INTO app_meta (key, value) "
          "VALUES ('pending_browse_index_ddl', ?)",
          [jsonEncode(rows.map((r) => r['sql'] as String).toList())]);
    } catch (e) {
      AppLog.warn('Sql.withDroppedBrowseIndexes: could not persist pending'
          ' index DDL (self-heal still covers it) — $e');
    }
    for (final r in rows) {
      await db.execute('DROP INDEX IF EXISTS "${r['name']}";');
    }
    _browseIndexesDropped = true;
    AppLog.info('Sql.withDroppedBrowseIndexes: dropped ${rows.length} channels'
        ' index(es) for bulk refresh'
        ' (${rows.map((r) => r['name']).join(", ")})');
    try {
      await body();
    } finally {
      // fix523: transient bounded memory window for the index recreate ONLY.
      // Placed HERE (inner withDroppedBrowseIndexes), NOT in the outer
      // withSuspendedFtsTriggers: on the single-source path (Utils.processSource)
      // withDroppedBrowseIndexes is the OUTER wrapper and the FTS suspend is
      // INNER, so a pragma set in the FTS wrapper would be restored BEFORE this
      // recreate runs (no speedup on single-source). This placement also covers
      // FTS-OFF users (fix212) who skip the FTS-suspend branch entirely.
      // Each CREATE INDEX over the ~1.17M-row channels table runs an external
      // merge-sort; with SQLite's ~2 MiB default cache the sort SPILLS to slow
      // eMMC (the uniform ~20-36s/index floor measured on the onn 4K box is the
      // disk-spill signature). A 32 MiB HARD-CAPPED page cache keeps the table
      // pages + merge runs resident. cache_size negative = KiB, so -32768 is an
      // ABSOLUTE 32 MiB ceiling SQLite never exceeds (pages allocated lazily;
      // OOM-safe on a 1-2GB render-capped box, fix506). temp_store=FILE is set
      // EXPLICITLY (NOT MEMORY): MEMORY would let the 1.17M-row sorter hold tens
      // of MB of spill in RAM with no cap across 20+ builds — a real OOM risk.
      // Connection-scoped pragmas on the single persistent sqlite_async writer
      // (db.execute routes through writeLock on one reused connection), so they
      // persist across the recreate db.execute()s and are restored below. In
      // finally so a throwing body() still restores.
      try {
        await db.execute('PRAGMA temp_store = FILE;');
        await db.execute('PRAGMA cache_size = -32768;');
      } catch (e) {
        AppLog.warn('Sql.withDroppedBrowseIndexes: failed to set recreate'
            ' memory pragmas (continuing on defaults) — $e');
      }
      var restored = 0;
      final total = rows.length;
      // fix549: surface the previously-silent index recreate phase (the
      // dominant tail of "Saving to database…" — each CREATE INDEX over the
      // ~1.17M-row catalog is a multi-second external merge-sort on eMMC).
      // Without this the UI sat on a static "Saving to database…" for minutes
      // and looked frozen. Per-index counter to the dialog + per-index elapsed
      // ms to the log so the slow ones are identifiable in field diagnostics.
      for (var i = 0; i < rows.length; i++) {
        final r = rows[i];
        onProgress?.call('Building index ${i + 1}/$total…');
        final swIdx = Stopwatch()..start();
        try {
          await db.execute(r['sql'] as String);
          restored++;
          AppLog.info('Sql.withDroppedBrowseIndexes: built ${i + 1}/$total'
              ' "${r['name']}" in ${swIdx.elapsedMilliseconds}ms');
        } catch (e) {
          AppLog.error('Sql.withDroppedBrowseIndexes: FAILED to recreate index'
              ' "${r['name']}" — $e');
        }
      }
      // fix628: clear the persisted rebuild DDL only when EVERY index came back
      // — a partial recreate leaves it so ensureBrowseIndexesPresent() finishes
      // the rest on next startup.
      if (restored == total) {
        try {
          await db.execute(
              "DELETE FROM app_meta WHERE key = 'pending_browse_index_ddl'");
        } catch (_) {}
      }
      onProgress?.call('Finalizing database…');
      try {
        await db.execute('PRAGMA optimize;');
      } catch (_) {}
      // fix523: restore the ~2 MiB SQLite default page cache so the bump never
      // lingers for normal browse/search on the persistent writer. temp_store
      // stays at FILE (the safe default). Best-effort like optimize.
      try {
        await db.execute('PRAGMA cache_size = -2000;');
      } catch (_) {}
      _browseIndexesDropped = false;
      AppLog.info('Sql.withDroppedBrowseIndexes: recreated $restored/'
          '${rows.length} channels index(es) + PRAGMA optimize');
    }
  }

  /// fix514: [skipRebuild] lets a caller that has ALREADY resynced the FTS
  /// index itself (a targeted per-source re-index) skip the redundant global
  /// rebuild this function would otherwise do when triggers were absent.
  /// Other callers (search-method toggle) don't pass it and keep the
  /// original always-rebuild-when-triggers-were-absent behavior.
  static Future<void> reconcileFtsTriggers(bool ftsActive,
      {bool skipRebuild = false}) async {
    final db = await DbFactory.db;
    final existing = await db.getAll(
      "SELECT name FROM sqlite_master WHERE type = 'trigger' "
      "AND name IN ('channels_ai', 'channels_au', 'channels_ad')",
    );
    final triggersPresent = existing.length == 3;
    if (ftsActive) {
      if (triggersPresent) return;
      // Triggers were absent => FTS index is stale. Rebuild once, then
      // recreate (unless the caller already resynced it themselves).
      if (!skipRebuild) {
        await db.execute("INSERT INTO channels_fts(channels_fts) VALUES('rebuild');");
      }
      await db.execute('CREATE TRIGGER IF NOT EXISTS channels_ai '
          'AFTER INSERT ON channels BEGIN '
          'INSERT INTO channels_fts(rowid, name) VALUES (new.id, new.name); END;');
      await db.execute('CREATE TRIGGER IF NOT EXISTS channels_ad '
          'AFTER DELETE ON channels BEGIN '
          "INSERT INTO channels_fts(channels_fts, rowid, name) "
          "VALUES('delete', old.id, old.name); END;");
      await db.execute('CREATE TRIGGER IF NOT EXISTS channels_au '
          'AFTER UPDATE OF name ON channels BEGIN '
          "INSERT INTO channels_fts(channels_fts, rowid, name) "
          "VALUES('delete', old.id, old.name); "
          'INSERT INTO channels_fts(rowid, name) VALUES (new.id, new.name); END;');
    } else {
      if (!triggersPresent && existing.isEmpty) {
        return;
      }
      await db.execute('DROP TRIGGER IF EXISTS channels_ai;');
      await db.execute('DROP TRIGGER IF EXISTS channels_au;');
      await db.execute('DROP TRIGGER IF EXISTS channels_ad;');
    }
  }

  /// fix619: recover from a malformed FTS index ("database disk image is
  /// malformed", SqliteException code 267). The external-content FTS5 shadow
  /// tables can become inconsistent (a corrupted `channels_fts`); when that
  /// happens every search and every refresh that touches FTS fails forever.
  /// This drops the FTS virtual table and its sync triggers, recreates them
  /// BYTE-IDENTICAL to migration 13 / reconcileFtsTriggers (unicode61,
  /// prefix='2 3'), and repopulates from the current `channels`. Returns true
  /// if recovery completed. Best-effort: callers should catch and surface a
  /// failure rather than crash.
  /// fix642: [reason] distinguishes the routine fix621 end-of-batch rebuild
  /// (index intentionally stale after a suspended-trigger batch — logged at
  /// INFO) from genuine code-267 corruption recovery (logged at WARN as
  /// "malformed"). Defaults to null → the malformed-recovery wording.
  static Future<void> rebuildFtsTableFromScratch({String? reason}) async {
    final db = await DbFactory.db;
    if (reason == null) {
      AppLog.warn('Sql.rebuildFtsTableFromScratch: rebuilding malformed FTS '
          'index from scratch');
    } else {
      AppLog.info('Sql.rebuildFtsTableFromScratch: $reason');
    }
    // Triggers reference channels_fts; drop them before the table.
    await db.execute('DROP TRIGGER IF EXISTS channels_ai;');
    await db.execute('DROP TRIGGER IF EXISTS channels_au;');
    await db.execute('DROP TRIGGER IF EXISTS channels_ad;');
    // Dropping the external-content FTS table also removes its shadow tables
    // (channels_fts_data/idx/docsize/config), discarding the corruption.
    await db.execute('DROP TABLE IF EXISTS channels_fts;');
    await db.execute('''
      CREATE VIRTUAL TABLE channels_fts USING fts5(
        name,
        content='channels',
        content_rowid='id',
        tokenize='unicode61',
        prefix='2 3'
      );
    ''');
    await db.execute('''
      INSERT INTO channels_fts(rowid, name)
      SELECT id, name FROM channels;
    ''');
    // Recreate sync triggers (reconcileFtsTriggers also creates these, but do
    // it here so recovery is self-contained and leaves a consistent state).
    await db.execute('CREATE TRIGGER IF NOT EXISTS channels_ai '
        'AFTER INSERT ON channels BEGIN '
        'INSERT INTO channels_fts(rowid, name) VALUES (new.id, new.name); END;');
    await db.execute('CREATE TRIGGER IF NOT EXISTS channels_ad '
        'AFTER DELETE ON channels BEGIN '
        "INSERT INTO channels_fts(channels_fts, rowid, name) "
        "VALUES('delete', old.id, old.name); END;");
    await db.execute('CREATE TRIGGER IF NOT EXISTS channels_au '
        'AFTER UPDATE OF name ON channels BEGIN '
        "INSERT INTO channels_fts(channels_fts, rowid, name) "
        "VALUES('delete', old.id, old.name); "
        'INSERT INTO channels_fts(rowid, name) VALUES (new.id, new.name); END;');
    // Clear the suspend flag — recovery left triggers present and consistent.
    _ftsTriggersSuspended = false;
    AppLog.info('Sql.rebuildFtsTableFromScratch: FTS index rebuilt and '
        'triggers recreated');
  }

  /// fix619: true if [e] is the SQLite "database disk image is malformed"
  /// error (code 267), used to trigger FTS auto-recovery.
  static bool isMalformedDbError(Object e) {
    final s = e.toString();
    return s.contains('code 267') ||
        s.contains('database disk image is malformed');
  }

  /// fix620: pre-flight FTS health check. A malformed external-content FTS5
  /// index (code 267) makes a refresh HANG rather than throw — the corrupting
  /// `DELETE FROM channels_fts` can block inside the synchronous SQLite call on
  /// the main isolate, where a Cancel button cannot interrupt it. So instead of
  /// relying on catching the error, the refresh paths call this FIRST: run
  /// FTS5's built-in `integrity-check`, and if it fails, rebuild the index from
  /// scratch BEFORE any refresh touches it. Cheap on a healthy index (~1s on
  /// the 857K-row catalog). Returns true if a rebuild was performed.
  static Future<bool> ensureFtsHealthy() async {
    final db = await DbFactory.db;
    try {
      await db
          .execute("INSERT INTO channels_fts(channels_fts) VALUES('integrity-check');");
      return false; // healthy
    } catch (e) {
      if (!isMalformedDbError(e)) {
        // Not a malformedness error — surface it rather than masking.
        rethrow;
      }
      AppLog.warn('Sql.ensureFtsHealthy: FTS integrity-check failed '
          '($e) — rebuilding index before refresh');
      await rebuildFtsTableFromScratch();
      return true;
    }
  }

  /// fix174.3: bulk upsert for large imports. Same ON CONFLICT key as
  /// insertChannel (fix174.1). Does NOT read last_insert_rowid().
  static Future<void> Function(SqliteWriteContext, Map<String, String>)
      insertChannelsBulk(List<Channel> channels) {
    return (SqliteWriteContext tx, Map<String, String> memory) async {
      if (channels.isEmpty) return;
      final sourceId = int.parse(memory['sourceId']!);
      const cols = 16; // fix256: +provider_order; fix272: +is_divider; fix300: +is_adult
      final rowPlaceholder = '(${List.filled(cols, '?').join(', ')})';
      final values = List.filled(channels.length, rowPlaceholder).join(', ');
      final params = <Object?>[];
      for (final ch in channels) {
        params.addAll([
          ch.name, ch.image, ch.url,
          ch.sourceId == -1 ? sourceId : ch.sourceId,
          ch.mediaType.index, ch.seriesId, ch.favorite,
          ch.streamId, ch.group, ch.epgChannelId,
          ch.catchupType, ch.catchupSource, ch.catchupDays,
          ch.providerOrder, // fix256
          ch.isDivider ? 1 : 0, // fix272
          ch.isAdult ? 1 : 0, // fix300
        ]);
      }
      await tx.execute('''
        INSERT INTO channels (
          name, image, url, source_id, media_type, series_id, favorite,
          stream_id, group_name, epg_channel_id,
          catchup_type, catchup_source, catchup_days, provider_order, is_divider,
          is_adult
        )
        VALUES $values
        ON CONFLICT DO UPDATE SET
          url = excluded.url,
          group_name = excluded.group_name,
          media_type = excluded.media_type,
          stream_id = excluded.stream_id,
          image = excluded.image,
          series_id = excluded.series_id,
          epg_channel_id = COALESCE(channels.epg_channel_id, excluded.epg_channel_id),
          catchup_type = excluded.catchup_type,
          catchup_source = excluded.catchup_source,
          catchup_days = excluded.catchup_days,
          provider_order = excluded.provider_order,
          is_divider = excluded.is_divider,
          is_adult = excluded.is_adult;
      ''', params);
    };
  }

  static Future<void> Function(SqliteWriteContext, Map<String, String>)
      updateGroups() {
    return (SqliteWriteContext tx, Map<String, String> memory) async {
      final sourceId = int.parse(memory['sourceId']!);
      // fix583 (#18): group by (name, media_type) and conflict on
      // (name, source_id, media_type) so a same-named category in different
      // media types (e.g. a Live "Sports" and a Movies "Sports") produces two
      // distinct group rows instead of collapsing/colliding into one. Matches
      // the migration-40 unique index groups(name, source_id, media_type).
      await tx.execute('''
        INSERT INTO groups (name, image, source_id, media_type)
        SELECT group_name, image, ?, media_type
        FROM channels
        WHERE source_id = ?
        GROUP BY group_name, media_type
        ON CONFLICT(name, source_id, media_type) DO UPDATE SET
          image = excluded.image
      ''', [sourceId, sourceId]);
      // fix298: re-apply the categories that were disabled before this refresh
      // (captured by wipeSource). Newly-appeared categories keep DEFAULT 1.
      final stashed = memory['disabledGroupNames'];
      if (stashed != null && stashed.isNotEmpty) {
        final names = (jsonDecode(stashed) as List).cast<String>();
        if (names.isNotEmpty) {
          await tx.execute(
            'UPDATE groups SET enabled = 0'
            ' WHERE source_id = ?'
            ' AND name IN (${generatePlaceholders(names.length)})',
            [sourceId, ...names],
          );
        }
      }
      // fix517: set-based UPDATE...FROM joins replace the old per-row
      // correlated scalar subqueries (measured 21.6s + 44.8s on a 273K-row
      // source). group_id: NULL the source's rows first, then join-assign from
      // groups; an unmatched group_name stays NULL — provably identical to the
      // old correlated subquery for BOTH the full-wipe and the fix321
      // keepMediaTypes refresh (the pre-NULL is what makes the keepMediaTypes
      // path match, since a join leaves unmatched rows unchanged).
      await tx.execute(
        'UPDATE channels SET group_id = NULL WHERE source_id = ?',
        [sourceId],
      );
      await tx.execute('''
        UPDATE channels
        SET group_id = g.id
        FROM groups g
        WHERE g.name = channels.group_name
          AND g.source_id = ?
          AND g.media_type IS channels.media_type
          AND channels.source_id = ?
      ''', [sourceId, sourceId]);
      // fix365/fix517: denormalize the category-enabled flag so the browse
      // index can exclude disabled-category channels without a per-row
      // subquery. Join sets it for channels with a matching group
      // (COALESCE(g.enabled,1) mirrors the old default for a null enabled
      // flag); channels with no group default to 1 — identical to the old
      // COALESCE((SELECT g.enabled ...), 1).
      await tx.execute('''
        UPDATE channels
        SET cat_enabled = COALESCE(g.enabled, 1)
        FROM groups g
        WHERE g.id = channels.group_id
          AND channels.source_id = ?
      ''', [sourceId]);
      await tx.execute(
        'UPDATE channels SET cat_enabled = 1'
        ' WHERE source_id = ? AND group_id IS NULL',
        [sourceId],
      );
    };
  }

  static Future<void> Function(SqliteWriteContext, Map<String, String>)
      insertChannelHeaders(ChannelHttpHeaders headers) {
    return (SqliteWriteContext tx, Map<String, String> memory) async {
      await tx.execute('''
          INSERT OR IGNORE INTO channel_http_headers (channel_id, referrer, user_agent, http_origin, ignore_ssl)
          VALUES (?, ?, ?, ?, ?)
        ''', [
        int.parse(memory['lastChannelId']!),
        headers.referrer,
        headers.userAgent,
        headers.httpOrigin,
        headers.ignoreSSL
      ]);
    };
  }

  static Future<ChannelHttpHeaders?> getChannelHeaders(int channelId) async {
    var db = await DbFactory.db;
    var result = await db.getOptional('''
        SELECT * FROM channel_http_headers
        WHERE channel_id = ?
        LIMIT 1
    ''', [channelId]);
    return result != null ? _rowToHeaders(result) : null;
  }

  static ChannelHttpHeaders _rowToHeaders(Row row) {
    return ChannelHttpHeaders(
        id: row.columnAt(0),
        channelId: row.columnAt(1),
        referrer: row.columnAt(2),
        userAgent: row.columnAt(3),
        httpOrigin: row.columnAt(4),
        ignoreSSL: row.columnAt(5)?.toString());
  }

  static Future<void> Function(SqliteWriteContext, Map<String, String>)
      getOrCreateSourceByName(Source source) {
    return (SqliteWriteContext tx, Map<String, String> memory) async {
      // INSERT OR REPLACE was rejected because AUTOINCREMENT assigns a new
      // id on each replace, which would orphan rows in `channels` that
      // reference `sources.id` via the source_id FK. The SELECT-first
      // pattern preserves the existing id while updating all other fields.
      final existing = await tx.getOptional(
        "SELECT id FROM sources WHERE name = ?",
        [source.name],
      );

      if (existing != null) {
        // Source already exists — update all editable fields so a
        // re-import correctly applies the backup's values (especially
        // `enabled`). The id is preserved, so
        // channel FK references are unaffected.
        final id = existing.columnAt(0);
        await tx.execute('''
              UPDATE sources
                 SET source_type    = ?,
                     url            = ?,
                     username       = COALESCE(?, username),
                     password       = COALESCE(?, password),
                     epg_url        = ?,
                     enabled        = ?,
                     max_connections = COALESCE(?, max_connections),
                     color           = COALESCE(?, color),
                     sort_mode       = COALESCE(?, sort_mode),
                     exp_date        = COALESCE(?, exp_date),
                     status          = COALESCE(?, status)
               WHERE id = ?
            ''', [
          source.sourceType.index,
          source.url,
          source.username,
          source.password,
          source.epgUrl,
          source.enabled ? 1 : 0,
          source.maxConnections,
          source.color,
          source.sortMode,
          source.expDate,
          source.status,
          id,
        ]);
        memory['sourceId'] = id.toString();
      } else {
        await tx.execute('''
              INSERT INTO sources
                (name, source_type, url, username, password, epg_url,
                 enabled, max_connections, color, sort_mode, exp_date, status)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            ''', [
          source.name,
          source.sourceType.index,
          source.url,
          source.username,
          source.password,
          source.epgUrl,
          source.enabled ? 1 : 0,
          source.maxConnections,
          source.color,
          source.sortMode,
          source.expDate,
          source.status,
        ]);
        memory['sourceId'] =
            (await tx.get("SELECT last_insert_rowid();")).columnAt(0).toString();
      }
    };
  }

  // Leading-wildcard LIKE forced a full-table scan; trigram FTS is index-backed.
  //
  /// [invocation] is an opaque correlation id passed through to log lines so
  /// the caller can tie search timing to its own load id.
  /// Safe to pass 0 if not correlating.
  static Future<List<Channel>> search(Filters filters,
      {int invocation = 0}) async {
    if (filters.viewType == ViewType.categories &&
        filters.groupId == null &&
        filters.seriesId == null) {
      return searchGroup(filters);
    }
    var db = await DbFactory.db;
    var offset = filters.page * pageSize - pageSize;
    // fix557: per-call override (see Filters.limit doc). Defaults to the
    // global pageSize for every existing caller.
    final effLimit = filters.limit ?? pageSize;
    var mediaTypes = filters.seriesId == null
        ? filters.mediaTypes!.map((x) => x.index)
        : [1];
    final rawQuery = (filters.query ?? "").trim();
    final useFts = rawQuery.isNotEmpty;

    String sqlQuery;
    String branch = 'no-query';
    List<Object> params = [];

    if (useFts) {
      // fix319: on low-RAM devices the in-memory cache is never built, so the
      // inMemory method would return nothing — fall through to the FTS SQL
      // path instead.
      if (filters.searchMethod == SearchMethod.inMemory &&
          !ChannelSearchCache.cacheSkipped) {
        return _searchInMemory(filters, rawQuery, mediaTypes, offset, effLimit);
      }
      if (filters.searchMethod == SearchMethod.likeSubstring) {
        return _searchLike(filters, rawQuery, mediaTypes, offset, effLimit);
      }
    }

    // For ftsPhrase and ftsAnd, effectiveKeywords overrides the legacy flag.
    // ftsAnd splits on whitespace (AND mode); ftsPhrase keeps the raw phrase.
    final effectiveKeywords =
        filters.searchMethod == SearchMethod.ftsAnd || filters.useKeywords;

    if (useFts) {
      // Review finding 133: a batch refresh suspends the channels_fts sync
      // triggers and only rebuilds the index at end-of-batch
      // (withSuspendedFtsTriggers). Any caller not gated by the UI's rebuild
      // blocking (a TV view / channel-picker text search) would otherwise
      // MATCH a stale index and silently miss freshly-inserted rows. Fall
      // back to LIKE (correct, slower) for the rebuild window.
      if (ftsRebuilding.value) {
        return _searchLike(filters, rawQuery, mediaTypes, offset, effLimit);
      }
      // fix519: word-prefix MATCH for the unicode61 channels_fts (migration
      // 35). Each term >= 2 chars becomes a quoted phrase + trailing prefix
      // star ("term"*), so "fox" matches "FOX Sports", "espn" matches
      // "ESPN HD", "sport" matches "FOX Sports" (the word "Sports"), and a
      // 2-char "fo" is still index-served (prefix='2 3'). Terms < 2 chars are
      // non-discriminating and dropped; if EVERY term is < 2 we skip the scan.
      final terms = effectiveKeywords
          ? rawQuery.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList()
          : [rawQuery];
      final longTerms = terms.where((t) => t.length >= 2).toList();

      if (longTerms.isNotEmpty) {
        // Quote each term (escaping embedded quotes) and append * for a
        // prefix query. "x"* is valid FTS5 (quoted phrase + prefix), so names
        // containing FTS operator characters are handled without a sanitizer.
        final matchExpr = longTerms
            .map((t) => '"${t.replaceAll('"', '""')}"*')
            .join(' AND ');
        sqlQuery = '''
          SELECT c.* FROM channels c
          INNER JOIN channels_fts ON channels_fts.rowid = c.id
          WHERE channels_fts MATCH ?
            AND c.media_type IN (${generatePlaceholders(mediaTypes.length)})
            AND c.source_id IN (${generatePlaceholders(filters.sourceIds!.length)})
            AND c.url IS NOT NULL
        ''';
        params.add(matchExpr);
        branch = 'fts';
      } else {
        // Every term is < 2 chars — non-discriminating. Skip the scan and
        // return early so the UI stays snappy; the user hasn't typed a
        // meaningful query yet.
        if (AppLog.enabled) {
          AppLog.info(
            'Sql.search[$invocation]: branch=short-skip'
            ' query="$rawQuery" — all terms < 2 chars, skipping scan',
          );
        }
        return [];
      }
      params.addAll(mediaTypes);
      params.addAll(filters.sourceIds!);
    } else {
      // fix393: when the in-scope sources MIX sort modes, the single-query
      // browse ORDER BY is the per-row correlated form (BrowseOrder.orderBy
      // (null)) that no index can serve — a full temp-B-tree sort of the whole
      // media-type set (~seconds cold on a multi-source S24). Split it into a
      // per-source UNION ALL where each source sorts in its OWN uniform,
      // index-served mode (alpha→idx_channels_browse_mt, provider→
      // idx_browse_prov, category→idx_browse_cat) and re-apply the global order
      // over the tiny union. Only the normal browse with ≥2 sources and no
      // series drilldown; favorites/history have their own ORDER BY and a
      // single source is already uniform.
      if (filters.viewType != ViewType.favorites &&
          filters.viewType != ViewType.history &&
          filters.seriesId == null &&
          (filters.sourceIds?.length ?? 0) >= 2) {
        final modes = await _sourceModes(filters.sourceIds!);
        if (modes.values.toSet().length > 1) {
          return _browseMixedUnion(filters, mediaTypes, offset, invocation, modes);
        }
      }
      // fix419: hint the (source_id, media_type) composite for the single-source,
      // single-media-type, ungrouped alpha browse. The planner won't pick it over
      // idx_channels_browse_mt on its own (LIMIT 36 defeats its selectivity
      // estimate), so it residual-scans every source's rows. Gated so the partial
      // index's conditions (series_id IS NULL, cat_enabled = 1 — both emitted by
      // VisibilityClause when seriesId/groupId are null) and its tier sort are
      // guaranteed present; otherwise no hint and behaviour is unchanged.
      final browseMode = await _uniformSortMode(filters.sourceIds!);
      var useSrcMtHint = filters.viewType != ViewType.favorites &&
          filters.viewType != ViewType.history &&
          filters.seriesId == null &&
          filters.groupId == null &&
          filters.sourceIds!.length == 1 &&
          mediaTypes.length == 1 &&
          browseMode == 'alpha';
      // fix526: a forced `INDEXED BY` on a MISSING index is a hard
      // SqliteException ("no such index") that escapes as an unhandled error and
      // leaves the browse stuck on "loading". Some upgraded DBs are missing the
      // partial browse indexes from migration 34, and withDroppedBrowseIndexes
      // also drops idx_browse_src_mt for the duration of a refresh. Only force
      // the hint when the index actually exists right now; otherwise fall back
      // to the planner (functional, just unhinted). Checked LIVE (not cached) so
      // the mid-refresh drop window cannot produce a stale "present".
      if (useSrcMtHint && !await _indexExists('idx_browse_src_mt')) {
        useSrcMtHint = false;
      }
      // fix627: a grouped/category browse (groupId set) filters source_id +
      // group_id, but the planner seeks by source_id ALONE, reads the whole
      // source partition (~275k-450k rows/source), residual-filters group_id,
      // then temp-B-tree sorts — measured 12-43s for a small category on the
      // onn (private log 2026-07-01, plan "SEARCH c USING INDEX
      // index_channel_source_id | USE TEMP B-TREE"). Force idx_browse_src_grp
      // (source_id, group_id, tier, name) so it seeks straight to the
      // category's rows. Its partial WHERE (url IS NOT NULL AND series_id IS
      // NULL) is provably implied: the query emits `url IS NOT NULL` and
      // VisibilityClause emits `series_id IS NULL` whenever groupId is set — so
      // results are identical, just fast. Same _indexExists gate as fix526 (the
      // index is dropped mid-refresh / absent on some upgraded DBs, and a
      // forced INDEXED BY on a missing index is a hard crash).
      var useSrcGrpHint = filters.viewType != ViewType.favorites &&
          filters.viewType != ViewType.history &&
          filters.seriesId == null &&
          filters.groupId != null;
      if (useSrcGrpHint && !await _indexExists('idx_browse_src_grp')) {
        useSrcGrpHint = false;
      }
      // fix648: the Favorites browse mis-picks like fix627's category browse
      // did — the fix646 partial index idx_fav_browse (media_type, source_id,
      // name WHERE favorite = 1) EXISTS but the planner walks
      // idx_channel_src_media_url over the whole media_type range instead,
      // residual-testing favorite=1 per row + temp-B-tree (onn 2026-07-03:
      // 64s/30s for 3 rows — VERIFY_643-647 §4 FAIL). Averaged sqlite_stat1
      // can't see that favorite=1 is ~a-dozen rows, so ANALYZE can't fix the
      // pick (fix531). Forcing is provably safe: this hint's condition is
      // IDENTICAL to the branch below that appends `AND favorite = 1`, which
      // implies the index's partial WHERE — same result set, just seeks the
      // tiny favorites index. Same live _indexExists gate as fix526/627.
      var useFavHint = filters.viewType == ViewType.favorites &&
          filters.seriesId == null;
      if (useFavHint && !await _indexExists('idx_fav_browse')) {
        useFavHint = false;
      }
      // No query — simple filter on indexed columns.
      sqlQuery = '''
        SELECT * FROM channels c${useFavHint ? ' INDEXED BY idx_fav_browse' : useSrcMtHint ? ' INDEXED BY idx_browse_src_mt' : useSrcGrpHint ? ' INDEXED BY idx_browse_src_grp' : ''}
        WHERE media_type IN (${generatePlaceholders(mediaTypes.length)})
          AND source_id IN (${generatePlaceholders(filters.sourceIds!.length)})
          AND url IS NOT NULL
      ''';
      params.addAll(mediaTypes);
      params.addAll(filters.sourceIds!);
    }

    if (filters.viewType == ViewType.favorites && filters.seriesId == null) {
      sqlQuery += "\nAND favorite = 1";
    }
    if (filters.viewType == ViewType.history) {
      sqlQuery += "\nAND last_watched IS NOT NULL";
    }
    // fix371: single source of truth for series/divider/category visibility.
    final (visSql, visParams) = VisibilityClause.build(
      alias: 'c.',
      seriesId: filters.seriesId,
      groupId: filters.groupId,
    );

    // Must be before ORDER BY — AND clauses after ORDER BY are invalid SQL.
    final (smClause, smParams) = safeModeClause(filters.safeMode);
    sqlQuery += smClause;
    params.addAll(smParams);
    if (filters.safeMode && AppLog.enabled) {
      AppLog.info(
        'Sql.search[$invocation]: safeMode=true'
        ' blocking ${safeModeBlocklist.length} terms',
      );
    }

    sqlQuery += visSql;
    params.addAll(visParams);

    if (filters.viewType == ViewType.favorites && filters.seriesId == null) {
      // fix377: Favorites view now honors the user-chosen sort mode the same
      // way the rest of search does (via BrowseOrder), so a user who set
      // "Provider order" or "By category" sees their favorites in that
      // sequence instead of always being grouped by source A–Z. When sources
      // mix modes (null) we keep the legacy A–Z subquery form — same shape
      // as fix356, no new correlated subquery, tiny result set.
      final uniformMode = await _uniformSortMode(filters.sourceIds!);
      if (uniformMode != null) {
        sqlQuery += BrowseOrder.orderBy(uniformMode);
      } else {
        // fix356: Favorites view — group by source (A–Z), channels A–Z within.
        // Correlated source-name subquery is fine here: favorites lists are
        // tiny (tens of rows), unlike the full-catalogue browse paths.
        sqlQuery += '\nORDER BY'
            ' (SELECT s.name FROM sources s WHERE s.id = c.source_id)'
            ' COLLATE NOCASE ASC,'
            ' c.name COLLATE NOCASE ASC';
      }
    } else if (filters.viewType == ViewType.history) {
      sqlQuery += "\nORDER BY c.last_watched DESC";
    } else {
      // fix138/256/258/272 sort semantics, built by BrowseOrder (fix344).
      // Resolve the in-scope sources' sort modes ONCE here in Dart: when they
      // are uniform the emitted ORDER BY has NO correlated subqueries, and the
      // alpha form structurally matches idx_channels_browse_tier (migration
      // 27) so the planner serves the sort from the index instead of a temp
      // B-tree over the whole catalogue (~11s cold on 270k rows on Shield).
      sqlQuery += BrowseOrder.orderBy(
          await _uniformSortMode(filters.sourceIds!));
    }

    sqlQuery += "\nLIMIT ?, ?";
    params.add(offset);
    params.add(effLimit);

    // log can tell us which is the bottleneck.
    final sqlStart = DateTime.now();
    // Review finding 134: if the no-query browse embedded a forced INDEXED BY
    // and the index was dropped between the gate and execution (refresh drop
    // burst), retry once with the hint stripped instead of hard-crashing.
    final hintedIdx = sqlQuery.contains(' INDEXED BY idx_fav_browse')
        ? ' INDEXED BY idx_fav_browse'
        : sqlQuery.contains(' INDEXED BY idx_browse_src_mt')
            ? ' INDEXED BY idx_browse_src_mt'
            : sqlQuery.contains(' INDEXED BY idx_browse_src_grp')
                ? ' INDEXED BY idx_browse_src_grp'
                : null;
    var results = hintedIdx == null
        ? await db.getAll(sqlQuery, params)
        : await _getAllHinted(
            db, sqlQuery, sqlQuery.replaceFirst(hintedIdx, ''), params);
    final sqlElapsed = DateTime.now().difference(sqlStart).inMilliseconds;

    final mapStart = DateTime.now();
    final mapped = results.map(rowToChannel).toList();
    final mapElapsed = DateTime.now().difference(mapStart).inMilliseconds;

    if (AppLog.enabled) {
      final truncatedQuery = rawQuery.length > 40
          ? '${rawQuery.substring(0, 40)}…'
          : rawQuery;
      AppLog.info(
        'Sql.search[$invocation]: branch=$branch'
        ' rows=${results.length}'
        ' sql=${sqlElapsed}ms'
        ' map=${mapElapsed}ms'
        ' params=${params.length}'
        ' query="$truncatedQuery"',
      );
    }

    return mapped;
  }

  static Channel rowToChannel(Row row) {
    // Column order: id(0) name(1) group_name(2) image(3) url(4) media_type(5)
    //   source_id(6) favorite(7) series_id(8) group_id(9) stream_id(10)
    //   last_watched(11) epg_channel_id(12) epg_manual_override(13)
    //   catchup_type(14) catchup_source(15) catchup_days(16)
    final rawMediaType = row.columnAt(5) as int?;
    final mediaType = (rawMediaType != null &&
            rawMediaType >= 0 &&
            rawMediaType < MediaType.values.length)
        ? MediaType.values[rawMediaType]
        : MediaType.livestream;
    final sv = row.columnAt(18) as int?;
    return Channel(
      id: row.columnAt(0),
      name: row.columnAt(1),
      group: row.columnAt(2),
      image: row.columnAt(3),
      url: row.columnAt(4),
      mediaType: mediaType,
      sourceId: row.columnAt(6),
      favorite: row.columnAt(7) == 1,
      seriesId: row.columnAt(8),
      groupId: row.columnAt(9),
      streamId: row.columnAt(10) as int?,
      lastWatched: row.columnAt(11) as int?,
      epgChannelId: row.columnAt(12) as String?,
      epgManualOverride: row.columnAt(13) as String?,
      catchupType: row.columnAt(14) as String?,
      catchupSource: row.columnAt(15) as String?,
      catchupDays: row.columnAt(16) as int?,
      // col 17 = engine_override — deprecated fix350 (ExoPlayer removed);
      // column retained in schema to avoid a full-table rewrite migration.
      streamValidated: sv == null ? null : sv == 1,
      // fix256: provider_order is the last column added (migration 20).
      providerOrder: row.columnAt(19) as int?,
      isDivider: (row.columnAt(20) as int?) == 1, // fix272 (migration 22)
    );
  }

  static String generatePlaceholders(int size) {
    return List.filled(size, "?").join(",");
  }

  /// Returns channel data for the in-memory search cache.
  ///
  /// Returns 10-tuples: (id, name, group, mediaType, sourceId,
  ///                      favorite, lastWatched, groupId, seriesId,
  ///                      streamValidated).
  /// The cache uses these to apply ALL view filters before pagination so
  /// full Channel objects are only fetched for the final page of IDs.
  ///
  /// Includes stream validation so cache ordering can match SQL search.
  static Future<
      List<(int, String, String, int, int, bool, int?, int?, int?, bool?,
          bool, bool, bool, int?)>>
      getAllChannelNamesForCache() async {
    final db = await DbFactory.db;
    final rows = await db.getAll(
      // fix322: hide_dividers via LEFT JOIN (was a per-row correlated subquery
      // that logged SLOW on huge catalogues). Column positions unchanged.
      'SELECT c.id, c.name, COALESCE(c.group_name, \'\'), c.media_type, c.source_id,'
      '       COALESCE(c.favorite, 0), c.last_watched, c.group_id, c.series_id,'
      '       c.stream_validated, COALESCE(c.is_divider, 0),'
      '       COALESCE(s.hide_dividers, 0),'
      '       COALESCE(c.is_adult, 0),'
      '       c.provider_order'
      ' FROM channels c'
      ' LEFT JOIN sources s ON s.id = c.source_id'
      ' WHERE c.url IS NOT NULL',
    );
    return rows
        .map((r) => (
              r.columnAt(0) as int,
              r.columnAt(1) as String,
              r.columnAt(2) as String,
              r.columnAt(3) as int,
              r.columnAt(4) as int,
              (r.columnAt(5) as int) == 1,       // favorite
              r.columnAt(6) as int?,              // lastWatched (epoch-seconds)
              r.columnAt(7) as int?,              // groupId
              r.columnAt(8) as int?,              // seriesId
              (r.columnAt(9) as int?) == null
                  ? null
                  : (r.columnAt(9) as int) == 1,
              (r.columnAt(10) as int) == 1,       // isDivider
              (r.columnAt(11) as int) == 1,       // hideDividers (source flag)
              (r.columnAt(12) as int) == 1,       // isAdult (fix300)
              r.columnAt(13) as int?,             // providerOrder (fix375)
            ))
        .toList(growable: false);
  }

  /// Returns the channel with [id], or null if not found.
  static Future<Channel?> getChannelById(int id) async {
    final db = await DbFactory.db;
    final rows = await db.getAll(
      'SELECT * FROM channels WHERE id = ? LIMIT 1',
      [id],
    );
    if (rows.isEmpty) return null;
    return rowToChannel(rows.first);
  }

  /// fix665: favorites for the Android TV home-screen row, ordered
  /// most-recently-watched first (last_watched DESC), un-watched favorites
  /// after (by name). Capped at [limit] (the tvHomeRowCount setting, 1-20).
  /// Only real playable rows (url NOT NULL, not dividers).
  static Future<List<Channel>> getFavoritesByLastWatched(int limit) async {
    final db = await DbFactory.db;
    final rows = await db.getAll(
      'SELECT * FROM channels'
      ' WHERE favorite = 1 AND url IS NOT NULL'
      '   AND COALESCE(is_divider, 0) = 0'
      ' ORDER BY (last_watched IS NULL), last_watched DESC,'
      '          name COLLATE NOCASE ASC'
      ' LIMIT ?',
      [limit],
    );
    return rows.map(rowToChannel).toList();
  }

  // ── fix667: Scheduled Recordings (SR) ──────────────────────────────────────

  static Recording _rowToRecording(Row r) => Recording(
        id: r.columnAt(0) as int?,
        channelId: r.columnAt(1) as int?,
        channelName: r.columnAt(2) as String,
        url: r.columnAt(3) as String,
        scheduledStartUtc: r.columnAt(4) as int,
        durationMs: r.columnAt(5) as int,
        padBeforeMin: r.columnAt(6) as int,
        padAfterMin: r.columnAt(7) as int,
        status: RecordingStatus.fromName(r.columnAt(8) as String?),
        outputPath: r.columnAt(9) as String?,
        error: r.columnAt(10) as String?,
        createdUtc: r.columnAt(11) as int,
      );

  static const String _recordingCols =
      'id, channel_id, channel_name, url, scheduled_start_utc, duration_ms, '
      'pad_before_min, pad_after_min, status, output_path, error, created_utc';

  /// Insert a recording; returns its new id.
  static Future<int> insertRecording(Recording rec) async {
    final db = await DbFactory.db;
    // fix677: the INSERT and its last_insert_rowid() read MUST run on the SAME
    // connection. sqlite_async pools connections, and last_insert_rowid() is
    // per-connection — the previous code did db.execute(INSERT) then a SEPARATE
    // db.getAll('SELECT last_insert_rowid()'), which could (and on the Samsung
    // consistently did) resolve on a different pooled connection that never
    // inserted, returning 0. That 0 was then used as the alarm id, so
    // recordingAlarmCallback(0) looked up a non-existent row (getRecordingById(0)
    // == null), logged "not found", and returned — every scheduled recording
    // died before capture. Wrapping both statements in one writeTransaction
    // pins them to a single connection (same idiom as insertSource /
    // insertChannel above). Confirmed on device via the fix676 [SRDBG] trace:
    // "SR-CB: got row id=0 rec=NULL".
    int id = 0;
    await db.writeTransaction((tx) async {
      await tx.execute(
        'INSERT INTO recordings '
        '(channel_id, channel_name, url, scheduled_start_utc, duration_ms, '
        ' pad_before_min, pad_after_min, status, output_path, error, created_utc) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          rec.channelId,
          rec.channelName,
          rec.url,
          rec.scheduledStartUtc,
          rec.durationMs,
          rec.padBeforeMin,
          rec.padAfterMin,
          rec.status.name,
          rec.outputPath,
          rec.error,
          rec.createdUtc,
        ],
      );
      id = (await tx.get('SELECT last_insert_rowid()')).columnAt(0) as int;
    });
    return id;
  }

  static Future<List<Recording>> getRecordings() async {
    final db = await DbFactory.db;
    final rows = await db.getAll(
      'SELECT $_recordingCols FROM recordings '
      'ORDER BY scheduled_start_utc DESC',
    );
    return rows.map(_rowToRecording).toList();
  }

  static Future<Recording?> getRecordingById(int id) async {
    final db = await DbFactory.db;
    final rows = await db.getAll(
      'SELECT $_recordingCols FROM recordings WHERE id = ? LIMIT 1',
      [id],
    );
    if (rows.isEmpty) return null;
    return _rowToRecording(rows.first);
  }

  static Future<void> updateRecordingStatus(
    int id,
    RecordingStatus status, {
    String? outputPath,
    String? error,
  }) async {
    final db = await DbFactory.db;
    await db.execute(
      'UPDATE recordings SET status = ?, '
      'output_path = COALESCE(?, output_path), '
      'error = COALESCE(?, error) WHERE id = ?',
      [status.name, outputPath, error, id],
    );
  }

  static Future<void> deleteRecording(int id) async {
    final db = await DbFactory.db;
    await db.execute('DELETE FROM recordings WHERE id = ?', [id]);
  }

  static String getKeywordsSql(int size) {
    return List.generate(size, (_) => "name LIKE ?").join(" AND ");
  }

  // fix278: toggle one category's enabled flag.
  /// fix645: monotonic generation for ANY category (groups-table) visibility
  /// change — enable/disable (single + bulk) and favorite (rail sort order).
  /// The TV guide's reloadGuide() keep-your-place optimization (fix610) only
  /// rebuilt the rail when the enabled-SOURCE set changed, so toggling
  /// categories in the Categories tab never refreshed the Live TV rail.
  /// Consumers snapshot this and rebuild when it moves.
  static int groupsGen = 0;

  /// finding 77: per-channel favorite generation counter, mirroring groupsGen.
  /// The TV guide's kept-alive Favorites rail (reloadGuide keep-your-place
  /// optimization) only rebuilt when the enabled-SOURCE or group set changed,
  /// so (un)starring a channel from another tab left the rail stale. Consumers
  /// snapshot this and force a rebuild when it moves. favoriteChannel() (the
  /// single chokepoint for per-channel favorite writes) bumps it.
  static int channelsGen = 0;

  static Future<void> setGroupEnabled(int groupId, bool enabled) async {
    groupsGen++; // fix645
    final db = await DbFactory.db;
    await db.execute(
      'UPDATE groups SET enabled = ? WHERE id = ?',
      [enabled ? 1 : 0, groupId],
    );
    // fix365: sync denormalized channels.cat_enabled for this group.
    await db.execute(
      'UPDATE channels SET cat_enabled = ? WHERE group_id = ?',
      [enabled ? 1 : 0, groupId],
    );
    // fix298: keep the in-memory search cache's disabled set in sync so the
    // keystroke search reflects the toggle immediately (no rebuild needed).
    ChannelSearchCache.setGroupEnabled(groupId, enabled);
  }

  /// fix298: ids of all groups with enabled = 0, for the search cache to
  /// exclude before pagination.
  static Future<Set<int>> getDisabledGroupIds() async {
    final db = await DbFactory.db;
    final rows =
        await db.getAll('SELECT id FROM groups WHERE COALESCE(enabled, 1) = 0');
    return {for (final r in rows) r.columnAt(0) as int};
  }

  // fix278: enable/disable ALL categories for the given sources (Select All /
  // Unselect All). Honors the same media-type filter the grid is showing.
  static Future<void> setAllGroupsEnabled(
    List<int> sourceIds,
    List<MediaType> mediaTypes,
    bool enabled,
  ) async {
    if (sourceIds.isEmpty) return;
    groupsGen++; // fix645
    final db = await DbFactory.db;
    final mt = mediaTypes.map((x) => x.index).toList();
    // fix296: when no media-type filter is active (mt empty), do NOT emit
    // "media_type IN ()" — that is a SQLite syntax error (peer Finding 1).
    // Empty filter means "all media types", so omit the media_type predicate.
    final mediaClause = mt.isEmpty
        ? ''
        : ' AND (media_type IS NULL OR media_type IN (${generatePlaceholders(mt.length)}))';
    await db.execute(
      'UPDATE groups SET enabled = ?'
      ' WHERE source_id IN (${generatePlaceholders(sourceIds.length)})'
      '$mediaClause',
      [enabled ? 1 : 0, ...sourceIds, ...mt],
    );
    // fix365: sync channels.cat_enabled for every channel whose group is in the
    // affected set (same WHERE as the groups UPDATE, via group membership).
    await db.execute(
      'UPDATE channels SET cat_enabled = ?'
      ' WHERE group_id IN ('
      '   SELECT id FROM groups'
      '   WHERE source_id IN (${generatePlaceholders(sourceIds.length)})'
      '$mediaClause)',
      [enabled ? 1 : 0, ...sourceIds, ...mt],
    );
    // fix298: resync the search cache's disabled set for the affected groups.
    // Re-query the exact rows the UPDATE touched (same WHERE) and apply the new
    // state to the cache so keystroke search reflects it without a rebuild.
    final affected = await db.getAll(
      'SELECT id FROM groups'
      ' WHERE source_id IN (${generatePlaceholders(sourceIds.length)})'
      '$mediaClause',
      [...sourceIds, ...mt],
    );
    ChannelSearchCache.setGroupsEnabledBulk(
      [for (final r in affected) r.columnAt(0) as int],
      enabled,
    );
  }

  // fix389: Select All / Unselect All in the Categories view when a search
  // query is active. Mirrors setAllGroupsEnabled's structure (subquery UPDATEs
  // + a re-query for the cache) but scopes to the search results via the shared
  // groupSearchWhere builder — so the bulk action toggles exactly the
  // categories the grid shows (all matches across every page, not just the ~36
  // visible) and provably the same set, including the safe-mode name block.
  // No id-list is ever bound, so there is no SQLITE_MAX_VARIABLE_NUMBER ceiling
  // on the writes regardless of how many categories match. Empty query / no
  // sources fall back to the unfiltered path.
  static Future<void> setAllGroupsEnabledForSearch(
    Filters filters,
    bool enabled,
  ) async {
    if ((filters.query ?? '').trim().isEmpty) {
      // No search query: defer to the unfiltered path (same effect, cheaper).
      await setAllGroupsEnabled(
        filters.sourceIds ?? const <int>[],
        filters.mediaTypes ?? const <MediaType>[],
        enabled,
      );
      return;
    }
    if (filters.sourceIds == null || filters.sourceIds!.isEmpty) return;
    final db = await DbFactory.db;
    final (where, params) = groupSearchWhere(filters);
    final flag = enabled ? 1 : 0;
    await db.execute(
      'UPDATE groups SET enabled = ?'
      ' WHERE id IN (SELECT id FROM groups WHERE $where)',
      [flag, ...params],
    );
    await db.execute(
      'UPDATE channels SET cat_enabled = ?'
      ' WHERE group_id IN (SELECT id FROM groups WHERE $where)',
      [flag, ...params],
    );
    // Re-query the affected ids (same WHERE) for the in-memory cache; binds only
    // the small WHERE params, never an id-list.
    final affected =
        await db.getAll('SELECT id FROM groups WHERE $where', params);
    ChannelSearchCache.setGroupsEnabledBulk(
      [for (final r in affected) r.columnAt(0) as int],
      enabled,
    );
  }

  /// fix373: warm the SQLite page cache for the browse path at startup so the
  /// first user-facing Home.load doesn't eat the cold-disk fault cost (a
  /// ~5.8s first paint on a large 2-source catalog). Runs ONE representative
  /// browse — the default view across all sources — discarding the result; the
  /// point is the side effect of pulling idx_channels_browse_mt /
  /// idx_channels_browse_enabled and their data pages into cache. Best-effort:
  /// any error is swallowed by the caller. Returns elapsed ms for logging.
  /// fix542: the deferred, one-time fix537 index maintenance — moved OFF the
  /// cold-start path because on the full ~1.43GB catalog it was ~27s of index
  /// rebuild + a full-file VACUUM on the main thread before runApp(), which
  /// blacked-out / ANR-killed the app on open. main() calls this unawaited
  /// after first frame. Gated by the app_meta marker so it runs at most once;
  /// the marker is only written after the WHOLE pass succeeds, so a partial /
  /// interrupted run simply retries on a later launch (every step is
  /// idempotent: DROP IF EXISTS, then drop-then-create). Until it completes the
  /// OLD cat_enabled-partial browse indexes remain and browse works normally.
  /// fix546: one-time deferred cleanup that DELETEs legacy "##### HEADER #####"
  /// divider rows from existing catalogs (new imports already discard them at
  /// parse time). Runs OFF the cold-start path (unawaited from main, after first
  /// frame) — on the 1.43GB field DB the delete touches ~7.5k rows across the
  /// indexes and took ~5.5s, which must never block startup (the fix542 lesson).
  /// Gated once by its own app_meta marker; best-effort and idempotent.
  static Future<void> runPendingDividerCleanup() async {
    const marker = 'fix546_dividers_purged';
    try {
      final db = await DbFactory.db;
      final done = await db.getOptional(
        "SELECT value FROM app_meta WHERE key = '$marker'",
      );
      if (done != null) return;
      AppLog.info('fix546: purging legacy divider rows…');
      final sw = Stopwatch()..start();
      await db.execute('DELETE FROM channels WHERE COALESCE(is_divider, 0) = 1;');
      await db.execute(
        "INSERT OR REPLACE INTO app_meta (key, value) VALUES ('$marker', '1');",
      );
      AppLog.info('fix546: divider purge complete (${sw.elapsedMilliseconds}ms).');
    } catch (e) {
      AppLog.warn('fix546: divider purge skipped (will retry next launch) — $e');
    }
  }

  static Future<void> runPendingIndexMaintenance() async {
    const marker = 'fix537_index_rebuild_done';
    // The 5 unused indexes to drop, and the 7 browse indexes rebuilt WITHOUT
    // `cat_enabled` in the partial predicate (so toggling cat_enabled no longer
    // churns them — the fix537 win). DDL is verified planner-equivalent.
    const dead = <String>[
      'idx_browse_cat',
      'idx_browse_cat_safe',
      'index_channel_name',
      'idx_channel_adult',
      'idx_channel_divider',
    ];
    const rebuilt = <String, String>{
      'idx_channels_browse_mt':
          'CREATE INDEX IF NOT EXISTS idx_channels_browse_mt ON channels( media_type,'
              ' (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0'
              ' WHEN COALESCE(favorite,0)=1 THEN 1'
              ' WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2'
              ' WHEN last_watched IS NOT NULL THEN 3'
              ' WHEN COALESCE(stream_validated,0)=1 THEN 4 ELSE 5 END),'
              ' name COLLATE NOCASE )'
              ' WHERE url IS NOT NULL AND series_id IS NULL',
      'idx_channels_browse_mt_safe':
          'CREATE INDEX IF NOT EXISTS idx_channels_browse_mt_safe ON channels( media_type,'
              ' (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0'
              ' WHEN COALESCE(favorite,0)=1 THEN 1'
              ' WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2'
              ' WHEN last_watched IS NOT NULL THEN 3'
              ' WHEN COALESCE(stream_validated,0)=1 THEN 4 ELSE 5 END),'
              ' name COLLATE NOCASE )'
              ' WHERE url IS NOT NULL AND series_id IS NULL'
              ' AND COALESCE(is_adult,0) = 0',
      'idx_browse_prov':
          'CREATE INDEX IF NOT EXISTS idx_browse_prov ON channels( media_type,'
              ' (CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 1 END),'
              ' (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0 ELSE 1 END),'
              ' provider_order, name COLLATE NOCASE )'
              ' WHERE url IS NOT NULL AND series_id IS NULL',
      'idx_browse_prov_safe':
          'CREATE INDEX IF NOT EXISTS idx_browse_prov_safe ON channels( media_type,'
              ' (CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 1 END),'
              ' (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0 ELSE 1 END),'
              ' provider_order, name COLLATE NOCASE )'
              ' WHERE url IS NOT NULL AND series_id IS NULL'
              ' AND COALESCE(is_adult,0) = 0',
      'idx_browse_src_mt':
          'CREATE INDEX IF NOT EXISTS idx_browse_src_mt ON channels( source_id, media_type,'
              ' (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0'
              ' WHEN COALESCE(favorite,0)=1 THEN 1'
              ' WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2'
              ' WHEN last_watched IS NOT NULL THEN 3'
              ' WHEN COALESCE(stream_validated,0)=1 THEN 4 ELSE 5 END),'
              ' name COLLATE NOCASE )'
              ' WHERE url IS NOT NULL AND series_id IS NULL',
      'idx_browse_src_mt_safe':
          'CREATE INDEX IF NOT EXISTS idx_browse_src_mt_safe ON channels( source_id, media_type,'
              ' (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0'
              ' WHEN COALESCE(favorite,0)=1 THEN 1'
              ' WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2'
              ' WHEN last_watched IS NOT NULL THEN 3'
              ' WHEN COALESCE(stream_validated,0)=1 THEN 4 ELSE 5 END),'
              ' name COLLATE NOCASE )'
              ' WHERE url IS NOT NULL AND series_id IS NULL'
              ' AND COALESCE(is_adult,0) = 0',
      'idx_channels_browse_enabled':
          'CREATE INDEX IF NOT EXISTS idx_channels_browse_enabled ON channels( source_id,'
              ' (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0'
              ' WHEN COALESCE(favorite,0)=1 THEN 1'
              ' WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2'
              ' WHEN last_watched IS NOT NULL THEN 3'
              ' WHEN COALESCE(stream_validated,0)=1 THEN 4 ELSE 5 END),'
              ' name COLLATE NOCASE )'
              ' WHERE url IS NOT NULL AND series_id IS NULL',
    };
    try {
      final db = await DbFactory.db;
      final done = await db.getOptional(
        "SELECT value FROM app_meta WHERE key = '$marker'",
      );
      if (done != null) return;
      // fix542: devices that already completed the OLD blocking migration-39
      // (its marker was 'fix537_vacuum_done') are ALREADY in the target state —
      // cat_enabled-free indexes + a VACUUMed DB. Don't redundantly re-run the
      // ~50s pass; just record the new marker and stop.
      final legacy = await db.getOptional(
        "SELECT value FROM app_meta WHERE key = 'fix537_vacuum_done'",
      );
      if (legacy != null) {
        await db.execute(
          "INSERT OR REPLACE INTO app_meta (key, value) VALUES ('$marker', '1');",
        );
        AppLog.info('fix542: legacy fix537 marker present — maintenance already'
            ' done, marking complete.');
        return;
      }
      // Review finding 127: never drop/recreate indexes while a bulk refresh
      // holds withDroppedBrowseIndexes — the two would resurrect the 5 dead
      // indexes mid-refresh and desync the drop bookkeeping. Same-isolate
      // flag is valid (both run on the foreground isolate). The marker stays
      // UNwritten so maintenance simply retries next launch, matching the
      // existing catch-block contract below.
      if (_browseIndexesDropped) {
        AppLog.info('fix537: index maintenance deferred — a bulk refresh is'
            ' dropping/rebuilding browse indexes; will retry next launch');
        return;
      }
      AppLog.info('fix542: deferred index maintenance starting…');
      final sw = Stopwatch()..start();
      // Bounded memory so the index merge-sorts spill to disk, not RAM (OOM-safe
      // on a 1-2GB box). Connection-scoped on the single persistent writer.
      try {
        await db.execute('PRAGMA temp_store = FILE;');
        await db.execute('PRAGMA cache_size = -32768;');
      } catch (_) {}
      for (final name in dead) {
        await db.execute('DROP INDEX IF EXISTS $name;');
      }
      for (final entry in rebuilt.entries) {
        await db.execute('DROP INDEX IF EXISTS ${entry.key};');
        await db.execute(entry.value);
      }
      // Review finding 128: rebuild is complete and durable — record it BEFORE
      // VACUUM so a storage-constrained box (SQLITE_FULL on VACUUM) cannot
      // force the whole multi-minute drop+rebuild to rerun every launch.
      await db.execute(
        "INSERT OR REPLACE INTO app_meta (key, value) VALUES ('$marker', '1');",
      );
      // VACUUM reclaims freed pages; genuinely best-effort. Gated on its own
      // marker so a box that can never VACUUM does not retry it every launch.
      // (fix537_vacuum_done is the SAME legacy key checked by the early-return
      // above — that check fires only when the OLD blocking migration set it,
      // before this code is reached, so there is no conflict.)
      final vacDone = await db.getOptional(
          "SELECT value FROM app_meta WHERE key = 'fix537_vacuum_done'");
      if (vacDone == null) {
        try {
          await db.execute('VACUUM;');
          await db.execute(
              "INSERT OR REPLACE INTO app_meta (key, value)"
              " VALUES ('fix537_vacuum_done', '1');");
        } catch (e) {
          AppLog.warn('fix537: VACUUM skipped (best-effort) — $e');
        }
      }
      try {
        await db.execute('PRAGMA cache_size = -2000;');
        await db.execute('PRAGMA optimize;');
      } catch (_) {}
      AppLog.info('fix542: deferred index maintenance complete'
          ' (${sw.elapsedMilliseconds}ms).');
    } catch (e) {
      // Leaves the OLD indexes in place (browse still works); retries next
      // launch since the marker is only written on full success.
      AppLog.warn('fix542: deferred index maintenance skipped'
          ' (will retry next launch) — $e');
    }
  }

  /// finding 58: the two largest full-scans that migrations 35 (fix519, the
  /// channels_fts unicode61 rebuild) and 38 (fix530, `ANALYZE`) used to run
  /// INSIDE the awaited migration chain — blocking runApp() before first frame
  /// and risking an ANR on an upgrade over a populated Shield-scale catalog.
  /// They now run here, unawaited, AFTER first frame (called from main()
  /// chained after [runPendingIndexMaintenance] so ANALYZE reflects the final
  /// fix537 index shapes). Each piece is independently, cheaply gated so it runs
  /// at most once over a populated catalog and self-heals if it didn't.
  static Future<void> runPendingFtsAndAnalyze() async {
    const analyzeMarker = 'mig38_analyze_done';
    try {
      final db = await DbFactory.db;
      // Both operations are only meaningful once the catalog has rows. On a
      // fresh install channels is empty at first launch — there is nothing to
      // backfill (the first source refresh rebuilds fts, fix621) and an
      // empty-table ANALYZE is worthless — so skip WITHOUT marking, and both
      // run on a later launch once a source is loaded.
      final hasChannels =
          await db.getOptional('SELECT 1 FROM channels LIMIT 1;') != null;
      if (!hasChannels) return;

      // (1) channels_fts backfill — condition-driven self-heal, no marker.
      // Migration 35 recreates channels_fts EMPTY, so an upgrader's channel
      // search is blank until this rebuild runs. This also self-heals a
      // channels_fts wiped by an interrupted refresh (before this, only
      // programmes_fts had a device-side rebuild path; channels_fts had none).
      // The unicode61 `rebuild` is the fix519 safe fallback — far cheaper than
      // the retired trigram. Guarded on "channels non-empty AND channels_fts
      // empty" so it is a no-op on every normal launch.
      //
      // Emptiness MUST be probed via the `_docsize` shadow table (one row per
      // INDEXED document): a bare `SELECT … FROM channels_fts` on an
      // external-content fts5 reads the CONTENT table (channels), so it would
      // report rows even when the index itself is empty. `_docsize` exists
      // because migration 35 creates the table without `columnsize=0`.
      final ftsEmpty = await db.getOptional(
              'SELECT rowid FROM channels_fts_docsize LIMIT 1;') ==
          null;
      if (ftsEmpty) {
        final sw = Stopwatch()..start();
        try {
          await db.execute('PRAGMA temp_store = FILE;');
          await db.execute('PRAGMA cache_size = -32768;');
        } catch (_) {}
        await db.execute(
            "INSERT INTO channels_fts(channels_fts) VALUES('rebuild');");
        try {
          await db.execute('PRAGMA cache_size = -2000;');
        } catch (_) {}
        AppLog.info('finding58: deferred channels_fts backfill complete'
            ' (${sw.elapsedMilliseconds}ms).');
      }

      // (2) ANALYZE — marker-gated (there is no cheap "already analyzed"
      // predicate). fix530 needs the *_safe partials' TRUE row counts so the
      // planner prefers them for Safe-Mode browse. A device that upgraded
      // through the OLD (inline-ANALYZE) mig38 has no marker yet, so it runs one
      // extra ANALYZE here — harmless, once, off the critical path.
      final analyzed = await db.getOptional(
          "SELECT value FROM app_meta WHERE key = '$analyzeMarker'");
      if (analyzed == null) {
        final sw = Stopwatch()..start();
        try {
          await db.execute('PRAGMA temp_store = FILE;');
          await db.execute('PRAGMA cache_size = -32768;');
        } catch (_) {}
        await db.execute('ANALYZE;');
        try {
          await db.execute('PRAGMA cache_size = -2000;');
        } catch (_) {}
        await db.execute("INSERT OR REPLACE INTO app_meta (key, value)"
            " VALUES ('$analyzeMarker', '1');");
        AppLog.info(
            'finding58: deferred ANALYZE complete (${sw.elapsedMilliseconds}ms).');
      }
    } catch (e) {
      // Leaves fts/stats as-is (browse still works; search may be briefly empty
      // on a fresh upgrade). Retries next launch — neither piece is marked on
      // failure.
      AppLog.warn('finding58: deferred FTS/ANALYZE skipped'
          ' (will retry next launch) — $e');
    }
  }

  // fix628: the shared 6-tier browse-order CASE. Structurally identical to
  // BrowseOrder.tier and the migration index expressions (no alias — index
  // exprs are unaliased); the planner matches structure, so this keeps every
  // rebuilt index identical to what the ORDER BY expects.
  static const String _t6 =
      '(CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0'
      ' WHEN COALESCE(favorite,0)=1 THEN 1'
      ' WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2'
      ' WHEN last_watched IS NOT NULL THEN 3'
      ' WHEN COALESCE(stream_validated,0)=1 THEN 4 ELSE 5 END)';

  // fix628: the canonical CREATE (IF NOT EXISTS) for EVERY index
  // withDroppedBrowseIndexes drops during a refresh. Single source of truth for
  // the startup self-heal. If a refresh is cancelled or the process is killed
  // between the DROP and the recreate-in-finally, these indexes are lost
  // PERMANENTLY (the finally never runs) — every browse then falls back to
  // index_channel_source_id and full-scans the ~1.2M-row catalog (10-45s;
  // confirmed onn 2026-07-01: the 20:16 refresh dropped 19 indexes, was
  // cancelled mid-FTS, and the next refresh logged "dropped 0"). Definitions
  // copied verbatim from the fix537 rebuilt set + the migrations.
  static const Map<String, String> _canonicalChannelIndexes = {
    'idx_channels_browse_mt':
        'CREATE INDEX IF NOT EXISTS idx_channels_browse_mt ON channels( media_type, $_t6, name COLLATE NOCASE ) WHERE url IS NOT NULL AND series_id IS NULL',
    'idx_channels_browse_mt_safe':
        'CREATE INDEX IF NOT EXISTS idx_channels_browse_mt_safe ON channels( media_type, $_t6, name COLLATE NOCASE ) WHERE url IS NOT NULL AND series_id IS NULL AND COALESCE(is_adult,0) = 0',
    'idx_browse_prov':
        'CREATE INDEX IF NOT EXISTS idx_browse_prov ON channels( media_type, (CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 1 END), (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0 ELSE 1 END), provider_order, name COLLATE NOCASE ) WHERE url IS NOT NULL AND series_id IS NULL',
    'idx_browse_prov_safe':
        'CREATE INDEX IF NOT EXISTS idx_browse_prov_safe ON channels( media_type, (CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 1 END), (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0 ELSE 1 END), provider_order, name COLLATE NOCASE ) WHERE url IS NOT NULL AND series_id IS NULL AND COALESCE(is_adult,0) = 0',
    'idx_browse_src_mt':
        'CREATE INDEX IF NOT EXISTS idx_browse_src_mt ON channels( source_id, media_type, $_t6, name COLLATE NOCASE ) WHERE url IS NOT NULL AND series_id IS NULL',
    'idx_browse_src_mt_safe':
        'CREATE INDEX IF NOT EXISTS idx_browse_src_mt_safe ON channels( source_id, media_type, $_t6, name COLLATE NOCASE ) WHERE url IS NOT NULL AND series_id IS NULL AND COALESCE(is_adult,0) = 0',
    'idx_channels_browse_enabled':
        'CREATE INDEX IF NOT EXISTS idx_channels_browse_enabled ON channels( source_id, $_t6, name COLLATE NOCASE ) WHERE url IS NOT NULL AND series_id IS NULL',
    'idx_browse_src_grp':
        'CREATE INDEX IF NOT EXISTS idx_browse_src_grp ON channels( source_id, group_id, $_t6, name COLLATE NOCASE ) WHERE url IS NOT NULL AND series_id IS NULL',
    'idx_channels_browse_tier':
        'CREATE INDEX IF NOT EXISTS idx_channels_browse_tier ON channels( source_id, $_t6, name COLLATE NOCASE ) WHERE url IS NOT NULL',
    'index_channel_group_id':
        'CREATE INDEX IF NOT EXISTS index_channel_group_id ON channels(group_id)',
    // fix629: index_channels_stream_id, index_channels_group_name and
    // index_channel_last_watched were dropped (migration 41). They were bare
    // single-column indexes that NO app query ever seeks on (stream_id is only
    // read by rowid/PK lookups; group_name is superseded by the group_id +
    // browse composites; last_watched is superseded by the PARTIAL composite
    // idx_channel_lastwatched_media below). They only cost write-amp on every
    // channel insert during a refresh. Removed from the canonical map so the
    // self-heal never resurrects them; see docs/CHANNELS_SQL_INDEX_MAP.md.
    'idx_channels_epg_id':
        'CREATE INDEX IF NOT EXISTS idx_channels_epg_id ON channels(epg_channel_id)',
    // fix628: PARTIAL (migration 32 / fix392). An UNCONDITIONAL index on
    // series_id matches the browse's `series_id IS NULL` predicate, gets chosen
    // by the planner, and shadows the browse-tier indexes → the fix392
    // temp-B-tree regression. The WHERE keeps it series-view-only.
    'index_channel_series_id':
        'CREATE INDEX IF NOT EXISTS index_channel_series_id ON channels(series_id) WHERE series_id IS NOT NULL',
    'index_channel_name_source':
        'CREATE INDEX IF NOT EXISTS index_channel_name_source ON channels(name, source_id)',
    'idx_epg_unmatched':
        'CREATE INDEX IF NOT EXISTS idx_epg_unmatched ON channels(source_id) WHERE media_type = 0 AND epg_manual_override IS NULL AND epg_channel_id IS NULL',
    'idx_channel_src_media_url':
        'CREATE INDEX IF NOT EXISTS idx_channel_src_media_url ON channels(source_id, media_type, url)',
    'idx_channel_lastwatched_media':
        'CREATE INDEX IF NOT EXISTS idx_channel_lastwatched_media ON channels(last_watched, media_type) WHERE last_watched IS NOT NULL',
    // fix648: the fix646 favorites partial index (migration 43) was NOT in
    // this map — an interrupted refresh would drop it permanently and the
    // self-heal would never rebuild it, silently turning the fix648 forced
    // hint off (the _indexExists gate). Def matches migration 43 verbatim.
    'idx_fav_browse':
        'CREATE INDEX IF NOT EXISTS idx_fav_browse ON channels(media_type, source_id, name COLLATE NOCASE) WHERE favorite = 1',
  };

  /// fix628: startup self-heal for the channels indexes. Rebuilds any that are
  /// missing — the primary case being an interrupted/killed refresh that
  /// dropped them without reaching the recreate (see _canonicalChannelIndexes).
  /// Also replays the exact DDL persisted by withDroppedBrowseIndexes if it was
  /// interrupted mid-run (covers any custom/future index not in the canonical
  /// map). Idempotent + cheap when all indexes are present (one lookup, no-op).
  /// MUST be called unawaited/deferred (a full rebuild of the ~1.2M-row catalog
  /// is minutes of merge-sort — never on the cold-start/splash path).
  static Future<void> ensureBrowseIndexesPresent() async {
    try {
      final db = await DbFactory.db;
      final pending = await db.getOptional(
          "SELECT value FROM app_meta WHERE key = 'pending_browse_index_ddl'");
      final names = _canonicalChannelIndexes.keys.toList();
      final present = (await db.getAll(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND name IN (${generatePlaceholders(names.length)})",
        names,
      ))
          .map((r) => r['name'] as String)
          .toSet();
      final missing = names.where((n) => !present.contains(n)).toList();
      if (missing.isEmpty && pending == null) return; // healthy — cheap no-op

      // Bounded memory so the index merge-sorts spill to disk, not RAM
      // (OOM-safe on a 1-2GB box). Connection-scoped on the single writer.
      try {
        await db.execute('PRAGMA temp_store = FILE;');
        await db.execute('PRAGMA cache_size = -32768;');
      } catch (_) {}

      // 1) Replay the exact DDL an interrupted withDroppedBrowseIndexes left
      //    behind (process killed between DROP and recreate).
      if (pending != null) {
        try {
          final ddl =
              (jsonDecode(pending['value'] as String) as List).cast<String>();
          AppLog.warn('Sql.ensureBrowseIndexesPresent: an interrupted refresh '
              'left ${ddl.length} browse index(es) un-rebuilt — replaying'
              ' persisted DDL');
          for (final sql in ddl) {
            try {
              await db.execute(sql);
            } catch (e) {
              AppLog.warn('  replay failed: $e');
            }
          }
        } catch (e) {
          AppLog.warn('Sql.ensureBrowseIndexesPresent: pending DDL parse'
              ' failed — $e');
        }
        // fix628: guard so a throw here can't skip the cache_size restore below
        // (leaving the writer at 32MiB for the session).
        try {
          await db.execute(
              "DELETE FROM app_meta WHERE key = 'pending_browse_index_ddl'");
        } catch (_) {}
      }

      // 2) Fill any canonical index still missing after the replay (covers the
      //    already-broken device that has no persisted record).
      final stillMissing = <String>[];
      for (final n in missing) {
        final row = await db.getOptional(
            "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
            [n]);
        if (row == null) stillMissing.add(n);
      }
      if (stillMissing.isNotEmpty) {
        AppLog.warn('Sql.ensureBrowseIndexesPresent: rebuilding'
            ' ${stillMissing.length} missing channels index(es) (likely lost to'
            ' an interrupted/killed refresh): ${stillMissing.join(", ")}');
        for (var i = 0; i < stillMissing.length; i++) {
          final n = stillMissing[i];
          final sw = Stopwatch()..start();
          try {
            await db.execute(_canonicalChannelIndexes[n]!);
            AppLog.info('Sql.ensureBrowseIndexesPresent: built'
                ' ${i + 1}/${stillMissing.length} $n'
                ' (${sw.elapsedMilliseconds}ms)');
          } catch (e) {
            AppLog.error(
                'Sql.ensureBrowseIndexesPresent: FAILED to build $n — $e');
          }
        }
      }
      try {
        await db.execute('PRAGMA cache_size = -2000;');
        await db.execute('PRAGMA optimize;');
      } catch (_) {}
    } catch (e) {
      AppLog.warn('Sql.ensureBrowseIndexesPresent: skipped'
          ' (will retry next launch) — $e');
    }
  }

  static Future<int> warmBrowseCache(Settings settings) async {
    final sw = Stopwatch()..start();
    try {
      final sourceIds = await _allSourceIds();
      if (sourceIds.isEmpty) return 0;
      // Mirror the default browse: livestream first (what the home screen loads
      // first), no query, page 1. Small LIMIT — we only need to touch the hot
      // pages, not materialize the whole view.
      final filters = Filters(
        sourceIds: sourceIds,
        mediaTypes: [MediaType.livestream],
        viewType: ViewType.all,
        page: 1,
        safeMode: settings.safeMode,
        searchMethod: settings.searchMethod,
      );
      await search(filters);
    } catch (_) {
      // Best-effort warm-up; never block or crash startup.
    }
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  static Future<List<int>> _allSourceIds() async {
    final db = await DbFactory.db;
    final rows = await db.getAll('SELECT id FROM sources');
    return rows.map((r) => r.columnAt(0) as int).toList();
  }

  // fix389: THE single source of truth for the Categories-search WHERE clause
  // and its bind params. Used by searchGroup (the grid the user sees) and by
  // setAllGroupsEnabledForSearch (the Select/Unselect-All bulk toggle). Because
  // both call this one builder, the bulk action provably selects the exact same
  // groups the grid shows — including the safe-mode name block, which an earlier
  // hand-built copy of this WHERE omitted. Returns (whereSql, params); callers
  // append their own ORDER BY / LIMIT (and bind offset/limit) afterwards.
  static (String, List<Object>) groupSearchWhere(Filters filters) {
    final query = filters.query ?? "";
    final keywords = filters.useKeywords
        ? query.split(" ").map((f) => "%$f%").toList()
        : ["%$query%"];
    final mediaTypes =
        (filters.mediaTypes ?? const <MediaType>[]).map((x) => x.index).toList();
    final mediaClause = mediaTypes.isEmpty
        ? ''
        : ' AND (media_type IS NULL OR media_type IN'
            ' (${generatePlaceholders(mediaTypes.length)}))';
    final sourceIds = filters.sourceIds ?? const <int>[];
    final (smClause, smParams) = safeModeGroupClause(filters.safeMode);
    final where = '(${getKeywordsSql(keywords.length)})'
        '$mediaClause'
        ' AND source_id IN (${generatePlaceholders(sourceIds.length)})'
        '$smClause';
    return (where, <Object>[...keywords, ...mediaTypes, ...sourceIds, ...smParams]);
  }

  static Future<List<Channel>> searchGroup(Filters filters) async {
    final rawGroupQuery = (filters.query ?? "").trim();
    // fix401: align the Categories minimum with fix400's >=2-char UI gate (the
    // old < 3 made Categories silently require 3 chars even on likeSubstring,
    // where a 2-char query matches fine). Groups are small and LIKE-searched,
    // so a 2-char scan is cheap. The channel-search FTS path keeps its own < 3
    // handling (trigram needs 3; a bare 2-char LIKE over 90k channels is slow).
    if (groupSearchAllTermsTooShort(rawGroupQuery,
        useKeywords: filters.useKeywords)) {
      AppLog.info(
        'Sql.searchGroup: branch=short-skip'
        ' query="$rawGroupQuery" — all terms < 2 chars, skipping scan',
      );
      return [];
    }
    var db = await DbFactory.db;
    var offset = filters.page * pageSize - pageSize;
    // fix389: build the WHERE (keywords + media type + source + safe mode) from
    // the shared groupSearchWhere so this grid and the Select/Unselect-All bulk
    // action can never diverge.
    final (groupWhere, groupParams) = groupSearchWhere(filters);
    var sqlQuery = 'SELECT * FROM groups WHERE $groupWhere';
    List<Object> params = [...groupParams];

    // fix308: favorited categories sort to the top.
    // fix356: alphabetical within each tier (was rowid order).
    // fix372: enabled categories sort above disabled ones. The Categories home
    // view shows disabled categories grayed-out (groupEnabled drives the tile
    // styling), but they were intermixed alphabetically with enabled ones — so
    // an enabled category could sit below a wall of disabled ones. Tier order
    // is now: favorites first, then enabled-before-disabled, then A–Z. enabled
    // defaults to 1, so a brand-new source (nothing toggled) is unaffected.
    // fix378: when the in-scope sources share a `provider` sort_mode, group
    // categories by source name A–Z, then category A–Z within each source —
    // so a user with multiple provider-ordered sources sees their categories
    // interleaved by source, matching the source-name grouping they see in
    // Favorites (fix377) and the rest of search. alpha and `category` modes
    // (and null/mixed) keep the A–Z form: there's no natural "category" order
    // for a list of categories, and the no-op for null/mixed avoids forcing
    // a correlated subquery on a rare path.
    final groupUniformMode =
        await _uniformSortMode(filters.sourceIds!);
    if (groupUniformMode == 'provider') {
      sqlQuery += '\nORDER BY COALESCE(favorite, 0) DESC,'
          ' COALESCE(enabled, 1) DESC,'
          ' (SELECT s.name FROM sources s WHERE s.id = source_id)'
          ' COLLATE NOCASE ASC,'
          ' name COLLATE NOCASE ASC, id ASC';
    } else {
      sqlQuery += '\nORDER BY COALESCE(favorite, 0) DESC,'
          ' COALESCE(enabled, 1) DESC,'
          ' name COLLATE NOCASE ASC, id ASC';
    }

    sqlQuery += '\nLIMIT ?, ?';
    params.add(offset);
    params.add(pageSize);
    var results = await db.getAll(sqlQuery, params);
    return results.map(groupChannelToRow).toList();
  }

  static Channel groupChannelToRow(Row row) {
    return Channel(
        id: row.columnAt(0),
        name: row.columnAt(1),
        image: row.columnAt(2),
        sourceId: row.columnAt(3),
        favorite: (row.columnAt(6) as int?) == 1, // fix308 (col 6 = favorite)
        groupEnabled: (row.columnAt(5) as int?) != 0, // fix278 (col 5 = enabled)
        mediaType: MediaType.group);
  }

  // fix308: toggle a category's favorite flag (sorts it to the top of the
  // Categories list; does NOT touch the channels inside it).
  static Future<void> favoriteGroup(int groupId, bool favorite) async {
    groupsGen++; // fix645: favorites sort to the top of the rail (fix308)
    final db = await DbFactory.db;
    await db.execute(
      'UPDATE groups SET favorite = ? WHERE id = ?',
      [favorite ? 1 : 0, groupId],
    );
  }

  static Future<bool> sourceNameExists(String? name) async {
    var db = await DbFactory.db;
    var result = await db.getOptional('''
      SELECT 1
      FROM sources
      WHERE name = ?
    ''', [name]);
    return result?.columnAt(0) == 1;
  }

  static Future<List<Source>> getSources() async {
    var db = await DbFactory.db;
    var results = await db.getAll('''
      SELECT *
      FROM sources
    ''');
    final sources = results.map(rowToSource).toList();
    // fix374: keep the log-redaction table current. getSources() is the read
    // chokepoint hit at startup and after every add/edit/delete/import, so the
    // token map always reflects the live source set without scattered hooks.
    AppLog.setSourceSecrets(sources);
    return sources;
  }

  static Future<Source?> getSourceById(int id) async {
    var db = await DbFactory.db;
    final row = await db.getOptional(
      'SELECT * FROM sources WHERE id = ?',
      [id],
    );
    return row == null ? null : rowToSource(row);
  }

  static Source rowToSource(Row row) {
    // Column order: id(0) name(1) source_type(2) url(3) username(4)
    //   password(5) enabled(6) epg_url(7) default_engine(8)
    //   max_connections(9)  ← fix184    color(10)  ← fix196
    //   sort_mode(11) ← fix256 (migration 20)
    //   last_live_count(12)/last_movie_count(13)/last_series_count(14)
    //   ← fix268 (migration 21)
    //   hide_dividers(15) ← fix272 (migration 22)
    //   epg_discovery_state(16) ← fix386 (migration 31)
    //   exp_date(17)/status(18) ← fix641 (migration 42)
    return Source(
      id: row.columnAt(0),
      name: row.columnAt(1),
      sourceType: SourceType.values[row.columnAt(2)],
      url: row.columnAt(3),
      username: row.columnAt(4),
      password: row.columnAt(5),
      enabled: row.columnAt(6) == 1,
      epgUrl: row.columnAt(7) as String?,
      // col 8 = default_engine — deprecated fix350, retained in schema.
      maxConnections: row.columnAt(9) as int?,
      color: row.columnAt(10) as int?,
      sortMode: row.columnAt(11) as String?, // fix256 (migration 20 column)
      lastLiveCount: row.columnAt(12) as int?, // fix268 (migration 21)
      lastMovieCount: row.columnAt(13) as int?,
      lastSeriesCount: row.columnAt(14) as int?,
      hideDividers: row.columnAt(15) as int?, // fix272 (migration 22)
      epgDiscoveryState: row.columnAt(16) as String?, // fix386 (migration 31)
      expDate: row.columnAt(17) as int?, // fix641 (migration 42)
      status: row.columnAt(18) as String?, // fix641 (migration 42)
    );
  }

  static Future<List<IdData<SourceType>>> getEnabledSourcesMinimal() async {
    var db = await DbFactory.db;
    var results = await db.getAll('''
      SELECT id, source_type
      FROM sources 
      WHERE enabled = 1
    ''');
    return results.map(rowToSourceMinimal).toList();
  }

  static IdData<SourceType> rowToSourceMinimal(Row row) {
    return IdData(
        id: row.columnAt(0), data: SourceType.values[row.columnAt(1)]);
  }

  static Future<bool> hasSources() async {
    var db = await DbFactory.db;
    var result = await db.getOptional('''
      SELECT 1
      FROM sources
      LIMIT 1
    ''');
    return result?.columnAt(0) == 1;
  }

  static Future<void> favoriteChannel(int channelId, bool favorite) async {
    var db = await DbFactory.db;
    await db.execute('''
      UPDATE channels
      SET favorite = ?
      WHERE id = ?
    ''', [favorite ? 1 : 0, channelId]);
    ChannelSearchCache.updateFavorite(channelId, favorite);
    channelsGen++; // finding 77: signal the kept-alive guide Favorites rail
  }

  static Future<HashMap<String, String>> getSettings() async {
    var db = await DbFactory.db;
    var results = await db.getAll('''SELECT key, value FROM Settings''');
    return HashMap.fromEntries(
        results.map((f) => MapEntry(f.columnAt(0), f.columnAt(1))));
  }

  static Future<void> updateSettings(HashMap<String, String> settings) async {
    var db = await DbFactory.db;
    await db.writeTransaction((tx) async {
      for (var entry in settings.entries) {
        await tx.execute('''
        INSERT INTO Settings (key, value)
        VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = ?''',
            [entry.key, entry.value, entry.value]);
      }
    });
  }

  // finding 63: does the source still have any rows of this media type? Used by
  // the Xtream refresh to preserve existing rows on a transient empty fetch even
  // when the recorded last_*_count is NULL/0 (which shouldRetryType gates on).
  // Authoritative over the drift-prone last_*_count columns.
  static Future<bool> sourceHasMediaType(int sourceId, MediaType t) async {
    var db = await DbFactory.db;
    final r = await db.getOptional(
      'SELECT 1 FROM channels WHERE source_id = ? AND media_type = ? LIMIT 1',
      [sourceId, t.index],
    );
    return r != null;
  }

  static Future<void> deleteSource(int sourceId) async {
    // Clean up EPG data in epg.sqlite first (cross-file FK can't cascade).
    await deleteEpgForSource(sourceId);
    var db = await DbFactory.db;
    await db.writeTransaction((tx) async {
      // finding 55: ON DELETE CASCADE on movie_positions/channel_http_headers is
      // inert (PRAGMA foreign_keys is OFF), so delete the dependent rows
      // explicitly BEFORE the channels DELETE while the subquery can still see
      // the channel ids. rowids are reused after a wipe, so leaving these rows
      // would misbind them to new channels.
      await tx.execute(
          "DELETE FROM movie_positions WHERE channel_id IN "
          "(SELECT id FROM channels WHERE source_id = ?)",
          [sourceId]);
      await tx.execute(
          "DELETE FROM channel_http_headers WHERE channel_id IN "
          "(SELECT id FROM channels WHERE source_id = ?)",
          [sourceId]);
      await tx.execute("DELETE FROM channels WHERE source_id = ?", [sourceId]);
      await tx.execute("DELETE FROM groups WHERE source_id = ?", [sourceId]);
      await tx.execute("DELETE FROM sources WHERE id = ?", [sourceId]);
    });
  }

  static Future<void> Function(SqliteWriteContext, Map<String, String>)
      wipeSource(int sourceId, {Set<int> keepMediaTypes = const {}}) {
    return (SqliteWriteContext tx, Map<String, String> memory) async {
      final countRow = await tx.getOptional(
        'SELECT COUNT(*) FROM channels WHERE source_id = ?', [sourceId]);
      final before = countRow?.columnAt(0) ?? 0;
      // fix298: preserve per-category enabled state across refresh. wipeSource
      // deletes the groups rows, so without this the recreated groups would all
      // default to enabled=1 and the user's disabled categories would silently
      // turn back on every refresh. Stash the disabled group NAMES (keyed by
      // name, which survives re-import) for updateGroups to restore.
      final disabledRows = await tx.getAll(
        'SELECT name FROM groups WHERE source_id = ? AND COALESCE(enabled,1) = 0',
        [sourceId],
      );
      // fix320: a group can have a NULL name (e.g. a provider stream with a
      // null category_id produced a nameless category). columnAt(0) as String
      // then throws and aborts the whole refresh mid-wipe (observed on Dino,
      // crashing the series fetch). Treat a null name as "Uncategorized" so the
      // disabled state is still tracked by that name (matching the synthetic
      // name xtreamToChannel now assigns to null categories).
      final disabledNames = [
        for (final r in disabledRows)
          (r.columnAt(0) as String?) ?? 'Uncategorized'
      ];
      memory['disabledGroupNames'] = jsonEncode(disabledNames);
      // fix321: a content type whose fresh fetch came back empty (after one
      // retry) for a source that previously HAD that type is treated as a
      // transient provider failure — keep its existing channels rather than
      // wiping them. keepMediaTypes holds those media_type indices; their rows
      // (and groups used only by them) are left untouched.
      if (keepMediaTypes.isEmpty) {
        // finding 55: cascades are inert (PRAGMA foreign_keys is OFF); delete
        // dependent rows explicitly BEFORE channels, for exactly the channel
        // ids about to be removed.
        await tx.execute(
            'DELETE FROM movie_positions WHERE channel_id IN '
            '(SELECT id FROM channels WHERE source_id = ?)',
            [sourceId]);
        await tx.execute(
            'DELETE FROM channel_http_headers WHERE channel_id IN '
            '(SELECT id FROM channels WHERE source_id = ?)',
            [sourceId]);
        await tx.execute(
            'DELETE FROM channels WHERE source_id = ?', [sourceId]);
        await tx.execute('DELETE FROM groups WHERE source_id = ?', [sourceId]);
      } else {
        final placeholders = List.filled(keepMediaTypes.length, '?').join(',');
        // finding 55: mirror the channels predicate so dependents are deleted
        // for exactly the channel ids about to be removed (media_type NOT IN
        // the kept set), BEFORE the channels DELETE.
        await tx.execute(
          'DELETE FROM movie_positions WHERE channel_id IN '
          '(SELECT id FROM channels WHERE source_id = ? '
          ' AND media_type NOT IN ($placeholders))',
          [sourceId, ...keepMediaTypes],
        );
        await tx.execute(
          'DELETE FROM channel_http_headers WHERE channel_id IN '
          '(SELECT id FROM channels WHERE source_id = ? '
          ' AND media_type NOT IN ($placeholders))',
          [sourceId, ...keepMediaTypes],
        );
        await tx.execute(
          'DELETE FROM channels WHERE source_id = ? '
          'AND media_type NOT IN ($placeholders)',
          [sourceId, ...keepMediaTypes],
        );
        // Only delete groups that have no surviving (kept) channels, so the
        // categories of preserved types remain intact.
        await tx.execute(
          'DELETE FROM groups WHERE source_id = ? AND id NOT IN '
          '(SELECT DISTINCT group_id FROM channels '
          ' WHERE source_id = ? AND group_id IS NOT NULL)',
          [sourceId, sourceId],
        );
        AppLog.info(
          'Sql.wipeSource: sourceId=$sourceId keeping media types '
          '${keepMediaTypes.toList()} (transient empty fetch)',
        );
      }
      AppLog.info('Sql.wipeSource: sourceId=$sourceId deleted $before channels');
    };
  }

  // fix387: the SET clause omitted `name = ?`, so Edit Source renames
  // (made editable in fix385) were silently dropped — every other editable
  // field was persisted, the name alone was not. Extracted to a const so the
  // Rule-8 test executes the exact statement the app runs; a future regression
  // that drops a SET column changes the placeholder count and fails the test.
  static const String updateSourceSql = '''
      UPDATE sources
      SET name = ?, url = ?, username = ?, password = ?,
          max_connections = ?, color = ?, sort_mode = ?,
          last_live_count = ?, last_movie_count = ?, last_series_count = ?,
          hide_dividers = ?, exp_date = ?, status = ?
      WHERE id = ?
    ''';

  static Future<void> updateSource(Source source) async {
    var db = await DbFactory.db;
    await db.execute(updateSourceSql, [
      source.name,
      source.url,
      source.username,
      source.password,
      source.maxConnections,
      source.color,
      source.sortMode, // fix256
      source.lastLiveCount, // fix268
      source.lastMovieCount,
      source.lastSeriesCount,
      source.hideDividers, // fix272
      source.expDate, // fix641
      source.status, // fix641
      source.id,
    ]);
  }

  static Future<Source> getSourceFromId(int id) async {
    var db = await DbFactory.db;
    var result = await db.get('''SELECT * FROM sources WHERE id = ?''', [id]);
    return rowToSource(result);
  }

  static Future<void> setSourceEnabled(bool enabled, int sourceId) async {
    var db = await DbFactory.db;
    await db.execute('''
      UPDATE sources 
      SET enabled = ? 
      WHERE id = ?
    ''', [enabled, sourceId]);
  }

  /// fix355 (backup): per-source curated category state — only rows the
  /// user actually changed (favorited or disabled), keeping exports small.
  static Future<List<Map<String, Object?>>> getGroupsCurated(
      int sourceId) async {
    final db = await DbFactory.db;
    final rows = await db.getAll(
      'SELECT name, COALESCE(favorite,0) f, COALESCE(enabled,1) e'
      ' FROM groups WHERE source_id = ?'
      ' AND (COALESCE(favorite,0) = 1 OR COALESCE(enabled,1) = 0)',
      [sourceId],
    );
    return [
      for (final r in rows)
        {
          'name': r.columnAt(0) as String?,
          'favorite': r.columnAt(1) as int,
          'enabled': r.columnAt(2) as int,
        }
    ];
  }

  /// fix355 (backup): apply imported category state by (source, name).
  static Future<void> applyGroupState(
      int sourceId, String name, int favorite, int enabled) async {
    final db = await DbFactory.db;
    await db.execute(
      'UPDATE groups SET favorite = ?, enabled = ?'
      ' WHERE source_id = ? AND name = ?',
      [favorite, enabled, sourceId, name],
    );
    // fix370/HIGH-1: keep the denormalized channels.cat_enabled (fix365) in
    // sync. applyGroupState runs during backup restore AFTER the refresh that
    // sets cat_enabled, so without this a restored "disabled" category leaked
    // into browse until the next manual refresh. Match channels by the group's
    // resolved id for this source+name.
    await db.execute(
      'UPDATE channels SET cat_enabled = ?'
      ' WHERE source_id = ? AND group_id ='
      ' (SELECT id FROM groups WHERE source_id = ? AND name = ? LIMIT 1)',
      [enabled, sourceId, sourceId, name],
    );
  }

  /// fix355 (backup): VOD resume positions keyed by channel URL (the stable
  /// identity across devices; names repeat across series episodes).
  static Future<List<Map<String, Object?>>> getMoviePositionsForExport(
      int sourceId) async {
    final db = await DbFactory.db;
    final rows = await db.getAll(
      'SELECT c.url, mp.position FROM movie_positions mp'
      ' JOIN channels c ON c.id = mp.channel_id'
      ' WHERE c.source_id = ? AND c.url IS NOT NULL AND mp.position > 0',
      [sourceId],
    );
    return [
      for (final r in rows)
        {
          'url': r.columnAt(0) as String?,
          'position': r.columnAt(1) as int,
        }
    ];
  }

  /// fix355 (backup): re-attach an imported resume position to the local
  /// channel row matching (source, url). No-op when the channel does not
  /// exist yet (e.g. an episode whose series has not been opened).
  static Future<void> applyMoviePosition(
      int sourceId, String url, int position) async {
    final db = await DbFactory.db;
    await db.execute('''
      INSERT INTO movie_positions (channel_id, position)
      SELECT id, ? FROM channels WHERE source_id = ? AND url = ?
      ON CONFLICT (channel_id)
      DO UPDATE SET position = excluded.position;
    ''', [position, sourceId, url]);
  }

  static Future setPosition(int channelId, int seconds) async {
    var db = await DbFactory.db;
    await db.execute('''
      INSERT INTO movie_positions (channel_id, position)
      VALUES (?, ?)
      ON CONFLICT (channel_id)
      DO UPDATE SET
      position = excluded.position;
    ''', [channelId, seconds]);
  }

  static Future<int?> getPosition(int channelId) async {
    var db = await DbFactory.db;
    var result = await db.getOptional('''
      SELECT position FROM movie_positions
      WHERE channel_id = ?
    ''', [channelId]);
    return result?.columnAt(0);
  }

  static Future<void> deleteHistoryEntry(int channelId) async {
    var db = await DbFactory.db;
    await db.execute(
      'UPDATE channels SET last_watched = NULL WHERE id = ?',
      [channelId],
    );
    ChannelSearchCache.updateLastWatched(channelId, null);
  }

  /// fix524: clear ALL watch history (TV History tab long-press). Nulls
  /// last_watched for every channel; unscoped sibling of deleteHistoryEntry.
  static Future<void> clearHistory() async {
    var db = await DbFactory.db;
    await db.execute(
      'UPDATE channels SET last_watched = NULL WHERE last_watched IS NOT NULL',
    );
    ChannelSearchCache.clearAllHistory();
  }

  static Future<void> addToHistory(int id) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var db = await DbFactory.db;
    await db.execute(
      'UPDATE channels SET last_watched = ? WHERE id = ?',
      [now, id],
    );
    await db.execute('''
      UPDATE channels
      SET last_watched = NULL
      WHERE last_watched IS NOT NULL
		  AND id NOT IN (
				SELECT id
				FROM channels
				WHERE last_watched IS NOT NULL
				ORDER BY last_watched DESC
				LIMIT 36
		  )
    ''');
    // The pruning query above may null-out older entries in SQLite; the cache
    // stays slightly optimistic for those until the next rebuild (acceptable —
    // they're beyond top-36 history anyway).
    ChannelSearchCache.updateLastWatched(id, now);
  }

  /// Capture per-channel attributes that must survive a source wipe.
  static Future<List<ChannelPreserve>> getChannelsPreserve(int sourceId) async {
    var db = await DbFactory.db;
    var results = await db.getAll('''
      SELECT name, favorite, last_watched, epg_channel_id, epg_manual_override,
             stream_validated
      FROM channels
      WHERE source_id = ?
        AND (
          favorite = 1
          OR last_watched IS NOT NULL
          OR epg_channel_id IS NOT NULL
          OR epg_manual_override IS NOT NULL
          OR stream_validated IS NOT NULL
        )
    ''', [sourceId]);
    final preserve = results.map(rowToChannelPreserve).toList();
    AppLog.info(
      'Sql.getChannelsPreserve: sourceId=$sourceId'
      ' total=${preserve.length}'
      ' favorites=${preserve.where((p) => p.favorite == 1).length}'
      ' lastWatched=${preserve.where((p) => p.lastWatched != null).length}'
      ' epgMatched=${preserve.where((p) => p.epgChannelId != null).length}'
      ' epgManual=${preserve.where((p) => p.epgManualOverride != null).length}',
    );
    return preserve;
  }

  /// finding 93: backup-only variant. Excludes rows whose ONLY non-null
  /// attribute is an auto-populated epg_channel_id or stream_validated — those
  /// are re-derivable from the provider M3U (tvg-id) and re-validation, so they
  /// do not belong in a user-authored backup and balloon the JSON to hundreds
  /// of thousands of rows on multi-source catalogs. Keeps favorite /
  /// last_watched / epg_manual_override (the user-authored data) plus
  /// epg_channel_id ONLY when it accompanies user data. Do NOT reuse the shared
  /// getChannelsPreserve here — that path (source refresh preserve/restore)
  /// legitimately must keep stream_validated across a refresh.
  static Future<List<ChannelPreserve>> getChannelsPreserveForBackup(
      int sourceId) async {
    var db = await DbFactory.db;
    var results = await db.getAll('''
      SELECT name, favorite, last_watched, epg_channel_id, epg_manual_override,
             stream_validated
      FROM channels
      WHERE source_id = ?
        AND (
          favorite = 1
          OR last_watched IS NOT NULL
          OR epg_manual_override IS NOT NULL
        )
    ''', [sourceId]);
    return results.map(rowToChannelPreserve).toList();
  }

  static ChannelPreserve rowToChannelPreserve(Row row) {
    return ChannelPreserve(
      name: row.columnAt(0),
      favorite: row.columnAt(1),
      lastWatched: row.columnAt(2),
      epgChannelId: row.columnAt(3) as String?,
      epgManualOverride: row.columnAt(4) as String?,
      streamValidated: row.columnAt(5) as int?,
    );
  }

  /// Restore per-channel attributes after a wipe+re-import.
  ///
  /// When a manual override is present, write it to BOTH
  /// epg_manual_override AND epg_channel_id so that the guide lookup (which
  /// reads epg_channel_id) immediately reflects the user's explicit pin.
  /// Without this, the override was stored in epg_manual_override but
  /// epg_channel_id kept whatever the fresh M3U/Xtream import wrote, making
  /// the override appear set but have no effect on the EPG display.
  /// For non-manual restores, epg_channel_id uses COALESCE so a fresher
  /// value from the import is preserved.
  static Future<void> Function(SqliteWriteContext, Map<String, String>)
      restorePreserve(List<ChannelPreserve> preserve) {
    return (SqliteWriteContext tx, Map<String, String> memory) async {
      final sourceId = int.parse(memory['sourceId']!);
      if (preserve.isEmpty) {
        AppLog.info('Sql.restorePreserve: sourceId=$sourceId total=0');
        return;
      }
      // fix226: batched, set-based restore. The old code ran one awaited
      // tx.execute UPDATE per preserved row — on-device each tx.execute is an
      // isolate round-trip costing several ms, so 21,794 rows took ~150s
      // (measured via fix222 closure timing). We instead bulk-load the preserve
      // rows into an indexed TEMP table (~few dozen round-trips) and apply ONE
      // set-based UPDATE...FROM join. Same semantics:
      //   - manual override (epg_manual_override != null): pin both
      //     epg_channel_id and epg_manual_override to the override value.
      //   - auto: epg_channel_id = COALESCE(existing, preserved) (keep fresher
      //     import value), epg_manual_override = NULL.
      // Measured ~190ms in-sandbox for 21,794 rows vs ~150s for the per-row loop.
      var restoredEpg = 0;
      var restoredManual = 0;
      await tx.execute('DROP TABLE IF EXISTS _preserve_restore');
      await tx.execute('CREATE TEMP TABLE _preserve_restore ('
          'name TEXT, source_id INTEGER, favorite INTEGER, '
          'last_watched INTEGER, epg_channel_id TEXT, '
          'epg_manual_override TEXT, stream_validated INTEGER)');
      const rowPlaceholder = '(?, ?, ?, ?, ?, ?, ?)';
      for (var i = 0; i < preserve.length; i += bulkInsertRows) {
        final end = (i + bulkInsertRows < preserve.length)
            ? i + bulkInsertRows
            : preserve.length;
        final chunk = preserve.sublist(i, end);
        final values = List.filled(chunk.length, rowPlaceholder).join(', ');
        final params = <Object?>[];
        for (final channel in chunk) {
          params.addAll([
            channel.name,
            sourceId,
            channel.favorite,
            channel.lastWatched,
            channel.epgChannelId,
            channel.epgManualOverride,
            channel.streamValidated,
          ]);
          if (channel.epgManualOverride != null) {
            restoredManual++;
          } else if (channel.epgChannelId != null) {
            restoredEpg++;
          }
        }
        await tx.execute(
          'INSERT INTO _preserve_restore (name, source_id, favorite, '
          'last_watched, epg_channel_id, epg_manual_override, stream_validated) '
          'VALUES $values',
          params,
        );
      }
      await tx.execute('CREATE INDEX _preserve_restore_idx '
          'ON _preserve_restore (name, source_id)');
      // fix236: match on (name, source_id) using index_channel_name_source
      // (created in migration 18). The old fix230 hint `INDEXED BY
      // channels_unique` referenced an index that migrations 14/15 (fix174/178)
      // DROPPED — re-keying uniqueness to provider stream/series ids — so it
      // threw "no such index". With a real (name, source_id) index present the
      // planner picks it automatically (no hint needed): ~25ms vs ~134s when it
      // fell back to the source_id-only index.
      await tx.execute('''
        UPDATE channels SET
          favorite            = p.favorite,
          last_watched        = p.last_watched,
          epg_channel_id      = CASE
              WHEN p.epg_manual_override IS NOT NULL THEN p.epg_manual_override
              ELSE COALESCE(channels.epg_channel_id, p.epg_channel_id)
            END,
          epg_manual_override = p.epg_manual_override,
          stream_validated    = COALESCE(p.stream_validated, channels.stream_validated)
        FROM _preserve_restore p
        WHERE p.name = channels.name AND p.source_id = channels.source_id
      ''');
      await tx.execute('DROP TABLE _preserve_restore');
      AppLog.info(
        'Sql.restorePreserve: sourceId=$sourceId'
        ' total=${preserve.length}'
        ' epgRestored=$restoredEpg'
        ' manualRestored=$restoredManual'
        ' (batched)',
      );
    };
  }


  /// Persist a stream scan result for a channel.
  /// [isValid] = true → stream confirmed as media.
  /// [isValid] = false → stream unreachable or not media.
  /// The value persists across sessions and is only updated by a new scan.
  static Future<void> setStreamValidated(int channelId, bool isValid) async {
    final db = await DbFactory.db;
    await db.execute(
      'UPDATE channels SET stream_validated = ? WHERE id = ?',
      [isValid ? 1 : 0, channelId],
    );
    AppLog.info(
      'Sql.setStreamValidated: channel=$channelId'
      ' validated=${isValid ? "✓" : "✗"}',
    );
    // green validation indicator immediately.
    ChannelSearchCache.updateStreamValidated(channelId, isValid);
  }

  /// Reset all stream_validated flags to NULL.
  /// Called from Settings → Reset → "Clear stream validation".
  static Future<void> clearAllStreamValidated() async {
    final db = await DbFactory.db;
    await db.execute('UPDATE channels SET stream_validated = NULL');
    AppLog.info('Sql.clearAllStreamValidated: reset all stream_validated flags');
    ChannelSearchCache.clearAllStreamValidated();
  }


  /// Persist the EPG URL for a source.
  static Future<void> setSourceEpgUrl(int sourceId, String? url) async {
    var db = await DbFactory.db;
    await db.execute(
      'UPDATE sources SET epg_url = ? WHERE id = ?',
      [url, sourceId],
    );
  }

  /// fix386: persist the result of an EPG auto-discovery probe.
  ///
  /// [url] is the auto-detected XMLTV endpoint (null for a 'none'
  /// result, in which case the existing [epg_url] is preserved —
  /// the user might have set it manually and we don't want to clobber
  /// their value just because a probe missed).
  ///
  /// [state] is one of 'auto' or 'none'. 'manual' is set by the
  /// existing EPG dialog and should NOT be touched here.
  static Future<void> setSourceEpgDiscovery(
    int sourceId, {
    String? url,
    required String state,
  }) async {
    final db = await DbFactory.db;
    if (url != null) {
      // Auto-detected an endpoint — persist the URL + state.
      await db.execute(
        'UPDATE sources SET epg_url = ?, epg_discovery_state = ? WHERE id = ?',
        [url, state, sourceId],
      );
    } else {
      // No endpoint found — only touch the state; preserve any
      // existing epg_url (user might have set it manually before
      // the probe ran).
      await db.execute(
        'UPDATE sources SET epg_discovery_state = ? WHERE id = ?',
        [state, sourceId],
      );
    }
  }

  /// Write matched/manual EPG channel IDs back to the channels table.
  ///
  /// Uses a chunked CTE-based UPDATE so a 10k-entry map costs ~50
  /// statements instead of 10k single-row UPDATEs.
  ///
  /// The earlier `UPDATE … FROM (VALUES …) AS _data(id, epg)` form
  /// required SQLite 3.39+ (for the derived-table column-alias-list
  /// syntax) and produced "syntax error near '('" on devices whose
  /// loaded sqlite is older. The CTE-based form below
  /// works on SQLite 3.8.3+ (2014), which covers every plausible
  /// runtime including the system sqlite on older Android.
  static Future<void> setChannelEpgIds(
    Map<int, String> channelIdToEpgId,
  ) async {
    if (channelIdToEpgId.isEmpty) return;
    // SQLite limits a single statement to 999 bind parameters; 2 params
    // per row → chunks of 200 stay well under that.
    const chunkSize = 200;
    final entries = channelIdToEpgId.entries.toList(growable: false);
    final db = await DbFactory.db;
    // Review finding 130: this is the ONLY epg-assignment writer that called
    // db.writeTransaction directly with no SQLITE_BUSY retry — it runs from
    // BOTH the foreground isolate and the Workmanager background isolate, so
    // cross-isolate contention returned code 5 straight to the caller. The
    // retry helper is DB-agnostic despite the "epg" name.
    await _epgWriteWithRetry('setChannelEpgIds',
        () => db.writeTransaction((tx) async {
      for (var offset = 0; offset < entries.length; offset += chunkSize) {
        final end = offset + chunkSize > entries.length
            ? entries.length
            : offset + chunkSize;
        final chunk = entries.sublist(offset, end);

        // Build a CTE that names its columns INSIDE the WITH clause —
        // the universally-supported way to alias derived-table columns
        //   WITH _data(id, epg) AS (VALUES (?,?), …)
        // The UPDATE then references _data.id / _data.epg normally.
        final placeholders = List.filled(chunk.length, '(?,?)').join(',');
        final params = <Object?>[];
        for (final e in chunk) {
          params
            ..add(e.key)
            ..add(e.value);
        }
        await tx.execute('''
          WITH _data(id, epg) AS (VALUES $placeholders)
          UPDATE channels
             SET epg_channel_id = (
               SELECT epg FROM _data WHERE _data.id = channels.id
             )
           WHERE id IN (SELECT id FROM _data)
        ''', params);
      }
    }));
    AppLog.info(
        'Sql.setChannelEpgIds: wrote ${channelIdToEpgId.length} EPG assignments');
  }

  /// Delete all programs for a source before re-importing.
  static Future<void> deleteProgramsForSource(int sourceId) async {
    final db = await EpgDbFactory.db;
    await db.execute(
      'DELETE FROM programmes WHERE source_id = ?',
      [sourceId],
    );
  }

  /// Delete all EPG data for a source from epg.sqlite.
  /// Call this when deleting a source from db.sqlite, since the cross-file
  /// FK cannot cascade automatically.
  static Future<void> deleteEpgForSource(int sourceId) async {
    final db = await EpgDbFactory.db;
    // fix625: guarded like the refresh writers — deleting a source can overlap a
    // background EPG refresh in the other isolate.
    await _epgWriteWithRetry('deleteEpgForSource', () => db.writeTransaction((tx) async {
      await tx.execute(
          'DELETE FROM programmes WHERE source_id = ?', [sourceId]);
      await tx.execute(
          'DELETE FROM epg_refresh_log WHERE source_id = ?', [sourceId]);
    }));
    // Review finding 135: programmes_fts is external-content with NO sync
    // triggers, so deleting a source's rows does not remove its titles from
    // the trigram index — a deleted source's titles stayed searchable until
    // the next unrelated rebuild. Rebuild now (outside the delete tx — the
    // FTS 'rebuild' command is table-scoped, and rebuildProgrammesFts wraps
    // its own busy-retry). One-time O(remaining rows) cost on a rare manual
    // action.
    await rebuildProgrammesFts();
    AppLog.info(
        'Sql.deleteEpgForSource: removed EPG data for source $sourceId'
        ' (fts rebuilt)');
  }

  /// Insert a batch of programs using multi-row VALUES clauses for performance.
  /// SQLite supports up to 999 parameters per statement; with 8 columns we use
  /// chunks of 100 rows (800 params) to stay well within the limit.
  ///
  /// Idempotent: on conflict against the v8 unique index
  /// `(source_id, epg_channel_id, start_utc)` we update the mutable metadata
  /// (title / description / category / stop_utc / episode_num). This lets
  /// EPG refresh skip the upfront DELETE and just upsert — repeating programs
  /// stay put and live-sport overruns get the new stop_utc.
  /// fix625: retry an epg.sqlite WRITE on SQLITE_BUSY ("database is locked,
  /// code 5"). The background Workmanager EPG task (`callbackDispatcher`) runs
  /// in a SEPARATE headless isolate and opens its OWN `epg.sqlite` write
  /// connection (statics — and thus `EpgDbFactory._db` — are per-isolate).
  /// sqlite_async's write mutex only serializes writers WITHIN one isolate, so
  /// when a foreground refresh / re-match overlaps that background refresh, the
  /// other isolate holds SQLite's single writer lock and this isolate's
  /// `BEGIN IMMEDIATE` waits the full 30s `busy_timeout` and then throws
  /// (onn, 2026-07-01: re-match sources 2-4 all failed this way; the first
  /// succeeded only because it happened not to overlap). A POSIX file lock
  /// can't serialize same-PROCESS isolates (fcntl locks are per-process), so we
  /// retry — the canonical, correct response to a transient, expected
  /// SQLITE_BUSY. Background write transactions are short (per parse batch) with
  /// gaps between, so a retry grabs the lock within a few attempts.
  // fix625: match the SQLite result code, NOT e.toString(). SqliteException's
  // string form appends the failing statement's bind params, which for
  // insertProgramsBatch include untrusted XMLTV programme titles — a title
  // literally containing "database is locked"/"code 5" would misclassify a real
  // (e.g. constraint) error as busy and retry it. resultCode == 5 covers the
  // whole SQLITE_BUSY family (5/261/517/773) and is locale/format-independent.
  static bool _isDbBusy(Object e) => e is SqliteException && e.resultCode == 5;

  static Future<T> _epgWriteWithRetry<T>(
    String label,
    Future<T> Function() op, {
    int maxAttempts = 5,
  }) async {
    for (var attempt = 1;; attempt++) {
      try {
        return await op();
      } catch (e) {
        if (_isDbBusy(e) && attempt < maxAttempts) {
          AppLog.warn('Sql.$label: epg.sqlite busy (SQLITE_BUSY, attempt '
              '$attempt/$maxAttempts) — another isolate holds the write lock; '
              'retrying');
          await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
          continue;
        }
        rethrow;
      }
    }
  }

  static Future<void> insertProgramsBatch(
    List<Program> programs,
  ) async {
    if (programs.isEmpty) return;
    const chunkSize = 100;
    final db = await EpgDbFactory.db;
    await _epgWriteWithRetry('insertProgramsBatch', () => db.writeTransaction((tx) async {
      for (var offset = 0; offset < programs.length; offset += chunkSize) {
        final chunk = programs.sublist(
          offset,
          offset + chunkSize > programs.length
              ? programs.length
              : offset + chunkSize,
        );
        final placeholders =
            List.filled(chunk.length, '(?,?,?,?,?,?,?,?)').join(',');
        final params = <Object?>[];
        for (final p in chunk) {
          params.addAll([
            p.epgChannelId,
            p.sourceId,
            p.title,
            p.description,
            p.category,
            p.startUtc,
            p.stopUtc,
            p.episodeNum,
          ]);
        }
        await tx.execute('''
          INSERT INTO programmes
            (epg_channel_id, source_id, title, description, category,
             start_utc, stop_utc, episode_num)
          VALUES $placeholders
          ON CONFLICT(source_id, epg_channel_id, start_utc) DO UPDATE SET
            title       = excluded.title,
            description = excluded.description,
            category    = excluded.category,
            stop_utc    = excluded.stop_utc,
            episode_num = excluded.episode_num
        ''', params);
      }
    }));
  }

  /// Garbage-collect EPG programs that ended before [windowStartEpoch].
  /// Force a full WAL checkpoint and truncate the WAL file to zero.
  ///
  /// Call after large batch writes (e.g. EPG programme inserts) to prevent
  /// SQLite's automatic PASSIVE checkpoint from running concurrently with UI
  /// reads. An unmanaged checkpoint on a 100MB+ WAL blocks all read queries
  /// for 90–150 seconds on phone flash.
  ///
  /// TRUNCATE mode: waits for all active readers, flushes the entire WAL to
  /// the main DB file, then truncates the WAL file to 0 bytes. Subsequent
  /// writes start with a clean WAL.
  ///
  /// Uses db.execute (not writeTransaction) — PRAGMA wal_checkpoint must run
  /// outside a transaction.
  static const String _refreshLockKey = 'refresh_lock';

  /// Review finding 141: best-effort cross-isolate advisory lock in db.sqlite
  /// app_meta (table exists since migration 39 — no new table/migration).
  /// The foreground catalog refresh takes it; the BACKGROUND WorkManager EPG
  /// matcher yields when it is held, so two isolates never fight for the
  /// single sqlite writer during a minutes-long bulk refresh. `owner` is a
  /// free label; `staleAfter` lets a crashed holder's lock be reclaimed.
  static Future<bool> tryAcquireRefreshLock(String owner,
      {Duration staleAfter = const Duration(minutes: 45)}) async {
    final db = await DbFactory.db;
    final now = DateTime.now().millisecondsSinceEpoch;
    return await db.writeTransaction((tx) async {
      final row = await tx.getOptional(
          'SELECT value FROM app_meta WHERE key = ?', [_refreshLockKey]);
      final value = row == null ? null : row['value'] as String?;
      if (value != null) {
        final parts = value.split('|'); // owner|acquiredMs
        final acquiredMs = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
        if (now - acquiredMs < staleAfter.inMilliseconds) {
          return false; // held & fresh
        }
      }
      await tx.execute(
          'INSERT OR REPLACE INTO app_meta (key, value) VALUES (?, ?)',
          [_refreshLockKey, '$owner|$now']);
      return true;
    });
  }

  static Future<void> releaseRefreshLock() async {
    final db = await DbFactory.db;
    await db.execute(
        'DELETE FROM app_meta WHERE key = ?', [_refreshLockKey]);
  }

  /// findings 38 & 43: generic cross-isolate key/value carrier in db.sqlite's
  /// app_meta (table exists since migration 39 — no new table/migration).
  /// Dart statics are per-isolate, so the WorkManager background isolate cannot
  /// signal the main isolate directly; these helpers bridge the boundary. Used
  /// for 'epg_last_completed_utc' (finding 38, guide-refresh signal) and
  /// 'epg_refresh_in_progress' (finding 43, background/foreground mutual
  /// exclusion marker).
  static Future<void> setAppMeta(String key, String value) async {
    final db = await DbFactory.db;
    await db.execute(
        'INSERT OR REPLACE INTO app_meta (key, value) VALUES (?, ?)',
        [key, value]);
  }

  static Future<String?> getAppMeta(String key) async {
    final db = await DbFactory.db;
    final row = await db.getOptional(
        'SELECT value FROM app_meta WHERE key = ?', [key]);
    return row == null ? null : row['value'] as String?;
  }

  static Future<void> checkpointAndTruncateWal({
    bool epg = true,
    bool db = true,
    WalCheckpointMode epgMode = WalCheckpointMode.truncate,
    WalCheckpointMode dbMode = WalCheckpointMode.truncate,
  }) async {
    // fix615: which databases to checkpoint, and in which mode, are now
    // per-call. Defaults (both, both TRUNCATE) preserve the original behaviour
    // for the import/export callers that legitimately touch both DBs.
    //
    // Background (sms938u crash, log 2026-06-29T21-54): the EPG refresh path
    // used to TRUNCATE-checkpoint db.sqlite even though EPG only writes
    // epg.sqlite. After a sources refresh (which now writes a lot to db.sqlite
    // and leaves a large WAL because wal_autocheckpoint is raised to 8000
    // pages), the NEXT EPG refresh inherited a hard TRUNCATE of that large
    // stale db.sqlite WAL — a synchronous fsync spike, and the last log line
    // before the process died. The fix: sources refresh checkpoints its OWN
    // db.sqlite WAL at its end (db-only, TRUNCATE), and the EPG path downgrades
    // its db.sqlite checkpoint to PASSIVE so it is never a blocking TRUNCATE.
    final targets = <(String, SqliteWriteContext, WalCheckpointMode)>[
      if (epg) ('epg.sqlite', await EpgDbFactory.db, epgMode),
      if (db) ('db.sqlite', await DbFactory.db, dbMode),
    ];
    for (final entry in targets) {
      final label = entry.$1;
      final database = entry.$2;
      final mode = entry.$3;
      final modeSql = mode == WalCheckpointMode.truncate ? 'TRUNCATE' : 'PASSIVE';
      try {
        final rows = await database.getAll('PRAGMA wal_checkpoint(PASSIVE)');
        if (rows.isNotEmpty) {
          final pages = rows.first.columnAt(1) as int;
          final mb = (pages * 4096 / 1024 / 1024).toStringAsFixed(1);
          AppLog.info(
            'Sql.checkpoint [$label]: WAL has $pages pages (~${mb}MB)'
            ' — starting $modeSql',
          );
        }
      } catch (_) {
        AppLog.info(
            'Sql.checkpoint [$label]: WAL size unknown — starting $modeSql');
      }
      // A PASSIVE probe already ran above; for PASSIVE mode that is the
      // checkpoint, so only issue the explicit pragma for TRUNCATE.
      final t = DateTime.now();
      if (mode == WalCheckpointMode.truncate) {
        // fix625: retry the checkpoint on a transient cross-isolate SQLITE_BUSY
        // (same busy_timeout starvation as the data writers). We do NOT swallow
        // it here — after the retries it rethrows, so each caller keeps its own
        // handling (import/export already wrap this and decide) rather than
        // silently shipping a WAL-stale DB snapshot.
        await _epgWriteWithRetry('checkpoint[$label]',
            () => database.execute('PRAGMA wal_checkpoint(TRUNCATE)'));
      }
      final ms = DateTime.now().difference(t).inMilliseconds;
      AppLog.info('Sql.checkpoint [$label]: $modeSql done in ${ms}ms');
    }
  }

  /// Called after a successful XMLTV parse to keep the `programmes` table
  /// bounded to the configured EPG window without wiping rows the parse
  /// just rewrote.
  static Future<void> deleteStalePrograms(
    int sourceId,
    int windowStartEpoch,
  ) async {
    final db = await EpgDbFactory.db;
    await _epgWriteWithRetry(
      'deleteStalePrograms',
      () => db.execute(
        'DELETE FROM programmes WHERE source_id = ? AND stop_utc < ?',
        [sourceId, windowStartEpoch],
      ),
    );
  }

  /// Returns [now, next] programs for a channel, or null entries if none.
  static Future<(Program?, Program?)> getNowNext(
    String epgChannelId,
    int sourceId,
  ) async {
    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final db = await EpgDbFactory.db;
    final rows = await db.getAll('''
      SELECT id, epg_channel_id, source_id, title, description, category,
             start_utc, stop_utc, episode_num
      FROM programmes
      WHERE epg_channel_id = ?
        AND source_id = ?
        AND stop_utc > ?
      ORDER BY start_utc ASC
      LIMIT 2
    ''', [epgChannelId, sourceId, nowEpoch]);
    final programs = rows.map(_rowToProgram).toList();
    final now = programs.isNotEmpty && programs[0].isOnNow(nowEpoch)
        ? programs[0]
        : null;
    final next = now != null && programs.length > 1
        ? programs[1]
        : (programs.isNotEmpty && !programs[0].isOnNow(nowEpoch)
            ? programs[0]
            : null);
    return (now, next);
  }

  /// Returns all programs for a channel within [windowStart, windowEnd].
  static Future<List<Program>> getSchedule(
    String epgChannelId,
    int sourceId,
    int windowStartEpoch,
    int windowEndEpoch,
  ) async {
    final db = await EpgDbFactory.db;
    final rows = await db.getAll('''
      SELECT id, epg_channel_id, source_id, title, description, category,
             start_utc, stop_utc, episode_num
      FROM programmes
      WHERE epg_channel_id = ?
        AND source_id = ?
        AND start_utc < ?
        AND stop_utc > ?
      ORDER BY start_utc ASC
    ''', [epgChannelId, sourceId, windowEndEpoch, windowStartEpoch]);
    return rows.map(_rowToProgram).toList();
  }

  static Program _rowToProgram(Row row) {
    return Program(
      id: row.columnAt(0) as int?,
      epgChannelId: row.columnAt(1) as String,
      sourceId: row.columnAt(2) as int,
      title: row.columnAt(3) as String,
      description: row.columnAt(4) as String?,
      category: row.columnAt(5) as String?,
      startUtc: row.columnAt(6) as int,
      stopUtc: row.columnAt(7) as int,
      episodeNum: row.columnAt(8) as String?,
    );
  }

  /// fix502: rebuild the programmes_fts index from the programmes table.
  /// Called once after each EPG refresh — programmes change only in batch, so
  /// no per-row sync triggers are needed (which would slow the bulk insert).
  static Future<void> rebuildProgrammesFts() async {
    final db = await EpgDbFactory.db;
    await _epgWriteWithRetry(
      'rebuildProgrammesFts',
      () => db
          .execute("INSERT INTO programmes_fts(programmes_fts) VALUES('rebuild');"),
    );
  }

  /// fix502: forward-only "what's on" search over EPG programme titles.
  /// Returns programmes whose title matches [query] (FTS5 trigram) and that are
  /// airing now or start within [nowEpoch, windowEndEpoch] — never backwards.
  /// FTS keeps it index-served on a ~1M-row table; the time/source filters are
  /// cheap residuals on the small matched set. Terms < 3 chars are skipped
  /// (trigram needs ≥3), matching Sql.search.
  static Future<List<Program>> searchPrograms({
    required String query,
    required List<int> sourceIds,
    required int nowEpoch,
    required int windowEndEpoch,
    int limit = 200,
  }) async {
    final terms = query
        .trim()
        .split(RegExp(r'\s+'))
        .where((t) => t.length >= 3)
        .toList();
    if (terms.isEmpty || sourceIds.isEmpty) return [];
    final matchExpr =
        terms.map((t) => '"${t.replaceAll('"', '""')}"').join(' AND ');
    final db = await EpgDbFactory.db;
    final rows = await db.getAll('''
      SELECT p.id, p.epg_channel_id, p.source_id, p.title, p.description,
             p.category, p.start_utc, p.stop_utc, p.episode_num
      FROM programmes_fts f
      -- fix556: CROSS JOIN (not INNER) forces the FTS virtual table to be the
      -- OUTER driver. The default plan drove off idx_programs_time_range and did
      -- one random FTS probe per in-window programme (~hundreds), which on the
      -- Onn's eMMC turned a search into 30-120s of random I/O (field logs:
      -- epgProg=119639ms). FTS-first scans one term's posting list sequentially,
      -- resolves rowids by PK, then sorts ≤200 — measured 4-40ms on the 1.1M-row
      -- EPG seed vs the previous catastrophe. Results are identical (verified).
      CROSS JOIN programmes p ON p.id = f.rowid
      WHERE programmes_fts MATCH ?
        AND p.source_id IN (${generatePlaceholders(sourceIds.length)})
        AND p.stop_utc > ?
        AND p.start_utc < ?
      ORDER BY p.start_utc ASC
      LIMIT ?
    ''', [matchExpr, ...sourceIds, nowEpoch, windowEndEpoch, limit]);
    // fix595: when the windowed result is EMPTY, log whether the trigram FTS
    // matched any programme TITLE at all (ignoring the now->window filter). This
    // attributes an empty "On now"/"Coming up" shelf to either (a) no programme
    // is titled like the query — expected for channel/network names like "fox"
    // — or (b) titles matched but none are in the live window. Only runs on the
    // empty path, so normal searches pay nothing.
    if (rows.isEmpty) {
      try {
        final ftsOnly = await db.getAll(
            'SELECT count(*) c FROM programmes_fts WHERE programmes_fts MATCH ?',
            [matchExpr]);
        final ftsCount =
            ftsOnly.isNotEmpty ? (ftsOnly.first['c'] as int? ?? 0) : 0;
        AppLog.info('Sql.searchPrograms: q="$query" match=$matchExpr '
            'ftsTitleMatches=$ftsCount windowed=0');
      } catch (e) {
        AppLog.warn('Sql.searchPrograms: diag count failed — $e');
      }
    }
    return rows.map(_rowToProgram).toList();
  }

  /// fix502: resolve the live channels backing EPG (sourceId, epgChannelId)
  /// pairs from a "what's on" programme search, so a result can show + play the
  /// channel. Keyed "sourceId|epgChannelId". One batch query — the input set is
  /// bounded by the searchPrograms LIMIT.
  static Future<Map<String, Channel>> getLiveChannelsByEpg(
    List<int> sourceIds,
    List<String> epgChannelIds, {
    required bool safeMode,
  }) async {
    if (sourceIds.isEmpty || epgChannelIds.isEmpty) return {};
    final db = await DbFactory.db;
    // fix524 (safe-mode TV leak): this query has NO `c.` alias, so use the bare
    // is_adult column (safeModeClause emits `c.is_adult` and would error here).
    // Constant predicate → no new bind params; safeMode=false → SQL byte-identical.
    final smSql = safeMode ? ' AND COALESCE(is_adult, 0) = 0' : '';
    final rows = await db.getAll(
      'SELECT * FROM channels'
      ' WHERE media_type = ${MediaType.livestream.index}'
      ' AND url IS NOT NULL'
      ' AND source_id IN (${generatePlaceholders(sourceIds.length)})'
      ' AND epg_channel_id IN (${generatePlaceholders(epgChannelIds.length)})'
      '$smSql',
      [...sourceIds, ...epgChannelIds],
    );
    final map = <String, Channel>{};
    for (final r in rows) {
      final ch = rowToChannel(r);
      final epg = ch.epgChannelId;
      if (epg != null) map['${ch.sourceId}|$epg'] = ch;
    }
    return map;
  }

  /// fix503: fetch programmes for the rail-scoped guide grid — only the
  /// channels currently realized (visible + overscan) in the vertical list.
  ///
  /// Driven by a bounded `epg_channel_id IN`-list PER source (never `source_id`
  /// alone, which would window-scan all of a source's channels), chunked under
  /// SQLite's 999-variable limit. Served by `idx_programs_channel_time`
  /// (epg_channel_id, source_id, start_utc). Two-phase by design: the channel
  /// set comes from db.sqlite (Sql.search); programmes live in epg.sqlite.
  static Future<List<Program>> getGridPrograms({
    required Map<int, List<String>> epgIdsBySource,
    required int windowStartEpoch,
    required int windowEndEpoch,
  }) async {
    final db = await EpgDbFactory.db;
    final out = <Program>[];
    for (final entry in epgIdsBySource.entries) {
      final sourceId = entry.key;
      final ids = entry.value.where((e) => e.isNotEmpty).toList();
      for (var i = 0; i < ids.length; i += 900) {
        final end = i + 900 > ids.length ? ids.length : i + 900;
        final chunk = ids.sublist(i, end);
        final rows = await db.getAll('''
          SELECT id, epg_channel_id, source_id, title, description, category,
                 start_utc, stop_utc, episode_num
          FROM programmes
          WHERE source_id = ?
            AND epg_channel_id IN (${generatePlaceholders(chunk.length)})
            AND start_utc < ?
            AND stop_utc > ?
        ''', [sourceId, ...chunk, windowEndEpoch, windowStartEpoch]);
        out.addAll(rows.map(_rowToProgram));
      }
    }
    return out;
  }

  /// Upsert a refresh log entry for a source.
  static Future<void> upsertEpgRefreshLog(
    int sourceId,
    int programsLoaded,
    String? lastError,
  ) async {
    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final db = await EpgDbFactory.db;
    await _epgWriteWithRetry(
      'upsertEpgRefreshLog',
      () => db.execute('''
      INSERT INTO epg_refresh_log (source_id, last_refreshed_utc, programmes_loaded, last_error)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(source_id) DO UPDATE SET
        last_refreshed_utc = excluded.last_refreshed_utc,
        programmes_loaded  = excluded.programmes_loaded,
        last_error         = excluded.last_error
    ''', [sourceId, nowEpoch, programsLoaded, lastError]),
    );
  }

  /// Returns the last refresh log for a source, or null if never refreshed.
  static Future<Map<String, dynamic>?> getEpgRefreshLog(int sourceId) async {
    final db = await EpgDbFactory.db;
    final row = await db.getOptional('''
      SELECT last_refreshed_utc, programmes_loaded, last_error
      FROM epg_refresh_log WHERE source_id = ?
    ''', [sourceId]);
    if (row == null) return null;
    return {
      'lastRefreshedUtc': row.columnAt(0) as int,
      'programsLoaded': row.columnAt(1) as int,
      'lastError': row.columnAt(2) as String?,
    };
  }

  /// fix541: the most recent EPG refresh time across ALL sources (epoch
  /// seconds), or null if EPG has never been refreshed. Used to show the user
  /// the last load time and to warn before a redundant re-download (<24h).
  /// finding 37: only SUCCESSFUL refreshes (last_error IS NULL) count toward the
  /// launch-refresh debounce — a failed/partial attempt must not suppress the
  /// next retry for an hour (upsertEpgRefreshLog stamps the time even on error).
  static Future<int?> getLatestEpgRefresh() async {
    final db = await EpgDbFactory.db;
    final row = await db.getOptional(
      'SELECT MAX(last_refreshed_utc) FROM epg_refresh_log '
      'WHERE last_error IS NULL',
    );
    if (row == null) return null;
    return row.columnAt(0) as int?;
  }

  /// All channels for a source that need EPG matching (have no epg_channel_id yet,
  /// or have a manual override to respect).
  static Future<List<Channel>> getChannelsForEpgMatching(int sourceId) async {
    var db = await DbFactory.db;
    final rows = await db.getAll('''
      SELECT * FROM channels
      WHERE source_id = ? AND media_type = 0
    ''', [sourceId]);
    return rows.map(rowToChannel).toList();
  }

  /// Review finding 131: keyset-paged variant of [getChannelsForEpgMatching].
  /// "Re-match all channels" previously materialized an entire source's live
  /// rows (SELECT *) in one list; the matcher now streams pages (epg_service)
  /// so peak Dart heap is bounded to one page + the shared channel map.
  static Future<List<Channel>> getChannelsForEpgMatchingPage(
    int sourceId, {
    required int afterId,
    int limit = 5000,
  }) async {
    final db = await DbFactory.db;
    final rows = await db.getAll(
      'SELECT * FROM channels'
      ' WHERE source_id = ? AND media_type = 0'
      ' AND id > ? ORDER BY id ASC LIMIT ?',
      [sourceId, afterId, limit],
    );
    return rows.map(rowToChannel).toList();
  }

  /// Live channels that need EPG matching: no existing assignment AND no
  /// manual override. Channels already matched (epg_channel_id IS NOT NULL)
  /// or manually pinned are excluded — they don't need re-matching.
  static Future<List<Channel>> getChannelsNeedingEpgMatch(
    int sourceId,
  ) async {
    var db = await DbFactory.db;
    // fix629: force idx_epg_unmatched. During "Re-match all channels" the
    // planner mis-picks index_channel_source_id (or idx_channels_epg_id) and
    // full-scans the per-source slice (13-21 s each on the onn — private log
    // 2026-06-30). ANALYZE cannot fix this: averaged sqlite_stat1 can't model
    // the 5-source, 149k-450k-row skew (see fix531). This query's WHERE is
    // IDENTICAL to idx_epg_unmatched's partial predicate (media_type = 0 AND
    // epg_manual_override IS NULL AND epg_channel_id IS NULL), so the force is
    // always a valid, full-result path — the partial index covers every row the
    // query can return. Gated on _indexExists because withDroppedBrowseIndexes
    // drops it during a refresh and a forced INDEXED BY on a missing index is a
    // hard crash (fix526).
    final hint = await _indexExists('idx_epg_unmatched')
        ? ' INDEXED BY idx_epg_unmatched'
        : '';
    // Review finding 136: the _indexExists gate is a cross-isolate TOCTOU —
    // the foreground refresh can drop idx_epg_unmatched between this
    // isolate's check and the getAll. Route through _getAllHinted so a
    // mid-flight drop degrades to the (identical-result) unhinted query
    // instead of a hard "no such index" crash aborting the source's match.
    const needingWhere = ' WHERE source_id = ?'
        ' AND media_type = 0'
        ' AND epg_manual_override IS NULL'
        ' AND epg_channel_id IS NULL';
    final rows = await _getAllHinted(
      db,
      'SELECT * FROM channels$hint$needingWhere',
      'SELECT * FROM channels$needingWhere',
      [sourceId],
    );
    return rows.map(rowToChannel).toList();
  }

  /// Review finding 131: keyset-paged variant of [getChannelsNeedingEpgMatch]
  /// so the matcher streams pages instead of materializing an entire source's
  /// live rows at once. Same predicate + hint semantics (incl. the finding-136
  /// unhinted retry); `id > afterId ORDER BY id` is a cheap tail on the seek.
  static Future<List<Channel>> getChannelsNeedingEpgMatchPage(
    int sourceId, {
    required int afterId,
    int limit = 5000,
  }) async {
    var db = await DbFactory.db;
    final hint = await _indexExists('idx_epg_unmatched')
        ? ' INDEXED BY idx_epg_unmatched'
        : '';
    const pagedWhere = ' WHERE source_id = ?'
        ' AND media_type = 0'
        ' AND epg_manual_override IS NULL'
        ' AND epg_channel_id IS NULL'
        ' AND id > ? ORDER BY id ASC LIMIT ?';
    final rows = await _getAllHinted(
      db,
      'SELECT * FROM channels$hint$pagedWhere',
      'SELECT * FROM channels$pagedWhere',
      [sourceId, afterId, limit],
    );
    return rows.map(rowToChannel).toList();
  }


  /// All live channels for a source, ordered: unmatched first then matched.
  static Future<List<Channel>> getLiveChannelsForMapping(int sourceId) async {
    var db = await DbFactory.db;
    final rows = await db.getAll('''
      SELECT * FROM channels
      WHERE source_id = ? AND media_type = 0
      ORDER BY epg_channel_id IS NOT NULL ASC, name ASC
    ''', [sourceId]);
    return rows.map(rowToChannel).toList();
  }

  /// Distinct EPG channel IDs that have program data for a source,
  /// paired with the most recent title (as a display hint).
  static Future<List<(String, String)>> getAvailableEpgIds(
    int sourceId,
  ) async {
    final db = await EpgDbFactory.db;
    // Review finding 137: the previous form ran a correlated per-group
    // subquery (latest title by start_utc) over the ~1.5M-row programmes
    // table — one extra probe per distinct epg_channel_id. sample_title is
    // only a display hint, so an arbitrary title is acceptable: MIN(title)
    // is a plain grouped aggregate the (source_id, epg_channel_id, start_utc)
    // index groups directly, with no window-function version risk.
    final rows = await db.getAll('''
      SELECT epg_channel_id, MIN(title) AS sample_title
      FROM programmes
      WHERE source_id = ?
      GROUP BY epg_channel_id
      ORDER BY epg_channel_id ASC
    ''', [sourceId]);
    return rows
        .map(
          (r) => (r.columnAt(0) as String, r.columnAt(1) as String? ?? ''),
        )
        .toList();
  }

  /// Save a manual EPG override for a channel and update epg_channel_id.
  /// Pass null to clear the mapping.
  static Future<void> setManualEpgOverride(
    int channelId,
    String? epgChannelId,
  ) async {
    var db = await DbFactory.db;
    await db.execute('''
      UPDATE channels
      SET epg_channel_id = ?, epg_manual_override = ?
      WHERE id = ?
    ''', [epgChannelId, epgChannelId, channelId]);
  }


  /// Generates a SQL fragment and parameters that exclude channels whose
  /// `group_name` or `name` contains any term from [safeModeBlocklist].
  ///
  /// Uses a `c.` table alias — call this inside queries that alias the
  /// channels table as `c`. Returns ('', []) when [safeMode] is false.
  static (String, List<String>) safeModeClause(bool safeMode) {
    if (!safeMode) return ('', []);
    // fix300: adult status is precomputed into channels.is_adult at import
    // (provider is_adult OR safeModeBlocklist name match), so the filter is a
    // single indexed check instead of a per-term LIKE chain.
    return ('\nAND COALESCE(c.is_adult, 0) = 0', []);
  }

  /// Same as [safeModeClause] but for the groups table (Categories view).
  /// No table alias — queries use bare column names.
  static (String, List<String>) safeModeGroupClause(bool safeMode) {
    if (!safeMode) return ('', []);
    final conditions = safeModeBlocklist
        .map((_) => 'LOWER(COALESCE(name, \'\')) NOT LIKE ?')
        .join(' AND ');
    final params =
        safeModeBlocklist.map((t) => '%${t.toLowerCase()}%').toList();
    return ('\nAND ($conditions)', params);
  }


  /// In-memory search: uses [ChannelSearchCache] to get matching IDs
  /// then fetches full [Channel] rows by ID from SQLite.
  /// Zero FTS / WAL impact — the cache holds pre-lowercased name + group strings.
  static Future<List<Channel>> _searchInMemory(
    Filters filters,
    String rawQuery,
    Iterable<int> mediaTypes,
    int offset,
    int limit,
  ) async {
    // fix375: honor the in-scope sources' uniform sort mode so in-memory
    // search matches browse for provider/category. null/mixed => default order.
    final sortMode = await _uniformSortMode(filters.sourceIds!.toList());
    final ids = ChannelSearchCache.search(
      query: rawQuery,
      mediaTypes: mediaTypes.toSet(),
      sourceIds: filters.sourceIds!.toSet(),
      viewType: filters.viewType,
      groupId: filters.groupId,
      seriesId: filters.seriesId,
      safeMode: filters.safeMode,
      limit: limit,
      offset: offset,
      sortMode: sortMode,
    );
    if (ids.isEmpty) return [];

    final db = await DbFactory.db;
    // fix298: the cache now applies the divider + disabled-category exclusions
    // BEFORE pagination (in ChannelSearchCache.search), so the returned ids are
    // already the correct, playable, enabled page. This fetch is pure hydration
    // by id — no post-fetch filtering (the old fix294 filter ran after the page
    // was capped, letting dividers/disabled rows hide real channels). The
    // fix296 diagnostic block is removed now that the cause is fixed.
    final sqlQuery =
        'SELECT * FROM channels c WHERE c.id IN (${generatePlaceholders(ids.length)})';
    final rows = await db.getAll(sqlQuery, [...ids]);

    // Preserve the cache's result order — WHERE IN does not guarantee ordering.
    final byId = <int, Channel>{};
    for (final row in rows) {
      final ch = rowToChannel(row);
      if (ch.id != null) byId[ch.id!] = ch;
    }

    AppLog.info(
      'Sql._searchInMemory: ids=${ids.length} matched=${rows.length}'
      ' offset=$offset',
    );

    // fix375: the ids already arrive in the cache's correct order, which now
    // honors the in-scope sources' uniform sort mode (provider/category/alpha).
    // Rebuilding by iterating ids preserves that order (WHERE IN does not).
    // We must NOT re-sort here: the old fixed favorite/validated/watched/name
    // comparator would override the cache's provider/category ordering.
    return [for (final id in ids) if (byId.containsKey(id)) byId[id]!];
  }

  /// LIKE-scan search: full-table substring scan, no FTS index.
  /// Slower than FTS but works for any query length including < 3 chars.
  /// fix344/345: resolve the single sort mode shared by every in-scope
  /// source, or null when they mix modes. Used by both the browse query and
  /// the LIKE search so the emitted ORDER BY (BrowseOrder) is identical —
  /// and index-served — on every path.
  static Future<String?> _uniformSortMode(List<int> sourceIds) async {
    final db = await DbFactory.db;
    final rows = await db.getAll(
      'SELECT DISTINCT sort_mode FROM sources WHERE id IN '
      '(${generatePlaceholders(sourceIds.length)})',
      sourceIds,
    );
    final modes = rows
        .map((r) => BrowseOrder.normalise(r['sort_mode'] as String?))
        .toSet();
    return modes.length == 1 ? modes.first : null;
  }

  /// fix393: normalised sort mode per in-scope source (id → 'alpha' |
  /// 'provider' | 'category'). Used to build the mixed-mode per-source UNION.
  static Future<Map<int, String>> _sourceModes(List<int> sourceIds) async {
    final db = await DbFactory.db;
    final rows = await db.getAll(
      'SELECT id, sort_mode FROM sources WHERE id IN '
      '(${generatePlaceholders(sourceIds.length)})',
      sourceIds,
    );
    return {
      for (final r in rows)
        r['id'] as int: BrowseOrder.normalise(r['sort_mode'] as String?),
    };
  }

  /// fix393: no-text browse across sources that MIX sort modes. Each source is
  /// queried in its OWN uniform mode (so the per-mode index serves it with no
  /// sort), `LIMIT offset+pageSize` each; the outer query re-applies the global
  /// (mixed) order over the union — at most sources×(offset+pageSize) rows, a
  /// trivially small temp sort — and pages it. Top-K-per-source is the correct
  /// candidate set for the global top-K because, within a source, the global
  /// order reduces to that source's own (constant) mode order. Verified to
  /// return identical rows to the single-query mixed form, including deep pages.
  static Future<List<Channel>> _browseMixedUnion(
    Filters filters,
    Iterable<int> mediaTypes,
    int offset,
    int invocation,
    Map<int, String> modes,
  ) async {
    final db = await DbFactory.db;
    final mt = mediaTypes.toList();
    final (smClause, smParams) = safeModeClause(filters.safeMode);
    final (visSql, visParams) = VisibilityClause.build(
      alias: 'c.',
      seriesId: filters.seriesId,
      groupId: filters.groupId,
    );
    // fix531: with Safe Mode ON the planner residual-filters is_adult on the
    // NON-safe idx_browse_src_mt and scans an adult-heavy source's whole
    // (source,media_type) partition to find 0 non-adult rows (measured 83s on
    // the onn; ANALYZE in fix530 couldn't fix it — sqlite_stat1 is averaged and
    // can't model per-source adult skew). Force the source-led *_safe partial
    // (fix528, migration 37): it EXCLUDES adult rows, so an adult-heavy source
    // contributes ~0 rows instantly. Only when the partial WHERE is provably
    // implied — ungrouped browse emits `series_id IS NULL AND cat_enabled = 1`
    // (VisibilityClause) and smClause emits `is_adult = 0`. Gated on existence
    // (a forced INDEXED BY on a missing index is a hard crash — fix526). For
    // provider/category modes the index serves the filter and the small
    // per-source result re-sorts via a cheap temp B-tree (results unchanged).
    // fix627: grouped/category browse — force idx_browse_src_grp so each
    // per-source subquery seeks straight to (source_id, group_id) instead of
    // scanning the whole source partition (the same 12-43s onn regression fixed
    // on the single-query path). Its partial WHERE (url IS NOT NULL AND
    // series_id IS NULL) is implied by the subquery's `url IS NOT NULL` +
    // VisibilityClause's `series_id IS NULL` (emitted when groupId is set), so
    // results are identical. Takes priority over the safe-mode ungrouped hint
    // (the two are mutually exclusive on groupId). Same _indexExists gate.
    final safeHint = (filters.seriesId == null &&
            filters.groupId != null &&
            await _indexExists('idx_browse_src_grp'))
        ? ' INDEXED BY idx_browse_src_grp'
        : (filters.safeMode &&
                filters.seriesId == null &&
                filters.groupId == null &&
                await _indexExists('idx_browse_src_mt_safe'))
            ? ' INDEXED BY idx_browse_src_mt_safe'
            : '';
    // Review finding 132: cap mixed-mode browse depth. innerLimit =
    // offset+pageSize is fetched and temp-sorted PER SOURCE, so deep pages
    // re-materialize the whole prefix (page 200 × 5 sources ≈ 36k rows sorted
    // to slice 36). Beyond this depth return empty — the UI's infinite scroll
    // treats an empty page as end-of-list; users refine with search long
    // before here. (~139 pages at pageSize 36.)
    const int mixedBrowseMaxRows = 5000;
    if (offset >= mixedBrowseMaxRows) {
      if (AppLog.enabled) {
        AppLog.info('Sql.search[$invocation]: branch=no-query-mixed-union'
            ' offset=$offset >= cap $mixedBrowseMaxRows — returning empty');
      }
      return const <Channel>[];
    }
    final innerLimit = offset + pageSize;
    final parts = <String>[];
    final params = <Object>[];
    for (final s in filters.sourceIds!) {
      parts.add('SELECT * FROM ('
          'SELECT c.* FROM channels c$safeHint'
          ' WHERE media_type IN (${generatePlaceholders(mt.length)})'
          ' AND source_id = ? AND url IS NOT NULL'
          '$smClause$visSql${BrowseOrder.orderBy(modes[s] ?? 'alpha')}'
          ' LIMIT ?)');
      params
        ..addAll(mt)
        ..add(s)
        ..addAll(smParams)
        ..addAll(visParams)
        ..add(innerLimit);
    }
    // Outer: re-apply the global (mixed) order over the small union, then page.
    final sqlQuery = 'SELECT * FROM (${parts.join(' UNION ALL ')}) c'
        '${BrowseOrder.orderBy(null)}'
        '\nLIMIT ?, ?';
    params
      ..add(offset)
      ..add(pageSize);

    final sqlStart = DateTime.now();
    // Review finding 134: the safeHint's _indexExists gate is a TOCTOU vs the
    // refresh's index-drop burst — retry once unhinted if the forced index
    // vanished mid-query (the hint is a planner nudge, never a correctness
    // constraint; each part's partial WHERE is implied by its predicates).
    final results = safeHint.isEmpty
        ? await db.getAll(sqlQuery, params)
        : await _getAllHinted(
            db, sqlQuery, sqlQuery.replaceAll(safeHint, ''), params);
    final sqlElapsed = DateTime.now().difference(sqlStart).inMilliseconds;
    final mapped = results.map(rowToChannel).toList();
    if (AppLog.enabled) {
      AppLog.info(
        'Sql.search[$invocation]: branch=no-query-mixed-union'
        ' sources=${filters.sourceIds!.length} rows=${results.length}'
        ' sql=${sqlElapsed}ms',
      );
    }
    return mapped;
  }

  static Future<List<Channel>> _searchLike(
    Filters filters,
    String rawQuery,
    Iterable<int> mediaTypes,
    int offset,
    int limit,
  ) async {
    final db = await DbFactory.db;
    final terms = rawQuery
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .map((t) => '%$t%')
        .toList();
    if (terms.isEmpty) return [];

    // fix648: same favorites force as the no-query browse. A favorites text
    // search otherwise LIKE-scans the catalog and residual-tests favorite=1;
    // seeking idx_fav_browse first bounds the scan to the ~dozen favorite
    // rows, with the LIKE terms applied as residuals. Valid because this
    // hint's condition is IDENTICAL to the branch below that appends
    // `AND c.favorite = 1` (implies the index's partial WHERE). Gated live on
    // _indexExists (fix526 — forced INDEXED BY on a missing index is a crash).
    final useFavHint = filters.viewType == ViewType.favorites &&
        filters.seriesId == null &&
        await _indexExists('idx_fav_browse');

    var sqlQuery = '''
      SELECT * FROM channels c${useFavHint ? ' INDEXED BY idx_fav_browse' : ''}
      WHERE (${terms.map((_) => 'c.name LIKE ?').join(' AND ')})
        AND c.media_type IN (${generatePlaceholders(mediaTypes.length)})
        AND c.source_id IN (${generatePlaceholders(filters.sourceIds!.length)})
        AND c.url IS NOT NULL
    ''';
    final List<Object> params = [...terms, ...mediaTypes, ...filters.sourceIds!];

    if (filters.viewType == ViewType.favorites && filters.seriesId == null) {
      sqlQuery += '\nAND c.favorite = 1';
    }
    if (filters.viewType == ViewType.history) {
      sqlQuery += '\nAND c.last_watched IS NOT NULL';
    }
    // fix371: same VisibilityClause as the FTS/no-query path. This path
    // previously carried its OWN copy of these predicates and was the one that
    // drifted — it still used the slow correlated (SELECT g.enabled …)
    // subquery after fix365 migrated the other path to cat_enabled. Now both
    // share one builder, so they cannot diverge again.
    final (visSql, visParams) = VisibilityClause.build(
      alias: 'c.',
      seriesId: filters.seriesId,
      groupId: filters.groupId,
    );

    final (smClause, smParams) = safeModeClause(filters.safeMode);
    sqlQuery += smClause;
    params.addAll(smParams);

    sqlQuery += visSql;
    params.addAll(visParams);

    if (filters.viewType == ViewType.favorites && filters.seriesId == null) {
      // fix356: Favorites view — group by source (A–Z), channels A–Z within.
      // Correlated source-name subquery is fine here: favorites lists are
      // tiny (tens of rows), unlike the full-catalogue browse paths.
      sqlQuery += '\nORDER BY'
          ' (SELECT s.name FROM sources s WHERE s.id = c.source_id)'
          ' COLLATE NOCASE ASC,'
          ' c.name COLLATE NOCASE ASC';
    } else if (filters.viewType == ViewType.history) {
      sqlQuery += '\nORDER BY c.last_watched DESC';
    } else {
      // fix345: this path carried a STALE pre-fix138 inline ORDER BY (4-tier
      // CASE, name without COLLATE NOCASE), so substring-search results
      // sorted differently from browse/FTS results. Unified on BrowseOrder —
      // one ordering everywhere (and index-served when modes are uniform).
      sqlQuery += BrowseOrder.orderBy(
          await _uniformSortMode(filters.sourceIds!));
    }

    sqlQuery += '\nLIMIT ?, ?';
    params.add(offset);
    params.add(limit);

    // Review finding 134: retry unhinted if idx_fav_browse was dropped between
    // the _indexExists gate and execution (refresh index-drop burst).
    final rows = !useFavHint
        ? await db.getAll(sqlQuery, params)
        : await _getAllHinted(db, sqlQuery,
            sqlQuery.replaceFirst(' INDEXED BY idx_fav_browse', ''), params);
    AppLog.info(
      'Sql._searchLike: terms=${terms.length} matched=${rows.length}'
      ' offset=$offset query="$rawQuery"',
    );
    return rows.map(rowToChannel).toList();
  }

  // ── fix154: Playback metrics rolling history ───────────────────────────────

  /// Persist one session's metrics. Deletes any existing row with the same
  /// session_start (idempotent re-runs) then inserts, then caps to 50 newest.
  static Future<void> insertPlaybackMetrics(PlaybackMetrics m) async {
    final db = await DbFactory.db;
    final epochSecs = m.sessionStart.millisecondsSinceEpoch ~/ 1000;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await db.writeTransaction((tx) async {
      await tx.execute(
        'DELETE FROM playback_metrics WHERE session_start = ?',
        [epochSecs],
      );
      await tx.execute(
        'INSERT INTO playback_metrics ('
        '  session_start, session_minutes, streams_opened,'
        '  median_first_frame_ms, median_stable_ms,'
        '  startup_visible_rebuffers,'
        '  total_rebuffers, visible_rebuffers, median_rebuffer_ms,'
        '  reconnects_watchdog, reconnects_error, gave_up, created_at'
        ') VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
        [
          epochSecs,
          m.sessionMinutes,
          m.streamsOpened,
          m.medianFirstFrameMs,
          m.medianStableMs,
          m.startupVisibleRebuffers,
          m.totalRebuffers,
          m.visibleRebuffers,
          m.medianRebufferMs,
          m.reconnectsWatchdog,
          m.reconnectsError,
          m.gaveUp,
          now,
        ],
      );
      // keep newest 50
      await tx.execute(
        'DELETE FROM playback_metrics WHERE id NOT IN ('
        '  SELECT id FROM playback_metrics ORDER BY session_start DESC LIMIT 50'
        ')',
      );
    });
    AppLog.info('Sql.insertPlaybackMetrics: session=${m.sessionStart} '
        'minutes=${m.sessionMinutes.toStringAsFixed(1)} '
        'streams=${m.streamsOpened} rebuffers=${m.totalRebuffers}');
  }

  /// fix180: wipe all stored Analyze/Suggest sessions — called once per
  /// new version boot so suggestions aren't biased by pre-upgrade sessions.
  static Future<void> clearPlaybackMetrics() async {
    final db = await DbFactory.db;
    await db.execute('DELETE FROM playback_metrics');
    AppLog.info('Sql.clearPlaybackMetrics: playback_metrics truncated');
  }

  /// Aggregate all stored sessions into a single weighted summary.
  static Future<AggregatedMetrics> getAggregatedMetrics() async {
    final db = await DbFactory.db;
    final rows = await db.getAll('SELECT * FROM playback_metrics', []);
    if (rows.isEmpty) {
      return const AggregatedMetrics(
        sessionCount: 0, totalMinutes: 0, totalStreams: 0,
        rebuffersPerHour: 0, medianFirstFrameMs: 0, medianStableMs: 0,
        medianRebufferMs: 0, startupVisibleRebufferRate: 0,
        reconnectsWatchdogPerHour: 0,
      );
    }

    double totalMinutes = 0;
    int totalStreams = 0;
    int totalRebuffers = 0;
    int totalStartupVisible = 0;
    int totalWatchdog = 0;
    final List<int> firstFrames = [];
    final List<int> stable = [];
    final List<int> rebufDurs = [];

    for (final row in rows) {
      final mins = (row['session_minutes'] as num).toDouble();
      final streams = row['streams_opened'] as int;
      totalMinutes += mins;
      totalStreams += streams;
      totalRebuffers += row['total_rebuffers'] as int;
      totalStartupVisible += row['startup_visible_rebuffers'] as int;
      totalWatchdog += row['reconnects_watchdog'] as int;
      final ffms = row['median_first_frame_ms'] as int;
      final sms = row['median_stable_ms'] as int;
      final rdms = row['median_rebuffer_ms'] as int;
      if (ffms > 0) firstFrames.add(ffms);
      if (sms > 0) stable.add(sms);
      if (rdms > 0) rebufDurs.add(rdms);
    }

    int med(List<int> l) {
      if (l.isEmpty) return 0;
      final s = List<int>.from(l)..sort();
      final mid = s.length ~/ 2;
      return s.length.isOdd ? s[mid] : ((s[mid - 1] + s[mid]) ~/ 2);
    }

    final hours = totalMinutes / 60.0;
    return AggregatedMetrics(
      sessionCount: rows.length,
      totalMinutes: totalMinutes,
      totalStreams: totalStreams,
      rebuffersPerHour: hours > 0 ? totalRebuffers / hours : 0,
      medianFirstFrameMs: med(firstFrames),
      medianStableMs: med(stable),
      medianRebufferMs: med(rebufDurs),
      startupVisibleRebufferRate:
          totalStreams > 0 ? totalStartupVisible / totalStreams : 0,
      reconnectsWatchdogPerHour: hours > 0 ? totalWatchdog / hours : 0,
    );
  }

}
