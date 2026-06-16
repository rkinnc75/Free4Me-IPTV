import 'dart:collection';
import 'dart:convert';

import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/browse_order.dart';
import 'package:open_tv/backend/visibility_clause.dart';
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
  /// (ftsTrigram/ftsAnd). When the active method is inMemory or likeSubstring,
  /// the per-row FTS trigram maintenance during a refresh is pure overhead.
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
  /// No-op for non-FTS users: their triggers are already absent (fix212), so
  /// [hadTriggers] is false and we neither drop nor rebuild — body runs as-is.
  /// Safe if [body] throws: the finally clause restores triggers + rebuild so
  /// search is never left stale.
  static Future<void> withSuspendedFtsTriggers(
      Future<void> Function() body) async {
    final db = await DbFactory.db;
    final existing = await db.getAll(
      "SELECT name FROM sqlite_master WHERE type = 'trigger' "
      "AND name IN ('channels_ai', 'channels_au', 'channels_ad')",
    );
    final hadTriggers = existing.length == 3;
    if (hadTriggers) {
      await db.execute('DROP TRIGGER IF EXISTS channels_ai;');
      await db.execute('DROP TRIGGER IF EXISTS channels_au;');
      await db.execute('DROP TRIGGER IF EXISTS channels_ad;');
      AppLog.info('Sql.withSuspendedFtsTriggers: FTS triggers dropped'
          ' for bulk refresh');
    }
    try {
      await body();
    } finally {
      if (hadTriggers) {
        // reconcileFtsTriggers(true) recreates the triggers AND, because they
        // were absent, rebuilds the FTS index once from the content table.
        await reconcileFtsTriggers(true);
        AppLog.info('Sql.withSuspendedFtsTriggers: FTS triggers restored'
            ' + index rebuilt');
      }
    }
  }

  static Future<void> reconcileFtsTriggers(bool ftsActive) async {
    final db = await DbFactory.db;
    final existing = await db.getAll(
      "SELECT name FROM sqlite_master WHERE type = 'trigger' "
      "AND name IN ('channels_ai', 'channels_au', 'channels_ad')",
    );
    final triggersPresent = existing.length == 3;
    if (ftsActive) {
      if (triggersPresent) return;
      // Triggers were absent => FTS index is stale. Rebuild once, then recreate.
      await db.execute("INSERT INTO channels_fts(channels_fts) VALUES('rebuild');");
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
      await tx.execute('''
        UPDATE channels
        SET group_id = (
          SELECT id FROM groups
          WHERE groups.name = channels.group_name
            AND groups.source_id = ?
          LIMIT 1
        )
        WHERE source_id = ?
      ''', [sourceId, sourceId]);
      // fix365: denormalize the category-enabled flag so the browse index can
      // exclude disabled-category channels without a per-row subquery.
      await tx.execute('''
        UPDATE channels
        SET cat_enabled = COALESCE(
          (SELECT g.enabled FROM groups g WHERE g.id = channels.group_id), 1)
        WHERE source_id = ?
      ''', [sourceId]);
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

    // For ftsTrigram and ftsAnd, effectiveKeywords overrides the legacy flag.
    // ftsAnd splits on whitespace (AND mode); ftsTrigram keeps the raw phrase.
    final effectiveKeywords =
        filters.searchMethod == SearchMethod.ftsAnd || filters.useKeywords;

    if (useFts) {
      // Build an FTS5 MATCH expression. Trigram tokenizer matches substrings
      // when the term is at least 3 characters; for shorter terms fall back
      // to LIKE so single/double-letter queries still work.
      final terms = effectiveKeywords
          ? rawQuery.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList()
          : [rawQuery];
      final longTerms = terms.where((t) => t.length >= 3).toList();
      final shortTerms = terms.where((t) => t.length < 3).toList();

      if (longTerms.isNotEmpty) {
        // Quote each term to escape FTS5 syntax.
        final matchExpr = longTerms
            .map((t) => '"${t.replaceAll('"', '""')}"')
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
        if (shortTerms.isNotEmpty) {
          sqlQuery += '\nAND (${shortTerms.map((_) => 'c.name LIKE ?').join(' AND ')})';
          params.addAll(shortTerms.map((t) => '%$t%'));
          branch = 'fts+like'; // long + short terms; rare
        } else {
          branch = 'fts'; // long terms only; the common ≥3-char case
        }
      } else {
        // A leading-wildcard LIKE scan here forces a full-table read that can
        // take 2–5 seconds on a 90k-channel source. The result set would be
        // enormous and unhelpful anyway. Return early with an empty list so
        // the UI stays snappy; the user hasn't typed a meaningful query yet.
        if (AppLog.enabled) {
          AppLog.info(
            'Sql.search[$invocation]: branch=short-skip'
            ' query="$rawQuery" — all terms < 3 chars, skipping scan',
          );
        }
        return [];
      }
      params.addAll(mediaTypes);
      params.addAll(filters.sourceIds!);
    } else {
      // No query — simple filter on indexed columns.
      sqlQuery = '''
        SELECT * FROM channels c
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

  static Future<List<Channel>> searchGroup(Filters filters) async {
    final rawGroupQuery = (filters.query ?? "").trim();
    if (rawGroupQuery.isNotEmpty) {
      final groupTerms = filters.useKeywords
          ? rawGroupQuery.split(RegExp(r'\s+')).where((t) => t.isNotEmpty)
          : [rawGroupQuery];
      if (groupTerms.every((t) => t.length < 3)) {
        AppLog.info(
          'Sql.searchGroup: branch=short-skip'
          ' query="$rawGroupQuery" — all terms < 3 chars, skipping scan',
        );
        return [];
      }
    }
    var db = await DbFactory.db;
    var offset = filters.page * pageSize - pageSize;
    var query = filters.query ?? "";
    var keywords = filters.useKeywords
        ? query.split(" ").map((f) => "%$f%").toList()
        : ["%$query%"];
    var mediaTypes = filters.mediaTypes!.map((x) => x.index);
    var sqlQuery = '''
        SELECT * FROM groups
        WHERE (${getKeywordsSql(keywords.length)})
        AND (media_type IS NULL OR media_type IN (${generatePlaceholders(mediaTypes.length)}))
        AND source_id IN (${generatePlaceholders(filters.sourceIds!.length)})
    ''';
    List<Object> params = [];
    params.addAll(keywords);
    params.addAll(mediaTypes);
    params.addAll(filters.sourceIds!);

    final (smGroupClause, smGroupParams) = safeModeGroupClause(filters.safeMode);
    sqlQuery += smGroupClause;
    params.addAll(smGroupParams);

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

  static Future<void> updateSource(Source source) async {
    var db = await DbFactory.db;
    await db.execute('''
      UPDATE sources
      SET url = ?, username = ?, password = ?,
          max_connections = ?, color = ?, sort_mode = ?,
          last_live_count = ?, last_movie_count = ?, last_series_count = ?,
          hide_dividers = ?
      WHERE id = ?
    ''', [
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
