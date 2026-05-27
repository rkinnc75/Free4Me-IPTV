import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/settings.dart' show safeModeBlocklist;

/// Lightweight record for in-memory search.
/// Only holds what the search filter needs — full Channel objects
/// are fetched by ID after the search narrows the candidate set.
class _CacheEntry {
  final int id;
  final String nameLower; // pre-lowercased for case-insensitive match
  final String groupLower; // group name for safe mode filtering (fix70)
  final int mediaType;
  final int sourceId;
  const _CacheEntry(
      this.id, this.nameLower, this.groupLower, this.mediaType, this.sourceId);
}

/// In-memory channel name cache for fix68 [SearchMethod.inMemory].
///
/// Populated by [rebuild] after every source refresh. Search runs as
/// pure Dart string matching — no SQLite, no disk I/O, no WAL impact.
class ChannelSearchCache {
  static List<_CacheEntry> _entries = [];
  static bool _built = false;
  // fix70: tracks which safeMode the cache was built with.
  static bool _builtWithSafeMode = false;

  /// True if the cache needs rebuilding because it hasn't been built
  /// yet, or because safeMode has changed since last build.
  static bool needsRebuild(bool currentSafeMode) =>
      !_built || _builtWithSafeMode != currentSafeMode;

  /// Rebuild the cache from the channels table.
  /// Call after every source refresh completes.
  ///
  /// [safeMode] — when true, adult-content channels are excluded at
  /// build time (fix70). Pass the current Settings.safeMode value.
  /// Use [needsRebuild] to check if the cached safeMode differs.
  static Future<void> rebuild({bool safeMode = false}) async {
    final t = DateTime.now();
    final rows = await Sql.getAllChannelNamesForCache();
    _entries = rows
        .map((r) => _CacheEntry(
              r.$1, // id
              r.$2.toLowerCase(), // nameLower
              r.$3.toLowerCase(), // groupLower (fix70)
              r.$4, // mediaType index
              r.$5, // sourceId
            ))
        // fix70: exclude adult channels at build time when safeMode on.
        .where((e) =>
            !safeMode ||
            !safeModeBlocklist
                .any((b) => e.nameLower.contains(b) || e.groupLower.contains(b)))
        .toList(growable: false);
    _built = true;
    _builtWithSafeMode = safeMode;
    final ms = DateTime.now().difference(t).inMilliseconds;
    AppLog.info(
      'ChannelSearchCache: rebuilt ${_entries.length} entries in ${ms}ms'
      ' (~${(_entries.length * 50 / 1024).toStringAsFixed(0)}KB)',
    );
  }

  /// Returns channel IDs matching [query] filtered by [mediaTypes]
  /// and [sourceIds]. Case-insensitive AND substring match on each
  /// space-separated term.
  static List<int> search({
    required String query,
    required List<int> mediaTypes,
    required List<int?> sourceIds,
    required int limit,
    required int offset,
  }) {
    if (!_built) return [];
    final terms = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (terms.isEmpty) return [];

    final sourceIdSet = sourceIds.whereType<int>().toSet();
    final mediaTypeSet = mediaTypes.toSet();

    final results = <int>[];
    for (final e in _entries) {
      if (!mediaTypeSet.contains(e.mediaType)) continue;
      if (!sourceIdSet.contains(e.sourceId)) continue;
      // All terms must appear somewhere in the name (AND logic).
      if (terms.every((t) => e.nameLower.contains(t))) {
        results.add(e.id);
      }
      if (results.length >= offset + limit) break;
    }
    return results.skip(offset).take(limit).toList();
  }

  static bool get isBuilt => _built;
  static int get size => _entries.length;

  /// Invalidate cache (e.g. when sources change).
  static void invalidate() {
    _entries = [];
    _built = false;
    AppLog.info('ChannelSearchCache: invalidated');
  }
}
