// fix518: Sql.withDroppedBrowseIndexes drops the NON-UNIQUE secondary indexes
// on `channels` for the duration of a bulk refresh and recreates them verbatim
// afterward, while KEEPING the UNIQUE indexes the reinsert relies on. The
// per-row maintenance of ~a dozen indexes across a multi-hundred-thousand-row
// wipe+reinsert was the dominant refresh cost (measured 101s DELETE + ~165s of
// inserts on a 273K-row source).
//
// This pins the load-bearing SQL logic — the sqlite_master filter that decides
// WHICH indexes to drop, and the verbatim recreate — against a real in-memory
// sqlite3, mirroring lib/backend/sql.dart withDroppedBrowseIndexes. A missed
// index (dropped but not recreated, or a UNIQUE index wrongly dropped) would
// silently degrade browse/search or break reinsert dedup, so it is tested
// explicitly.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

// The exact predicate from Sql.withDroppedBrowseIndexes.
List<Map<String, Object?>> _droppable(s3.Database db) => db
    .select("SELECT name, sql FROM sqlite_master "
        "WHERE type='index' AND tbl_name='channels' "
        "AND sql IS NOT NULL AND UPPER(sql) NOT LIKE 'CREATE UNIQUE%' "
        "AND name NOT IN ('index_channel_source_id')")
    .map((r) => {'name': r['name'], 'sql': r['sql']})
    .toList();

Map<String, String?> _allChannelIndexes(s3.Database db) => {
      for (final r in db.select(
          "SELECT name, sql FROM sqlite_master "
          "WHERE type='index' AND tbl_name='channels'"))
        r['name'] as String: r['sql'] as String?,
    };

void _schema(s3.Database db) {
  db.execute('''
    CREATE TABLE channels (
      id INTEGER PRIMARY KEY, name TEXT, source_id INTEGER, group_name TEXT,
      group_id INTEGER, media_type INTEGER, stream_id INTEGER,
      series_id INTEGER, favorite INTEGER, cat_enabled INTEGER
    );
  ''');
  // Non-unique secondary indexes (must be dropped + recreated).
  db.execute('CREATE INDEX index_channel_source_id ON channels(source_id);');
  db.execute(
      'CREATE INDEX index_channels_group_name ON channels(group_name);');
  db.execute('CREATE INDEX idx_browse_src_mt ON channels(source_id, media_type);');
  db.execute('CREATE INDEX index_channel_favorite ON channels(favorite);');
  // UNIQUE indexes (must be KEPT — the reinsert dedups on them).
  db.execute('CREATE UNIQUE INDEX channels_unique_stream '
      'ON channels(source_id, stream_id);');
  db.execute('CREATE UNIQUE INDEX channels_unique_series '
      'ON channels(source_id, series_id, name);');
}

void main() {
  group('fix518 withDroppedBrowseIndexes SQL logic', () {
    test('predicate selects exactly the non-unique channels indexes', () {
      final db = s3.sqlite3.openInMemory();
      addTearDown(db.dispose);
      _schema(db);
      final names = _droppable(db).map((r) => r['name']).toSet();
      expect(
          names,
          {
            'index_channels_group_name',
            'idx_browse_src_mt',
            'index_channel_favorite',
          },
          reason: 'non-unique secondary indexes are droppable EXCEPT the '
              'refresh-critical index_channel_source_id (fix520)');
      expect(names, isNot(contains('index_channel_source_id')),
          reason: 'fix520: kept so per-source WHERE source_id=? stays indexed '
              '(dropping it made each a ~20s full scan on the box)');
      expect(names, isNot(contains('channels_unique_stream')));
      expect(names, isNot(contains('channels_unique_series')));
    });

    test('drop + verbatim recreate restores the exact index set', () {
      final db = s3.sqlite3.openInMemory();
      addTearDown(db.dispose);
      _schema(db);
      final before = _allChannelIndexes(db);
      final dropped = _droppable(db);
      for (final r in dropped) {
        db.execute('DROP INDEX IF EXISTS "${r['name']}";');
      }
      // Mid-body: unique indexes + the kept source_id index survive;
      // droppable ones are gone.
      final mid = _allChannelIndexes(db);
      expect(mid.containsKey('channels_unique_stream'), isTrue);
      expect(mid.containsKey('channels_unique_series'), isTrue);
      expect(mid.containsKey('index_channel_source_id'), isTrue,
          reason: 'fix520: kept so refresh source_id queries stay indexed');
      expect(mid.containsKey('idx_browse_src_mt'), isFalse);
      // Recreate from the stored DDL.
      for (final r in dropped) {
        db.execute(r['sql'] as String);
      }
      expect(_allChannelIndexes(db), equals(before),
          reason: 'index names + DDL byte-identical after restore');
    });

    test('recreate still runs when the body throws (finally semantics)', () {
      final db = s3.sqlite3.openInMemory();
      addTearDown(db.dispose);
      _schema(db);
      final before = _allChannelIndexes(db);
      final dropped = _droppable(db);
      for (final r in dropped) {
        db.execute('DROP INDEX IF EXISTS "${r['name']}";');
      }
      try {
        throw StateError('refresh failed mid-way');
      } catch (_) {
        // swallow — mirrors a source refresh throwing inside the wrapper body
      } finally {
        for (final r in dropped) {
          db.execute(r['sql'] as String);
        }
      }
      expect(_allChannelIndexes(db), equals(before),
          reason: 'a failed refresh must still leave all indexes restored');
    });
  });
}
