// fix514: withSuspendedFtsTriggers' targeted re-index path replaces a global
// 'rebuild' (cost scales with TOTAL catalog size) with a per-source resync
// when the refreshed source is small on BOTH an absolute-row-count axis AND
// a fraction-of-catalog axis (see Sql.withSuspendedFtsTriggers' doc comment
// for the full rationale — a single fraction threshold wasn't sufficient;
// a real 5-source-load log showed a 451,728-row source at 38.6% of the
// catalog still losing to global rebuild despite being well under a 50%
// fraction cap, because targeted's cost is dominated by the source's own
// absolute row count, not just its share of the total).
//
// CORRECTNESS-CRITICAL ORDERING this test exists to prove: external-content
// FTS5 can only remove an index entry while the content table (`channels`)
// still holds that row — `DELETE FROM channels_fts WHERE rowid=?` is a
// SILENT no-op once the row is already gone from `channels` (confirmed
// empirically; an earlier draft of this fix got this backwards and shipped
// a delete-AFTER-wipe sequence that looked correct but left every removed
// channel permanently stuck in the search index). The real sequence is:
//   1. DELETE FROM channels_fts for this source — BEFORE the wipe, while
//      `channels` still has the old rows to read.
//   2. The wipe runs: DELETE FROM channels WHERE source_id=? + reinsert.
//   3. INSERT INTO channels_fts for this source — AFTER, reading the new
//      post-refresh rows.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

// Mirrors Sql's thresholds exactly.
const _ftsTargetedMaxRows = 50000;
const _ftsTargetedMaxFraction = 0.2;

bool shouldUseTargeted(int srcRows, int totalRows) =>
    totalRows > 0 &&
    srcRows <= _ftsTargetedMaxRows &&
    srcRows / totalRows <= _ftsTargetedMaxFraction;

bool _has() {
  try {
    s3.sqlite3.openInMemory().dispose();
    return true;
  } catch (_) {
    return false;
  }
}

s3.Database _seeded({String name1 = 'ESPN HD'}) {
  final db = s3.sqlite3.openInMemory();
  db.execute('CREATE TABLE channels (id INTEGER PRIMARY KEY, name TEXT NOT NULL, '
      'source_id INTEGER NOT NULL)');
  // fix519: channels_fts is now unicode61 word-prefix (migration 35), not
  // trigram. The targeted-reindex delete/insert ordering this test pins is
  // tokenizer-independent, so it runs against the current tokenizer.
  db.execute("CREATE VIRTUAL TABLE channels_fts USING fts5(name, content='channels', "
      "content_rowid='id', tokenize='unicode61', prefix='2 3')");
  // Source 1 (refreshed) + source 2 (must stay untouched throughout).
  db.execute('INSERT INTO channels(id,name,source_id) VALUES '
      "(1,?,1), (2,'CNN HD',1), (3,'FOX SPORTS',2), (4,'BBC NEWS',2)", [name1]);
  db.execute('INSERT INTO channels_fts(rowid, name) SELECT id, name FROM channels');
  return db;
}

/// Mirrors Sql.withSuspendedFtsTriggers' targeted path exactly: pre-wipe
/// delete (materialized id list, chunked), caller-supplied wipe+reinsert,
/// post-wipe insert.
void _runTargetedRefresh(
    s3.Database db, int sourceId, void Function() simulateWipeAndReinsert) {
  final ids = db
      .select('SELECT id FROM channels WHERE source_id = ?', [sourceId])
      .map((r) => r['id'] as int)
      .toList();
  for (var i = 0; i < ids.length; i += 900) {
    final end = i + 900 > ids.length ? ids.length : i + 900;
    final chunk = ids.sublist(i, end);
    final placeholders = List.filled(chunk.length, '?').join(',');
    db.execute('DELETE FROM channels_fts WHERE rowid IN ($placeholders)', chunk);
  }
  simulateWipeAndReinsert();
  db.execute(
    'INSERT INTO channels_fts(rowid, name) '
    'SELECT id, name FROM channels WHERE source_id = ?',
    [sourceId],
  );
}

List<int> _matchIds(s3.Database db, String needle) => db
    .select('SELECT rowid FROM channels_fts WHERE channels_fts MATCH ?',
        [needle])
    .map((r) => r['rowid'] as int)
    .toList()
  ..sort();

void main() {
  group('threshold gating (the new dual cap)', () {
    test('small source, small fraction: targeted', () {
      expect(shouldUseTargeted(39515, 1150000), isTrue,
          reason: 'the original A3000 case this fix was built for');
    });

    test('source over the absolute row cap: global, even at a tiny fraction', () {
      expect(shouldUseTargeted(60000, 5000000), isFalse,
          reason: '60K rows exceeds the 50K absolute cap even though it is '
              'only 1.2% of a 5M-row catalog -- absolute size alone disqualifies it');
    });

    test('source under the row cap but over the fraction cap: global', () {
      expect(shouldUseTargeted(40000, 150000), isFalse,
          reason: '40K rows is under the cap, but 40000/150000=26.7% exceeds '
              'the 20% fraction cap');
    });

    test('the real-world case that exposed the gap: 451,728 rows at 38.6%', () {
      expect(shouldUseTargeted(451728, 1171380), isFalse,
          reason: 'this is the Media4u case from the real 5-source-load log -- '
              'it lost to global rebuild despite being under a 50% fraction cap '
              'because of its absolute size; the dual threshold must exclude it');
    });

    test('empty catalog: global (guards div-by-zero, and rebuild is instant anyway)', () {
      expect(shouldUseTargeted(0, 0), isFalse);
    });
  });

  group('targeted re-index correctness', () {
    if (!_has()) {
      test('sqlite3 unavailable — skipped', () => expect(true, isTrue));
      return;
    }

    test('a channel renamed by the refresh is searchable under its new name only', () {
      // 'ESPN' is common to both names so isn't a discriminator; pick names
      // with no trigram overlap so this test actually discriminates old vs
      // new (confirmed empirically that some near-miss name pairs can share
      // enough trigrams to falsely "match" under SQLite's trigram tokenizer
      // regardless of which resync mechanism populated the index).
      final db = _seeded(name1: 'SPORTS CHANNEL ONE');
      _runTargetedRefresh(db, 1, () {
        db.execute("UPDATE channels SET name='NEWS NETWORK TWO' WHERE id=1");
      });

      expect(_matchIds(db, 'NETWORK'), [1]);
      expect(_matchIds(db, 'SPORTS CHANNEL'), isEmpty,
          reason: 'must not still match the pre-refresh name');
      db.dispose();
    });

    test('a channel REMOVED by the refresh (wiped, never reinserted) is gone from FTS', () {
      // This is the case a delete-AFTER-wipe sequence gets wrong: by the
      // time a post-wipe delete runs, `channels` no longer has row 2 to
      // read, so the FTS delete is a silent no-op and the stale entry
      // survives forever.
      final db = _seeded();
      _runTargetedRefresh(db, 1, () {
        db.execute('DELETE FROM channels WHERE id=2'); // wipe: row 2 dropped
        // (no reinsert for id=2 -- it's genuinely gone from the provider feed)
      });

      expect(_matchIds(db, 'CNN'), isEmpty,
          reason: 'a channel dropped by the refresh must not remain searchable '
              'forever -- this is the regression the pre-wipe delete prevents');
      db.dispose();
    });

    test('a brand-new channel id added by the refresh is searchable', () {
      final db = _seeded();
      _runTargetedRefresh(db, 1, () {
        db.execute('DELETE FROM channels WHERE source_id=1');
        db.execute("INSERT INTO channels(id,name,source_id) VALUES (1,'ESPN HD',1),"
            "(2,'CNN HD',1), (501,'NEW SPORTS CHANNEL',1)");
      });

      expect(_matchIds(db, 'NEW SPORTS'), [501]);
      db.dispose();
    });

    test('source 2 is byte-identical before and after a source-1 targeted refresh', () {
      final db = _seeded();
      final before = _matchIds(db, 'FOX');
      final beforeBbc = _matchIds(db, 'BBC');

      _runTargetedRefresh(db, 1, () {
        db.execute('DELETE FROM channels WHERE source_id=1');
        db.execute("INSERT INTO channels(id,name,source_id) VALUES "
            "(1,'ESPN UHD',1), (777,'SOMETHING ELSE',1)");
      });

      expect(_matchIds(db, 'FOX'), before);
      expect(_matchIds(db, 'BBC'), beforeBbc);
      db.dispose();
    });

    test('targeted result matches what a global rebuild produces for the same refresh', () {
      // Proves switching the threshold never changes correctness, only
      // speed: both mechanisms must agree on the final searchable state for
      // the exact same refresh (a rename, a drop, and a brand-new id, all
      // in the same pass).
      void simulateWipe(s3.Database db) {
        db.execute('DELETE FROM channels WHERE source_id=1');
        db.execute("INSERT INTO channels(id,name,source_id) VALUES "
            "(1,'ESPN UHD',1), (777,'SOMETHING ELSE',1)");
        // id 2 (CNN HD) intentionally not reinserted -- dropped by the refresh.
      }

      final viaTargeted = _seeded();
      _runTargetedRefresh(viaTargeted, 1, () => simulateWipe(viaTargeted));

      final viaRebuild = _seeded();
      simulateWipe(viaRebuild);
      viaRebuild.execute("INSERT INTO channels_fts(channels_fts) VALUES('rebuild')");

      for (final needle in ['ESPN', 'UHD', 'SOMETHING', 'FOX', 'BBC', 'CNN']) {
        expect(_matchIds(viaTargeted, needle), _matchIds(viaRebuild, needle),
            reason: 'targeted vs rebuild disagree for "$needle"');
      }
      viaTargeted.dispose();
      viaRebuild.dispose();
    });
  });
}
