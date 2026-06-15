// fix344: Rule 8 done right — EXPLAIN the EXACT ORDER BY the app emits
// (BrowseOrder.orderBy) against a real sqlite DB seeded with the verbatim
// migration-27 index. fix330 failed by testing a hand-written approximation
// of the query instead of the emitted one; because Sql.search and this test
// now share BrowseOrder, tested == emitted by construction.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/browse_order.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

bool _sqliteAvailable() {
  try {
    s3.sqlite3.openInMemory().dispose();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  group('BrowseOrder strings', () {
    test('alpha emits bare tier with no subqueries', () {
      final o = BrowseOrder.orderBy('alpha');
      expect(o, contains(BrowseOrder.tier));
      expect(o, isNot(contains('select sort_mode')));
    });
    test('provider/category emit no subqueries and correct keys', () {
      final p = BrowseOrder.orderBy('provider');
      expect(p, contains('c.provider_order'));
      expect(p, isNot(contains('select sort_mode')));
      expect(p, contains('stream_validated'),
          reason: 'fix375: validated favorites float in provider mode');
      final c = BrowseOrder.orderBy('category');
      expect(c, contains('c.group_name COLLATE NOCASE'));
      expect(c, contains('c.provider_order'));
      expect(c, isNot(contains('select sort_mode')));
      expect(c, contains('stream_validated'),
          reason: 'fix375: validated favorites float in category mode');
    });
    test('mixed (null) keeps the legacy correlated form', () {
      final m = BrowseOrder.orderBy(null);
      expect(m, contains('select sort_mode'));
      expect(m, contains(BrowseOrder.tier));
    });
    test('normalise maps unknown/null to alpha', () {
      expect(BrowseOrder.normalise(null), 'alpha');
      expect(BrowseOrder.normalise('alpha'), 'alpha');
      expect(BrowseOrder.normalise('weird'), 'alpha');
      expect(BrowseOrder.normalise('provider'), 'provider');
      expect(BrowseOrder.normalise('category'), 'category');
    });
  });

  group('migration-27 index serves the emitted alpha ORDER BY', () {
    final available = _sqliteAvailable();

    test('EXPLAIN uses idx_channels_browse_tier, no temp B-tree', () {
      if (!available) {
        markTestSkipped('libsqlite3 not loadable on this host');
        return;
      }
      final db = s3.sqlite3.openInMemory();
      try {
        db.execute('''
          CREATE TABLE sources(id INTEGER PRIMARY KEY, sort_mode TEXT);
          CREATE TABLE groups(id INTEGER PRIMARY KEY, enabled INTEGER);
          CREATE TABLE channels(
            id INTEGER PRIMARY KEY,
            name TEXT,
            url TEXT,
            media_type INTEGER,
            source_id INTEGER,
            group_id INTEGER,
            group_name TEXT,
            favorite INTEGER,
            stream_validated INTEGER,
            last_watched INTEGER,
            provider_order INTEGER
          );
        ''');
        // Verbatim migration-27 DDL (db_factory.dart) — keep in sync.
        db.execute('''
          CREATE INDEX IF NOT EXISTS idx_channels_browse_tier
          ON channels(
            source_id,
            (CASE
              WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0
              WHEN COALESCE(favorite,0)=1 THEN 1
              WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2
              WHEN last_watched IS NOT NULL THEN 3
              WHEN COALESCE(stream_validated,0)=1 THEN 4
              ELSE 5 END),
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL
        ''');
        db.execute("INSERT INTO sources VALUES (1,'alpha')");
        final ins = db.prepare(
            'INSERT INTO channels VALUES (?,?,?,?,?,?,?,?,?,?,?)');
        for (var i = 0; i < 500; i++) {
          ins.execute([
            i, 'ch$i', 'http://x/$i', i % 3, 1, null, 'g${i % 7}',
            i % 11 == 0 ? 1 : 0, i % 5 == 0 ? 1 : 0, null, i,
          ]);
        }
        ins.dispose();

        // The browse query EXACTLY as Sql.search assembles it for a
        // no-search-text view, with the EMITTED alpha ORDER BY.
        final sql = '''
        SELECT * FROM channels c
        WHERE media_type IN (?,?,?)
          AND source_id IN (?)
          AND url IS NOT NULL
AND COALESCE((SELECT g.enabled FROM groups g WHERE g.id = c.group_id), 1) = 1${BrowseOrder.orderBy('alpha')}
LIMIT ?, ?''';
        final plan = db
            .select('EXPLAIN QUERY PLAN $sql', [0, 1, 2, 1, 0, 36])
            .map((r) => r['detail'] as String)
            .join('\n');
        expect(plan, contains('idx_channels_browse_tier'),
            reason: 'alpha ORDER BY must be served by the mig-27 index:\n$plan');
        expect(plan, isNot(contains('TEMP B-TREE')),
            reason: 'no temp B-tree sort expected:\n$plan');

        // Document WHY the legacy correlated form needed fixing: it cannot
        // use the index and falls back to a temp B-tree sort.
        final legacy = '''
        SELECT * FROM channels c
        WHERE media_type IN (?,?,?)
          AND source_id IN (?)
          AND url IS NOT NULL${BrowseOrder.orderBy(null)}
LIMIT ?, ?''';
        final legacyPlan = db
            .select('EXPLAIN QUERY PLAN $legacy', [0, 1, 2, 1, 0, 36])
            .map((r) => r['detail'] as String)
            .join('\n');
        expect(legacyPlan, contains('TEMP B-TREE'),
            reason: 'mixed-mode form is expected to temp-sort:\n$legacyPlan');
      } finally {
        db.dispose();
      }
    });
  });
}
