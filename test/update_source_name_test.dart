// fix387: Sql.updateSource silently dropped the name. fix385 made the Edit
// Source dialog's name field editable and the dialog passes the new name into
// Sql.updateSource, but the UPDATE's SET clause omitted `name = ?`, so renames
// were never persisted (every other editable field WAS persisted).
//
// Rule-8 test: it executes the EXACT statement the app runs — the canonical
// `Sql.updateSourceSql` const that Sql.updateSource binds against — with the
// same bind order, against a seeded sqlite DB, and asserts the rename lands.
// Because it runs the real const, a future regression that removes a SET
// column changes the placeholder count (→ sqlite bind error) or the value
// (→ assertion failure), so the test fails instead of silently passing.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;
import 'package:open_tv/backend/sql.dart';

bool _sqliteAvailable() {
  try {
    s3.sqlite3.openInMemory().dispose();
    return true;
  } catch (_) {
    return false;
  }
}

s3.Database _seed() {
  final db = s3.sqlite3.openInMemory();
  // Column order matches the production sources table for the columns the
  // UPDATE touches; positional INSERT below sets them.
  db.execute('''
    CREATE TABLE sources(
      id INTEGER PRIMARY KEY,
      name TEXT,
      url TEXT,
      username TEXT,
      password TEXT,
      max_connections INTEGER,
      color INTEGER,
      sort_mode TEXT,
      last_live_count INTEGER,
      last_movie_count INTEGER,
      last_series_count INTEGER,
      hide_dividers INTEGER
    )''');
  // Target row (id 7) + a sibling control (id 8) that must stay untouched.
  db.execute(
    "INSERT INTO sources VALUES (7,'Old Name','http://old','u','p',1,0,'provider',10,20,30,0)",
  );
  db.execute(
    "INSERT INTO sources VALUES (8,'Sibling','http://sib','u2','p2',1,0,'category',1,2,3,1)",
  );
  return db;
}

// Same bind order as Sql.updateSource.
List<Object?> _binds({
  required String name,
  required String url,
  required int color,
  required int id,
}) =>
    [name, url, 'u', 'p', 1, color, 'provider', 10, 20, 30, 0, id];

void main() {
  group('Sql.updateSource persists the name (fix387)', () {
    test('renaming source 7 writes name/url/color and leaves sibling 8 alone',
        () {
      if (!_sqliteAvailable()) {
        markTestSkipped('sqlite native lib unavailable');
        return;
      }
      final db = _seed();
      try {
        db.execute(
          Sql.updateSourceSql,
          _binds(name: 'New Name', url: 'http://new', color: 5, id: 7),
        );

        final row7 =
            db.select('SELECT name,url,color FROM sources WHERE id=7').first;
        expect(row7['name'], 'New Name'); // the bug: stayed 'Old Name'
        expect(row7['url'], 'http://new');
        expect(row7['color'], 5);

        final row8 = db.select('SELECT name FROM sources WHERE id=8').first;
        expect(row8['name'], 'Sibling'); // id-targeted: control untouched
      } finally {
        db.dispose();
      }
    });

    test('canonical statement includes the name column', () {
      expect(Sql.updateSourceSql.contains('name = ?'), isTrue);
    });
  });
}
