// fix521: the FTS rebuild is deferred to ONCE per refresh batch, not once per
// source. refreshAllSources now wraps the whole loop in an OUTER
// withSuspendedFtsTriggers (no refreshedSourceId); the per-source wraps in
// xtream.dart hit the `_ftsTriggersSuspended` early-return and become
// pass-throughs, so the triggers stay dropped across every source and a single
// global rebuild at the end of the batch reindexes everything — including M3U
// sources, which never wrap FTS on their own.
//
// The real Sql.withSuspendedFtsTriggers needs the full sqlite_async + Flutter
// stack, so (like fts_word_prefix_test) this faithfully MIRRORS its branching
// against a real in-memory sqlite3 FTS5 table and pins the invariants:
//   - inside a batch, inner per-source wraps pass through (triggers stay down,
//     no per-source rebuild);
//   - exactly ONE global rebuild fires at the end of the batch, regardless of
//     source count, and it covers every source (incl. an M3U-style body with
//     no wrap of its own);
//   - a standalone single-source refresh still takes the per-source path
//     (targeted re-index, no global rebuild, other sources untouched);
//   - the re-entrancy flag is cleared after the batch.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

/// Faithful mirror of Sql.withSuspendedFtsTriggers (lib/backend/sql.dart) +
/// the `_ftsTriggersSuspended` re-entrancy guard added in fix521.
class FtsHarness {
  FtsHarness(this.db);
  final s3.Database db;

  /// Mirrors Sql._ftsTriggersSuspended.
  bool suspended = false;

  /// Observability: how many global rebuilds / targeted re-indexes ran.
  int globalRebuilds = 0;
  int targetedReindexes = 0;

  bool get triggersPresent =>
      db.select("SELECT name FROM sqlite_master WHERE type='trigger' "
          "AND name IN ('channels_ai','channels_au','channels_ad')").length == 3;

  Future<void> withSuspend(Future<void> Function() body,
      {int? refreshedSourceId}) async {
    final hadTriggers = triggersPresent;
    // fix521 early-return: an outer batch already suspended the triggers.
    if (suspended) {
      await body();
      return;
    }
    var useTargeted = false;
    if (hadTriggers) {
      _dropTriggers();
      suspended = true; // fix521
      if (refreshedSourceId != null) {
        // (the small-source gate from the real code is the caller's choice in
        // these tests — eligibility is decided by passing refreshedSourceId).
        final ids = db
            .select('SELECT id FROM channels WHERE source_id = ?',
                [refreshedSourceId])
            .map((r) => r['id'] as int)
            .toList();
        for (final id in ids) {
          db.execute('DELETE FROM channels_fts WHERE rowid = ?', [id]);
        }
        useTargeted = true;
      }
    }
    var ok = false;
    try {
      await body();
      ok = true;
    } finally {
      if (hadTriggers) {
        suspended = false; // fix521: clear before recreating
        if (useTargeted && ok) {
          db.execute('INSERT INTO channels_fts(rowid,name) '
              'SELECT id,name FROM channels WHERE source_id = ?',
              [refreshedSourceId]);
          _recreateTriggers();
          targetedReindexes++;
        } else {
          // external-content FTS5 rebuild: resyncs the whole index from the
          // content table (`channels`), so every source is reindexed.
          db.execute("INSERT INTO channels_fts(channels_fts) VALUES('rebuild')");
          _recreateTriggers();
          globalRebuilds++;
        }
      }
    }
  }

  void _dropTriggers() {
    db.execute('DROP TRIGGER IF EXISTS channels_ai;');
    db.execute('DROP TRIGGER IF EXISTS channels_au;');
    db.execute('DROP TRIGGER IF EXISTS channels_ad;');
  }

  void _recreateTriggers() {
    db.execute('CREATE TRIGGER channels_ai AFTER INSERT ON channels BEGIN '
        'INSERT INTO channels_fts(rowid,name) VALUES(new.id,new.name); END;');
    db.execute('CREATE TRIGGER channels_ad AFTER DELETE ON channels BEGIN '
        "INSERT INTO channels_fts(channels_fts,rowid,name) "
        "VALUES('delete',old.id,old.name); END;");
    db.execute('CREATE TRIGGER channels_au AFTER UPDATE OF name ON channels '
        "BEGIN INSERT INTO channels_fts(channels_fts,rowid,name) "
        "VALUES('delete',old.id,old.name); "
        'INSERT INTO channels_fts(rowid,name) VALUES(new.id,new.name); END;');
  }
}

s3.Database _freshDb() {
  final db = s3.sqlite3.openInMemory();
  db.execute('CREATE TABLE channels '
      '(id INTEGER PRIMARY KEY, name TEXT, source_id INTEGER)');
  db.execute("CREATE VIRTUAL TABLE channels_fts USING fts5(name, "
      "content='channels', content_rowid='id', tokenize='unicode61', "
      "prefix='2 3')");
  // Triggers present at rest, as after migration 35.
  db.execute('CREATE TRIGGER channels_ai AFTER INSERT ON channels BEGIN '
      'INSERT INTO channels_fts(rowid,name) VALUES(new.id,new.name); END;');
  db.execute('CREATE TRIGGER channels_ad AFTER DELETE ON channels BEGIN '
      "INSERT INTO channels_fts(channels_fts,rowid,name) "
      "VALUES('delete',old.id,old.name); END;");
  db.execute('CREATE TRIGGER channels_au AFTER UPDATE OF name ON channels BEGIN '
      "INSERT INTO channels_fts(channels_fts,rowid,name) "
      "VALUES('delete',old.id,old.name); "
      'INSERT INTO channels_fts(rowid,name) VALUES(new.id,new.name); END;');
  return db;
}

List<int> _search(s3.Database db, String word) => db
    .select('SELECT rowid FROM channels_fts WHERE channels_fts MATCH ? '
        'ORDER BY rowid', ['"$word"*'])
    .map((r) => r['rowid'] as int)
    .toList();

/// Mimics a source refresh body: wipe this source's rows, reinsert new ones.
/// With triggers suspended (inside a batch) these channel writes do NOT touch
/// channels_fts — exactly the deferral fix521 relies on.
void _refreshBody(s3.Database db, int sourceId, List<(int, String)> rows) {
  db.execute('DELETE FROM channels WHERE source_id = ?', [sourceId]);
  for (final (id, name) in rows) {
    db.execute('INSERT INTO channels(id,name,source_id) VALUES(?,?,?)',
        [id, name, sourceId]);
  }
}

void main() {
  group('fix521 deferred batch rebuild', () {
    late s3.Database db;
    late FtsHarness h;
    setUp(() {
      db = _freshDb();
      h = FtsHarness(db);
      // Pre-batch catalog (3 sources) with OLD names, indexed via triggers.
      _refreshBody(db, 1, [(1, 'Old Alpha')]);
      _refreshBody(db, 2, [(2, 'Old Bravo')]);
      _refreshBody(db, 3, [(3, 'Old Charlie')]);
    });
    tearDown(() => db.dispose());

    test('batch = exactly ONE global rebuild, regardless of source count', () async {
      // refreshAllSources: OUTER suspend (no refreshedSourceId) wrapping a loop
      // whose per-source bodies each call withSuspend (xtream-style).
      await h.withSuspend(() async {
        for (final s in [1, 2, 3]) {
          await h.withSuspend(() async {
            _refreshBody(db, s, [(s * 10, 'New Source$s')]);
          }, refreshedSourceId: s);
        }
      });

      expect(h.globalRebuilds, 1, reason: 'one rebuild for the whole batch');
      expect(h.targetedReindexes, 0,
          reason: 'inner per-source wraps passed through — no per-source work');
    });

    test('inside the batch, triggers stay dropped (deferral is real)', () async {
      var triggersMidLoop = true;
      var ftsStaleMidLoop = false;
      await h.withSuspend(() async {
        for (final s in [1, 2, 3]) {
          await h.withSuspend(() async {
            _refreshBody(db, s, [(s * 10, 'New Source$s')]);
          }, refreshedSourceId: s);
          if (s == 2) {
            // Halfway through: triggers must NOT have been recreated, and the
            // FTS index must still reflect OLD content (not yet rebuilt).
            triggersMidLoop = h.triggersPresent;
            ftsStaleMidLoop = _search(db, 'old').isNotEmpty &&
                _search(db, 'new').isEmpty;
          }
        }
      });
      expect(triggersMidLoop, isFalse,
          reason: 'no per-source trigger recreate inside the batch');
      expect(ftsStaleMidLoop, isTrue,
          reason: 'FTS not maintained mid-batch — rebuilt only at the end');
    });

    test('end-of-batch rebuild reindexes EVERY source correctly', () async {
      await h.withSuspend(() async {
        for (final s in [1, 2, 3]) {
          await h.withSuspend(() async {
            _refreshBody(db, s, [(s * 10, 'New Source$s')]);
          }, refreshedSourceId: s);
        }
      });
      // Old names gone, new names searchable across all 3 sources.
      expect(_search(db, 'old'), isEmpty);
      expect(_search(db, 'source1'), [10]);
      expect(_search(db, 'source2'), [20]);
      expect(_search(db, 'source3'), [30]);
      expect(h.triggersPresent, isTrue, reason: 'triggers restored at the end');
    });

    test('an M3U-style source (no withSuspend wrap) is still covered', () async {
      // Source 2 stands in for M3U: its refresh body does NOT wrap FTS — it
      // relies entirely on the outer batch rebuild.
      await h.withSuspend(() async {
        await h.withSuspend(() async {
          _refreshBody(db, 1, [(11, 'Xtream One')]);
        }, refreshedSourceId: 1);
        // M3U body — bare, no inner withSuspend:
        _refreshBody(db, 2, [(22, 'M3U Two')]);
        await h.withSuspend(() async {
          _refreshBody(db, 3, [(33, 'Xtream Three')]);
        }, refreshedSourceId: 3);
      });
      expect(h.globalRebuilds, 1);
      expect(_search(db, 'm3u'), [22],
          reason: 'M3U rows indexed by the end-of-batch rebuild');
      expect(_search(db, 'xtream'), [11, 33]);
    });

    test('re-entrancy flag is cleared after the batch', () async {
      await h.withSuspend(() async {
        await h.withSuspend(() async {
          _refreshBody(db, 1, [(10, 'New Source1')]);
        }, refreshedSourceId: 1);
      });
      expect(h.suspended, isFalse, reason: 'flag cleared in finally');
    });
  });

  group('fix521 single-source refresh (no batch) unchanged', () {
    late s3.Database db;
    late FtsHarness h;
    setUp(() {
      db = _freshDb();
      h = FtsHarness(db);
      _refreshBody(db, 1, [(1, 'Keep Alpha')]);
      _refreshBody(db, 2, [(2, 'Old Bravo')]);
    });
    tearDown(() => db.dispose());

    test('targeted re-index for the one source, no global rebuild', () async {
      // Standalone per-source refresh (settings_view per-source button): no
      // outer suspend, so this takes the normal targeted path.
      await h.withSuspend(() async {
        _refreshBody(db, 2, [(20, 'New Bravo')]);
      }, refreshedSourceId: 2);

      expect(h.targetedReindexes, 1);
      expect(h.globalRebuilds, 0, reason: 'no batch → no global rebuild');
      // Refreshed source updated, the other source left intact.
      expect(_search(db, 'new'), [20]);
      expect(_search(db, 'old'), isEmpty);
      expect(_search(db, 'keep'), [1], reason: 'untouched source still indexed');
      expect(h.triggersPresent, isTrue);
    });
  });
}
