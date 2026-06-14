// fix371: VisibilityClause is the single source of truth for series/divider/
// category-visibility predicates across all search paths. These tests pin the
// emitted SQL (so drift like fix365's — where _searchLike kept the slow
// correlated g.enabled subquery while the FTS path moved to cat_enabled — is
// caught) and verify the predicate behaves correctly against a real DB.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/visibility_clause.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

bool _has() { try { s3.sqlite3.openInMemory().dispose(); return true; } catch (_) { return false; } }

void main() {
  group('VisibilityClause emitted SQL', () {
    test('series view: series_id = ?, no IS NULL; keeps category gate (matches prior behaviour)', () {
      final (sql, params) = VisibilityClause.build(alias: 'c.', seriesId: 42, groupId: null);
      expect(sql, contains('c.series_id = ?'));
      expect(sql, isNot(contains('series_id IS NULL')));
      // Original gated cat_enabled on groupId==null only, so a series view
      // (groupId null) keeps it — a series in a disabled category stays hidden.
      expect(sql, contains('c.cat_enabled = 1'));
      expect(params, [42]);
    });

    test('aggregated view: excludes episodes + hides disabled categories', () {
      final (sql, params) = VisibilityClause.build(alias: 'c.', seriesId: null, groupId: null);
      expect(sql, contains('c.series_id IS NULL'));
      expect(sql, contains('c.cat_enabled = 1'));
      expect(sql, isNot(contains('g.enabled'))); // NOT the slow correlated subquery
      expect(params, isEmpty);
    });

    test('inside a category: shows all of it (group_id, no cat_enabled gate)', () {
      final (sql, params) = VisibilityClause.build(alias: 'c.', seriesId: null, groupId: 7);
      expect(sql, contains('c.group_id = ?'));
      expect(sql, isNot(contains('cat_enabled')));
      expect(params, [7]);
    });

    test('alias is threaded through every predicate', () {
      final (sql, _) = VisibilityClause.build(alias: '', seriesId: null, groupId: null);
      expect(sql, contains('series_id IS NULL'));
      expect(sql, contains('cat_enabled = 1'));
      expect(sql, isNot(contains('c.'))); // unaliased no-query path
    });
  });

  if (!_has()) {
    test('sqlite3 unavailable — DB checks skipped', () => expect(true, isTrue));
    return;
  }

  test('aggregated browse uses idx_channels_browse_enabled (both paths)', () {
    final db = s3.sqlite3.openInMemory();
    db.execute('CREATE TABLE sources(id INTEGER PRIMARY KEY, hide_dividers INT);');
    db.execute('INSERT INTO sources VALUES(1,0);');
    db.execute('''CREATE TABLE channels(id INTEGER PRIMARY KEY, name TEXT, url TEXT,
      source_id INT, media_type INT, series_id INT, favorite INT, stream_validated INT,
      last_watched INT, is_adult INT, is_divider INT, group_id INT, cat_enabled INT DEFAULT 1);''');
    db.execute('''CREATE INDEX idx_channels_browse_enabled ON channels(source_id,
      (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0
       WHEN COALESCE(favorite,0)=1 THEN 1 WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2
       WHEN last_watched IS NOT NULL THEN 3 WHEN COALESCE(stream_validated,0)=1 THEN 4 ELSE 5 END),
      name COLLATE NOCASE) WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled=1;''');
    for (var i = 0; i < 2000; i++) {
      db.execute('INSERT INTO channels(name,url,source_id,media_type,series_id,is_divider,cat_enabled) '
          'VALUES(?,?,1,1,?,0,?)', ['C$i', 'u$i', i % 5 == 0 ? null : 42, i % 3 == 0 ? 1 : 0]);
    }
    db.execute('ANALYZE');
    final (vis, _) = VisibilityClause.build(alias: 'c.', seriesId: null, groupId: null);
    final q = 'SELECT * FROM channels c WHERE media_type IN (1) AND source_id IN (1) '
        'AND c.url IS NOT NULL $vis ORDER BY source_id, name COLLATE NOCASE LIMIT 36';
    final plan = db.select('EXPLAIN QUERY PLAN $q').map((r) => r['detail'] as String).join(' | ');
    // The browse uses the partial index for the hot path. (A correlated
    // subquery for the per-source divider-hide guard remains by design — it is
    // the category-enabled filter that must NOT be a correlated subquery, and
    // it is not: cat_enabled is a plain indexed column.)
    expect(plan, contains('idx_channels_browse_enabled'));
    expect(plan, isNot(contains('g.enabled')));
    expect(vis, contains('cat_enabled = 1'));
    expect(vis, isNot(contains('SELECT g.enabled')));
    db.dispose();
  });
}
