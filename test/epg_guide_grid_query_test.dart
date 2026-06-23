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
}
