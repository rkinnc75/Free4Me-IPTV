// fix677: guards the insertRecording rowid contract.
//
// The device bug: Sql.insertRecording did `db.execute(INSERT)` then a SEPARATE
// `db.getAll('SELECT last_insert_rowid()')`. Under sqlite_async's connection
// pool those two statements can land on DIFFERENT connections, and
// last_insert_rowid() is per-connection — so the read returned 0 for a row that
// was inserted on another connection. The 0 became the alarm id, and
// recordingAlarmCallback(0) then found no row (confirmed on device by the
// fix676 [SRDBG] trace: "got row id=0 rec=NULL"). Every scheduled recording
// died before capture.
//
// The fix runs the INSERT and its last_insert_rowid() read inside ONE
// writeTransaction (single connection). sqlite_async's pool isn't exercised in
// the sandbox, so this test asserts the underlying SQLite contract against the
// verbatim `recordings` DDL: an INSERT that omits the INTEGER PRIMARY KEY
// AUTOINCREMENT column allocates a non-zero rowid, and last_insert_rowid() read
// on the SAME connection returns it, monotonically increasing across inserts.
// If someone reverts insertRecording to the two-statement form, the reviewer
// still has this documenting the id must be captured on the inserting
// connection.
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

// Verbatim from db_factory.dart migration 44.
const _recordingsDdl = '''
  CREATE TABLE recordings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id INTEGER,
    channel_name TEXT NOT NULL,
    url TEXT NOT NULL,
    scheduled_start_utc INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL,
    pad_before_min INTEGER NOT NULL DEFAULT 0,
    pad_after_min INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'scheduled',
    output_path TEXT,
    error TEXT,
    created_utc INTEGER NOT NULL
  );
''';

void main() {
  final available = _sqliteAvailable();

  test('insert allocates non-zero rowid; last_insert_rowid() on same '
      'connection returns it and increases', () {
    if (!available) {
      markTestSkipped('sqlite native lib unavailable in this environment');
      return;
    }
    final db = s3.sqlite3.openInMemory();
    try {
      db.execute(_recordingsDdl);

      int insertOne(int startUtc) {
        db.execute(
          'INSERT INTO recordings '
          '(channel_id, channel_name, url, scheduled_start_utc, duration_ms, '
          ' pad_before_min, pad_after_min, status, output_path, error, created_utc) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          [1, 'ch', 'http://x/y', startUtc, 120000, 1, 1, 'scheduled', null, null, 0],
        );
        // Same connection — this is the invariant insertRecording must hold.
        final r = db.select('SELECT last_insert_rowid()');
        return r.first.columnAt(0) as int;
      }

      final id1 = insertOne(1000);
      final id2 = insertOne(2000);

      expect(id1, isNonZero, reason: 'rowid must not be 0 (the device bug)');
      expect(id2, isNonZero);
      expect(id2, greaterThan(id1), reason: 'AUTOINCREMENT ids increase');

      // The row is actually findable by the returned id (the callback's lookup).
      final found = db.select('SELECT id FROM recordings WHERE id = ?', [id1]);
      expect(found, isNotEmpty,
          reason: 'getRecordingById(returnedId) must find the row');
    } finally {
      db.dispose();
    }
  });
}
