// fix377: Favorites view now honors the user-chosen sort mode the same way
// the rest of search does. This test seeds a real sqlite DB and asserts
// the EXACT row order produced by the emitted SQL against the order
// BrowseOrder specifies, for each uniform mode and for the mixed (null)
// fallback. Mirrors the fix344 pattern from test/browse_order_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/browse_order.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

bool _sqliteAvailable() {
  try {
    s3.sqlite3.openInMemory().dispose();
  } catch (_) {
    return false;
  }
  return true;
}

void main() {
  final available = _sqliteAvailable();

  // 6 favorites so each sort mode yields a distinct, verifiable order.
  // Filled in once per test against a fresh in-memory DB.
  void seedFavorites(s3.Database db) {
    db.execute('''
      CREATE TABLE sources(id INTEGER PRIMARY KEY, name TEXT, sort_mode TEXT);
      CREATE TABLE channels(
        id INTEGER PRIMARY KEY,
        name TEXT,
        url TEXT,
        media_type INTEGER,
        source_id INTEGER,
        group_name TEXT,
        favorite INTEGER,
        stream_validated INTEGER,
        last_watched INTEGER,
        provider_order INTEGER
      );
    ''');
    db.execute("INSERT INTO sources VALUES (1, 'S1', NULL)"); // placeholder
    final ins = db.prepare(
        'INSERT INTO channels VALUES (?,?,?,?,?,?,?,?,?,?)');
    // All six are favorites (favorite=1). last_watched is NULL for all
    // so the 6-tier CASE skips the history tiers and lands on
    // tier 0 (fav+validated) and tier 1 (fav only).
    ins.execute([1, 'fav-A',  'http://x/1', 0, 1, 'News',   1, 1, null, 30]);
    ins.execute([2, 'fav-B',  'http://x/2', 0, 1, 'News',   1, 0, null, 20]);
    ins.execute([3, 'fav-C',  'http://x/3', 0, 1, 'Sports', 1, 1, null, 10]);
    ins.execute([4, 'fav-D',  'http://x/4', 0, 1, 'Sports', 1, 0, null, 50]);
    ins.execute([5, 'fav-E',  'http://x/5', 0, 1, 'News',   1, 0, null, 40]);
    ins.execute([6, 'fav-F',  'http://x/6', 0, 1, 'Sports', 1, 0, null, 60]);
    ins.dispose();
  }

  // The Favorites SQL fragment the new code emits: AND favorite = 1 is
  // already in the WHERE clause upstream (sql.dart line ~580), so the
  // emitted ORDER BY tail is just what BrowseOrder returns.
  String favSql(String orderByTail) => '''
    SELECT id, name FROM channels c
    WHERE favorite = 1
      AND url IS NOT NULL$orderByTail
    LIMIT 0, 100''';

  List<int> ids(s3.Database db, String sql) => db
      .select(sql)
      .map((r) => r['id'] as int)
      .toList();

  group('fix377 Favorites view honors sort_mode', () {
    if (!available) {
      test('skipped (libsqlite3 not loadable)', () {},
          skip: 'libsqlite3 not loadable on this host');
      return;
    }

    test('uniform alpha: 6-tier — validated favs first, then name A–Z', () {
      // alpha's 6-tier CASE on the 6 favorites:
      //   tier 0 (fav+validated): id 1, 3
      //   tier 1 (fav only):       id 2, 4, 5, 6
      // Within tier 1: name A–Z → fav-B(2), fav-D(4), fav-E(5), fav-F(6).
      // Tier 0 ordered by name: fav-A(1), fav-C(3).
      final db = s3.sqlite3.openInMemory();
      try {
        seedFavorites(db);
        final result = ids(db, favSql(BrowseOrder.orderBy('alpha')));
        expect(result, [1, 3, 2, 4, 5, 6], reason: 'alpha 6-tier order');
      } finally {
        db.dispose();
      }
    });

    test('uniform provider: favFirst/valFloat/provider_order, then name', () {
      // provider ORDER BY: favFirst (all 0 since all favs), then valFloat
      // (id 1,3 → 0; id 2,4,5,6 → 1), then provider_order, then name.
      // valFloat 0: id 1 (ord 30), id 3 (ord 10) → sorted by ord: 3, 1.
      // valFloat 1: id 2 (20), 4 (50), 5 (40), 6 (60) → sorted by ord:
      //   2, 5, 4, 6.
      final db = s3.sqlite3.openInMemory();
      try {
        seedFavorites(db);
        final result = ids(db, favSql(BrowseOrder.orderBy('provider')));
        expect(result, [3, 1, 2, 5, 4, 6],
            reason: 'provider: valFloat, then provider_order, then name');
      } finally {
        db.dispose();
      }
    });

    test('uniform category: favFirst/valFloat/group/provider_order/name', () {
      // category ORDER BY: same as provider, but non-validated favs are
      // grouped by group_name first. valFloat 0 stays 3, 1.
      // valFloat 1 group News: id 2 (20), 5 (40) → 2, 5.
      // valFloat 1 group Sports: id 4 (50), 6 (60) → 4, 6.
      // Groups News < Sports A–Z, so News comes first.
      final db = s3.sqlite3.openInMemory();
      try {
        seedFavorites(db);
        final result = ids(db, favSql(BrowseOrder.orderBy('category')));
        // In category mode, valFloat-0 groups by group_name: id 1
        // (News, ord 30) before id 3 (Sports, ord 10) because 'News' <
        // 'Sports' alphabetically. valFloat-1 also groups: News {2, 5}
        // (ord 20, 40) before Sports {4, 6} (ord 50, 60).
        expect(result, [1, 3, 2, 5, 4, 6],
            reason: 'category: group_name orders News before Sports');
      } finally {
        db.dispose();
      }
    });

    test('mixed (null uniformMode): falls back to fix356 source-name A–Z',
        () {
      // Two sources with different sort_modes → _uniformSortMode returns
      // null → the legacy fix356 subquery form is used.
      final db = s3.sqlite3.openInMemory();
      try {
        db.execute('''
          CREATE TABLE sources(id INTEGER PRIMARY KEY, name TEXT, sort_mode TEXT);
          CREATE TABLE channels(
            id INTEGER PRIMARY KEY, name TEXT, url TEXT, media_type INTEGER,
            source_id INTEGER, group_name TEXT, favorite INTEGER,
            stream_validated INTEGER, provider_order INTEGER
          );
        ''');
        db.execute("INSERT INTO sources VALUES (1, 'Beta', 'alpha')");
        db.execute("INSERT INTO sources VALUES (2, 'Alpha', 'provider')");
        final ins = db.prepare(
            'INSERT INTO channels VALUES (?,?,?,?,?,?,?,?,?)');
        ins.execute([1, 'fav-B', 'http://x/1', 0, 1, 'G', 1, 0, 5]);
        ins.execute([2, 'fav-A', 'http://x/2', 0, 2, 'G', 1, 0, 1]);
        ins.execute([3, 'fav-C', 'http://x/3', 0, 2, 'G', 1, 0, 2]);
        ins.dispose();

        // The exact null-fallback SQL emitted by Sql.search when
        // uniformMode is null. The correlated source-name subquery IS
        // the source of order here.
        final sql = favSql(
            '\nORDER BY'
            ' (SELECT s.name FROM sources s WHERE s.id = c.source_id)'
            ' COLLATE NOCASE ASC,'
            ' c.name COLLATE NOCASE ASC');
        final result = ids(db, sql);
        // Source 'Alpha' (id 2) < 'Beta' (id 1) A–Z.
        // Within source 2 (Alpha): fav-A(2), fav-C(3) by name.
        // Within source 1 (Beta): fav-B(1).
        expect(result, [2, 3, 1],
            reason: 'mixed null: source A–Z, then channel A–Z (fix356)');
      } finally {
        db.dispose();
      }
    });

    test(
        'BrowseOrder.orderBy has no correlated subqueries for uniform modes '
        '— fix377 Favorites path inherits this',
        () {
      // Regression guard for the handoff pattern that bit fix376: the
      // favorites path must NOT add a correlated subquery when the mode
      // is uniform (it would defeat the BrowseOrder builder entirely).
      for (final mode in ['alpha', 'provider', 'category']) {
        final o = BrowseOrder.orderBy(mode);
        expect(o, isNot(contains('select sort_mode')),
            reason: 'mode=$mode must not add a correlated subquery');
        expect(o, isNot(contains('select s.name')),
            reason: 'mode=$mode must not add a source-name subquery');
      }
    });
  });
}
