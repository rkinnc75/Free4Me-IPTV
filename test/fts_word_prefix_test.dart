// fix519: channel search moved from a trigram channels_fts (every 3-char gram
// indexed → ~200s+ global 'rebuild' per large-source refresh) to a unicode61
// WORD-PREFIX index (migration 35). Search now matches word/start-of-name
// ("fox" → "FOX Sports", "espn" → "ESPN HD", "sport" → the word "Sports"),
// which is all channel search needs (owner decision), and the index is cheap
// to maintain incrementally — no giant rebuild.
//
// This pins (a) the fix519 MATCH builder from Sql.search (quoted phrase +
// trailing prefix star, 2-char floor, all-terms-<2 short-skip), and (b) the
// migration-35 DDL (trigram → unicode61 recreate + repopulate + triggers),
// against a real in-memory sqlite3 FTS5 table.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

/// Mirrors the fix519 MATCH builder in lib/backend/sql.dart Sql.search.
/// Returns null when every term is < 2 chars (the short-skip early return).
String? matchExpr(String rawQuery, {bool keywords = true}) {
  final terms = keywords
      ? rawQuery.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList()
      : [rawQuery.trim()];
  final longTerms = terms.where((t) => t.length >= 2).toList();
  if (longTerms.isEmpty) return null;
  return longTerms.map((t) => '"${t.replaceAll('"', '""')}"*').join(' AND ');
}

s3.Database _ftsDb() {
  final db = s3.sqlite3.openInMemory();
  db.execute('CREATE TABLE channels '
      '(id INTEGER PRIMARY KEY, name TEXT, source_id INTEGER)');
  db.execute("CREATE VIRTUAL TABLE channels_fts USING fts5(name, "
      "content='channels', content_rowid='id', tokenize='unicode61', "
      "prefix='2 3')");
  // The migration-35 sync triggers.
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

List<int> _search(s3.Database db, String q, {bool keywords = true}) {
  final expr = matchExpr(q, keywords: keywords);
  if (expr == null) return [];
  return db
      .select('SELECT rowid FROM channels_fts WHERE channels_fts MATCH ? '
          'ORDER BY rowid', [expr])
      .map((r) => r['rowid'] as int)
      .toList();
}

void main() {
  group('fix519 word-prefix search', () {
    late s3.Database db;
    setUp(() {
      db = _ftsDb();
      db.execute("INSERT INTO channels(id,name,source_id) VALUES "
          "(1,'FOX Sports',1),(2,'FOX News',1),(3,'ESPN HD',1),"
          "(4,'CNN',1),(5,'BBC One',1)");
    });
    tearDown(() => db.dispose());

    test('matches by word / start-of-name', () {
      expect(_search(db, 'fox'), [1, 2], reason: 'fox -> FOX Sports, FOX News');
      expect(_search(db, 'espn'), [3]);
      expect(_search(db, 'sport'), [1],
          reason: 'prefix of the word "Sports" inside "FOX Sports"');
      expect(_search(db, 'hd'), [3], reason: 'second word of "ESPN HD"');
    });

    test('2-char queries are supported (prefix index)', () {
      expect(_search(db, 'fo'), [1, 2]);
      expect(_search(db, 'bb'), [5]);
    });

    test('multiple terms AND their word-prefixes', () {
      expect(_search(db, 'fox sport'), [1], reason: 'both words required');
      expect(_search(db, 'fox news'), [2]);
    });

    test('a 1-char query short-skips (no expr, no scan)', () {
      expect(matchExpr('a'), isNull);
      expect(_search(db, 'a'), isEmpty);
    });

    test('names with FTS operator chars are quoted safely (no syntax error)', () {
      db.execute("INSERT INTO channels(id,name,source_id) VALUES (6,'A + B: (HD)',1)");
      expect(() => _search(db, 'a + b'), returnsNormally);
      expect(() => _search(db, 'b:'), returnsNormally);
    });

    test('triggers keep the index live across insert/update/delete', () {
      db.execute("INSERT INTO channels(id,name,source_id) VALUES "
          "(9,'Discovery Channel',1)");
      expect(_search(db, 'discovery'), [9]);
      db.execute("UPDATE channels SET name='History Channel' WHERE id=9");
      expect(_search(db, 'discovery'), isEmpty, reason: 'old name removed');
      expect(_search(db, 'history'), [9], reason: 'new name indexed');
      db.execute("DELETE FROM channels WHERE id=9");
      expect(_search(db, 'history'), isEmpty);
    });
  });

  group('fix519 migration 35 (trigram -> unicode61)', () {
    test('drops + recreates FTS as word-prefix, repopulates, searchable', () {
      final db = s3.sqlite3.openInMemory();
      addTearDown(db.dispose);
      db.execute('CREATE TABLE channels '
          '(id INTEGER PRIMARY KEY, name TEXT, source_id INTEGER)');
      // Pre-migration state: trigram FTS + its insert trigger + data.
      db.execute("CREATE VIRTUAL TABLE channels_fts USING fts5(name, "
          "content='channels', content_rowid='id', tokenize='trigram')");
      db.execute('CREATE TRIGGER channels_ai AFTER INSERT ON channels BEGIN '
          'INSERT INTO channels_fts(rowid,name) VALUES(new.id,new.name); END;');
      db.execute("INSERT INTO channels(id,name,source_id) VALUES "
          "(1,'FOX Sports',1),(2,'ESPN HD',1)");

      // --- migration 35 DDL (mirrors db_factory.dart) ---
      db.execute('DROP TRIGGER IF EXISTS channels_ai;');
      db.execute('DROP TRIGGER IF EXISTS channels_au;');
      db.execute('DROP TRIGGER IF EXISTS channels_ad;');
      db.execute('DROP TABLE IF EXISTS channels_fts;');
      db.execute("CREATE VIRTUAL TABLE channels_fts USING fts5(name, "
          "content='channels', content_rowid='id', tokenize='unicode61', "
          "prefix='2 3')");
      db.execute('INSERT INTO channels_fts(rowid,name) '
          'SELECT id,name FROM channels');
      db.execute('CREATE TRIGGER channels_ai AFTER INSERT ON channels BEGIN '
          'INSERT INTO channels_fts(rowid,name) VALUES(new.id,new.name); END;');

      // Repopulated + word-prefix searchable.
      final res = db
          .select("SELECT rowid FROM channels_fts WHERE channels_fts MATCH ? "
              "ORDER BY rowid", ['"fox"*'])
          .map((r) => r['rowid'])
          .toList();
      expect(res, [1], reason: 'migrated index is populated + searchable');

      // The recreated table is unicode61 word-prefix.
      final ddl = db
          .select("SELECT sql FROM sqlite_master WHERE name='channels_fts'")
          .first['sql'] as String;
      expect(ddl, contains('unicode61'));
      expect(ddl.replaceAll('"', "'"), contains("prefix='2 3'"));
    });
  });
}
