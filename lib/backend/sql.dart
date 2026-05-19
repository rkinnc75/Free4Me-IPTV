import 'dart:collection';

import 'package:open_tv/backend/db_factory.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/channel_http_headers.dart';
import 'package:open_tv/models/channel_preserve.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/id_data.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/programme.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:sqlite_async/sqlite3.dart';
import 'package:sqlite_async/sqlite_async.dart';

const int pageSize = 36;
const int importBatchSize = 500;

class Sql {
  static Future<void> commitWrite(
      List<Future<void> Function(SqliteWriteContext, Map<String, String>)>
          commits,
      {Map<String, String>? memory}) async {
    if (commits.isEmpty) return;
    var db = await DbFactory.db;
    final shared = memory ?? <String, String>{};
    await db.writeTransaction((tx) async {
      for (var commit in commits) {
        await commit(tx, shared);
      }
    });
  }

  /// Large imports (M3U/Xtream) — same [memory] across batches so sourceId persists.
  static Future<void> commitWriteBatched(
    List<Future<void> Function(SqliteWriteContext, Map<String, String>)>
        commits, {
    int batchSize = importBatchSize,
    Map<String, String>? memory,
  }) async {
    if (commits.isEmpty) return;
    final shared = memory ?? <String, String>{};
    for (var i = 0; i < commits.length; i += batchSize) {
      final end = (i + batchSize < commits.length) ? i + batchSize : commits.length;
      await commitWrite(commits.sublist(i, end), memory: shared);
    }
  }

  static Future<void> Function(SqliteWriteContext, Map<String, String> memory)
      insertChannel(Channel channel) {
    return (SqliteWriteContext tx, Map<String, String> memory) async {
      await tx.execute('''
        INSERT INTO channels (
          name, image, url, source_id, media_type, series_id, favorite,
          stream_id, group_name, epg_channel_id,
          catchup_type, catchup_source, catchup_days
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (name, source_id)
        DO UPDATE SET
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
          catchup_days = excluded.catchup_days;
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
      ]);
      memory['lastChannelId'] =
          (await tx.get("SELECT last_insert_rowid()")).columnAt(0).toString();
    };
  }

  // FIX (Tier 3, #13): the upstream version of this function had two SQL
  // bugs that silently broke group_id assignment:
  //   1. A stray `;` between GROUP BY and ON CONFLICT split the statement.
  //   2. The UPDATE referenced `source_id = ?` but had no parameter bound.
  // Rewritten as two clean parameterized statements.
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
      var sourceId = (await tx.getOptional(
              "SELECT id FROM sources WHERE name = ?", [source.name]))
          ?.columnAt(0);
      if (sourceId != null) {
        memory['sourceId'] = sourceId.toString();
        return;
      }
      await tx.execute('''
            INSERT INTO sources (name, source_type, url, username, password) VALUES (?, ?, ?, ?, ?);
          ''', [
        source.name,
        source.sourceType.index,
        source.url,
        source.username,
        source.password,
      ]);
      memory['sourceId'] =
          (await tx.get("SELECT last_insert_rowid();")).columnAt(0).toString();
    };
  }

  // FIX (Tier 4, #8): use FTS5 when the user has typed a search query.
  // Leading-wildcard LIKE forced a full-table scan; trigram FTS is index-backed.
  static Future<List<Channel>> search(Filters filters) async {
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
    List<Object> params = [];

    if (useFts) {
      // Build an FTS5 MATCH expression. Trigram tokenizer matches substrings
      // when the term is at least 3 characters; for shorter terms fall back
      // to LIKE so single/double-letter queries still work.
      final terms = filters.useKeywords
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
        }
      } else {
        // All terms are too short for trigram; fall back to LIKE.
        sqlQuery = '''
          SELECT * FROM channels c
          WHERE (${shortTerms.map((_) => 'name LIKE ?').join(' AND ')})
            AND media_type IN (${generatePlaceholders(mediaTypes.length)})
            AND source_id IN (${generatePlaceholders(filters.sourceIds!.length)})
            AND url IS NOT NULL
        ''';
        params.addAll(shortTerms.map((t) => '%$t%'));
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
      sqlQuery += "\nORDER BY last_watched DESC";
    }
    if (filters.seriesId != null) {
      sqlQuery += "\nAND series_id = ?";
      params.add(filters.seriesId!);
    } else if (filters.groupId != null) {
      sqlQuery += "\nAND group_id = ?";
      params.add(filters.groupId!);
    }
    sqlQuery += "\nLIMIT ?, ?";
    params.add(offset);
    params.add(pageSize);
    var results = await db.getAll(sqlQuery, params);
    return results.map(rowToChannel).toList();
  }

  static Channel rowToChannel(Row row) {
    // Column order: id(0) name(1) group_name(2) image(3) url(4) media_type(5)
    //   source_id(6) favorite(7) series_id(8) group_id(9) stream_id(10)
    //   last_watched(11) epg_channel_id(12) epg_manual_override(13)
    //   catchup_type(14) catchup_source(15) catchup_days(16)
    return Channel(
      id: row.columnAt(0),
      name: row.columnAt(1),
      group: row.columnAt(2),
      image: row.columnAt(3),
      url: row.columnAt(4),
      mediaType: MediaType.values[row.columnAt(5)],
      sourceId: row.columnAt(6),
      favorite: row.columnAt(7) == 1,
      seriesId: row.columnAt(8),
      groupId: row.columnAt(9),
      epgChannelId: row.columnAt(12) as String?,
      catchupType: row.columnAt(14) as String?,
      catchupSource: row.columnAt(15) as String?,
      catchupDays: row.columnAt(16) as int?,
    );
  }

  static String generatePlaceholders(int size) {
    return List.filled(size, "?").join(",");
  }

  static String getKeywordsSql(int size) {
    return List.generate(size, (_) => "name LIKE ?").join(" AND ");
  }

  static Future<List<Channel>> searchGroup(Filters filters) async {
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
        LIMIT ?, ?
    ''';
    List<Object> params = [];
    params.addAll(keywords);
    params.addAll(mediaTypes);
    params.addAll(filters.sourceIds!);
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
        favorite: false,
        mediaType: MediaType.group);
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
    return results.map(rowToSource).toList();
  }

  static Source rowToSource(Row row) {
    // Column order: id(0) name(1) source_type(2) url(3) username(4)
    //   password(5) enabled(6) epg_url(7)
    return Source(
      id: row.columnAt(0),
      name: row.columnAt(1),
      sourceType: SourceType.values[row.columnAt(2)],
      url: row.columnAt(3),
      username: row.columnAt(4),
      password: row.columnAt(5),
      enabled: row.columnAt(6) == 1,
      epgUrl: row.columnAt(7) as String?,
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
    var db = await DbFactory.db;
    await db.writeTransaction((tx) async {
      await tx.execute("DELETE FROM channels WHERE source_id = ?", [sourceId]);
      await tx.execute("DELETE FROM groups WHERE source_id = ?", [sourceId]);
      await tx.execute("DELETE FROM sources WHERE id = ?", [sourceId]);
    });
  }

  static Future<void> Function(SqliteWriteContext, Map<String, String>)
      wipeSource(int sourceId) {
    return (SqliteWriteContext tx, Map<String, String> memory) async {
      await tx.execute('''
        DELETE FROM channels 
        WHERE source_id = ? 
      ''', [sourceId]);
      await tx.execute('''
        DELETE FROM groups
        WHERE source_id = ?
      ''', [sourceId]);
    };
  }

  static Future<void> updateSource(Source source) async {
    var db = await DbFactory.db;
    await db.execute('''
      UPDATE sources
      SET url = ?, username = ?, password = ?
      WHERE id = ?
    ''', [source.url, source.username, source.password, source.id]);
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

  static Future<void> addToHistory(int id) async {
    var db = await DbFactory.db;
    await db.execute('''
      UPDATE channels
      SET last_watched = strftime('%s', 'now')
      WHERE id = ?
    ''', [id]);
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
  }

  static Future<List<ChannelPreserve>> getChannelsPreserve(int sourceId) async {
    var db = await DbFactory.db;
    var results = await db.getAll('''
      SELECT name, favorite, last_watched
      FROM channels
      WHERE (favorite = 1 OR last_watched IS NOT NULL) AND source_id = ?
    ''', [sourceId]);
    return results.map(rowToChannelPreserve).toList();
  }

  static ChannelPreserve rowToChannelPreserve(Row row) {
    return ChannelPreserve(
        name: row.columnAt(0),
        favorite: row.columnAt(1),
        lastWatched: row.columnAt(2));
  }

  static Future<void> Function(SqliteWriteContext, Map<String, String>)
      restorePreserve(List<ChannelPreserve> preserve) {
    return (SqliteWriteContext tx, Map<String, String> memory) async {
      final sourceId = int.parse(memory['sourceId']!);
      for (var channel in preserve) {
        await tx.execute('''
          UPDATE channels
          SET favorite = ?, last_watched = ?
          WHERE name = ?
          AND source_id = ?
        ''', [channel.favorite, channel.lastWatched, channel.name, sourceId]);
      }
    };
  }

  // ── EPG ────────────────────────────────────────────────────────────────────

  /// Persist the EPG URL for a source.
  static Future<void> setSourceEpgUrl(int sourceId, String? url) async {
    var db = await DbFactory.db;
    await db.execute(
      'UPDATE sources SET epg_url = ? WHERE id = ?',
      [url, sourceId],
    );
  }

  /// Write matched/manual EPG channel IDs back to the channels table.
  static Future<void> setChannelEpgIds(
    Map<int, String> channelIdToEpgId,
  ) async {
    if (channelIdToEpgId.isEmpty) return;
    var db = await DbFactory.db;
    await db.writeTransaction((tx) async {
      for (final entry in channelIdToEpgId.entries) {
        await tx.execute(
          'UPDATE channels SET epg_channel_id = ? WHERE id = ?',
          [entry.value, entry.key],
        );
      }
    });
  }

  /// Delete all programmes for a source before re-importing.
  static Future<void> deleteProgrammesForSource(int sourceId) async {
    var db = await DbFactory.db;
    await db.execute(
      'DELETE FROM programmes WHERE source_id = ?',
      [sourceId],
    );
  }

  /// Insert a batch of programmes in a single write transaction.
  static Future<void> insertProgrammesBatch(
    List<Programme> programmes,
  ) async {
    if (programmes.isEmpty) return;
    var db = await DbFactory.db;
    await db.writeTransaction((tx) async {
      for (final p in programmes) {
        await tx.execute('''
          INSERT OR IGNORE INTO programmes
            (epg_channel_id, source_id, title, description, category,
             start_utc, stop_utc, episode_num)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ''', [
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
    });
  }

  /// Returns [now, next] programmes for a channel, or null entries if none.
  static Future<(Programme?, Programme?)> getNowNext(
    String epgChannelId,
    int sourceId,
  ) async {
    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var db = await DbFactory.db;
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
    final programmes = rows.map(_rowToProgramme).toList();
    final now = programmes.isNotEmpty && programmes[0].isOnNow(nowEpoch)
        ? programmes[0]
        : null;
    final next = now != null && programmes.length > 1
        ? programmes[1]
        : (programmes.isNotEmpty && !programmes[0].isOnNow(nowEpoch)
            ? programmes[0]
            : null);
    return (now, next);
  }

  /// Returns all programmes for a channel within [windowStart, windowEnd].
  static Future<List<Programme>> getSchedule(
    String epgChannelId,
    int sourceId,
    int windowStartEpoch,
    int windowEndEpoch,
  ) async {
    var db = await DbFactory.db;
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
    return rows.map(_rowToProgramme).toList();
  }

  static Programme _rowToProgramme(Row row) {
    return Programme(
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
    int programmesLoaded,
    String? lastError,
  ) async {
    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var db = await DbFactory.db;
    await db.execute('''
      INSERT INTO epg_refresh_log (source_id, last_refreshed_utc, programmes_loaded, last_error)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(source_id) DO UPDATE SET
        last_refreshed_utc = excluded.last_refreshed_utc,
        programmes_loaded  = excluded.programmes_loaded,
        last_error         = excluded.last_error
    ''', [sourceId, nowEpoch, programmesLoaded, lastError]);
  }

  /// Returns the last refresh log for a source, or null if never refreshed.
  static Future<Map<String, dynamic>?> getEpgRefreshLog(int sourceId) async {
    var db = await DbFactory.db;
    final row = await db.getOptional('''
      SELECT last_refreshed_utc, programmes_loaded, last_error
      FROM epg_refresh_log WHERE source_id = ?
    ''', [sourceId]);
    if (row == null) return null;
    return {
      'lastRefreshedUtc': row.columnAt(0) as int,
      'programmesLoaded': row.columnAt(1) as int,
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

  // ── EPG manual channel mapping ─────────────────────────────────────────────

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

  /// Distinct EPG channel IDs that have programme data for a source,
  /// paired with the most recent title (as a display hint).
  static Future<List<(String, String)>> getAvailableEpgIds(
    int sourceId,
  ) async {
    var db = await DbFactory.db;
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
}
