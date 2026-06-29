import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/channel_search_cache.dart';
import 'package:open_tv/backend/db_factory.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/view_type.dart';

/// fix612: on-device search-method benchmark.
///
/// Runs every [SearchMethod] against the user's REAL catalog and reports a
/// COLD first-hit number and a WARM median. The recommendation is driven by
/// the warm median (the fair, reproducible steady-state cost); the cold
/// number is shown but caveated — Android's OS file cache cannot be flushed
/// from Dart, so once any method touches the catalog file the index pages are
/// warm for every method that runs after it. We can drop SQLite's OWN page
/// cache between methods (cache_size reset) but not the OS page cache, so the
/// cold figure is a loose "first search after refresh" indicator, not an
/// apples-to-apples cross-method comparison.
class SearchMethodPerfResult {
  final SearchMethod method;

  /// Cold first-hit query time (ms). For [SearchMethod.inMemory] this INCLUDES
  /// the cache build time (the real cost of the first search after a refresh).
  final double coldMs;

  /// Median of the warm runs (ms). Drives the recommendation.
  final double warmMedianMs;

  /// True if the method ran but returned no rows for any probe (e.g. the
  /// in-memory cache was skipped on a low-RAM device and fell through). Shown
  /// so a 0ms-but-useless result isn't mistaken for "fastest".
  final bool degraded;

  const SearchMethodPerfResult({
    required this.method,
    required this.coldMs,
    required this.warmMedianMs,
    required this.degraded,
  });
}

class SearchPerfTest {
  /// Hard cap on how many channel names we sample to build the probe queries —
  /// keeps the test fast on a 1M+ row catalog (the SELECT is the only
  /// catalog-size-bound part of setup).
  static const int _nameSampleCap = 2000;

  /// 5 queries x 3 shapes = 15 warm runs per method.
  static const int _queriesPerShape = 5;

  /// Run the full benchmark. [onProgress] reports a human string per phase.
  static Future<List<SearchMethodPerfResult>> run({
    required List<int> enabledSourceIds,
    required bool safeMode,
    void Function(String)? onProgress,
  }) async {
    if (enabledSourceIds.isEmpty) {
      throw Exception('No enabled sources — add or enable a source first.');
    }
    onProgress?.call('Sampling channel names…');
    final probes = await _buildProbes();
    if (probes.oneWord.isEmpty) {
      throw Exception('Not enough channel data to build a test.');
    }

    final results = <SearchMethodPerfResult>[];
    try {
      for (final method in SearchMethod.values) {
        onProgress?.call('Testing ${_label(method)}…');
        results.add(await _benchmarkMethod(
          method: method,
          probes: probes,
          enabledSourceIds: enabledSourceIds,
          safeMode: safeMode,
        ));
      }
    } finally {
      // The benchmark rebuilds the in-memory cache for its own timing. Leave it
      // invalidated so the next REAL search lazily rebuilds against whatever
      // method the user ends up on (same lazy path the method-picker uses).
      ChannelSearchCache.invalidate();
    }
    return results;
  }

  /// The fastest method by warm median, ignoring degraded results.
  static SearchMethod recommend(List<SearchMethodPerfResult> results) {
    final viable = results.where((r) => !r.degraded).toList();
    final pool = viable.isEmpty ? results : viable;
    pool.sort((a, b) => a.warmMedianMs.compareTo(b.warmMedianMs));
    return pool.first.method;
  }

  static Future<SearchMethodPerfResult> _benchmarkMethod({
    required SearchMethod method,
    required _Probes probes,
    required List<int> enabledSourceIds,
    required bool safeMode,
  }) async {
    // Drop SQLite's own page cache so the cold run pays a fresh read (best we
    // can do — the OS file cache is out of reach from Dart).
    await _dropSqlitePageCache();

    Filters mk(String q) => Filters(
          query: q,
          sourceIds: List.of(enabledSourceIds),
          mediaTypes: const [MediaType.livestream, MediaType.movie, MediaType.serie],
          viewType: ViewType.all,
          searchMethod: method,
          safeMode: safeMode,
          useKeywords: method == SearchMethod.ftsAnd,
          limit: 50,
        );

    var degraded = false;

    // ── COLD ──
    // inMemory: cold = build + first query. Force a fresh build so the number
    // reflects the real first-search-after-refresh cost.
    double coldMs;
    if (method == SearchMethod.inMemory) {
      final sw = Stopwatch()..start();
      ChannelSearchCache.invalidate();
      await ChannelSearchCache.rebuild();
      final rows = await Sql.search(mk(probes.oneWord.first));
      sw.stop();
      coldMs = sw.elapsedMicroseconds / 1000.0;
      if (ChannelSearchCache.cacheSkipped || rows.isEmpty) degraded = true;
    } else {
      final sw = Stopwatch()..start();
      final rows = await Sql.search(mk(probes.oneWord.first));
      sw.stop();
      coldMs = sw.elapsedMicroseconds / 1000.0;
      if (rows.isEmpty) degraded = true;
    }

    // ── WARM ── 15 runs across the three shapes; median.
    final warmTimes = <double>[];
    final shapes = [probes.oneWord, probes.multiWord, probes.prefix];
    var anyRows = false;
    for (final shape in shapes) {
      for (var i = 0; i < _queriesPerShape; i++) {
        final q = shape[i % shape.length];
        final sw = Stopwatch()..start();
        final rows = await Sql.search(mk(q));
        sw.stop();
        warmTimes.add(sw.elapsedMicroseconds / 1000.0);
        if (rows.isNotEmpty) anyRows = true;
      }
    }
    if (!anyRows) degraded = true;
    warmTimes.sort();
    final median = warmTimes.isEmpty
        ? 0.0
        : warmTimes[warmTimes.length ~/ 2];

    AppLog.info(
      'SearchPerfTest: ${_label(method)} cold=${coldMs.toStringAsFixed(1)}ms '
      'warmMedian=${median.toStringAsFixed(1)}ms degraded=$degraded',
    );

    return SearchMethodPerfResult(
      method: method,
      coldMs: coldMs,
      warmMedianMs: median,
      degraded: degraded,
    );
  }

  /// Reset SQLite's page cache by shrinking cache_size to a single page then
  /// restoring it — this forces the pager to evict its cached pages. Not a true
  /// cold read: the OS file cache persists and is out of reach from Dart, so
  /// methods that run later still read warm OS pages (the cold figure is
  /// caveated in the UI for exactly this reason). The -2000 restore matches the
  /// browse default used elsewhere in sql.dart.
  static Future<void> _dropSqlitePageCache() async {
    final db = await DbFactory.db;
    await db.execute('PRAGMA cache_size = 1;');
    await db.execute('PRAGMA cache_size = -2000;');
  }

  /// Sample real channel names (capped) and derive probe queries of each shape:
  /// one-word, multi-word, and a short prefix.
  static Future<_Probes> _buildProbes() async {
    final db = await DbFactory.db;
    final rows = await db.getAll(
      'SELECT name FROM channels WHERE name IS NOT NULL LIMIT ?',
      [_nameSampleCap],
    );
    final names = rows
        .map((r) => (r['name'] as String).trim())
        .where((n) => n.isNotEmpty)
        .toList();

    final oneWord = <String>[];
    final multiWord = <String>[];
    final prefix = <String>[];

    for (final name in names) {
      final words =
          name.split(RegExp(r'\s+')).where((w) => w.length >= 2).toList();
      if (words.isEmpty) continue;
      if (oneWord.length < _queriesPerShape) oneWord.add(words.first);
      if (words.length >= 2 && multiWord.length < _queriesPerShape) {
        multiWord.add('${words[0]} ${words[1]}');
      }
      if (prefix.length < _queriesPerShape) {
        final w = words.first;
        prefix.add(w.length >= 3 ? w.substring(0, 3) : w);
      }
      if (oneWord.length >= _queriesPerShape &&
          multiWord.length >= _queriesPerShape &&
          prefix.length >= _queriesPerShape) {
        break;
      }
    }
    // Fallbacks so a thin catalog still runs (mirror one-word into the others).
    if (multiWord.isEmpty) multiWord.addAll(oneWord);
    if (prefix.isEmpty) prefix.addAll(oneWord);
    return _Probes(oneWord: oneWord, multiWord: multiWord, prefix: prefix);
  }

  static String _label(SearchMethod m) => switch (m) {
        SearchMethod.ftsAnd => 'FTS AND',
        SearchMethod.ftsPhrase => 'FTS Phrase',
        SearchMethod.likeSubstring => 'LIKE Scan',
        SearchMethod.inMemory => 'In-Memory',
      };
}

class _Probes {
  final List<String> oneWord;
  final List<String> multiWord;
  final List<String> prefix;
  const _Probes({
    required this.oneWord,
    required this.multiWord,
    required this.prefix,
  });
}
