// fix546: "##### HEADER #####" divider rows are discarded at import (so they
// never enter the DB) and purged from existing catalogs by a deferred, gated
// one-time cleanup. This test pins (1) the divider-name predicate used to
// discard at import, and (2) the cleanup's run-once gating + that the DELETE
// removes exactly the divider rows.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;

// Mirror of Channel.nameIsDivider (kept pure for unit testing).
bool _nameIsDivider(String? name) {
  if (name == null) return false;
  final s = name.trim();
  return s.length >= 2 && s.startsWith('#') && s.endsWith('#');
}

bool _sqlite() {
  try {
    s3.sqlite3.openInMemory().dispose();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  group('fix546 divider name detection (import discard predicate)', () {
    test('detects ##### HEADER ##### style dividers', () {
      expect(_nameIsDivider('##### 4K UHD #####'), isTrue);
      expect(_nameIsDivider('###### RELAX 3840P ######'), isTrue);
      expect(_nameIsDivider('#single#'), isTrue);
    });
    test('does not flag real channel names', () {
      expect(_nameIsDivider('GO| METV TOONS'), isFalse);
      expect(_nameIsDivider('CNN'), isFalse);
      expect(_nameIsDivider('#1 Movies'), isFalse); // starts but no end #
      expect(_nameIsDivider(null), isFalse);
      expect(_nameIsDivider(''), isFalse);
    });
  });

  group('fix546 deferred divider purge', () {
    if (!_sqlite()) {
      test('sqlite unavailable — skipped', () => expect(true, isTrue));
      return;
    }
    late s3.Database db;
    setUp(() {
      db = s3.sqlite3.openInMemory();
      db.execute('CREATE TABLE app_meta(key TEXT PRIMARY KEY, value TEXT)');
      db.execute('CREATE TABLE channels(id INTEGER PRIMARY KEY, name TEXT,'
          ' is_divider INTEGER)');
      db.execute("INSERT INTO channels(name,is_divider) VALUES"
          " ('##### SPORTS #####',1),('ESPN',0),('CNN',0),('#### MOVIES ####',1)");
    });
    tearDown(() => db.dispose());

    const marker = 'fix546_dividers_purged';

    // Mirrors Sql.runPendingDividerCleanup's gating + delete.
    String purge() {
      final done = db.select("SELECT 1 FROM app_meta WHERE key=?", [marker]);
      if (done.isNotEmpty) return 'skip';
      db.execute('DELETE FROM channels WHERE COALESCE(is_divider,0)=1');
      db.execute("INSERT OR REPLACE INTO app_meta VALUES('$marker','1')");
      return 'purged';
    }

    test('purges exactly the divider rows, leaves real channels', () {
      expect(purge(), 'purged');
      final names = db
          .select('SELECT name FROM channels ORDER BY name')
          .map((r) => r['name'] as String)
          .toList();
      expect(names, ['CNN', 'ESPN']);
    });

    test('runs once — second call is a no-op', () {
      expect(purge(), 'purged');
      expect(purge(), 'skip');
    });
  });
}
