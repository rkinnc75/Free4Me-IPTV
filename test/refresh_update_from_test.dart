// fix517: the post-insert refresh step that sets channels.group_id and
// channels.cat_enabled used per-row CORRELATED SCALAR SUBQUERIES — measured at
// 21.6s (group_id) + 44.8s (cat_enabled) on a 273,738-row source on the onn 4K
// box. fix517 rewrites them as set-based UPDATE...FROM joins.
//
// This test pins the rewrite to be PROVABLY identical to the old correlated
// subqueries across every relevant case: a matched+enabled group, a
// matched+disabled group, a matched group with a NULL enabled flag, an
// unmatched group_name, a NULL group_name, a stale pre-existing row (the
// fix321 keepMediaTypes path, where group_id/cat_enabled must be recomputed,
// not left), and a second source that must be untouched.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

void _schema(s3.Database db) {
  db.execute('''
    CREATE TABLE "groups" (
      id INTEGER PRIMARY KEY,
      name TEXT,
      source_id INTEGER,
      enabled INTEGER DEFAULT 1,
      UNIQUE(name, source_id)
    );
    CREATE TABLE channels (
      id INTEGER PRIMARY KEY,
      name TEXT,
      source_id INTEGER,
      group_name TEXT,
      group_id INTEGER,
      cat_enabled INTEGER DEFAULT 1
    );
  ''');
  // groups: source 1 has Sports(on), News(off), Music(null-enabled);
  // source 2 has a group that must stay isolated.
  db.execute('''
    INSERT INTO "groups" (id, name, source_id, enabled) VALUES
      (10, 'Sports', 1, 1),
      (11, 'News',   1, 0),
      (12, 'Music',  1, NULL),
      (20, 'Sports', 2, 1);
  ''');
  // channels: cover matched/unmatched/null + a stale keepMediaTypes row (id 6:
  // group_name now Sports but carrying a stale group_id 999 / cat_enabled 0)
  // + a source-2 row that must not be touched by a source-1 refresh.
  db.execute('''
    INSERT INTO channels (id, name, source_id, group_name, group_id, cat_enabled) VALUES
      (1, 'A', 1, 'Sports', NULL, 1),
      (2, 'B', 1, 'News',   NULL, 1),
      (3, 'C', 1, 'Music',  NULL, 1),
      (4, 'D', 1, 'Orphan', NULL, 1),
      (5, 'E', 1, NULL,     NULL, 1),
      (6, 'F', 1, 'Sports', 999,  0),
      (7, 'Z', 2, 'Sports', NULL, 1);
  ''');
}

/// The OLD per-row correlated-subquery form (pre-fix517).
void _applyOld(s3.Database db, int sourceId) {
  db.execute('''
    UPDATE channels
    SET group_id = (
      SELECT id FROM "groups"
      WHERE "groups".name = channels.group_name
        AND "groups".source_id = ?
      LIMIT 1
    )
    WHERE source_id = ?
  ''', [sourceId, sourceId]);
  db.execute('''
    UPDATE channels
    SET cat_enabled = COALESCE(
      (SELECT g.enabled FROM "groups" g WHERE g.id = channels.group_id), 1)
    WHERE source_id = ?
  ''', [sourceId]);
}

/// The NEW set-based form (fix517), mirroring lib/backend/sql.dart updateGroups.
void _applyNew(s3.Database db, int sourceId) {
  db.execute('UPDATE channels SET group_id = NULL WHERE source_id = ?',
      [sourceId]);
  db.execute('''
    UPDATE channels
    SET group_id = g.id
    FROM "groups" g
    WHERE g.name = channels.group_name
      AND g.source_id = ?
      AND channels.source_id = ?
  ''', [sourceId, sourceId]);
  db.execute('''
    UPDATE channels
    SET cat_enabled = COALESCE(g.enabled, 1)
    FROM "groups" g
    WHERE g.id = channels.group_id
      AND channels.source_id = ?
  ''', [sourceId]);
  db.execute(
      'UPDATE channels SET cat_enabled = 1'
      ' WHERE source_id = ? AND group_id IS NULL',
      [sourceId]);
}

Map<int, List<Object?>> _snapshot(s3.Database db) {
  final rows = db.select(
      'SELECT id, group_id, cat_enabled FROM channels ORDER BY id');
  return {
    for (final r in rows)
      r['id'] as int: [r['group_id'], r['cat_enabled']],
  };
}

void main() {
  group('fix517 set-based UPDATE...FROM == old correlated subqueries', () {
    test('group_id + cat_enabled identical across all cases', () {
      final oldDb = s3.sqlite3.openInMemory();
      final newDb = s3.sqlite3.openInMemory();
      addTearDown(oldDb.dispose);
      addTearDown(newDb.dispose);
      _schema(oldDb);
      _schema(newDb);

      _applyOld(oldDb, 1);
      _applyNew(newDb, 1);

      expect(_snapshot(newDb), equals(_snapshot(oldDb)),
          reason: 'set-based rewrite must match the correlated subqueries');
    });

    test('expected values are correct (not just mutually consistent)', () {
      final db = s3.sqlite3.openInMemory();
      addTearDown(db.dispose);
      _schema(db);
      _applyNew(db, 1);
      final snap = _snapshot(db);
      // id: [group_id, cat_enabled]
      expect(snap[1], [10, 1], reason: 'Sports, enabled');
      expect(snap[2], [11, 0], reason: 'News, disabled -> cat_enabled 0');
      expect(snap[3], [12, 1], reason: 'Music, NULL enabled -> COALESCE 1');
      expect(snap[4], [null, 1], reason: 'Orphan group_name -> NULL group');
      expect(snap[5], [null, 1], reason: 'NULL group_name -> NULL group');
      expect(snap[6], [10, 1],
          reason: 'stale row recomputed: group_id 999->10, cat_enabled 0->1');
    });

    test('a second source is untouched by a source-1 refresh', () {
      final db = s3.sqlite3.openInMemory();
      addTearDown(db.dispose);
      _schema(db);
      _applyNew(db, 1);
      final z = db.select(
          'SELECT group_id, cat_enabled FROM channels WHERE id = 7').first;
      // Source-2 row (id 7) was never group_id-resolved by the source-1 run.
      expect(z['group_id'], isNull);
      expect(z['cat_enabled'], 1);
    });
  });
}
