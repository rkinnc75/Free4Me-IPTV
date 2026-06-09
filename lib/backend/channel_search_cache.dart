import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/device_memory.dart';
import 'package:open_tv/backend/sql.dart';
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
  /// Null = never scanned, true = valid, false = invalid.
  final bool? streamValidated;
  /// True when name or group matches any [safeModeBlocklist] term.
  /// Computed once at build time so safe mode toggling never needs a rebuild.
  final bool adultBlocked;
  /// True when this channel's name is a "#### divider ####" label (fix272).
  final bool isDivider;
  /// True when this channel's source has hide_dividers enabled (fix272).
  final bool hideDividers;

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
    required this.isDivider,
    required this.hideDividers,
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
      isDivider:       isDivider,
      hideDividers:    hideDividers,
    );
  }
}

/// In-memory channel name cache for [SearchMethod.inMemory].
///
/// Populated by [rebuild] after every source refresh. Search runs as
/// pure Dart string matching — no SQLite, no disk I/O, no WAL impact.
///
/// Pre-sorted views keep pagination consistent with SQL ordering, and targeted
/// mutation methods keep favorite/history/validation state current without a
/// full rebuild.
class ChannelSearchCache {
  static List<_CacheEntry> _entries = [];

  /// Pre-sorted by: favorite DESC, streamValidated DESC, lastWatched DESC, name ASC.
  static List<_CacheEntry> _entriesByDefaultOrder = [];

  /// Pre-sorted by: lastWatched DESC (history view).
  static List<_CacheEntry> _entriesByHistoryOrder = [];

  /// ID → index in [_entries] for O(1) targeted mutations.
  static Map<int, int> _indexById = {};

  static bool _built = false;

  /// fix319: minimum device RAM (MB) to build the full in-memory search cache.
  /// Below this, the cache is skipped and search uses direct SQL — large
  /// catalogues (700k+) otherwise OOM-crash low-RAM TV boxes.
  static const int _minRamMbForCache = 2300;

  /// True when the in-memory cache is intentionally not used on this device.
  static bool get cacheSkipped => DeviceMemory.totalMb < _minRamMbForCache;

  /// fix298: ids of groups with enabled=0. Checked in [search] BEFORE the
  /// limit so disabled categories don't consume page slots. Mutable at runtime
  /// (category toggle) via [setGroupEnabled]/[setGroupsEnabledBulk] without a
  /// full rebuild — enabled state lives only here, not on each entry.
  static Set<int> _disabledGroupIds = {};

  /// Generation token — incremented on [invalidate] to abort stale rebuilds.
  static int _generation = 0;

  /// In-flight build future — prevents double-build on cold start.
  static Future<void>? _buildFuture;

  /// Returns true when the cache has not yet been built this session.
  static bool needsRebuild() => !_built;


  /// Canonical default compare: favorites+validated → favorites → validated
  /// → recently watched → alphabetical. Matches SQL ORDER BY.
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


  /// Rebuild the cache from the channels table.
  /// Call after every source refresh completes.
  static Future<void> rebuild() async {
    if (cacheSkipped) return; // fix319: low-RAM devices use direct SQL search
    final generation = _generation;
    final t = DateTime.now();
    final rows = await Sql.getAllChannelNamesForCache();
    // fix298: snapshot which groups are currently disabled so search can
    // exclude them before pagination. Kept current on toggle by setGroupEnabled.
    final disabled = await Sql.getDisabledGroupIds();

    if (generation != _generation) {
      AppLog.info('ChannelSearchCache: rebuild discarded (generation changed)');
      return;
    }

    final entries = rows.map((r) {
      final nameLower  = r.$2.toLowerCase();
      final groupLower = r.$3.toLowerCase();
      // fix300: adult status is precomputed into channels.is_adult at import,
      // so the cache reads it directly instead of re-scanning the blocklist.
      final adultBlocked = r.$13;
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
        streamValidated: r.$10,
        adultBlocked:    adultBlocked,
        isDivider:       r.$11,
        hideDividers:    r.$12,
      );
    }).toList(growable: false);

    if (generation != _generation) {
      AppLog.info(
        'ChannelSearchCache: rebuild discarded after mapping (generation changed)',
      );
      return;
    }

    _entries = entries;
    _disabledGroupIds = disabled;
    _indexById = {
      for (var i = 0; i < _entries.length; i++) _entries[i].id: i
    };
    _rebuildSortedViews();
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
    // fix319: on low-RAM devices (e.g. onn 4K Plus, ~2GB) a full in-memory
    // cache of a 700k+ channel catalogue is ~60MB+ and takes 30s+ to build,
    // causing OOM restarts. Skip the cache entirely there; search falls back
    // to direct SQL (see Sql.search / cacheSkipped).
    if (cacheSkipped) {
      AppLog.info(
        'ChannelSearchCache: skipped (low RAM ${DeviceMemory.totalMb}MB '
        '< ${_minRamMbForCache}MB) — using direct SQL search',
      );
      return Future.value();
    }
    final inFlight = _buildFuture;
    if (inFlight != null) return inFlight;
    _buildFuture = rebuild().whenComplete(() => _buildFuture = null);
    return _buildFuture!;
  }


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

  /// fix298: keep the disabled-category set current after a single category
  /// toggle, without rebuilding the cache. Enabled state lives only in
  /// [_disabledGroupIds], so this is O(1).
  static void setGroupEnabled(int groupId, bool enabled) {
    if (enabled) {
      _disabledGroupIds.remove(groupId);
    } else {
      _disabledGroupIds.add(groupId);
    }
  }

  /// fix298: bulk variant for Select all / Unselect all. [groupIds] is the full
  /// set of group ids the action covered; [enabled] is their new state.
  static void setGroupsEnabledBulk(Iterable<int> groupIds, bool enabled) {
    if (enabled) {
      _disabledGroupIds.removeAll(groupIds);
    } else {
      _disabledGroupIds.addAll(groupIds);
    }
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


  /// Returns channel IDs matching all supplied filters, fully paginated.
  ///
  /// All filters are applied before [offset]/[limit] so pagination is correct
  /// regardless of which view type is active.
  ///
  /// Iterates pre-sorted views so ordering is correct across pages and
  /// early-break works for all view types.
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
      // fix298: apply the divider + disabled-category exclusions HERE, before
      // the limit, so they don't consume page slots (the old post-fetch SQL
      // filter ran after the cache had already capped at `limit`, which let
      // dividers/disabled rows fill the page and hide real channels).
      if (e.isDivider && e.hideDividers) continue;
      if (e.groupId != null && _disabledGroupIds.contains(e.groupId)) continue;
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
    _generation++;
    _entries = [];
    _entriesByDefaultOrder = [];
    _entriesByHistoryOrder = [];
    _indexById = {};
    _built = false;
    _buildFuture = null;
    AppLog.info('ChannelSearchCache: invalidated (generation=$_generation)');
  }
}
