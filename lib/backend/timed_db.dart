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

  Future<T> _timed<T>(String sql, Future<T> Function() run) async {
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
      }
    }
  }

  @override
  Future<sqlite.ResultSet> execute(String sql,
          [List<Object?> parameters = const []]) =>
      _timed(sql, () => _inner.execute(sql, parameters));

  @override
  Future<sqlite.ResultSet> getAll(String sql,
          [List<Object?> parameters = const []]) =>
      _timed(sql, () => _inner.getAll(sql, parameters));

  @override
  Future<sqlite.Row> get(String sql,
          [List<Object?> parameters = const []]) =>
      _timed(sql, () => _inner.get(sql, parameters));

  @override
  Future<sqlite.Row?> getOptional(String sql,
          [List<Object?> parameters = const []]) =>
      _timed(sql, () => _inner.getOptional(sql, parameters));

  @override
  Future<void> executeBatch(String sql, List<List<Object?>> parameterSets) =>
      _timed(sql, () => _inner.executeBatch(sql, parameterSets));

  @override
  Future<void> executeMultiple(String sql) =>
      _timed(sql, () => _inner.executeMultiple(sql));

  @override
  Future<T> writeTransaction<T>(
          Future<T> Function(SqliteWriteContext tx) callback) =>
      _inner.writeTransaction((tx) => callback(TimedWriteContext(tx)));

  // Any member not explicitly proxied above delegates to the inner context.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      (_inner as dynamic).noSuchMethod(invocation);
}
