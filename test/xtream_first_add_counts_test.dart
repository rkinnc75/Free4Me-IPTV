// fix376: on a FIRST Xtream add, source.id was never assigned (getXtream queued
// getOrCreateSourceByName into the batched `statements` and never read
// memory['sourceId'] back). The count-persistence block guarded by
// `if (source.id != null)` was therefore skipped, leaving last_live/movie/series
// _count null until a manual refresh. The fix commits the source row up front
// (m3u.dart pattern) and threads the shared `memory` map into the batched commit
// so channel inserts (sourceId == -1) still resolve to the new id.
//
// These tests run the REAL Sql statement closures against a seeded sqlite DB
// (same harness as wipe_source_test). Skips cleanly if libsqlite3 is absent.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:sqlite3/sqlite3.dart' as s3;
import 'package:sqlite_async/sqlite_async.dart';

bool _sqliteAvailable() {
  try {
    s3.sqlite3.openInMemory().dispose();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  final available = _sqliteAvailable();

  group('fix376 Xtream first-add populates counts', () {
    late Directory dir;
    late SqliteDatabase db;

    setUp(() async {
      if (!available) return;
      dir = await Directory.systemTemp.createTemp('xtream_first_add');
      db = SqliteDatabase(path: '${dir.path}/t.sqlite');
      await db.execute('''
        CREATE TABLE sources(
          id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, source_type INTEGER,
          url TEXT, username TEXT, password TEXT, epg_url TEXT, enabled INTEGER,
          max_connections INTEGER, color INTEGER, sort_mode TEXT,
          last_live_count INTEGER, last_movie_count INTEGER,
          last_series_count INTEGER, hide_dividers INTEGER)''');
      await db.execute('''
        CREATE TABLE channels(
          id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, image TEXT, url TEXT,
          source_id INTEGER, media_type INTEGER, series_id INTEGER,
          favorite INTEGER, stream_id INTEGER, group_name TEXT,
          epg_channel_id TEXT, catchup_type TEXT, catchup_source TEXT,
          catchup_days INTEGER, provider_order INTEGER, is_divider INTEGER,
          is_adult INTEGER)''');
    });

    tearDown(() async {
      if (!available) return;
      await db.close();
      await dir.delete(recursive: true);
    });

    // The actual bug: source.id must be non-null after the up-front commit so
    // the `if (source.id != null)` count guard in getXtream fires on first add.
    test('first add (id:null) assigns source.id from memory', () async {
      if (!available) {
        markTestSkipped('libsqlite3 not loadable');
        return;
      }
      final source = Source(
          name: 'Test', sourceType: SourceType.xtream,
          url: 'http://host', username: 'u', password: 'p');
      expect(source.id, isNull, reason: 'first-add shape from setup.dart');

      final memory = <String, String>{};
      await db.writeTransaction(
          (tx) => Sql.getOrCreateSourceByName(source)(tx, memory));
      source.id = int.parse(memory['sourceId']!); // fix376

      expect(source.id, isNotNull,
          reason: 'count-persistence guard now passes on first add');
      final row =
          await db.get('SELECT id FROM sources WHERE name = ?', ['Test']);
      expect(row['id'], source.id);
    });

    // Regression guard for the error in the original handoff proposal: pulling
    // getOrCreateSourceByName out of the batch means it no longer fills the
    // batch's own map, so the shared `memory` MUST be threaded into the bulk
    // insert or channels (sourceId == -1) crash / land on the wrong source.
    test('channel sourceId==-1 still resolves with the threaded memory map',
        () async {
      if (!available) {
        markTestSkipped('libsqlite3 not loadable');
        return;
      }
      final source = Source(
          name: 'Test', sourceType: SourceType.xtream, url: 'http://h');
      final memory = <String, String>{};
      await db.writeTransaction(
          (tx) => Sql.getOrCreateSourceByName(source)(tx, memory));
      source.id = int.parse(memory['sourceId']!);

      final ch = Channel(
          name: 'CH1', mediaType: MediaType.livestream, sourceId: -1,
          favorite: false, url: 'u1', group: 'G');
      // Mirrors commitWriteBatched(statements, memory: memory) — same map.
      await db.writeTransaction(
          (tx) => Sql.insertChannelsBulk([ch])(tx, memory));

      final got = await db
          .get('SELECT source_id FROM channels WHERE name = ?', ['CH1']);
      expect(got['source_id'], source.id,
          reason: 'channel resolved to the created source, not -1');
    });

    // End-to-end of the count write the guard gates (updateSource's UPDATE).
    test('counts persist for the first-add source row', () async {
      if (!available) {
        markTestSkipped('libsqlite3 not loadable');
        return;
      }
      final source = Source(
          name: 'Test', sourceType: SourceType.xtream, url: 'http://h');
      final memory = <String, String>{};
      await db.writeTransaction(
          (tx) => Sql.getOrCreateSourceByName(source)(tx, memory));
      source.id = int.parse(memory['sourceId']!);

      source.lastLiveCount = 12;
      source.lastMovieCount = 34;
      source.lastSeriesCount = 5;
      // Identical column write to Sql.updateSource (which uses DbFactory).
      await db.execute(
          'UPDATE sources SET last_live_count=?, last_movie_count=?,'
          ' last_series_count=? WHERE id=?',
          [source.lastLiveCount, source.lastMovieCount, source.lastSeriesCount,
           source.id]);

      final row = await db.get(
          'SELECT last_live_count l, last_movie_count m, last_series_count s'
          ' FROM sources WHERE id=?', [source.id]);
      expect(row['l'], 12);
      expect(row['m'], 34);
      expect(row['s'], 5);
    });
  });
}
