// fix542: the heavy fix537 index maintenance moved OFF the cold-start path
// (it black-screened large-catalog devices for minutes during startup). It now
// runs once, deferred, gated by an app_meta marker — and is SKIPPED outright on
// devices that already completed the OLD blocking migration (legacy marker
// 'fix537_vacuum_done'). This test documents that gating contract against a
// real in-memory sqlite (the production method needs DbFactory, so the logic is
// mirrored here exactly).
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

const _marker = 'fix537_index_rebuild_done';
const _legacy = 'fix537_vacuum_done';

// Mirrors Sql.runPendingIndexMaintenance's gating: returns the action that
// would be taken given the current app_meta state.
String _decideAction(s3.Database db) {
  String? get(String k) {
    final r = db.select("SELECT value FROM app_meta WHERE key = ?", [k]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  if (get(_marker) != null) return 'skip-done';
  if (get(_legacy) != null) {
    db.execute(
      "INSERT OR REPLACE INTO app_meta(key,value) VALUES('$_marker','1')",
    );
    return 'skip-legacy';
  }
  return 'run';
}

void main() {
  if (!_has()) {
    test('sqlite3 unavailable — skipped', () => expect(true, isTrue));
    return;
  }
  late s3.Database db;
  setUp(() {
    db = s3.sqlite3.openInMemory();
    db.execute('CREATE TABLE app_meta(key TEXT PRIMARY KEY, value TEXT)');
  });
  tearDown(() => db.dispose());

  test('fresh DB → runs the maintenance', () {
    expect(_decideAction(db), 'run');
  });

  test('already-done marker → skips', () {
    db.execute("INSERT INTO app_meta VALUES('$_marker','1')");
    expect(_decideAction(db), 'skip-done');
  });

  test('legacy fix537 marker → skips and records new marker', () {
    db.execute("INSERT INTO app_meta VALUES('$_legacy','1')");
    expect(_decideAction(db), 'skip-legacy');
    // The new marker is now set, so a second pass short-circuits as done.
    expect(_decideAction(db), 'skip-done');
  });

  test('idempotent: once done, never runs again', () {
    expect(_decideAction(db), 'run'); // first call would run
    db.execute("INSERT OR REPLACE INTO app_meta VALUES('$_marker','1')");
    expect(_decideAction(db), 'skip-done');
    expect(_decideAction(db), 'skip-done');
  });
}
