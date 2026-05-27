import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/settings.dart' show safeModeBlocklist;
import 'package:open_tv/models/view_type.dart';

/// Lightweight record for in-memory search.
/// Holds every field needed to apply all filters before pagination —
/// full Channel objects are fetched by ID only after the final page is known.
class _CacheEntry {
  final int id;
  final String nameLower;    // pre-lowercased for case-insensitive match
  final String groupLower;   // group name, lowercased
  final int mediaType;
  final int sourceId;
  final bool favorite;
  final int? lastWatched;    // epoch-ms; null = never watched
  final int? groupId;
  final int? seriesId;
  /// True when name or group matches any [safeModeBlocklist] term.
  /// Computed once at build time so safe mode toggling never needs a rebuild.
  final bool adultBlocked;

  const _CacheEntry({
    required this.id,
    required this.nameLower,
    required this.groupLower,
    required this.mediaType,
    required this.sourceId,
    required this.favorite,
    required this.lastWatched,
    required this.groupId,
    required this.seriesId,
    required this.adultBlocked,
  });
}

/// In-memory channel name cache for fix68 [SearchMethod.inMemory].
///
/// Populated by [rebuild] after every source refresh. Search runs as
/// pure Dart string matching — no SQLite, no disk I/O, no WAL impact.
///
/// Safe mode (fix70 / fix55): every entry stores [_CacheEntry.adultBlocked]
/// computed at build time. The [search] caller passes [safeMode] and adult
/// entries are filtered without requiring a cache rebuild on toggle.
class ChannelSearchCache {
  static List<_CacheEntry> _entries = [];
  static bool _built = false;

  /// In-flight build future — prevents double-build on cold start.
  static Future<void>? _buildFuture;

  /// Returns true when the cache has not yet been built this session.
  static bool needsRebuild() => !_built;

  /// Rebuild the cache from the channels table.
  /// Call after every source refresh completes.
  static Future<void> rebuild() async {
    final t = DateTime.now();
    final rows = await Sql.getAllChannelNamesForCache();
    _entries = rows.map((r) {
      final nameLower  = r.$2.toLowerCase();
      final groupLower = r.$3.toLowerCase();
      final adultBlocked = safeModeBlocklist
          .any((b) => nameLower.contains(b) || groupLower.contains(b));
      return _CacheEntry(
        id:           r.$1,
        nameLower:    nameLower,
        groupLower:   groupLower,
        mediaType:    r.$4,
        sourceId:     r.$5,
        favorite:     r.$6,
        lastWatched:  r.$7,
        groupId:      r.$8,
        seriesId:     r.$9,
        adultBlocked: adultBlocked,
      );
    }).toList(growable: false);
    _built = true;
    final ms = DateTime.now().difference(t).inMilliseconds;
    AppLog.info(
      'ChannelSearchCache: rebuilt ${_entries.length} entries in ${ms}ms'
      ' (~${(_entries.length * 80 / 1024).toStringAsFixed(0)}KB)',
    );
  }

  /// Returns a [Future] that resolves when the cache is ready.
  ///
  /// - Already built → returns immediately.
  /// - Build in-flight → awaits the existing build (no double work).
  /// - Not built → starts a new build.
  static Future<void> ensureBuilt() {
    if (_built) return Future.value();
    final inFlight = _buildFuture;
    if (inFlight != null) return inFlight;
    _buildFuture = rebuild().whenComplete(() => _buildFuture = null);
    return _buildFuture!;
  }

  /// Returns channel IDs matching all supplied filters, fully paginated.
  ///
  /// All filters are applied before [offset]/[limit] so pagination is correct
  /// regardless of which view type is active.
  ///
  /// History view is sorted [lastWatched] DESC before pagination.
  static List<int> search({
    required String query,
    required Set<int> mediaTypes,
    required Set<int> sourceIds,
    required ViewType viewType,
    required int? groupId,
    required int? seriesId,
    required bool safeMode,
    required int limit,
    required int offset,
  }) {
    if (!_built) return [];

    final terms = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();

    // History requires a full sort pass — collect all matches first.
    if (viewType == ViewType.history) {
      final matches = <_CacheEntry>[];
      for (final e in _entries) {
        if (!mediaTypes.contains(e.mediaType)) continue;
        if (!sourceIds.contains(e.sourceId)) continue;
        if (safeMode && e.adultBlocked) continue;
        if (e.lastWatched == null) continue;
        if (seriesId != null && e.seriesId != seriesId) continue;
        if (groupId != null && e.groupId != groupId) continue;
        if (terms.isNotEmpty && !terms.every((t) => e.nameLower.contains(t))) {
          continue;
        }
        matches.add(e);
      }
      matches.sort(
        (a, b) => (b.lastWatched ?? 0).compareTo(a.lastWatched ?? 0),
      );
      return matches.skip(offset).take(limit).map((e) => e.id).toList();
    }

    // All other views: early-break once the page is full.
    final results = <int>[];
    var seen = 0; // entries that passed all filters (for offset)
    for (final e in _entries) {
      if (!mediaTypes.contains(e.mediaType)) continue;
      if (!sourceIds.contains(e.sourceId)) continue;
      if (safeMode && e.adultBlocked) continue;
      if (viewType == ViewType.favorites && !e.favorite) continue;
      if (seriesId != null && e.seriesId != seriesId) continue;
      if (groupId != null && e.groupId != groupId) continue;
      if (terms.isNotEmpty && !terms.every((t) => e.nameLower.contains(t))) {
        continue;
      }
      if (seen++ < offset) continue;
      results.add(e.id);
      if (results.length >= limit) break;
    }
    return results;
  }

  static bool get isBuilt => _built;
  static int get size => _entries.length;

  /// Invalidate cache (e.g. when sources change).
  static void invalidate() {
    _entries = [];
    _built = false;
    _buildFuture = null;
    AppLog.info('ChannelSearchCache: invalidated');
  }
}
