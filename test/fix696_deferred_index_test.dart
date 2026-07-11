// fix696: a bulk refresh drops the browse/secondary channels indexes, then in
// withDroppedBrowseIndexes' finally rebuilds ONLY the two match-critical ones
// synchronously and DEFERS the rest to a background ensureBrowseIndexesPresent()
// pass the refresh caller kicks once channels+EPG+match are done. This moves
// ~14 × ~20s CREATE INDEXes off the perceived-refresh (dialog) critical path.
//
// The flow is DbFactory-coupled, so this pins the decisions that make it
// correct + SAFE: the critical set, the deferred-DDL persistence (so nothing is
// lost), the post-refresh kicks, and the re-entrancy guard.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _slice(String s, String from, String to) {
  final a = s.indexOf(from);
  final b = to.isEmpty ? s.length : s.indexOf(to, a + from.length);
  return s.substring(a, b < 0 ? s.length : b);
}

// Mirrors the partition in withDroppedBrowseIndexes' finally.
(List<String>, List<String>) partition(
    List<String> dropped, Set<String> critical) {
  final c = dropped.where(critical.contains).toList();
  final d = dropped.where((n) => !critical.contains(n)).toList();
  return (c, d);
}

void main() {
  final sql = File('lib/backend/sql.dart').readAsStringSync();

  group('fix696 critical/deferred partition (logic mirror)', () {
    const critical = {'idx_epg_unmatched', 'idx_channel_src_media_url'};
    // The full droppable browse/secondary set (everything dropped by a refresh
    // except the kept index_channel_source_id / index_channel_name_source).
    const dropped = [
      'idx_channels_browse_mt',
      'idx_channels_browse_mt_safe',
      'idx_browse_prov',
      'idx_browse_prov_safe',
      'idx_browse_src_mt',
      'idx_browse_src_mt_safe',
      'idx_channels_browse_enabled',
      'idx_browse_src_grp',
      'idx_channels_browse_tier',
      'index_channel_group_id',
      'idx_channels_epg_id',
      'index_channel_series_id',
      'idx_epg_unmatched',
      'idx_channel_src_media_url',
      'idx_channel_lastwatched_media',
      'idx_fav_browse',
    ];

    test('exactly the 2 match feeders are critical; the other 14 defer', () {
      final (c, d) = partition(dropped, critical);
      expect(c.toSet(), critical);
      expect(d.length, 14);
      expect(d.contains('idx_epg_unmatched'), isFalse);
      expect(d.contains('idx_fav_browse'), isTrue); // browse-only → deferred
    });
  });

  group('fix696 source invariants', () {
    test('_refreshCriticalIndexes is exactly the two match feeders', () {
      final block = _slice(sql, '_refreshCriticalIndexes', '];');
      expect(block.contains("'idx_epg_unmatched'"), isTrue);
      expect(block.contains("'idx_channel_src_media_url'"), isTrue);
      // Guard against accidental expansion that would defeat the deferral.
      final count = "'".allMatches(block).length ~/ 2;
      expect(count, 2, reason: 'critical set must stay just the 2 match feeders');
    });

    test('withDroppedBrowseIndexes persists the DEFERRED DDL (nothing lost)',
        () {
      final fn = _slice(sql, 'static Future<void> withDroppedBrowseIndexes',
          'static Future<void> reconcileFtsTriggers');
      expect(fn.contains("DEFERRED"), isTrue);
      // The safety belt: deferred DDL is written back to pending_browse_index_ddl
      // so ensureBrowseIndexesPresent (kicked pass OR startup self-heal) rebuilds
      // exactly the still-missing set.
      expect(
          fn.contains(
              "'pending_browse_index_ddl', ?") &&
              fn.contains('deferred.map'),
          isTrue,
          reason: 'deferred indexes must be persisted for rebuild/self-heal');
    });

    test('ensureBrowseIndexesPresent has the re-entrancy guard', () {
      final fn = _slice(sql, 'static bool _ensuringBrowseIndexes',
          'static Future<int> warmBrowseCache');
      expect(fn.contains('_ensuringBrowseIndexes = true'), isTrue);
      expect(fn.contains('_ensuringBrowseIndexes = false'), isTrue);
    });

    test('both refresh completion paths kick the deferred rebuild', () {
      final settings = File('lib/settings_view.dart').readAsStringSync();
      final dialog =
          File('lib/widgets/sources_refresh_dialog.dart').readAsStringSync();
      expect(settings.contains('Sql.ensureBrowseIndexesPresent()'), isTrue,
          reason: 'single-source refresh must kick the deferred rebuild');
      expect(dialog.contains('Sql.ensureBrowseIndexesPresent()'), isTrue,
          reason: 'global refresh dialog must kick the deferred rebuild');
    });
  });
}
