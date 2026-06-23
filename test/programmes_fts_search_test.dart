// fix502: searchPrograms() must be FTS-index-served on programmes_fts — a
// trigram MATCH driving a PK join, never a full SCAN of the ~1M-row programmes
// table (the <1000ms-cold gate). Also verifies the forward-only window + the
// source filter, and the trigger-free 'rebuild' backfill.
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
const _windowEnd = _now + 3 * 3600; // default 3-hour forward window

// Mirrors Sql.searchPrograms' SQL exactly.
const _select = 'SELECT p.id, p.title, p.source_id, p.start_utc '
    'FROM programmes_fts f INNER JOIN programmes p ON p.id = f.rowid '
    'WHERE programmes_fts MATCH ? AND p.source_id IN (PH) '
    'AND p.stop_utc > ? AND p.start_utc < ? ORDER BY p.start_utc ASC LIMIT 200';

String _ph(int n) => List.filled(n, '?').join(',');

void _ins(s3.Database db, String ch, int src, String title, int start, int stop) {
  db.execute(
    'INSERT INTO programmes(epg_channel_id, source_id, title, start_utc, stop_utc) '
    'VALUES(?,?,?,?,?)',
    [ch, src, title, start, stop],
  );
}

void main() {
  if (!_has()) {
    test('sqlite3 unavailable — skipped', () => expect(true, isTrue));
    return;
  }
  late s3.Database db;
  setUp(() {
    db = s3.sqlite3.openInMemory();
    db.execute('''
      CREATE TABLE programmes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        epg_channel_id TEXT NOT NULL, source_id INTEGER NOT NULL,
        title TEXT NOT NULL, description TEXT, category TEXT,
        start_utc INTEGER NOT NULL, stop_utc INTEGER NOT NULL, episode_num TEXT);
    ''');
    db.execute('CREATE INDEX idx_programs_time_range '
        'ON programmes(source_id, start_utc, stop_utc);');
    db.execute("CREATE VIRTUAL TABLE programmes_fts USING fts5("
        "title, content='programmes', content_rowid='id', tokenize='trigram');");
    // Volume of non-matching rows so the planner cannot dismiss the index.
    for (var i = 0; i < 3000; i++) {
      _ins(db, 'ch$i', (i % 2) + 1, 'Show $i', _now + i * 60, _now + i * 60 + 1800);
    }
    _ins(db, 'gsn', 1, 'Family Feud', _now - 600, _now + 1200); // on now (src1)
    _ins(db, 'abc', 1, 'Celebrity Family Feud', _now + 7200, _now + 9000); // +2h
    _ins(db, 'gsn', 1, 'Family Feud', _now + 5 * 3600, _now + 5 * 3600 + 1800); // +5h: out
    _ins(db, 'gsn', 1, 'Family Feud', _now - 7200, _now - 3600); // ended: past
    _ins(db, 'x', 3, 'Family Feud', _now + 600, _now + 2400); // source 3: excluded
    // Trigger-free backfill — exactly what Sql.rebuildProgrammesFts runs.
    db.execute("INSERT INTO programmes_fts(programmes_fts) VALUES('rebuild');");
    db.execute('ANALYZE');
  });
  tearDown(() => db.dispose());

  List<Map<String, Object?>> run(String term, List<int> src) {
    final match = '"${term.replaceAll('"', '""')}"';
    final sql = _select.replaceFirst('PH', _ph(src.length));
    return db.select(sql, [match, ...src, _now, _windowEnd]);
  }

  String plan(String term, List<int> src) {
    final match = '"$term"';
    final sql = _select.replaceFirst('PH', _ph(src.length));
    return db
        .select('EXPLAIN QUERY PLAN $sql', [match, ...src, _now, _windowEnd])
        .map((r) => r['detail'] as String)
        .join(' | ')
        .toUpperCase();
  }

  test('FTS-index-served: programmes_fts MATCH + PK join, no base-table scan', () {
    final p = plan('family', [1, 2]);
    // EXPLAIN labels tables by alias: the FTS virtual table is 'f', the base
    // 'p'. The perf signals: FTS index engaged (a VIRTUAL TABLE scan via the
    // MATCH) + the base reached by its rowid PRIMARY KEY, never a full scan.
    expect(p, contains('VIRTUAL TABLE')); // programmes_fts MATCH drives the query
    expect(p, contains('PRIMARY KEY')); // programmes reached by rowid
    expect(p, isNot(contains('SCAN P'))); // no full scan of the programmes base
  });

  test('forward window + source filter: only now/upcoming matches, current sources', () {
    final rows = run('family', [1, 2]);
    final titles = rows.map((r) => r['title'] as String).toList();
    expect(titles, contains('Family Feud')); // airing now
    expect(titles, contains('Celebrity Family Feud')); // +2h, within window
    // excludes: +5h (out of window), ended (past), source 3 (filtered)
    expect(titles.length, 2);
    expect(rows.first['title'], 'Family Feud'); // ordered by start_utc asc
  });
}
