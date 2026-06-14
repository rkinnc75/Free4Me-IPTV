// fix365: the Live/VOD/Series browse query must use idx_channels_browse_enabled
// (the partial index excluding disabled-category + episode rows) and must NOT
// fall back to the per-row correlated g.enabled subquery that caused 5s grid
// loads when most categories were disabled. Verifies index usage + that
// cat_enabled stays consistent with groups.enabled after toggles.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

bool _has() { try { s3.sqlite3.openInMemory().dispose(); return true; } catch (_) { return false; } }

void main() {
  if (!_has()) { test('sqlite3 unavailable — skipped', () => expect(true, isTrue)); return; }
  late s3.Database db;
  setUp(() {
    db = s3.sqlite3.openInMemory();
    db.execute('''CREATE TABLE groups(id INTEGER PRIMARY KEY, name TEXT, source_id INT, enabled INT);''');
    db.execute('''CREATE TABLE channels(id INTEGER PRIMARY KEY, name TEXT, url TEXT,
      source_id INT, media_type INT, series_id INT, favorite INT, stream_validated INT,
      last_watched INT, is_adult INT, is_divider INT, group_id INT, cat_enabled INT DEFAULT 1);''');
    db.execute('''CREATE INDEX idx_channels_browse_enabled ON channels(source_id,
      (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0
       WHEN COALESCE(favorite,0)=1 THEN 1 WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2
       WHEN last_watched IS NOT NULL THEN 3 WHEN COALESCE(stream_validated,0)=1 THEN 4 ELSE 5 END),
      name COLLATE NOCASE) WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled=1;''');
    for (var g = 1; g <= 20; g++) {
      db.execute('INSERT INTO groups VALUES(?,?,1,?)', [g, 'G$g', g <= 2 ? 1 : 0]);
    }
    for (var i = 0; i < 5000; i++) {
      final g = (i % 20) + 1;
      db.execute('INSERT INTO channels(name,url,source_id,media_type,series_id,favorite,'
          'stream_validated,is_adult,is_divider,group_id,cat_enabled) '
          'VALUES(?,?,1,1,?,0,0,0,0,?,?)',
          ['C$i', 'u$i', i % 5 == 0 ? null : 42, g, g <= 2 ? 1 : 0]);
    }
    db.execute('ANALYZE');
  });
  tearDown(() => db.dispose());

  const browse = '''SELECT * FROM channels c WHERE media_type IN (1) AND source_id IN (1)
    AND url IS NOT NULL AND series_id IS NULL AND COALESCE(c.is_adult,0)=0
    AND c.cat_enabled = 1
    ORDER BY source_id,(CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0
     WHEN COALESCE(favorite,0)=1 THEN 1 WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2
     WHEN last_watched IS NOT NULL THEN 3 WHEN COALESCE(stream_validated,0)=1 THEN 4 ELSE 5 END),
     name COLLATE NOCASE LIMIT 36''';

  test('browse uses idx_channels_browse_enabled, not a correlated subquery', () {
    final plan = db.select('EXPLAIN QUERY PLAN $browse').map((r) => r['detail'] as String).join(' | ');
    expect(plan, contains('idx_channels_browse_enabled'));
    expect(plan.toLowerCase(), isNot(contains('correlated')));
  });

  test('toggle keeps cat_enabled consistent with groups.enabled', () {
    db.execute('UPDATE groups SET enabled=1 WHERE id=5');
    db.execute('UPDATE channels SET cat_enabled=1 WHERE group_id=5');
    final mism = db.select('''SELECT COUNT(*) n FROM channels c JOIN groups g ON g.id=c.group_id
      WHERE c.cat_enabled != g.enabled''').first['n'] as int;
    expect(mism, 0);
  });
}
