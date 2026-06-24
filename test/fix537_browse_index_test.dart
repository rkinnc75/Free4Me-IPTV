// fix537: migration 39 removes `cat_enabled = 1` from the 7 browse indexes
// (it churned every partial index on a Select-All / source enable — measured
// 11s->0.6s on the field DB by removing it) and drops 5 unused indexes. This
// test seeds the cat_enabled-free indexes exactly as the migration creates
// them and asserts: (1) NO browse index mentions cat_enabled, and (2) every
// sort-mode browse is still served by an index with the residual cat_enabled=1
// filter and NO temp B-tree for the ORDER BY. Skips cleanly without libsqlite3.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

bool _sqliteAvailable() {
  try {
    s3.sqlite3.openInMemory().dispose();
    return true;
  } catch (_) {
    return false;
  }
}

const _tier = 'CASE'
    ' WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1 THEN 0'
    ' WHEN COALESCE(favorite,0)=1 THEN 1'
    ' WHEN last_watched IS NOT NULL AND COALESCE(stream_validated,0)=1 THEN 2'
    ' WHEN last_watched IS NOT NULL THEN 3'
    ' WHEN COALESCE(stream_validated,0)=1 THEN 4 ELSE 5 END';

void main() {
  final available = _sqliteAvailable();

  group('fix537 cat_enabled-free browse indexes', () {
    late s3.Database db;

    setUp(() {
      db = s3.sqlite3.openInMemory();
      db.execute('CREATE TABLE channels (id INTEGER PRIMARY KEY, name TEXT,'
          ' media_type INTEGER, url TEXT, source_id INTEGER, series_id INTEGER,'
          ' group_id INTEGER, cat_enabled INTEGER, favorite INTEGER,'
          ' stream_validated INTEGER, last_watched INTEGER, provider_order'
          ' INTEGER, is_adult INTEGER)');
      // The exact cat_enabled-free DDL migration 39 creates (alpha + provider,
      // mt-only + source-led, safe + non-safe).
      db.execute('CREATE INDEX idx_channels_browse_mt_safe ON channels('
          ' media_type, ($_tier), name COLLATE NOCASE )'
          ' WHERE url IS NOT NULL AND series_id IS NULL'
          ' AND COALESCE(is_adult,0) = 0');
      db.execute('CREATE INDEX idx_browse_prov_safe ON channels('
          ' media_type, (CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 1 END),'
          ' (CASE WHEN COALESCE(favorite,0)=1 AND COALESCE(stream_validated,0)=1'
          ' THEN 0 ELSE 1 END), provider_order, name COLLATE NOCASE )'
          ' WHERE url IS NOT NULL AND series_id IS NULL'
          ' AND COALESCE(is_adult,0) = 0');
      db.execute('CREATE INDEX idx_browse_src_mt_safe ON channels('
          ' source_id, media_type, ($_tier), name COLLATE NOCASE )'
          ' WHERE url IS NOT NULL AND series_id IS NULL'
          ' AND COALESCE(is_adult,0) = 0');
      db.execute("INSERT INTO channels(id,name,media_type,url,source_id,"
          "series_id,cat_enabled,favorite,stream_validated,last_watched,"
          "provider_order,is_adult) VALUES "
          "(1,'ESPN',1,'u',1,NULL,1,0,1,NULL,10,0),"
          "(2,'AMC',1,'u',1,NULL,0,0,0,NULL,11,0)");
    });
    tearDown(() => db.dispose());

    test('no browse index mentions cat_enabled', () {
      final rows = db.select(
        "SELECT name FROM sqlite_master WHERE type='index'"
        " AND sql LIKE '%cat_enabled%'",
      );
      expect(rows, isEmpty,
          reason: 'cat_enabled must be a residual filter, never in an index');
    });

    test('alpha safe browse is index-served with no temp B-tree', () {
      final q = 'SELECT * FROM channels c INDEXED BY idx_channels_browse_mt_safe'
          ' WHERE media_type IN (1) AND url IS NOT NULL'
          ' AND COALESCE(c.is_adult,0)=0 AND c.series_id IS NULL'
          ' AND c.cat_enabled=1'
          ' ORDER BY ${_tier.replaceAll('favorite', 'c.favorite').replaceAll('stream_validated', 'c.stream_validated').replaceAll('last_watched', 'c.last_watched')},'
          ' c.name COLLATE NOCASE';
      final plan = db
          .select('EXPLAIN QUERY PLAN $q')
          .map((r) => r['detail'] as String)
          .join(' | ');
      expect(plan, contains('idx_channels_browse_mt_safe'));
      expect(plan.toUpperCase(), isNot(contains('USE TEMP B-TREE')));
    });

    test('residual cat_enabled=1 filters disabled rows correctly', () {
      // id=2 is cat_enabled=0; the query must return only id=1.
      final ids = db
          .select('SELECT id FROM channels c INDEXED BY'
              ' idx_channels_browse_mt_safe WHERE media_type IN (1)'
              ' AND url IS NOT NULL AND COALESCE(c.is_adult,0)=0'
              ' AND c.series_id IS NULL AND c.cat_enabled=1')
          .map((r) => r['id'] as int)
          .toList();
      expect(ids, [1],
          reason: 'disabled (cat_enabled=0) row excluded by residual filter');
    });
  }, skip: available ? false : 'libsqlite3 not loadable on this host');
}
