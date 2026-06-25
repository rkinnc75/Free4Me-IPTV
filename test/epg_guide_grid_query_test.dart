// fix503: getGridPrograms must seek programmes by a BOUNDED epg_channel_id
// IN-list using idx_programs_channel_time — never a source-wide window scan via
// idx_programs_time_range, and never a full SCAN of the ~1M-row programmes
// table. This is the rail-scoped <1000ms-cold gate; the result is grouped +
// sorted in Dart (no ORDER BY in SQL, so no temp B-tree).
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

bool _has() {
  try {
    s3.sqlite3.openInMemory().dispose();
    return true;
  } catch (_) {
    return false;
  }
}

const _now = 1700000000;
const _windowEnd = _now + 3 * 3600;

void main() {
  if (!_has()) {
    test('sqlite3 unavailable — skipped', () => expect(true, isTrue));
    return;
  }
  late s3.Database db;
  setUp(() {
    db = s3.sqlite3.openInMemory();
    db.execute('''CREATE TABLE programmes (
      id INTEGER PRIMARY KEY AUTOINCREMENT, epg_channel_id TEXT NOT NULL,
      source_id INTEGER NOT NULL, title TEXT NOT NULL, description TEXT,
      category TEXT, start_utc INTEGER NOT NULL, stop_utc INTEGER NOT NULL,
      episode_num TEXT);''');
    db.execute('CREATE INDEX idx_programs_channel_time '
        'ON programmes(epg_channel_id, source_id, start_utc);');
    db.execute('CREATE INDEX idx_programs_time_range '
        'ON programmes(source_id, start_utc, stop_utc);');
    // Volume: 2 sources × 200 channels × 30 programmes — a source-wide scan
    // would touch thousands of rows; the bounded IN-list must not.
    final stmt = db.prepare(
      'INSERT INTO programmes(epg_channel_id, source_id, title, start_utc, stop_utc) '
      'VALUES(?,?,?,?,?)',
    );
    for (var src = 1; src <= 2; src++) {
      for (var ch = 0; ch < 200; ch++) {
        for (var k = 0; k < 30; k++) {
          final start = _now - 6 * 3600 + k * 1800;
          stmt.execute(['ch$ch', src, 'P$ch-$k', start, start + 1800]);
        }
      }
    }
    stmt.dispose();
    db.execute('ANALYZE');
  });
  tearDown(() => db.dispose());

  String plan(int sourceId, List<String> ids) {
    final ph = List.filled(ids.length, '?').join(',');
    final sql = 'SELECT id, epg_channel_id, source_id, title, start_utc, stop_utc '
        'FROM programmes WHERE source_id = ? AND epg_channel_id IN ($ph) '
        'AND start_utc < ? AND stop_utc > ?';
    return db
        .select('EXPLAIN QUERY PLAN $sql', [sourceId, ...ids, _windowEnd, _now])
        .map((r) => r['detail'] as String)
        .join(' | ')
        .toUpperCase();
  }

  test('grid query seeks per-channel via idx_programs_channel_time, no full scan', () {
    final ids = List.generate(20, (i) => 'ch$i'); // a realized page of rows
    final p = plan(1, ids);
    // Must seek the per-channel index (bounded by the IN-list), not a
    // source-wide time-range scan, and never a full table SCAN.
    expect(p, contains('IDX_PROGRAMS_CHANNEL_TIME'));
    expect(p, isNot(contains('SCAN PROGRAMMES')));
  });

  // fix541 (item 6): the guide's _windowStart/_windowEnd were set ONCE in
  // initState and never recomputed; because the shell keeps the guide alive,
  // the window went stale and getGridPrograms fetched a fully-elapsed range, so
  // now/next details vanished. This documents the failure (stale window misses
  // the on-now programme) and the fix (a window re-anchored to NOW catches it).
  group('fix541 stale guide window', () {
    int countInWindow(int windowStart, int windowEnd) {
      final rows = db.select(
        'SELECT COUNT(*) c FROM programmes WHERE source_id = 1 '
        'AND epg_channel_id = ? AND start_utc < ? AND stop_utc > ?',
        ['ch0', windowEnd, windowStart],
      );
      return rows.first['c'] as int;
    }

    test('a stale window entirely before the data misses on-now', () {
      // ch0's earliest programme starts at _now - 6h. A window that ends before
      // that (the "set once, hours ago, now elapsed" case) sees nothing.
      final staleStart = _now - 12 * 3600;
      final staleEnd = _now - 8 * 3600; // ends 2h before the first programme
      expect(countInWindow(staleStart, staleEnd), 0,
          reason: 'fully-elapsed window cannot see any current programme');
    });

    test('a window re-anchored to NOW finds the on-now programme', () {
      // ch0 has a programme at [_now, _now+1800) (k=12 in the seed:
      // start = _now - 6h + 12*1800 = _now). Re-anchoring catches it.
      expect(countInWindow(_now, _windowEnd), greaterThan(0),
          reason: 'recomputed window includes the current programme');
    });
  });
}
