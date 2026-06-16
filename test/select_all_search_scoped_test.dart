// fix389: Select All / Unselect All in the Categories view must act on exactly
// the categories the grid shows for the active search — all matches across every
// page, including the safe-mode name block — and never a different set.
//
// These tests execute the REAL shared WHERE builder, `Sql.groupSearchWhere`,
// against a seeded in-memory sqlite DB. That is the same builder `searchGroup`
// (the grid) and `setAllGroupsEnabledForSearch` (the bulk toggle) both use, so
// a future change to the search WHERE that breaks the bulk/grid parity fails
// here. (The earlier version of this test ran a hand-written copy of the SQL,
// which could silently drift from production — and did not cover safe mode at
// all, which the bulk helper had been omitting.)
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/models/settings.dart' show safeModeBlocklist;

bool _sqliteAvailable() {
  try {
    s3.sqlite3.openInMemory().dispose();
    return true;
  } catch (_) {
    return false;
  }
}

s3.Database _seed(List<List<Object?>> rows) {
  final db = s3.sqlite3.openInMemory();
  db.execute('''
    CREATE TABLE groups(
      id INTEGER PRIMARY KEY, name TEXT, source_id INTEGER,
      media_type INTEGER, enabled INTEGER
    );''');
  final ins = db.prepare('INSERT INTO groups VALUES (?,?,?,?,?)');
  for (final r in rows) {
    ins.execute(r);
  }
  ins.dispose();
  return db;
}

Filters _f({
  required String? query,
  required List<int> sourceIds,
  List<MediaType> mediaTypes = const [],
  bool safeMode = false,
}) =>
    Filters(
      viewType: ViewType.categories,
      query: query,
      sourceIds: sourceIds,
      mediaTypes: mediaTypes,
      safeMode: safeMode,
    );

List<int> _matchingIds(s3.Database db, Filters filters) {
  final (where, params) = Sql.groupSearchWhere(filters);
  final rows = db.select('SELECT id FROM groups WHERE $where ORDER BY id', params);
  return [for (final r in rows) r['id'] as int];
}

void main() {
  final available = _sqliteAvailable();

  group('fix389 — Sql.groupSearchWhere scopes Select/Unselect-All to the search',
      () {
    test('single keyword matches only the matching groups', () {
      if (!available) {
        markTestSkipped('sqlite native lib unavailable');
        return;
      }
      final db = _seed([
        [1, '24/7 News', 1, null, 1],
        [2, '24/7 Sports', 1, null, 1],
        [3, 'Kids', 1, null, 1],
        [4, '24/7 Movies', 1, null, 1],
      ]);
      try {
        expect(_matchingIds(db, _f(query: '24/7', sourceIds: [1])), [1, 2, 4]);
      } finally {
        db.dispose();
      }
    });

    test('two keywords use AND — only groups matching both', () {
      if (!available) {
        markTestSkipped('sqlite native lib unavailable');
        return;
      }
      final db = _seed([
        [1, '24/7 News', 1, null, 1],
        [2, '24/7 Sports', 1, null, 1],
        [3, 'Daily News', 1, null, 1],
      ]);
      try {
        expect(_matchingIds(db, _f(query: '24/7 News', sourceIds: [1])), [1]);
      } finally {
        db.dispose();
      }
    });

    test('media_type filter narrows to the active tab', () {
      if (!available) {
        markTestSkipped('sqlite native lib unavailable');
        return;
      }
      final db = _seed([
        [1, '24/7 Live', 1, 0, 1],
        [2, '24/7 Movie', 1, 1, 1],
        [3, '24/7 Series', 1, 2, 1],
      ]);
      try {
        expect(
          _matchingIds(db,
              _f(query: '24/7', sourceIds: [1], mediaTypes: [MediaType.livestream])),
          [1],
        );
      } finally {
        db.dispose();
      }
    });

    test('source_ids filter narrows to in-scope sources', () {
      if (!available) {
        markTestSkipped('sqlite native lib unavailable');
        return;
      }
      final db = _seed([
        [1, '24/7 Live', 1, null, 1],
        [2, '24/7 Live', 2, null, 1],
      ]);
      try {
        expect(_matchingIds(db, _f(query: '24/7', sourceIds: [1, 2])), [1, 2]);
        expect(_matchingIds(db, _f(query: '24/7', sourceIds: [1])), [1]);
      } finally {
        db.dispose();
      }
    });

    test(
        'safe mode excludes a name-blocked category the grid hides '
        '(the divergence the shared builder fixes)', () {
      if (!available) {
        markTestSkipped('sqlite native lib unavailable');
        return;
      }
      // Build a group whose name matches the search query AND contains a real
      // safe-mode blocklist term. With safe mode OFF it is selectable; with
      // safe mode ON the grid hides it, so the bulk action must skip it too.
      final blocked = safeModeBlocklist.first;
      final db = _seed([
        [1, '24/7 Family', 1, null, 1],
        [2, '24/7 $blocked Stuff', 1, null, 1],
      ]);
      try {
        // Safe mode OFF: both match.
        expect(
          _matchingIds(db, _f(query: '24/7', sourceIds: [1], safeMode: false)),
          [1, 2],
        );
        // Safe mode ON: the blocked-name group is excluded, matching searchGroup.
        expect(
          _matchingIds(db, _f(query: '24/7', sourceIds: [1], safeMode: true)),
          [1],
        );
      } finally {
        db.dispose();
      }
    });
  });
}
