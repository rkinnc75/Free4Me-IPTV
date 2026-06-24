import 'dart:collection';
import 'dart:convert';

import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/browse_order.dart';
import 'package:open_tv/backend/visibility_clause.dart';
import 'package:open_tv/backend/group_search_gate.dart';
import 'package:open_tv/backend/playback_analyzer.dart';
import 'package:open_tv/backend/channel_search_cache.dart';
import 'package:open_tv/backend/db_factory.dart';
import 'package:open_tv/models/channel.dart';
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
      Future<void> Function() body, {int? refreshedSourceId}) async {
    final db = await DbFactory.db;
    final existing = await db.getAll(
      "SELECT name FROM sqlite_master WHERE type = 'trigger' "
      "AND name IN ('channels_ai', 'channels_au', 'channels_ad')",
    );
    final hadTriggers = existing.length == 3;
    // fix521: re-entrancy — when an outer batch (refreshAllSources) has already
    // suspended the FTS triggers around the WHOLE loop, this inner per-source
    // call is a pure pass-through: the triggers are already dropped so the body
    // inserts trigger-free, and the OUTER finally owns the single end-of-batch
    // global rebuild (no per-source rebuild). Mirrors fix518's
    // _browseIndexesDropped.
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
        } else {
          // Either targeted wasn't applicable (large source / large
          // fraction / no sourceId given), or body() threw before finishing
          // its wipe+reinsert — in the latter case a targeted delete may
          // have already removed this source's OLD entries with nothing
          // reinserted yet, so a global rebuild is the only safe way to
          // leave search consistent.
          await reconcileFtsTriggers(true);
          AppLog.info('Sql.withSuspendedFtsTriggers: FTS triggers restored'
              ' + index rebuilt');
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
  ];
  static Future<void> withDroppedBrowseIndexes(
      Future<void> Function() body) async {
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
      var restored = 0;
      for (final r in rows) {
        try {
          await db.execute(r['sql'] as String);
          restored++;
        } catch (e) {
          AppLog.error('Sql.withDroppedBrowseIndexes: FAILED to recreate index'
              ' "${r['name']}" — $e');
        }
      }
      try {
        await db.execute('PRAGMA optimize;');
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
      await tx.execute('''
        INSERT INTO groups (name, image, source_id, media_type)
        SELECT group_name, image, ?, media_type
        FROM channels
        WHERE source_id = ?
        GROUP BY group_name
        ON CONFLICT(name, source_id) DO UPDATE SET
          media_type = excluded.media_type
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
                     sort_mode       = COALESCE(?, sort_mode)
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
          id,
        ]);
        memory['sourceId'] = id.toString();
      } else {
        await tx.execute('''
              INSERT INTO sources
                (name, source_type, url, username, password, epg_url,
                 enabled, max_connections, color, sort_mode)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
        return _searchInMemory(filters, rawQuery, mediaTypes, offset);
      }
      if (filters.searchMethod == SearchMethod.likeSubstring) {
        return _searchLike(filters, rawQuery, mediaTypes, offset);
      }
    }

    // For ftsPhrase and ftsAnd, effectiveKeywords overrides the legacy flag.
    // ftsAnd splits on whitespace (AND mode); ftsPhrase keeps the raw phrase.
    final effectiveKeywords =
        filters.searchMethod == SearchMethod.ftsAnd || filters.useKeywords;

    if (useFts) {
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
      final useSrcMtHint = filters.viewType != ViewType.favorites &&
          filters.viewType != ViewType.history &&
          filters.seriesId == null &&
          filters.groupId == null &&
          filters.sourceIds!.length == 1 &&
          mediaTypes.length == 1 &&
          browseMode == 'alpha';
      // No query — simple filter on indexed columns.
      sqlQuery = '''
        SELECT * FROM channels c${useSrcMtHint ? ' INDEXED BY idx_browse_src_mt' : ''}
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
    params.add(pageSize);

    // log can tell us which is the bottleneck.
    final sqlStart = DateTime.now();
    var results = await db.getAll(sqlQuery, params);
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

  static String getKeywordsSql(int size) {
    return List.generate(size, (_) => "name LIKE ?").join(" AND ");
  }

  // fix278: toggle one category's enabled flag.
  static Future<void> setGroupEnabled(int groupId, bool enabled) async {
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

  static Future<void> deleteSource(int sourceId) async {
    // Clean up EPG data in epg.sqlite first (cross-file FK can't cascade).
    await deleteEpgForSource(sourceId);
    var db = await DbFactory.db;
    await db.writeTransaction((tx) async {
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
        await tx.execute(
            'DELETE FROM channels WHERE source_id = ?', [sourceId]);
        await tx.execute('DELETE FROM groups WHERE source_id = ?', [sourceId]);
      } else {
        final placeholders = List.filled(keepMediaTypes.length, '?').join(',');
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
          hide_dividers = ?
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
    await db.writeTransaction((tx) async {
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
    });
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
    await db.writeTransaction((tx) async {
      await tx.execute(
          'DELETE FROM programmes WHERE source_id = ?', [sourceId]);
      await tx.execute(
          'DELETE FROM epg_refresh_log WHERE source_id = ?', [sourceId]);
    });
    AppLog.info(
        'Sql.deleteEpgForSource: removed EPG data for source $sourceId');
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
  static Future<void> insertProgramsBatch(
    List<Program> programs,
  ) async {
    if (programs.isEmpty) return;
    const chunkSize = 100;
    final db = await EpgDbFactory.db;
    await db.writeTransaction((tx) async {
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
    });
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
  static Future<void> checkpointAndTruncateWal() async {
    // Checkpoint both databases — epg.sqlite is where the large writes
    // happen; db.sqlite may also have pending WAL from channel updates.
    for (final entry in [
      ('epg.sqlite', await EpgDbFactory.db),
      ('db.sqlite', await DbFactory.db),
    ]) {
      final label = entry.$1;
      final db = entry.$2;
      try {
        final rows = await db.getAll('PRAGMA wal_checkpoint(PASSIVE)');
        if (rows.isNotEmpty) {
          final pages = rows.first.columnAt(1) as int;
          final mb = (pages * 4096 / 1024 / 1024).toStringAsFixed(1);
          AppLog.info(
            'Sql.checkpoint [$label]: WAL has $pages pages (~${mb}MB)'
            ' — starting TRUNCATE',
          );
        }
      } catch (_) {
        AppLog.info(
            'Sql.checkpoint [$label]: WAL size unknown — starting TRUNCATE');
      }
      final t = DateTime.now();
      await db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      final ms = DateTime.now().difference(t).inMilliseconds;
      AppLog.info('Sql.checkpoint [$label]: WAL truncated in ${ms}ms');
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
    await db.execute(
      'DELETE FROM programmes WHERE source_id = ? AND stop_utc < ?',
      [sourceId, windowStartEpoch],
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
    await db
        .execute("INSERT INTO programmes_fts(programmes_fts) VALUES('rebuild');");
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
      INNER JOIN programmes p ON p.id = f.rowid
      WHERE programmes_fts MATCH ?
        AND p.source_id IN (${generatePlaceholders(sourceIds.length)})
        AND p.stop_utc > ?
        AND p.start_utc < ?
      ORDER BY p.start_utc ASC
      LIMIT ?
    ''', [matchExpr, ...sourceIds, nowEpoch, windowEndEpoch, limit]);
    return rows.map(_rowToProgram).toList();
  }

  /// fix502: resolve the live channels backing EPG (sourceId, epgChannelId)
  /// pairs from a "what's on" programme search, so a result can show + play the
  /// channel. Keyed "sourceId|epgChannelId". One batch query — the input set is
  /// bounded by the searchPrograms LIMIT.
  static Future<Map<String, Channel>> getLiveChannelsByEpg(
    List<int> sourceIds,
    List<String> epgChannelIds,
  ) async {
    if (sourceIds.isEmpty || epgChannelIds.isEmpty) return {};
    final db = await DbFactory.db;
    final rows = await db.getAll(
      'SELECT * FROM channels'
      ' WHERE media_type = ${MediaType.livestream.index}'
      ' AND url IS NOT NULL'
      ' AND source_id IN (${generatePlaceholders(sourceIds.length)})'
      ' AND epg_channel_id IN (${generatePlaceholders(epgChannelIds.length)})',
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
    await db.execute('''
      INSERT INTO epg_refresh_log (source_id, last_refreshed_utc, programmes_loaded, last_error)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(source_id) DO UPDATE SET
        last_refreshed_utc = excluded.last_refreshed_utc,
        programmes_loaded  = excluded.programmes_loaded,
        last_error         = excluded.last_error
    ''', [sourceId, nowEpoch, programsLoaded, lastError]);
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

  /// Live channels that need EPG matching: no existing assignment AND no
  /// manual override. Channels already matched (epg_channel_id IS NOT NULL)
  /// or manually pinned are excluded — they don't need re-matching.
  static Future<List<Channel>> getChannelsNeedingEpgMatch(
    int sourceId,
  ) async {
    var db = await DbFactory.db;
    final rows = await db.getAll('''
      SELECT * FROM channels
      WHERE source_id = ?
        AND media_type = 0
        AND epg_manual_override IS NULL
        AND epg_channel_id IS NULL
    ''', [sourceId]);
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
    final rows = await db.getAll('''
      SELECT epg_channel_id,
             (SELECT title FROM programmes p2
              WHERE p2.epg_channel_id = p.epg_channel_id
                AND p2.source_id = p.source_id
              ORDER BY start_utc DESC LIMIT 1) AS sample_title
      FROM programmes p
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
      limit: pageSize,
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
    final innerLimit = offset + pageSize;
    final parts = <String>[];
    final params = <Object>[];
    for (final s in filters.sourceIds!) {
      parts.add('SELECT * FROM ('
          'SELECT c.* FROM channels c'
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
    final results = await db.getAll(sqlQuery, params);
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
  ) async {
    final db = await DbFactory.db;
    final terms = rawQuery
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .map((t) => '%$t%')
        .toList();
    if (terms.isEmpty) return [];

    var sqlQuery = '''
      SELECT * FROM channels c
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
    params.add(pageSize);

    final rows = await db.getAll(sqlQuery, params);
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
