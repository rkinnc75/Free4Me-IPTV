// fix382 (cold-eyes HIGH-1): the in-memory ChannelSearchCache applied the
// disabled-category exclusion UNCONDITIONALLY, while VisibilityClause (the SQL
// source of truth) applies it ONLY when groupId == null. So browsing INTO a
// disabled category and searching returned 0 rows on the default in-memory
// path, while the SQL FTS/LIKE/browse paths returned the category's channels
// (fix302: browsing into a category shows its channels regardless of the
// enabled checkbox).
//
// This test proves equivalence the rigorous way (same approach as
// in_memory_sort_mode_test): it runs the EXACT `VisibilityClause`-emitted
// predicate against a seeded sqlite DB for the (seriesId=null, groupId=<disabled
// cat>) case, runs a Dart mirror of ChannelSearchCache's per-entry filter over
// the SAME rows, and asserts the two id sets are identical. It also pins the
// regression: the OLD unconditional form returned 0 for that case.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as s3;
import 'package:open_tv/backend/visibility_clause.dart';

bool _sqliteAvailable() {
  try {
    s3.sqlite3.openInMemory().dispose();
    return true;
  } catch (_) {
    return false;
  }
}

/// One seeded channel. Mirrors the fields both the cache and the SQL filter on.
class _Row {
  final int id;
  final int mediaType;
  final int sourceId;
  final int? seriesId;
  final int? groupId;
  final bool isDivider;
  final bool catEnabled; // denormalized groups.enabled
  const _Row(this.id, this.mediaType, this.sourceId, this.seriesId,
      this.groupId, this.isDivider, this.catEnabled);
}

// Category 10 is DISABLED (catEnabled=false); category 20 is ENABLED.
const _seed = <_Row>[
  _Row(1, 2, 1, null, 10, false, false),
  _Row(2, 2, 1, null, 10, false, false),
  _Row(3, 2, 1, null, 10, false, false),
  _Row(4, 2, 1, null, 10, false, false),
  _Row(5, 2, 1, null, 10, false, false),
  _Row(6, 2, 1, null, 20, false, true),
  _Row(7, 2, 1, null, 20, false, true),
  _Row(8, 2, 1, null, 20, false, true),
];

// --- Dart side: mirrors ChannelSearchCache.search's per-entry filter loop. ---
// [disabledFixed] selects the fix382 behaviour (gate on groupId==null) vs the
// pre-fix382 unconditional behaviour.
List<int> _cacheFilter({
  required int? groupId,
  required Set<int> disabledGroupIds,
  required bool disabledFixed,
}) {
  const mediaTypes = {2};
  const sourceIds = {1};
  const int? seriesId = null;
  final out = <int>[];
  for (final e in _seed) {
    if (!mediaTypes.contains(e.mediaType)) continue;
    if (!sourceIds.contains(e.sourceId)) continue;
    if (seriesId != null && e.seriesId != seriesId) continue;
    if (seriesId == null && e.seriesId != null) continue;
    if (groupId != null && e.groupId != groupId) continue;
    if (e.isDivider) continue; // hideDividers irrelevant here (none are dividers)
    final hitDisabled = e.groupId != null && disabledGroupIds.contains(e.groupId);
    if (disabledFixed) {
      if (groupId == null && hitDisabled) continue; // fix382
    } else {
      if (hitDisabled) continue; // pre-fix382 (unconditional) — the bug
    }
    out.add(e.id);
  }
  return out;
}

s3.Database _seedDb() {
  final db = s3.sqlite3.openInMemory();
  db.execute('CREATE TABLE sources(id INTEGER PRIMARY KEY, hide_dividers INT DEFAULT 0)');
  db.execute('''CREATE TABLE channels(
    id INTEGER PRIMARY KEY, media_type INT, source_id INT, url TEXT,
    series_id INT, group_id INT, is_divider INT DEFAULT 0, cat_enabled INT DEFAULT 1)''');
  db.execute('INSERT INTO sources(id,hide_dividers) VALUES (1,0)');
  for (final r in _seed) {
    db.execute(
      'INSERT INTO channels(id,media_type,source_id,url,series_id,group_id,is_divider,cat_enabled) '
      'VALUES (?,?,?,?,?,?,?,?)',
      [r.id, r.mediaType, r.sourceId, 'http://x', r.seriesId, r.groupId,
       r.isDivider ? 1 : 0, r.catEnabled ? 1 : 0],
    );
  }
  return db;
}

// Run the REAL VisibilityClause-emitted predicate appended to the browse base.
List<int> _sqlIds(s3.Database db, {required int? seriesId, required int? groupId}) {
  final (visSql, visParams) =
      VisibilityClause.build(alias: 'c.', seriesId: seriesId, groupId: groupId);
  final sql =
      'SELECT c.id FROM channels c WHERE c.media_type = 2 AND c.source_id = 1 '
      'AND c.url IS NOT NULL$visSql ORDER BY c.id';
  return db.select(sql, visParams).map((r) => r['id'] as int).toList();
}

void main() {
  group('in-memory cache vs VisibilityClause: disabled category (fix382)', () {
    test('browsing INTO disabled category 10 — SQL shows its channels, '
        'fixed cache matches, old cache returned 0', () {
      if (!_sqliteAvailable()) {
        markTestSkipped('sqlite native lib unavailable');
        return;
      }
      final db = _seedDb();
      try {
        final sqlIds = _sqlIds(db, seriesId: null, groupId: 10);
        final fixedIds =
            _cacheFilter(groupId: 10, disabledGroupIds: {10}, disabledFixed: true);
        final oldIds =
            _cacheFilter(groupId: 10, disabledGroupIds: {10}, disabledFixed: false);

        // SQL path returns all 5 channels of the disabled category (groupId set
        // ⇒ VisibilityClause drops the cat_enabled gate).
        expect(sqlIds, [1, 2, 3, 4, 5]);
        // fix382 cache mirrors the SQL exactly.
        expect(fixedIds, sqlIds);
        // Regression guard: the pre-fix382 unconditional form returned nothing.
        expect(oldIds, isEmpty);
      } finally {
        db.dispose();
      }
    });

    test('top-level browse (groupId null) still hides disabled-category rows '
        '— equivalence preserved', () {
      if (!_sqliteAvailable()) {
        markTestSkipped('sqlite native lib unavailable');
        return;
      }
      final db = _seedDb();
      try {
        final sqlIds = _sqlIds(db, seriesId: null, groupId: null);
        final fixedIds =
            _cacheFilter(groupId: null, disabledGroupIds: {10}, disabledFixed: true);
        // Only the enabled category's channels appear; disabled-cat rows hidden.
        expect(sqlIds, [6, 7, 8]);
        expect(fixedIds, sqlIds);
      } finally {
        db.dispose();
      }
    });
  });
}
