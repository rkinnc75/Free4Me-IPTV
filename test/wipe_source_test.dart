// fix325: Rule 8 in CI — Sql.wipeSource against a real seeded sqlite DB.
// Skips cleanly if the host has no loadable libsqlite3 (the Mac build
// machine and GitHub ubuntu runners both have it).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/sql.dart';
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

  group('Sql.wipeSource', () {
    late Directory dir;
    late SqliteDatabase db;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('wipe_source_test');
      db = SqliteDatabase(path: '${dir.path}/t.sqlite');
      await db.execute('''
        CREATE TABLE channels (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT, source_id INTEGER, media_type INTEGER, group_id INTEGER
        )''');
      await db.execute('''
        CREATE TABLE groups (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT, source_id INTEGER, enabled INTEGER
        )''');
      // finding 55: wipeSource now explicitly deletes dependent rows (cascades
      // are inert — PRAGMA foreign_keys is OFF), so the test schema must carry
      // these tables like the real migration does.
      await db.execute('''
        CREATE TABLE movie_positions (
          channel_id INTEGER, position INTEGER
        )''');
      await db.execute('''
        CREATE TABLE channel_http_headers (
          channel_id INTEGER
        )''');
      // Source 7: live group (id 1, disabled), vod group (id 2), and a
      // NULL-name disabled group (id 3, the fix320 case). Source 9: untouched.
      await db.execute(
          "INSERT INTO groups (id, name, source_id, enabled) VALUES "
          "(1,'Live A',7,0),(2,'Movies A',7,1),(3,NULL,7,0),(4,'Other',9,1)");
      await db.execute(
          "INSERT INTO channels (name, source_id, media_type, group_id) VALUES "
          "('L1',7,0,1),('L2',7,0,1),('M1',7,1,2),('S1',7,2,NULL),('X1',9,0,4)");
    });

    tearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });

    test('empty keep set = full wipe of the source, others untouched',
        () async {
      final memory = <String, String>{};
      await db.writeTransaction(
          (tx) => Sql.wipeSource(7, keepMediaTypes: {})(tx, memory));
      final c7 = await db.get(
          'SELECT COUNT(*) c FROM channels WHERE source_id = 7');
      final g7 =
          await db.get('SELECT COUNT(*) c FROM groups WHERE source_id = 7');
      final c9 = await db.get(
          'SELECT COUNT(*) c FROM channels WHERE source_id = 9');
      expect(c7['c'], 0);
      expect(g7['c'], 0);
      expect(c9['c'], 1);
    });

    test('keepMediaTypes preserves those rows + their groups only', () async {
      final memory = <String, String>{};
      // Preserve live (0); wipe movies (1) and series (2).
      await db.writeTransaction(
          (tx) => Sql.wipeSource(7, keepMediaTypes: {0})(tx, memory));
      final rows = await db.getAll(
          'SELECT name, media_type FROM channels WHERE source_id = 7 ORDER BY name');
      expect(rows.map((r) => r['name']), ['L1', 'L2']);
      // Group 1 (live, has surviving channels) kept; groups 2 and 3 gone.
      final gids = await db
          .getAll('SELECT id FROM groups WHERE source_id = 7 ORDER BY id');
      expect(gids.map((r) => r['id']), [1]);
    });

    test('stashes disabled group names, NULL name -> Uncategorized (fix320)',
        () async {
      final memory = <String, String>{};
      await db.writeTransaction(
          (tx) => Sql.wipeSource(7, keepMediaTypes: {})(tx, memory));
      final names =
          (jsonDecode(memory['disabledGroupNames']!) as List).cast<String>();
      expect(names.toSet(), {'Live A', 'Uncategorized'});
    });
  }, skip: available ? false : 'libsqlite3 not loadable on this host');
}
