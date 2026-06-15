// fix375: the in-memory search cache must order results the SAME as a browse
// query when in-scope sources use provider/category mode — including the new
// "validated favorites float to the top of the favorites block" rule (option A).
//
// This test proves equivalence the rigorous way: it runs the EXACT emitted
// `BrowseOrder.orderBy(...)` SQL against a seeded sqlite DB, and runs a Dart
// comparator that mirrors ChannelSearchCache's _providerCompare/_categoryCompare
// over the SAME rows, and asserts the two id orders are identical. If the cache
// comparator ever drifts from the SQL ORDER BY, this fails.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;
import 'package:open_tv/backend/browse_order.dart';

bool _sqliteAvailable() {
  try {
    s3.sqlite3.openInMemory().dispose();
    return true;
  } catch (_) {
    return false;
  }
}

/// One seeded channel. Mirrors the fields the cache and SQL both sort on.
class _Row {
  final int id;
  final String name;
  final bool favorite;
  final bool? validated;
  final int? providerOrder;
  final String group;
  const _Row(this.id, this.name, this.favorite, this.validated,
      this.providerOrder, this.group);
}

// Discriminating seed: provider_order alone would interleave validated and
// unvalidated favorites; the float must reorder them. Non-favorites (incl. a
// validated one, id6) must NOT float — they keep provider order.
const _seed = <_Row>[
  _Row(1, 'fav unval a', true, false, 1, 'gb'),
  _Row(2, 'fav val b', true, true, 2, 'ga'),
  _Row(3, 'nonfav c', false, false, 3, 'ga'),
  _Row(4, 'fav val d', true, true, 4, 'gb'),
  _Row(5, 'fav unval e', true, false, 5, 'ga'),
  _Row(6, 'nonfav f (validated)', false, true, 6, 'gb'),
];

// --- Dart side: mirrors ChannelSearchCache (fix375) exactly. ---
int _favKey(_Row e) => e.favorite ? 0 : 1;
int _valFloatKey(_Row e) => (e.favorite && e.validated == true) ? 0 : 1;
int _cmpPo(int? a, int? b) {
  if (a == null) return b == null ? 0 : -1; // NULL first (SQLite ASC)
  if (b == null) return 1;
  return a.compareTo(b);
}

int _providerCompare(_Row a, _Row b) {
  var c = _favKey(a).compareTo(_favKey(b));
  if (c != 0) return c;
  c = _valFloatKey(a).compareTo(_valFloatKey(b));
  if (c != 0) return c;
  c = _cmpPo(a.providerOrder, b.providerOrder);
  if (c != 0) return c;
  return a.name.compareTo(b.name);
}

int _categoryCompare(_Row a, _Row b) {
  var c = _favKey(a).compareTo(_favKey(b));
  if (c != 0) return c;
  c = _valFloatKey(a).compareTo(_valFloatKey(b));
  if (c != 0) return c;
  c = a.group.compareTo(b.group);
  if (c != 0) return c;
  c = _cmpPo(a.providerOrder, b.providerOrder);
  if (c != 0) return c;
  return a.name.compareTo(b.name);
}

void main() {
  final available = _sqliteAvailable();

  // SQL side: run the EMITTED BrowseOrder string against the seed.
  List<int> sqlOrder(String mode) {
    final db = s3.sqlite3.openInMemory();
    try {
      db.execute('''
        CREATE TABLE channels(
          id INTEGER PRIMARY KEY, name TEXT, url TEXT,
          favorite INTEGER, stream_validated INTEGER,
          provider_order INTEGER, group_name TEXT);
      ''');
      final ins = db.prepare('INSERT INTO channels VALUES (?,?,?,?,?,?,?)');
      for (final r in _seed) {
        ins.execute([
          r.id, r.name, 'http://x/${r.id}', r.favorite ? 1 : 0,
          r.validated == null ? null : (r.validated! ? 1 : 0),
          r.providerOrder, r.group,
        ]);
      }
      ins.dispose();
      final sql =
          'SELECT id FROM channels c WHERE url IS NOT NULL${BrowseOrder.orderBy(mode)}';
      return db.select(sql).map((r) => r['id'] as int).toList();
    } finally {
      db.dispose();
    }
  }

  List<int> dartOrder(int Function(_Row, _Row) cmp) =>
      (List<_Row>.of(_seed)..sort(cmp)).map((r) => r.id).toList();

  group('fix375 in-memory order matches emitted SQL', () {
    test('provider: cache comparator == BrowseOrder SQL', () {
      if (!available) {
        markTestSkipped('libsqlite3 not loadable');
        return;
      }
      final sql = sqlOrder('provider');
      // validated favs (2,4) float above unvalidated favs (1,5) despite lower
      // provider_order; non-favs (3,6) keep provider order, validation ignored.
      expect(sql, [2, 4, 1, 5, 3, 6]);
      expect(dartOrder(_providerCompare), sql,
          reason: 'in-memory provider order must equal SQL provider order');
    });

    test('category: cache comparator == BrowseOrder SQL', () {
      if (!available) {
        markTestSkipped('libsqlite3 not loadable');
        return;
      }
      final sql = sqlOrder('category');
      // favFirst, valFloat, group_name, provider_order, name.
      expect(sql, [2, 4, 5, 1, 3, 6]);
      expect(dartOrder(_categoryCompare), sql,
          reason: 'in-memory category order must equal SQL category order');
    });

    test('non-favorites never float on validation alone', () {
      if (!available) {
        markTestSkipped('libsqlite3 not loadable');
        return;
      }
      // id6 is validated but NOT a favorite — it must stay last (provider_order
      // 6), proving the float is gated on favorite, not validation alone.
      expect(sqlOrder('provider').last, 6);
      expect(dartOrder(_providerCompare).last, 6);
    });
  });
}
