// fix373: idx_channels_browse_mt (media_type, tier, name) must serve a
// single-media-type browse across MULTIPLE sources without a temp B-tree — the
// case that caused ~5.8s cold first paint on a 2-source catalog (the fix365
// index leads with source_id, so a multi-source ORDER BY tier,name fell back
// to USE TEMP B-TREE).
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

bool _has() { try { s3.sqlite3.openInMemory().dispose(); return true; } catch (_) { return false; } }

const _tier = 'CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0 '
    'WHEN COALESCE(favorite,0)=1 THEN 1 '
    'WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2 '
    'WHEN last_watched IS NOT NULL THEN 3 '
    'WHEN COALESCE(stream_validated,0)=1 THEN 4 ELSE 5 END';
const _tierC = 'CASE WHEN COALESCE(c.favorite,0)=1 AND COALESCE(c.stream_validated,0)=1 THEN 0 '
    'WHEN COALESCE(c.favorite,0)=1 THEN 1 '
    'WHEN c.last_watched IS NOT NULL AND COALESCE(c.stream_validated,0)=1 THEN 2 '
    'WHEN c.last_watched IS NOT NULL THEN 3 '
    'WHEN COALESCE(c.stream_validated,0)=1 THEN 4 ELSE 5 END';

void main() {
  if (!_has()) { test('sqlite3 unavailable — skipped', () => expect(true, isTrue)); return; }
  late s3.Database db;
  setUp(() {
    db = s3.sqlite3.openInMemory();
    db.execute('CREATE TABLE sources(id INTEGER PRIMARY KEY, hide_dividers INT);');
    db.execute('INSERT INTO sources VALUES(1,0),(2,0);');
    db.execute('''CREATE TABLE channels(id INTEGER PRIMARY KEY, name TEXT, url TEXT,
      source_id INT, media_type INT, series_id INT, favorite INT, stream_validated INT,
      last_watched INT, is_adult INT, is_divider INT, cat_enabled INT DEFAULT 1);''');
    db.execute('''CREATE INDEX idx_channels_browse_mt ON channels(media_type,($_tier),
      name COLLATE NOCASE) WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled=1;''');
    for (var i = 0; i < 4000; i++) {
      db.execute('INSERT INTO channels(name,url,source_id,media_type,series_id,is_divider,cat_enabled) '
          'VALUES(?,?,?,?,NULL,0,1)', ['C$i', 'u$i', (i % 2) + 1, i % 3]);
    }
    db.execute('ANALYZE');
  });
  tearDown(() => db.dispose());

  String plan(List<int> mt, List<int> src) {
    final mtc = mt.join(','); final sc = src.join(',');
    final q = 'SELECT * FROM channels c WHERE media_type IN ($mtc) AND source_id IN ($sc) '
        'AND c.url IS NOT NULL AND COALESCE(c.is_adult,0)=0 AND c.series_id IS NULL '
        'AND c.cat_enabled=1 ORDER BY ($_tierC) ASC, c.name COLLATE NOCASE ASC LIMIT 36';
    return db.select('EXPLAIN QUERY PLAN $q').map((r) => r['detail'] as String).join(' | ');
  }

  test('single-media multi-source: uses idx_channels_browse_mt, NO temp b-tree', () {
    final p = plan([0], [1, 2]);
    expect(p, contains('idx_channels_browse_mt'));
    expect(p.toUpperCase(), isNot(contains('TEMP B-TREE')));
  });

  test('single-media single-source: still index-served, no temp b-tree', () {
    final p = plan([0], [1]);
    expect(p, contains('idx_channels_browse_mt'));
    expect(p.toUpperCase(), isNot(contains('TEMP B-TREE')));
  });
}
