import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/settings.dart' show safeModeBlocklist;
import 'package:open_tv/models/view_type.dart';

// Sentinel for copyWith — distinguishes "explicitly null" from "not provided".
const Object _absent = Object();

/// Lightweight record for in-memory search.
/// Holds every field needed to apply all filters before pagination —
/// full Channel objects are fetched by ID only after the final page is known.
class _CacheEntry {
  final int id;
  final String nameLower;     // pre-lowercased for case-insensitive match
  final String groupLower;    // group name, lowercased
  final int mediaType;
  final int sourceId;
  final bool favorite;
  final int? lastWatched;     // epoch-seconds; null = never watched
  final int? groupId;
  final int? seriesId;
  /// fix57: null = never scanned, true = valid, false = invalid.
  final bool? streamValidated;
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
    required this.streamValidated,
    required this.adultBlocked,
  });

  /// Creates a copy with specific fields overridden.
  ///
  /// [lastWatched] and [streamValidated] are nullable, so the [_absent]
  /// sentinel is used to distinguish "not provided" from "explicitly null".
  _CacheEntry copyWith({
    bool? favorite,
    Object? lastWatched = _absent,
    Object? streamValidated = _absent,
  }) {
    return _CacheEntry(
      id:              id,
      nameLower:       nameLower,
      groupLower:      groupLower,
      mediaType:       mediaType,
      sourceId:        sourceId,
      favorite:        favorite ?? this.favorite,
      lastWatched:     lastWatched == _absent
          ? this.lastWatched
          : lastWatched as int?,
      groupId:         groupId,
      seriesId:        seriesId,
      streamValidated: streamValidated == _absent
          ? this.streamValidated
          : streamValidated as bool?,
      adultBlocked:    adultBlocked,
    );
  }
}

/// In-memory channel name cache for fix68 [SearchMethod.inMemory].
///
/// Populated by [rebuild] after every source refresh. Search runs as
/// pure Dart string matching — no SQLite, no disk I/O, no WAL impact.
///
/// fix57:
/// - Adds [_CacheEntry.streamValidated] so in-memory ORDER BY matches SQL.
/// - Maintains pre-sorted views ([_entriesByDefaultOrder] and
///   [_entriesByHistoryOrder]) built once at rebuild time so pagination is
///   correct regardless of cache insertion order.
/// - Generation token prevents a stale in-flight rebuild from writing results
///   after [invalidate] has been called.
/// - Targeted mutation methods ([updateFavorite], [updateLastWatched],
///   [updateStreamValidated], [clearAllStreamValidated]) keep the cache
///   current after single-row DB writes so in-memory search reflects the
///   latest user action without a full rebuild.
///
/// Safe mode (fix70 / fix55): every entry stores [_CacheEntry.adultBlocked]
/// computed at build time. The [search] caller passes [safeMode] and adult
/// entries are filtered without requiring a cache rebuild on toggle.
class ChannelSearchCache {
  static List<_CacheEntry> _entries = [];

  /// Pre-sorted by: favorite DESC, streamValidated DESC, lastWatched DESC, name ASC.
  static List<_CacheEntry> _entriesByDefaultOrder = [];

  /// Pre-sorted by: lastWatched DESC (history view).
  static List<_CacheEntry> _entriesByHistoryOrder = [];

  /// ID → index in [_entries] for O(1) targeted mutations.
  static Map<int, int> _indexById = {};

  static bool _built = false;

  /// Generation token — incremented on [invalidate] to abort stale rebuilds.
  static int _generation = 0;

  /// In-flight build future — prevents double-build on cold start.
  static Future<void>? _buildFuture;

  /// Returns true when the cache has not yet been built this session.
  static bool needsRebuild() => !_built;

  // ── Sorting ────────────────────────────────────────────────────────────────

  /// Canonical default compare: favorites+validated → favorites → validated
  /// → recently watched → alphabetical. Matches SQL ORDER BY in fix72/74.
  static int _defaultCompare(_CacheEntry a, _CacheEntry b) {
    final favCmp = (b.favorite ? 1 : 0).compareTo(a.favorite ? 1 : 0);
    if (favCmp != 0) return favCmp;

    final valCmp = (b.streamValidated == true ? 1 : 0)
        .compareTo(a.streamValidated == true ? 1 : 0);
    if (valCmp != 0) return valCmp;

    final watchCmp = (b.lastWatched ?? 0).compareTo(a.lastWatched ?? 0);
    if (watchCmp != 0) return watchCmp;

    return a.nameLower.compareTo(b.nameLower);
  }

  /// Rebuild [_entriesByDefaultOrder] and [_entriesByHistoryOrder] from
  /// current [_entries]. Called after rebuild and after mutations.
  static void _rebuildSortedViews() {
    _entriesByDefaultOrder = [..._entries]..sort(_defaultCompare);
    _entriesByHistoryOrder = [..._entries]..sort(
      (a, b) => (b.lastWatched ?? 0).compareTo(a.lastWatched ?? 0),
    );
  }

  // ── Build / invalidate ─────────────────────────────────────────────────────

  /// Rebuild the cache from the channels table.
  /// Call after every source refresh completes.
  static Future<void> rebuild() async {
    final generation = _generation; // fix57: capture before async SQL call
    final t = DateTime.now();
    final rows = await Sql.getAllChannelNamesForCache();

    // fix57: discard if invalidate() was called while waiting for SQL.
    if (generation != _generation) {
      AppLog.info('ChannelSearchCache: rebuild discarded (generation changed)');
      return;
    }

    final entries = rows.map((r) {
      final nameLower  = r.$2.toLowerCase();
      final groupLower = r.$3.toLowerCase();
      final adultBlocked = safeModeBlocklist
          .any((b) => nameLower.contains(b) || groupLower.contains(b));
      return _CacheEntry(
        id:              r.$1,
        nameLower:       nameLower,
        groupLower:      groupLower,
        mediaType:       r.$4,
        sourceId:        r.$5,
        favorite:        r.$6,
        lastWatched:     r.$7,
        groupId:         r.$8,
        seriesId:        r.$9,
        streamValidated: r.$10, // fix57
        adultBlocked:    adultBlocked,
      );
    }).toList(growable: false);

    // fix57: check again after mapping in case invalidate() fired.
    if (generation != _generation) {
      AppLog.info(
        'ChannelSearchCache: rebuild discarded after mapping (generation changed)',
      );
      return;
    }

    _entries = entries;
    _indexById = {
      for (var i = 0; i < _entries.length; i++) _entries[i].id: i
    };
    _rebuildSortedViews(); // fix57: build pre-sorted views once
    _built = true;

    final ms = DateTime.now().difference(t).inMilliseconds;
    AppLog.info(
      'ChannelSearchCache: rebuilt ${_entries.length} entries in ${ms}ms'
      ' (~${(_entries.length * 88 / 1024).toStringAsFixed(0)}KB)',
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

  // ── Targeted mutations (fix57.2) ───────────────────────────────────────────

  /// Apply [update] to the entry with [id] and rebuild sorted views.
  /// No-op if [id] is not in the cache (cache not built or entry not found).
  static void _replaceEntry(int id, _CacheEntry Function(_CacheEntry) update) {
    final idx = _indexById[id];
    if (idx == null) return;
    final copy = List<_CacheEntry>.of(_entries);
    copy[idx] = update(_entries[idx]);
    _entries = copy;
    // _indexById unchanged — same IDs, same indices, only entry values differ.
    _rebuildSortedViews();
  }

  /// Update [favorite] for a single channel in the cache after a DB write.
  static void updateFavorite(int id, bool favorite) {
    _replaceEntry(id, (e) => e.copyWith(favorite: favorite));
  }

  /// Update [lastWatched] for a single channel after addToHistory /
  /// deleteHistoryEntry.
  static void updateLastWatched(int id, int? lastWatched) {
    _replaceEntry(id, (e) => e.copyWith(lastWatched: lastWatched));
  }

  /// Update [streamValidated] for a single channel after a stream scan.
  static void updateStreamValidated(int id, bool? streamValidated) {
    _replaceEntry(id, (e) => e.copyWith(streamValidated: streamValidated));
  }

  /// Reset all [streamValidated] flags to null after
  /// [Sql.clearAllStreamValidated].
  static void clearAllStreamValidated() {
    if (!_built || _entries.isEmpty) return;
    _entries = _entries
        .map((e) => e.copyWith(streamValidated: null))
        .toList(growable: false);
    // _indexById unchanged — IDs and indices are the same.
    _rebuildSortedViews();
    AppLog.info(
      'ChannelSearchCache: clearAllStreamValidated reset ${_entries.length} entries',
    );
  }

  // ── Search ─────────────────────────────────────────────────────────────────

  /// Returns channel IDs matching all supplied filters, fully paginated.
  ///
  /// All filters are applied before [offset]/[limit] so pagination is correct
  /// regardless of which view type is active.
  ///
  /// fix57: iterates [_entriesByDefaultOrder] or [_entriesByHistoryOrder]
  /// (pre-sorted at rebuild/mutation time) so ORDER BY is correct across pages
  /// and early-break works for all view types.
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

    // fix57: choose pre-sorted view — iterate and early-break after filling.
    final source = viewType == ViewType.history
        ? _entriesByHistoryOrder
        : _entriesByDefaultOrder;

    final results = <int>[];
    var seen = 0; // entries that passed all filters (for skip/offset)
    for (final e in source) {
      if (!mediaTypes.contains(e.mediaType)) continue;
      if (!sourceIds.contains(e.sourceId)) continue;
      if (safeMode && e.adultBlocked) continue;
      if (viewType == ViewType.history && e.lastWatched == null) continue;
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
    _generation++; // fix57: abort any in-flight rebuild
    _entries = [];
    _entriesByDefaultOrder = [];
    _entriesByHistoryOrder = [];
    _indexById = {};
    _built = false;
    _buildFuture = null;
    AppLog.info('ChannelSearchCache: invalidated (generation=$_generation)');
  }
}
