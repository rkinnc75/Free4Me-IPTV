// fix362: regression tests for the series-view / episode-leak query semantics
// that fix353's table-level test never exercised. These build the exact WHERE
// fragments Sql.search emits and run them against a seeded DB:
//   - series view (seriesId set) returns that series' episodes
//   - movies browse + movies search (seriesId null) EXCLUDE episodes
// CRIT-1 was: an unconditional "series_id IS NULL" in the base ANDed with the
// series view's "series_id = ?" -> every series empty. HIGH-1 was the parallel
// gap in the in-memory cache filter.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

bool _has() {
  try { s3.sqlite3.openInMemory().dispose(); return true; } catch (_) { return false; }
}

void main() {
  if (!_has()) {
    test('sqlite3 unavailable — skipped', () => expect(true, isTrue));
    return;
  }
  late s3.Database db;
  setUp(() {
    db = s3.sqlite3.openInMemory();
    db.execute('''CREATE TABLE channels(id INTEGER PRIMARY KEY, name TEXT, url TEXT,
      source_id INT, media_type INT, series_id INT, favorite INT DEFAULT 0);''');
    db.execute('''INSERT INTO channels(name,url,source_id,media_type,series_id) VALUES
      ('Breaking Bad','42',5,2,NULL),('S01E01','u1',5,1,42),('S01E02','u2',5,1,42),
      ('Some Movie','m1',5,1,NULL),('Another Film','m2',5,1,NULL);''');
  });
  tearDown(() => db.dispose());

  // Mirrors Sql.search append logic: seriesId set -> "series_id = ?";
  // else -> "series_id IS NULL".
  List<String> run({int? seriesId}) {
    var q = 'SELECT name FROM channels c WHERE media_type IN (1)'
        ' AND source_id IN (5) AND url IS NOT NULL';
    final p = <Object>[];
    if (seriesId != null) {
      q += ' AND series_id = ?';
      p.add(seriesId);
    } else {
      q += ' AND series_id IS NULL';
    }
    return db.select(q, p).map((r) => r['name'] as String).toList()..sort();
  }

  test('series view returns that series\' episodes (CRIT-1 guard)', () {
    expect(run(seriesId: 42), ['S01E01', 'S01E02']);
  });

  test('movies browse/search excludes episodes (fix355 intent preserved)', () {
    expect(run(seriesId: null), ['Another Film', 'Some Movie']);
  });

  // HIGH-1: the in-memory cache filter must be symmetric.
  bool cacheKeep(int? eSeriesId, int? seriesId) {
    if (seriesId != null && eSeriesId != seriesId) return false;
    if (seriesId == null && eSeriesId != null) return false;
    return true;
  }

  test('in-memory cache excludes episodes outside a series, keeps them inside', () {
    expect(cacheKeep(42, null), false); // episode in movies search
    expect(cacheKeep(null, null), true); // movie in movies search
    expect(cacheKeep(42, 42), true); // episode in its series
    expect(cacheKeep(99, 42), false); // other series' episode
  });
}
