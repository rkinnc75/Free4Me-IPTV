// fix344: Rule 8 done right — EXPLAIN the EXACT ORDER BY the app emits
// (BrowseOrder.orderBy) against a real sqlite DB seeded with the verbatim
// migration-27 index. fix330 failed by testing a hand-written approximation
// of the query instead of the emitted one; because Sql.search and this test
// now share BrowseOrder, tested == emitted by construction.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/browse_order.dart';
import 'package:open_tv/backend/visibility_clause.dart';
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

    test('fix392: real browse query (VisibilityClause) is served by the '
        'media_type-led index with no temp B-tree; partial series index '
        'does not shadow it', () {
      if (!available) {
        markTestSkipped('libsqlite3 not loadable on this host');
        return;
      }
      final db = s3.sqlite3.openInMemory();
      try {
        db.execute('''
          CREATE TABLE sources(id INTEGER PRIMARY KEY, sort_mode TEXT,
            hide_dividers INTEGER DEFAULT 0);
          CREATE TABLE channels(
            id INTEGER PRIMARY KEY, name TEXT, url TEXT, media_type INTEGER,
            source_id INTEGER, group_id INTEGER, group_name TEXT,
            favorite INTEGER, stream_validated INTEGER, last_watched INTEGER,
            provider_order INTEGER, series_id INTEGER,
            is_divider INTEGER DEFAULT 0, is_adult INTEGER DEFAULT 0,
            cat_enabled INTEGER DEFAULT 1);
        ''');
        // Verbatim migration-30 DDL — the media_type-led partial browse index
        // that actually serves the multi-source browse once the series index
        // stops shadowing it. Keep in sync with db_factory.dart.
        db.execute('''
          CREATE INDEX idx_channels_browse_mt ON channels(
            media_type,
            (CASE
              WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0
              WHEN COALESCE(favorite,0)=1 THEN 1
              WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2
              WHEN last_watched IS NOT NULL THEN 3
              WHEN COALESCE(stream_validated,0)=1 THEN 4
              ELSE 5 END),
            name COLLATE NOCASE
          )
          WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled = 1;
        ''');
        for (var s = 1; s <= 3; s++) {
          db.execute("INSERT INTO sources VALUES ($s,'alpha',0)");
        }
        // fix392 state: the series index is PARTIAL on series_id IS NOT NULL,
        // so it serves the drilldown but cannot match the browse's
        // `series_id IS NULL` and therefore cannot shadow idx_channels_browse_mt.
        db.execute('CREATE INDEX index_channel_series_id'
            ' ON channels(series_id) WHERE series_id IS NOT NULL');
        final ins = db.prepare('INSERT INTO channels '
            '(id,name,url,media_type,source_id,group_id,group_name,favorite,'
            'stream_validated,last_watched,provider_order,series_id,'
            'is_divider,is_adult,cat_enabled) '
            'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,0,0,1)');
        var id = 0;
        for (var s = 1; s <= 3; s++) {
          for (var i = 0; i < 4000; i++) {
            id++;
            // Episodes: media_type=movie WITH a series_id (must be excluded by
            // the browse). Standalone movies: series_id NULL.
            final isEpisode = i % 2 == 0;
            ins.execute([
              id, 'ch$id', 'http://x/$id', 1, s, i % 50, 'g${i % 50}',
              i % 60 == 0 ? 1 : 0, i % 5 == 0 ? 1 : 0, null, i,
              isEpisode ? 900000 + (i ~/ 20) : null,
            ]);
          }
        }
        ins.dispose();

        // The browse query EXACTLY as Sql.search assembles it for a Movies tab,
        // no search text, safe mode off — built from the SAME shared builders
        // (VisibilityClause + BrowseOrder) the app emits, so tested == emitted.
        final (vis, _) = VisibilityClause.build(
            alias: 'c.', seriesId: null, groupId: null);
        final sql = 'SELECT * FROM channels c'
            ' WHERE media_type IN (?)'
            ' AND source_id IN (?,?,?)'
            ' AND url IS NOT NULL'
            '$vis${BrowseOrder.orderBy('alpha')}'
            '\nLIMIT ?, ?';
        final plan = db
            .select('EXPLAIN QUERY PLAN $sql', [1, 1, 2, 3, 0, 36])
            .map((r) => r['detail'] as String)
            .join('\n');
        // fix392: with the series index partial (NOT created here, so it cannot
        // shadow), the planner serves the global tier+name order from the
        // media_type-led index with no sort, across all three sources.
        expect(plan, contains('idx_channels_browse_mt'),
            reason: 'browse must be served by the mig-30 index:\n$plan');
        expect(plan, isNot(contains('TEMP B-TREE')),
            reason: 'no temp B-tree sort expected after fix392:\n$plan');
        // The partial series index (series_id IS NOT NULL) structurally cannot
        // satisfy the browse's `series_id IS NULL`, so the planner cannot grab
        // it here — which is exactly why it no longer shadows the browse index.
        // (Pre-fix392 the index was unconditional and the planner DID pick it,
        // then temp-sorted — the ~4.3s first-paint bug. Reproducing that choice
        // is cost-/stats-dependent, so it is verified by EXPLAIN on a seeded
        // ~675k-row catalogue in the fix392 runbook, not asserted on this small
        // unanalyzed fixture where the planner already prefers the right index.)
        expect(plan, isNot(contains('index_channel_series_id')),
            reason: 'partial series index must not serve the browse:\n$plan');
      } finally {
        db.dispose();
      }
    });
  });
}
