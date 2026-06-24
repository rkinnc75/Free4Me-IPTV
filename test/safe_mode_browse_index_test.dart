// fix528 (P0 perf): Safe-Mode-ON TV browse was 7-84s because the partial browse
// indexes don't cover the safe-mode predicate (COALESCE(is_adult,0)=0), forcing
// a TEMP B-TREE sort over the whole media_type partition. The fix adds
// SAFE-MODE-VARIANT partial indexes (same key columns + the is_adult condition
// in the partial WHERE). The design hinges on SQLite's partial-index matching:
//   - the Safe-Mode-ON query (carries COALESCE(is_adult,0)=0) MATCHES the
//     variant → index-served filter+sort;
//   - the Safe-Mode-OFF query (no is_adult predicate) does NOT match the variant
//     → it keeps using the ORIGINAL index (zero safe-off regression).
// This pins both halves with a forced INDEXED BY (reliable — no dependence on
// planner row-stats, which a tiny test table lacks).
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

const _tierProv =
    '(CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 1 END), '
    '(CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 '
    'THEN 0 ELSE 1 END), provider_order, name COLLATE NOCASE';

void main() {
  late s3.Database db;
  setUp(() {
    db = s3.sqlite3.openInMemory();
    db.execute('CREATE TABLE channels (id INTEGER PRIMARY KEY, name TEXT, '
        'media_type INTEGER, url TEXT, source_id INTEGER, series_id INTEGER, '
        'cat_enabled INTEGER, favorite INTEGER, stream_validated INTEGER, '
        'provider_order INTEGER, is_adult INTEGER)');
    // fix528 safe variant (mirrors idx_browse_prov + the is_adult partial cond).
    db.execute('CREATE INDEX idx_browse_prov_safe ON channels('
        'media_type, (CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 1 END), '
        '(CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 '
        'THEN 0 ELSE 1 END), provider_order, name COLLATE NOCASE) '
        'WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled = 1 '
        'AND COALESCE(is_adult,0) = 0');
    // The original (no is_adult), for the safe-OFF path.
    db.execute('CREATE INDEX idx_browse_prov ON channels('
        'media_type, (CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 1 END), '
        '(CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 '
        'THEN 0 ELSE 1 END), provider_order, name COLLATE NOCASE) '
        'WHERE url IS NOT NULL AND series_id IS NULL AND cat_enabled = 1');
    db.execute("INSERT INTO channels(id,name,media_type,url,source_id,series_id,"
        "cat_enabled,favorite,stream_validated,provider_order,is_adult) VALUES "
        "(1,'ESPN',0,'http://x/1',1,NULL,1,0,1,10,0),"
        "(2,'XXX TV',0,'http://x/2',1,NULL,1,0,1,11,1)");
  });
  tearDown(() => db.dispose());

  String _q(String hint, {required bool safe}) =>
      'SELECT id FROM channels c INDEXED BY $hint '
      'WHERE media_type IN (0) AND url IS NOT NULL AND series_id IS NULL '
      'AND cat_enabled = 1${safe ? ' AND COALESCE(is_adult,0) = 0' : ''} '
      'ORDER BY $_tierProv';

  test('Safe-Mode-ON query matches the _safe variant + excludes adult', () {
    final ids = db.select(_q('idx_browse_prov_safe', safe: true))
        .map((r) => r['id'] as int).toList();
    expect(ids, [1], reason: 'adult id=2 excluded by the partial index');
  });

  test('Safe-Mode-OFF query CANNOT use the _safe variant (no regression)', () {
    // No is_adult predicate → SQLite cannot prove the partial index applies →
    // forcing it is an error. Proves safe-off falls back to the ORIGINAL index.
    expect(() => db.select(_q('idx_browse_prov_safe', safe: false)),
        throwsA(isA<s3.SqliteException>()));
  });

  test('Safe-Mode-OFF query uses the ORIGINAL index fine', () {
    expect(() => db.select(_q('idx_browse_prov', safe: false)), returnsNormally);
    final ids = db.select(_q('idx_browse_prov', safe: false))
        .map((r) => r['id'] as int).toList();
    expect(ids, [1, 2], reason: 'safe-off shows all (provider_order)');
  });

  test('the safe-mode query is served by the variant with NO temp B-tree', () {
    final plan = db
        .select('EXPLAIN QUERY PLAN ${_q('idx_browse_prov_safe', safe: true)}')
        .map((r) => r['detail'] as String)
        .join(' | ');
    expect(plan, contains('idx_browse_prov_safe'));
    expect(plan.toUpperCase(), isNot(contains('USE TEMP B-TREE')),
        reason: 'index serves the ORDER BY — no sort');
  });
}
