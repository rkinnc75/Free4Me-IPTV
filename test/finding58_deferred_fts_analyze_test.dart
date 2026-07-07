// finding 58: the two heaviest cold-start full-scans — migration 35's
// channels_fts backfill (fix519) and migration 38's `ANALYZE` (fix530) — used
// to run INSIDE the awaited migration chain, blocking first frame and risking
// an ANR on an upgrade over a populated Shield-scale catalog. They moved to
// Sql.runPendingFtsAndAnalyze(), run unawaited after first frame.
//
// The production method needs DbFactory, so its gating + SQL are mirrored here
// exactly against a real in-memory sqlite3 (FTS5). This also statically pins
// that the migrations no longer carry the heavy statements.
import 'dart:io';

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

const _analyzeMarker = 'mig38_analyze_done';

// Post-migration-35 upgrade shape: channels holds rows, channels_fts exists but
// is EMPTY (mig35 recreated it empty), triggers exist but did not fire for the
// pre-existing rows. NO triggers here so a direct insert leaves fts empty,
// exactly like an upgrader before the deferred backfill runs.
s3.Database _upgradeShapeDb({required bool withChannels}) {
  final db = s3.sqlite3.openInMemory();
  db.execute('CREATE TABLE app_meta(key TEXT PRIMARY KEY, value TEXT)');
  db.execute('CREATE TABLE channels '
      '(id INTEGER PRIMARY KEY, name TEXT, source_id INTEGER)');
  db.execute("CREATE VIRTUAL TABLE channels_fts USING fts5(name, "
      "content='channels', content_rowid='id', tokenize='unicode61', "
      "prefix='2 3')");
  if (withChannels) {
    db.execute("INSERT INTO channels(id,name,source_id) VALUES"
        "(1,'FOX Sports',1),(2,'ESPN HD',1),(3,'CNN',1)");
  }
  return db;
}

// Mirrors Sql.runPendingFtsAndAnalyze's gating + SQL. Returns the actions taken.
String _runDeferred(s3.Database db) {
  final actions = <String>[];
  final hasChannels = db.select('SELECT 1 FROM channels LIMIT 1').isNotEmpty;
  if (!hasChannels) return 'skip-empty';

  // External-content fts5: probe the _docsize shadow table (indexed docs), not
  // the virtual table itself (which reads the content table).
  final ftsEmpty =
      db.select('SELECT rowid FROM channels_fts_docsize LIMIT 1').isEmpty;
  if (ftsEmpty) {
    db.execute("INSERT INTO channels_fts(channels_fts) VALUES('rebuild')");
    actions.add('fts-rebuild');
  }

  final analyzed = db
      .select("SELECT value FROM app_meta WHERE key = ?", [_analyzeMarker])
      .isNotEmpty;
  if (!analyzed) {
    db.execute('ANALYZE');
    db.execute("INSERT OR REPLACE INTO app_meta(key,value) VALUES(?, '1')",
        [_analyzeMarker]);
    actions.add('analyze');
  }
  return actions.isEmpty ? 'noop' : actions.join('+');
}

List<int> _search(s3.Database db, String term) => db
    .select('SELECT rowid FROM channels_fts WHERE channels_fts MATCH ? '
        'ORDER BY rowid', ['"$term"*'])
    .map((r) => r['rowid'] as int)
    .toList();

void main() {
  group('finding58 static migration guards', () {
    final src = File('lib/backend/db_factory.dart').readAsStringSync();

    test('migration 35 no longer carries the channels_fts backfill INSERT', () {
      // The deferred backfill uses the fts5 `rebuild` command; the migration
      // must not full-scan channels with the old row-by-row backfill.
      final mig35 = src.substring(
          src.indexOf('SqliteMigration(35'), src.indexOf('SqliteMigration(36'));
      expect(mig35.contains('SELECT id, name FROM channels'), isFalse,
          reason: 'mig35 backfill INSERT should be deferred, not inline');
    });

    test('migration 38 no longer runs ANALYZE inline', () {
      final mig38 = src.substring(
          src.indexOf('SqliteMigration(38'), src.indexOf('SqliteMigration(39'));
      // Match the executed statement, not the word "ANALYZE" in the comment.
      expect(mig38.contains("execute('ANALYZE"), isFalse,
          reason: 'mig38 ANALYZE should be deferred to runPendingFtsAndAnalyze');
    });
  });

  if (!_has()) {
    test('sqlite3/fts5 unavailable — skipped', () => expect(true, isTrue));
    return;
  }

  group('finding58 deferred backfill + ANALYZE gating', () {
    test('fresh install (channels empty) → no-op, nothing marked', () {
      final db = _upgradeShapeDb(withChannels: false);
      addTearDown(db.dispose);
      expect(_runDeferred(db), 'skip-empty');
      // fts stays empty, ANALYZE marker not set → both retry once a source loads
      expect(db.select('SELECT rowid FROM channels_fts LIMIT 1'), isEmpty);
      expect(
          db.select("SELECT 1 FROM app_meta WHERE key = ?", [_analyzeMarker]),
          isEmpty);
    });

    test('upgrade (populated, empty fts) → rebuilds fts and analyzes once', () {
      final db = _upgradeShapeDb(withChannels: true);
      addTearDown(db.dispose);
      // Search is blank before the backfill (the upgrade regression window).
      expect(_search(db, 'fox'), isEmpty);

      expect(_runDeferred(db), 'fts-rebuild+analyze');

      // Backfill repopulated the index from the content table.
      expect(_search(db, 'fox'), [1]);
      expect(_search(db, 'espn'), [2]);
      // ANALYZE ran + marker recorded.
      expect(
          db.select("SELECT value FROM app_meta WHERE key = ?",
              [_analyzeMarker]).single['value'],
          '1');
    });

    test('idempotent: second pass is a no-op', () {
      final db = _upgradeShapeDb(withChannels: true);
      addTearDown(db.dispose);
      expect(_runDeferred(db), 'fts-rebuild+analyze');
      expect(_runDeferred(db), 'noop');
    });

    test('populated fts + no marker → ANALYZE only (fts untouched)', () {
      final db = _upgradeShapeDb(withChannels: true);
      addTearDown(db.dispose);
      // Simulate fts already populated (e.g. a refresh rebuilt it) but ANALYZE
      // not yet run.
      db.execute("INSERT INTO channels_fts(channels_fts) VALUES('rebuild')");
      expect(_runDeferred(db), 'analyze');
    });
  });
}
