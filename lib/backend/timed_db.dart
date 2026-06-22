import 'package:sqlite3/common.dart' as sqlite;
import 'package:sqlite_async/sqlite_async.dart';

import 'package:open_tv/backend/app_logger.dart';

/// fix238: app-wide slow-query logging. Wraps a [SqliteWriteContext] and times
/// every execute/getAll/get/getOptional call. Any statement whose wall-clock
/// duration (Dart-side — includes the sqlite_async isolate round-trip, which is
/// what actually matters for this app) is at least [slowQueryThresholdMs] is
/// logged via [AppLog.warn], but ONLY when AppLog.enabled (the same debug-log
/// flag that gates all other diagnostics). When disabled the overhead is a
/// single Stopwatch per call and no logging.
///
/// The wrapper also intercepts [writeTransaction] so the [SqliteWriteContext]
/// handed to the callback is itself wrapped — this is what makes queries INSIDE
/// transactions (e.g. the source-refresh commit) subject to the same timing.
///
/// NOTE: this implements [SqliteWriteContext], which is the interface
/// `DbFactory.db` callers actually use (execute/getAll/get/getOptional/
/// writeTransaction). If a future caller needs a `SqliteDatabase`-only member
/// (e.g. close()), call it on the raw instance the factory retains, not through
/// this wrapper. Un-proxied members fall through to [noSuchMethod] on the inner
/// object.
const int slowQueryThresholdMs = 1000;

class TimedWriteContext implements SqliteWriteContext {
  final SqliteWriteContext _inner;

  TimedWriteContext(this._inner);

  // fix418: one-shot guard so the (heavier) browse-stats aggregate runs at most
  // once per process — the first time a slow browse query is seen.
  static bool _browseStatsLogged = false;

  Future<T> _timed<T>(String sql, List<Object?> params, Future<T> Function() run,
      {bool canExplain = true}) async {
    if (!AppLog.enabled) return run();
    final sw = Stopwatch()..start();
    try {
      return await run();
    } finally {
      sw.stop();
      if (sw.elapsedMilliseconds >= slowQueryThresholdMs) {
        final flat = sql.trim().replaceAll(RegExp(r'\s+'), ' ');
        final clipped = flat.length > 300 ? '${flat.substring(0, 300)}…' : flat;
        AppLog.warn('SLOW SQL ${sw.elapsedMilliseconds}ms: $clipped');
        // fix418: also log the offending statement's query plan and (once) the
        // per-source row shape, so a slow browse/category query can be fully
        // diagnosed from an exported log — no adb / debuggable build needed.
        // EXPLAIN QUERY PLAN runs the planner only (no row execution), so it
        // never re-runs a slow DELETE/UPDATE. Already gated by AppLog.enabled.
        if (canExplain) {
          try {
            final rows = await _inner.getAll('EXPLAIN QUERY PLAN $sql', params);
            AppLog.info(
                'fix418 PLAN: ${rows.map((r) => r['detail']).join(' | ')}');
          } catch (e) {
            AppLog.warn('fix418 PLAN failed: $e');
          }
          if (!_browseStatsLogged && flat.contains('FROM channels c')) {
            _browseStatsLogged = true;
            await _logBrowseStats();
          }
        }
      }
    }
  }

  // fix418: per-source row-shape dump, used to build a faithful benchmark seed
  // for the slow-browse fix. Runs on the raw inner context so it does not
  // re-enter the slow-query logger.
  Future<void> _logBrowseStats() async {
    try {
      final dist = await _inner.getAll(
        'SELECT source_id, media_type, COUNT(*) n,'
        ' SUM(CASE WHEN COALESCE(cat_enabled,0)=1 THEN 1 ELSE 0 END) en,'
        ' SUM(CASE WHEN COALESCE(favorite,0)=1 THEN 1 ELSE 0 END) fav,'
        ' SUM(CASE WHEN COALESCE(stream_validated,0)=1 THEN 1 ELSE 0 END) val,'
        ' SUM(CASE WHEN COALESCE(is_adult,0)=1 THEN 1 ELSE 0 END) adult,'
        ' SUM(CASE WHEN COALESCE(is_divider,0)=1 THEN 1 ELSE 0 END) divs'
        ' FROM channels GROUP BY source_id, media_type',
      );
      for (final r in dist) {
        AppLog.info('fix418 stats src=${r['source_id']} mt=${r['media_type']}'
            ' n=${r['n']} en=${r['en']} fav=${r['fav']} val=${r['val']}'
            ' adult=${r['adult']} div=${r['divs']}');
      }
      final cats = await _inner.getAll(
        'SELECT source_id, COUNT(DISTINCT group_id) cats, COUNT(*) total'
        ' FROM channels GROUP BY source_id',
      );
      for (final r in cats) {
        AppLog.info('fix418 stats src=${r['source_id']}'
            ' cats=${r['cats']} total=${r['total']}');
      }
      final big = await _inner.getAll(
        'SELECT source_id, group_id, COUNT(*) n FROM channels'
        ' GROUP BY source_id, group_id ORDER BY n DESC LIMIT 5',
      );
      for (final r in big) {
        AppLog.info('fix418 stats bigcat src=${r['source_id']}'
            ' group=${r['group_id']} n=${r['n']}');
      }
    } catch (e) {
      AppLog.warn('fix418 stats failed: $e');
    }
  }

  @override
  Future<sqlite.ResultSet> execute(String sql,
          [List<Object?> parameters = const []]) =>
      _timed(sql, parameters, () => _inner.execute(sql, parameters));

  @override
  Future<sqlite.ResultSet> getAll(String sql,
          [List<Object?> parameters = const []]) =>
      _timed(sql, parameters, () => _inner.getAll(sql, parameters));

  @override
  Future<sqlite.Row> get(String sql,
          [List<Object?> parameters = const []]) =>
      _timed(sql, parameters, () => _inner.get(sql, parameters));

  @override
  Future<sqlite.Row?> getOptional(String sql,
          [List<Object?> parameters = const []]) =>
      _timed(sql, parameters, () => _inner.getOptional(sql, parameters));

  @override
  Future<void> executeBatch(String sql, List<List<Object?>> parameterSets) =>
      _timed(sql, const [], () => _inner.executeBatch(sql, parameterSets),
          canExplain: false);

  @override
  Future<void> executeMultiple(String sql) =>
      _timed(sql, const [], () => _inner.executeMultiple(sql), canExplain: false);

  @override
  Future<T> writeTransaction<T>(
          Future<T> Function(SqliteWriteContext tx) callback) =>
      _inner.writeTransaction((tx) => callback(TimedWriteContext(tx)));

  // Any member not explicitly proxied above delegates to the inner context.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      (_inner as dynamic).noSuchMethod(invocation);
}
