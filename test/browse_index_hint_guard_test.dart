// fix526 (P0 regression): the single-source alpha browse force-hinted
// `SELECT * FROM channels c INDEXED BY idx_browse_src_mt ...` (sql.dart). On
// some upgraded installs that partial index (migration 34) is ABSENT, and a
// forced INDEXED BY on a missing index is a HARD SqliteException ("no such
// index") — it escaped as an unhandled error and left the browse stuck on
// "loading" with nothing shown. The fix gates the hint on the index actually
// existing (Sql._indexExists). These tests pin both halves against a real
// in-memory sqlite3 DB: the bare forced hint throws when the index is missing
// (the crash), and the existence probe + fallback are correct.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

bool _indexExists(s3.Database db, String name) => db
    .select("SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
        [name])
    .isNotEmpty;

void main() {
  late s3.Database db;
  setUp(() {
    db = s3.sqlite3.openInMemory();
    db.execute('CREATE TABLE channels (id INTEGER PRIMARY KEY, name TEXT, '
        'media_type INTEGER, url TEXT, source_id INTEGER, series_id INTEGER, '
        'cat_enabled INTEGER, favorite INTEGER, stream_validated INTEGER, '
        'last_watched INTEGER)');
    db.execute('INSERT INTO channels(id,name,media_type,url,source_id,'
        'series_id,cat_enabled) VALUES (1,?,0,?,1,NULL,1)', ['ESPN', 'http://x']);
  });
  tearDown(() => db.dispose());

  test('forcing a MISSING index throws (the crash this fix prevents)', () {
    expect(_indexExists(db, 'idx_browse_src_mt'), isFalse);
    expect(
      () => db.select('SELECT * FROM channels c INDEXED BY idx_browse_src_mt '
          'WHERE media_type IN (0) AND source_id IN (1) AND url IS NOT NULL'),
      throwsA(isA<s3.SqliteException>()),
      reason: 'forced INDEXED BY on an absent index is a hard error',
    );
  });

  test('gate falls back to an UNHINTED query when the index is absent', () {
    // Mirrors the fix526 gate: index missing → drop the hint → query runs fine.
    final useHint = _indexExists(db, 'idx_browse_src_mt');
    expect(useHint, isFalse);
    final sql = 'SELECT * FROM channels c'
        '${useHint ? ' INDEXED BY idx_browse_src_mt' : ''} '
        'WHERE media_type IN (0) AND source_id IN (1) AND url IS NOT NULL';
    expect(() => db.select(sql), returnsNormally);
    expect(db.select(sql).length, 1);
  });

  test('when the index EXISTS, the probe is true and the hint works', () {
    db.execute('''
      CREATE INDEX idx_browse_src_mt ON channels(
        source_id, media_type,
        (CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 5 END),
        name COLLATE NOCASE)
      WHERE url IS NOT NULL AND series_id IS NULL
    ''');
    expect(_indexExists(db, 'idx_browse_src_mt'), isTrue);
    // fix537: cat_enabled is no longer in the index predicate (it is a residual
    // WHERE filter now), so the forced INDEXED BY is honored as long as the
    // query satisfies the remaining partial (series_id IS NULL).
    expect(
      () => db.select('SELECT * FROM channels c INDEXED BY idx_browse_src_mt '
          'WHERE media_type IN (0) AND source_id IN (1) AND url IS NOT NULL '
          'AND series_id IS NULL AND cat_enabled = 1'),
      returnsNormally,
    );
  });

  test('fix627: grouped browse forcing idx_browse_src_grp — honored only when '
      'url IS NOT NULL AND series_id IS NULL are present (both always emitted); '
      'missing one is a hard error, NEVER silent row loss', () {
    final gdb = s3.sqlite3.openInMemory();
    gdb.execute('CREATE TABLE channels (id INTEGER PRIMARY KEY, name TEXT, '
        'media_type INTEGER, url TEXT, source_id INTEGER, series_id INTEGER, '
        'group_id INTEGER, cat_enabled INTEGER, favorite INTEGER, '
        'stream_validated INTEGER, last_watched INTEGER)');
    gdb.execute('''
      CREATE INDEX idx_browse_src_grp ON channels(
        source_id, group_id,
        (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0
              WHEN COALESCE(favorite,0)=1 THEN 1
              WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2
              WHEN last_watched IS NOT NULL THEN 3
              WHEN COALESCE(stream_validated,0)=1 THEN 4 ELSE 5 END),
        name COLLATE NOCASE)
      WHERE url IS NOT NULL AND series_id IS NULL
    ''');
    gdb.execute('INSERT INTO channels(id,name,media_type,url,source_id,'
        'series_id,group_id,cat_enabled) VALUES (1,?,0,?,1,NULL,7,1)',
        ['ESPN', 'http://x']);
    // Grouped browse emits url IS NOT NULL (query) + series_id IS NULL
    // (VisibilityClause, groupId set) → satisfies the partial index → honored.
    final ok = 'SELECT * FROM channels c INDEXED BY idx_browse_src_grp '
        'WHERE media_type IN (0) AND source_id IN (1) AND url IS NOT NULL '
        'AND series_id IS NULL AND group_id = 7';
    expect(() => gdb.select(ok), returnsNormally);
    expect(gdb.select(ok).length, 1);
    // Drop series_id IS NULL → SQLite refuses to plan ("no query solution"):
    // a HARD error, proving the force can never silently drop rows.
    expect(
      () => gdb.select('SELECT * FROM channels c INDEXED BY idx_browse_src_grp '
          'WHERE media_type IN (0) AND source_id IN (1) AND url IS NOT NULL '
          'AND group_id = 7'),
      throwsA(isA<s3.SqliteException>()),
    );
    gdb.dispose();
  });
}
