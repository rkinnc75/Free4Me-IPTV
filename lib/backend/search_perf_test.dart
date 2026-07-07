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

/// Review finding 157: cooperative cancel for the perf benchmark so a Back
/// press / dialog dispose stops the (DB-hammering) run instead of orphaning it.
class SearchPerfCancelToken {
  bool cancelled = false;
  void cancel() => cancelled = true;
}

class SearchPerfTest {
  /// Hard cap on how many channel names we sample to build the probe queries —
  /// keeps the test fast on a 1M+ row catalog (the SELECT is the only
  /// catalog-size-bound part of setup).
  static const int _nameSampleCap = 2000;

  /// 5 queries x 3 shapes = 15 probe queries per pass.
  static const int _queriesPerShape = 5;

  /// fix613: cold and warm now run the SAME probe set so the only difference is
  /// cache state. Pass 1 is cold (SQLite page cache dropped first); passes
  /// 2..(1+_warmPasses) are warm. Each number is the MEDIAN over its pass(es).
  static const int _warmPasses = 3;

  /// Run the full benchmark. [onProgress] reports a human string per phase.
  static Future<List<SearchMethodPerfResult>> run({
    required List<int> enabledSourceIds,
    required bool safeMode,
    void Function(String)? onProgress,
    SearchPerfCancelToken? cancelToken, // review finding 157
  }) async {
    if (enabledSourceIds.isEmpty) {
      throw Exception('No enabled sources — add or enable a source first.');
    }
    onProgress?.call('Sampling channel names…');
    final probes = await _buildProbes();
    if (probes.isEmpty) {
      throw Exception('Not enough channel data to build a test.');
    }

    final results = <SearchMethodPerfResult>[];
    try {
      for (final method in SearchMethod.values) {
        if (cancelToken?.cancelled == true) break; // review finding 157
        onProgress?.call('Testing ${_label(method)}…');
        results.add(await _benchmarkMethod(
          method: method,
          probes: probes,
          enabledSourceIds: enabledSourceIds,
          safeMode: safeMode,
          cancelToken: cancelToken,
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
    required List<String> probes,
    required List<int> enabledSourceIds,
    required bool safeMode,
    SearchPerfCancelToken? cancelToken, // review finding 157
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
    var anyRows = false;

    // Run one full pass over the shared probe set; return each query's time.
    Future<List<double>> runPass() async {
      final times = <double>[];
      for (final q in probes) {
        if (cancelToken?.cancelled == true) break; // review finding 157
        final sw = Stopwatch()..start();
        final rows = await Sql.search(mk(q));
        sw.stop();
        times.add(sw.elapsedMicroseconds / 1000.0);
        if (rows.isNotEmpty) anyRows = true;
      }
      return times;
    }

    double medianOf(List<double> xs) {
      if (xs.isEmpty) return 0.0;
      final sorted = List<double>.of(xs)..sort();
      return sorted[sorted.length ~/ 2];
    }

    // fix613: cold and warm use the SAME probe set; only cache state differs.
    // For inMemory, build the cache BEFORE pass 1 so its queries time against a
    // freshly-built cache (the cache build itself is a one-time cost, not folded
    // into the per-query median).
    if (method == SearchMethod.inMemory) {
      ChannelSearchCache.invalidate();
      await ChannelSearchCache.rebuild();
      if (ChannelSearchCache.cacheSkipped) degraded = true;
    }

    // ── COLD ── pass 1, SQLite page cache dropped first. Cold = median of pass.
    final coldTimes = await runPass();
    final coldMs = medianOf(coldTimes);

    // ── WARM ── passes 2..(1+_warmPasses) over the identical set; median of all.
    final warmTimes = <double>[];
    for (var pass = 0; pass < _warmPasses; pass++) {
      warmTimes.addAll(await runPass());
    }
    final warmMs = medianOf(warmTimes);

    if (!anyRows) degraded = true;

    AppLog.info(
      'SearchPerfTest: ${_label(method)} cold=${coldMs.toStringAsFixed(1)}ms '
      'warmMedian=${warmMs.toStringAsFixed(1)}ms degraded=$degraded '
      '(probes=${probes.length} warmPasses=$_warmPasses)',
    );

    return SearchMethodPerfResult(
      method: method,
      coldMs: coldMs,
      warmMedianMs: warmMs,
      degraded: degraded,
    );
  }

  /// Reset SQLite's page cache by shrinking cache_size to a single page then
  /// restoring it — this forces the pager to evict its cached pages. Not a true
  /// cold read: the OS file cache persists and is out of reach from Dart, so
  /// methods that run later still read warm OS pages (the cold figure is
  /// caveated in the UI for exactly this reason). The -2000 restore matches the
  /// browse default used elsewhere in sql.dart.
  ///
  /// finding 168: this PRAGMA runs on the write connection (DbFactory.db),
  /// whereas Sql.search serves each probe through db.getAll → the read pool.
  /// sqlite_async 0.13.x exposes only a single-connection readLock with no way
  /// to enumerate or reset every pooled read connection, so the probe pool
  /// cannot be reliably cold-started from Dart. The "cold" number is therefore
  /// a best-effort lower bound, not a guaranteed cold read — accepted here (and
  /// caveated in the UI) rather than rearchitected, since the write-connection
  /// eviction still perturbs the shared pager/OS state enough to be indicative.
  static Future<void> _dropSqlitePageCache() async {
    final db = await DbFactory.db;
    await db.execute('PRAGMA cache_size = 1;');
    await db.execute('PRAGMA cache_size = -2000;');
  }

  /// fix613: strip leading/trailing punctuation/symbols from a token, keeping
  /// only a clean alphanumeric (+ internal spaces already split out) word. This
  /// removes the garbage probes the first version produced ("#Li", "\'Al",
  /// "(AU") by sampling raw words.first — leading symbols are not how a user
  /// searches and skew FTS timing.
  static String _clean(String w) {
    final m = RegExp(r'[\p{L}\p{N}]+', unicode: true).allMatches(w);
    return m.map((x) => x.group(0)!).join();
  }

  /// Sample real channel names (capped) and derive a SINGLE flat, ordered probe
  /// set: [_queriesPerShape] each of one-word, multi-word, and 3-char prefix.
  /// fix613: cold and warm both run this exact list, so they differ only by
  /// cache state. Tokens are sanitized (see [_clean]) and de-duplicated.
  static Future<List<String>> _buildProbes() async {
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
      final words = name
          .split(RegExp(r'\s+'))
          .map(_clean)
          .where((w) => w.length >= 2)
          .toList();
      if (words.isEmpty) continue;
      if (oneWord.length < _queriesPerShape && !oneWord.contains(words.first)) {
        oneWord.add(words.first);
      }
      if (words.length >= 2 && multiWord.length < _queriesPerShape) {
        final pair = '${words[0]} ${words[1]}';
        if (!multiWord.contains(pair)) multiWord.add(pair);
      }
      if (prefix.length < _queriesPerShape) {
        final w = words.first;
        final pre = w.length >= 3 ? w.substring(0, 3) : w;
        if (!prefix.contains(pre)) prefix.add(pre);
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
    return [...oneWord, ...multiWord, ...prefix];
  }

  static String _label(SearchMethod m) => switch (m) {
        SearchMethod.ftsAnd => 'FTS AND',
        SearchMethod.ftsPhrase => 'FTS Phrase',
        SearchMethod.likeSubstring => 'LIKE Scan',
        SearchMethod.inMemory => 'In-Memory',
      };
}

