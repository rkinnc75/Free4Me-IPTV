// fix393: the no-text browse across sources that MIX sort modes is split into
// a per-source UNION ALL (each source in its own uniform, index-served mode),
// with the global order re-applied over the union. This test:
//   1. proves the UNION returns the SAME rows, in the same order, as the
//      single-query mixed form it replaces — page 1 and a deep page;
//   2. proves the new per-mode indexes (idx_browse_cat / idx_browse_prov) serve
//      the uniform category / provider browse with no temp B-tree.
// All ORDER BY / WHERE come from the production BrowseOrder + VisibilityClause
// builders, so tested == emitted (the fix330/fix344 discipline).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/browse_order.dart';
import 'package:open_tv/backend/visibility_clause.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

bool _avail() {
  try {
    s3.sqlite3.openInMemory().dispose();
    return true;
  } catch (_) {
    return false;
  }
}

// Verbatim browse-tier expressions — keep in sync with db_factory migrations.
const _tier = '(CASE'
    ' WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0'
    ' WHEN COALESCE(favorite,0)=1 THEN 1'
    ' WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2'
    ' WHEN last_watched IS NOT NULL THEN 3'
    ' WHEN COALESCE(stream_validated,0)=1 THEN 4 ELSE 5 END)';
const _ff = '(CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 1 END)';
const _vf = '(CASE WHEN COALESCE(favorite,0)=1'
    ' AND COALESCE(stream_validated,0)=1 THEN 0 ELSE 1 END)';
// fix537: cat_enabled removed from the index partial predicate (now a residual
// WHERE filter in the query, not an index condition).
const _part = 'WHERE url IS NOT NULL AND series_id IS NULL';

s3.Database _seed() {
  final db = s3.sqlite3.openInMemory();
  db.execute('''
    CREATE TABLE sources(id INTEGER PRIMARY KEY, sort_mode TEXT,
      hide_dividers INTEGER DEFAULT 0);
    CREATE TABLE channels(
      id INTEGER PRIMARY KEY, name TEXT, url TEXT, media_type INTEGER,
      source_id INTEGER, group_id INTEGER, group_name TEXT, favorite INTEGER,
      stream_validated INTEGER, last_watched INTEGER, provider_order INTEGER,
      series_id INTEGER, is_divider INTEGER DEFAULT 0, is_adult INTEGER DEFAULT 0,
      cat_enabled INTEGER DEFAULT 1);
  ''');
  db.execute('CREATE INDEX index_channel_series_id'
      ' ON channels(series_id) WHERE series_id IS NOT NULL');
  db.execute('CREATE INDEX idx_channels_browse_mt ON channels('
      'media_type,$_tier,name COLLATE NOCASE) $_part');
  db.execute('CREATE INDEX idx_browse_prov ON channels('
      'media_type,$_ff,$_vf,provider_order,name COLLATE NOCASE) $_part');
  db.execute('CREATE INDEX idx_browse_cat ON channels('
      'media_type,$_ff,$_vf,group_name COLLATE NOCASE,provider_order,'
      'name COLLATE NOCASE) $_part');
  // Mixed modes like the real device: src1 alpha, src2/3 category.
  db.execute("INSERT INTO sources VALUES (1,'alpha',0)");
  db.execute("INSERT INTO sources VALUES (2,'category',0)");
  db.execute("INSERT INTO sources VALUES (3,'category',0)");
  final ins = db.prepare('INSERT INTO channels '
      '(id,name,url,media_type,source_id,group_id,group_name,favorite,'
      'stream_validated,last_watched,provider_order,series_id,is_divider,'
      'is_adult,cat_enabled) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,0,0,1)');
  var id = 0;
  for (var s = 1; s <= 3; s++) {
    for (var i = 0; i < 600; i++) {
      id++;
      final episode = i % 3 == 0; // media_type=movie WITH series_id → excluded
      ins.execute([
        id, 'Ch ${1000000 + id}', 'http://x/$id', 1, s,
        i % 20, 'Cat${i % 20}', i % 30 == 0 ? 1 : 0, i % 4 == 0 ? 1 : 0,
        i % 50 == 0 ? 1700000000 + i : null, (id * 31) % 5000,
        episode ? 900000 + (i ~/ 10) : null,
      ]);
    }
  }
  ins.dispose();
  return db;
}

String _where() {
  final (vis, _) = VisibilityClause.build(
      alias: 'c.', seriesId: null, groupId: null);
  return 'media_type IN (1) AND source_id IN (1,2,3) AND url IS NOT NULL$vis';
}

List<int> _ids(s3.Database db, String sql) =>
    db.select(sql).map((r) => r['id'] as int).toList();

void main() {
  group('fix393 mixed-mode browse UNION', () {
    final available = _avail();

    List<int> baseline(s3.Database db, int offset) => _ids(
        db,
        'SELECT c.id FROM channels c WHERE ${_where()}'
        '${BrowseOrder.orderBy(null)}\nLIMIT $offset,36');

    List<int> union(s3.Database db, Map<int, String> modes, int offset) {
      final (vis, _) = VisibilityClause.build(
          alias: 'c.', seriesId: null, groupId: null);
      final lim = offset + 36;
      final parts = [
        for (final s in [1, 2, 3])
          'SELECT * FROM (SELECT c.* FROM channels c'
              ' WHERE media_type IN (1) AND source_id = $s AND url IS NOT NULL'
              '$vis${BrowseOrder.orderBy(modes[s])} LIMIT $lim)'
      ];
      return _ids(
          db,
          'SELECT c.id FROM (${parts.join(' UNION ALL ')}) c'
          '${BrowseOrder.orderBy(null)}\nLIMIT $offset,36');
    }

    test('UNION returns identical rows to the single-query mixed form (page 1)',
        () {
      if (!available) {
        markTestSkipped('libsqlite3 unavailable');
        return;
      }
      final db = _seed();
      try {
        final modes = {1: 'alpha', 2: 'category', 3: 'category'};
        expect(union(db, modes, 0), baseline(db, 0));
      } finally {
        db.dispose();
      }
    });

    test('UNION matches the single-query mixed form on a deep page (offset 72)',
        () {
      if (!available) {
        markTestSkipped('libsqlite3 unavailable');
        return;
      }
      final db = _seed();
      try {
        final modes = {1: 'alpha', 2: 'category', 3: 'category'};
        expect(union(db, modes, 72), baseline(db, 72));
      } finally {
        db.dispose();
      }
    });

    test('uniform category/provider browse is served by the new index, no sort',
        () {
      if (!available) {
        markTestSkipped('libsqlite3 unavailable');
        return;
      }
      final db = _seed();
      try {
        for (final (mode, idx) in [
          ('category', 'idx_browse_cat'),
          ('provider', 'idx_browse_prov'),
        ]) {
          final sql = 'SELECT c.id FROM channels c WHERE ${_where()}'
              '${BrowseOrder.orderBy(mode)}\nLIMIT 0,36';
          final plan = db
              .select('EXPLAIN QUERY PLAN $sql')
              .map((r) => r['detail'] as String)
              .join('\n');
          expect(plan, contains(idx),
              reason: 'uniform $mode browse must use $idx:\n$plan');
          expect(plan, isNot(contains('TEMP B-TREE')),
              reason: 'no temp B-tree expected for uniform $mode:\n$plan');
        }
      } finally {
        db.dispose();
      }
    });
  });
}
