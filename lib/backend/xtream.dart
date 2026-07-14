import 'dart:convert';
import 'dart:io';
import 'dart:isolate'; // finding 62: off-isolate jsonDecode

import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/xtream_refresh_logic.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/channel_preserve.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/xtream_types.dart';
import 'package:sqlite_async/sqlite_async.dart';
import 'package:open_tv/backend/http_client.dart';
import 'package:open_tv/backend/settings_service.dart';

const String getLiveStreams = "get_live_streams";
const String getVods = "get_vod_streams";
const String getSeries = "get_series";
const String getSeriesInfo = "get_series_info";
const String getSeriesCategories = "get_series_categories";
const String getLiveStreamCategories = "get_live_categories";
const String getVodCategories = "get_vod_categories";
const String liveStreamExtension = "ts";

// finding 66: cap the debug raw-response dump so a large provider catalog
// (hundreds of MB) can't fill the app dir on every refresh.
const int _kMaxDumpBytes = 256 * 1024;

Future<void> getXtream(
  Source source,
  bool wipe, [
  void Function(String)? onProgress,
  void Function(int done, int total)? onRowProgress,
  bool Function()? shouldCancel, // review finding 143
]) async {
  List<Future<void> Function(SqliteWriteContext, Map<String, String>)>
  statements = [];
  List<ChannelPreserve>? preserve;
  // fix376: commit the source row up front (matching m3u.dart:43-44) so
  // source.id is known before the bulk import. Without this, on a FIRST add
  // source.id stayed null, the `if (source.id != null)` count-persistence block
  // below was skipped, and last_live/movie/series_count were never written
  // until a manual refresh. The shared `memory` map is threaded into the
  // batched commit below so the channel inserts (which carry sourceId == -1)
  // still resolve to this id — pulling getOrCreateSourceByName out of the batch
  // means it no longer populates the batch's own map, so we supply it.
  final memory = <String, String>{};
  await Sql.commitWrite(
    [Sql.getOrCreateSourceByName(source)],
    memory: memory,
  );
  source.id = int.parse(memory['sourceId']!);
  if (wipe) {
    preserve = await Sql.getChannelsPreserve(source.id!);
    AppLog.info(
      'Xtream: preserve captured — source="${source.name}"'
      ' epg=${preserve.where((p) => p.epgChannelId != null).length}'
      ' favorites=${preserve.where((p) => p.favorite == 1).length}'
      ' total=${preserve.length}',
    );
    // fix321: the wipe statement is added AFTER the fetch below, once we know
    // which content types came back empty (and should be preserved).
  }
  source.urlOrigin = Uri.parse(source.url!).origin;
  AppLog.info('Xtream: fetching source="${source.name}" url="${source.url}"');
  onProgress?.call('Fetching data from provider…');
  int failCount = 0;
  // fix752: WHICH types failed, not just how many. A failed fetch is not data:
  // these types must be preserved from the wipe regardless of prior state (see
  // XtreamRefreshLogic.typesToKeepOnFetchFailure).
  final failedMediaTypes = <int>{};
  // fix752: set when SOME types failed — surfaced to the caller after the
  // commit succeeds (the fresh types are still written).
  String? partialWarning;
  int liveCount = 0;
  int movieCount = 0;
  int seriesCount = 0;
  // fix321: content insert statements are collected separately so the wipe can
  // be spliced in front of them AFTER we know which types came back empty.
  final contentStatements =
      <Future<void> Function(SqliteWriteContext, Map<String, String>)>[];
  // fix321: media types whose fresh fetch was empty for a source that
  // previously had them (transient provider failure) — their existing rows are
  // preserved rather than wiped.
  final keepMediaTypes = <int>{};
  // finding 62 (MEMORY): the old code did a single six-way Future.wait and held
  // all six decoded JSON trees (live+cats, vod+cats, series+cats) alive at once
  // — on a 400k+ channel source that is the peak Dart heap and a low-memory OS
  // kill risk on a 2 GB box. Fetch each content type in its own sequential pass
  // and let each pass's decoded tree go out of scope (eligible for GC) before
  // the next type is fetched. The two fetches WITHIN a type still run
  // concurrently (streams + categories), matching the provider round-trips of
  // the old code. processXtream buffers the channels into insert closures, so
  // the raw decoded lists are no longer referenced once the pass returns.
  //
  // Each pass increments failCount on a null fetch or a decode/parse throw,
  // exactly as the old results[..]!=null gate + try/catch did, and returns the
  // parsed row count (0 on failure). fix321/fix322 semantics downstream are
  // untouched: liveCount/movieCount/seriesCount and keepMediaTypes feed the same
  // retry/preserve blocks below.
  Future<int> fetchLive() async {
    final res = await Future.wait([
      getXtreamHttpData(getLiveStreams, source),
      getXtreamHttpData(getLiveStreamCategories, source),
    ]);
    if (res[0] == null || res[1] == null) {
      failCount++;
      failedMediaTypes.add(MediaType.livestream.index); // fix752
      return 0;
    }
    try {
      final streams = processJsonList(res[0], XtreamStream.fromJson);
      final count = streams.length;
      onProgress?.call('Loading $count live channels…');
      processXtream(
        contentStatements,
        streams,
        processJsonList(res[1], XtreamCategory.fromJson),
        source,
        MediaType.livestream,
      );
      return count;
    } catch (e) {
      failCount++;
      failedMediaTypes.add(MediaType.livestream.index); // fix752
      return 0;
    }
  }

  Future<int> fetchMovies() async {
    final res = await Future.wait([
      getXtreamHttpData(getVods, source),
      getXtreamHttpData(getVodCategories, source),
    ]);
    if (res[0] == null || res[1] == null) {
      failCount++;
      failedMediaTypes.add(MediaType.movie.index); // fix752
      return 0;
    }
    try {
      final vodCats = processJsonList(res[1], XtreamCategory.fromJson);
      var vods = processJsonList(res[0], XtreamStream.fromJson);
      // fix301: some providers (e.g. trex) cap the unfiltered get_vod_streams
      // response far below their real catalog, while per-category fetches
      // return everything. When the bulk count looks truncated relative to the
      // number of VOD categories, refetch per category_id and merge (dedup by
      // stream_id). Providers that already return the full catalog in one call
      // (emjay, dino) skip this — the heuristic only fires on a short response.
      if (_vodLooksTruncated(vods.length, vodCats.length)) {
        AppLog.info(
          'Xtream.fix301: bulk VOD count ${vods.length} looks short for'
          ' ${vodCats.length} categories — refetching per category',
        );
        vods = await _fetchVodPerCategory(source, vodCats, vods, onProgress,
            shouldCancel: shouldCancel);
      }
      final count = vods.length;
      onProgress?.call('Loading $count movies…');
      processXtream(
        contentStatements,
        vods,
        vodCats,
        source,
        MediaType.movie,
      );
      return count;
    } catch (e) {
      failCount++;
      failedMediaTypes.add(MediaType.movie.index); // fix752
      return 0;
    }
  }

  Future<int> fetchSeries() async {
    final res = await Future.wait([
      getXtreamHttpData(getSeries, source),
      getXtreamHttpData(getSeriesCategories, source),
    ]);
    if (res[0] == null || res[1] == null) {
      failCount++;
      failedMediaTypes.add(MediaType.serie.index); // fix752
      return 0;
    }
    try {
      final series = processJsonList(res[0], XtreamStream.fromJson);
      final count = series.length;
      onProgress?.call('Loading $count series…');
      processXtream(
        contentStatements,
        series,
        processJsonList(res[1], XtreamCategory.fromJson),
        source,
        MediaType.serie,
      );
      return count;
    } catch (e) {
      failCount++;
      failedMediaTypes.add(MediaType.serie.index); // fix752
      return 0;
    }
  }

  // Sequential per-type passes: each type's decoded tree is released before the
  // next type is fetched, bounding peak heap to one content type at a time.
  liveCount = await fetchLive();
  movieCount = await fetchMovies();
  seriesCount = await fetchSeries();

  // fix321: for each content type that came back EMPTY but the source
  // previously had rows for it, retry that one fetch once (transient empties
  // are common at the tail of a long refresh on max_connections=1 providers,
  // especially in background mode). If still empty, preserve the old rows for
  // that type instead of wiping them to zero.
  if (wipe) {
    Future<int> retryType(
      String liveAction,
      String catAction,
      MediaType mediaType,
    ) async {
      AppLog.warn(
        'Xtream.fix321: ${mediaType.name} came back empty for "${source.name}"'
        ' which previously had rows — retrying once',
      );
      final retry = await Future.wait([
        getXtreamHttpData(liveAction, source),
        getXtreamHttpData(catAction, source),
      ]);
      if (retry[0] == null || retry[1] == null) return 0;
      try {
        final streams = processJsonList(retry[0], XtreamStream.fromJson);
        if (streams.isEmpty) return 0;
        processXtream(
          contentStatements,
          streams,
          processJsonList(retry[1], XtreamCategory.fromJson),
          source,
          mediaType,
        );
        return streams.length;
      } catch (_) {
        return 0;
      }
    }

    if (XtreamRefreshLogic.shouldRetryType(
        count: liveCount, lastCount: source.lastLiveCount)) {
      liveCount = await retryType(
          getLiveStreams, getLiveStreamCategories, MediaType.livestream);
      if (liveCount == 0) {
        keepMediaTypes.add(MediaType.livestream.index);
      } else {
        // fix322: retry recovered this type — undo the initial failCount so a
        // successful retry can't leave us at the 3/3 throw with real data in
        // hand (observed: Z2U recovered on retry but was still thrown away).
        failCount = XtreamRefreshLogic.reconcileFailCount(failCount);
      }
    }
    if (XtreamRefreshLogic.shouldRetryType(
        count: movieCount, lastCount: source.lastMovieCount)) {
      movieCount =
          await retryType(getVods, getVodCategories, MediaType.movie);
      if (movieCount == 0) {
        keepMediaTypes.add(MediaType.movie.index);
      } else {
        failCount = XtreamRefreshLogic.reconcileFailCount(failCount);
      }
    }
    if (XtreamRefreshLogic.shouldRetryType(
        count: seriesCount, lastCount: source.lastSeriesCount)) {
      seriesCount =
          await retryType(getSeries, getSeriesCategories, MediaType.serie);
      if (seriesCount == 0) {
        keepMediaTypes.add(MediaType.serie.index);
      } else {
        failCount = XtreamRefreshLogic.reconcileFailCount(failCount);
      }
    }
    // finding 63: shouldRetryType only fires when lastCount>0, so a type whose
    // recorded last_*_count is NULL/0 never retries AND is never preserved — a
    // transient empty fetch would then wipe its existing rows. Drive the
    // keep/preserve decision off whether rows ACTUALLY exist in the DB, not off
    // the possibly-stale last_*_count column, so NULL/0-lastCount sources are
    // protected too. (This is independent of the retry above, which still helps
    // recover the lastCount>0 case.)
    if (source.id != null) {
      Future<void> preserveIfEmptyButHasRows(int count, MediaType t) async {
        if (count == 0 &&
            !keepMediaTypes.contains(t.index) &&
            await Sql.sourceHasMediaType(source.id!, t)) {
          keepMediaTypes.add(t.index);
        }
      }

      await preserveIfEmptyButHasRows(liveCount, MediaType.livestream);
      await preserveIfEmptyButHasRows(movieCount, MediaType.movie);
      await preserveIfEmptyButHasRows(seriesCount, MediaType.serie);
    }
    // fix752: a type whose fetch FAILED is preserved from the wipe regardless
    // of prior state. The three guards above all key off prior state (retry
    // needs lastCount>0; preserve needs existing rows; the throw needs 3/3),
    // and ALL of them are defeated once an interrupted refresh has already
    // emptied the source — which is exactly how 55,325 live channels stayed
    // gone on 2026-07-14. A failed fetch is not data, so it must never be
    // committed as "empty" and must never contribute to a wipe.
    keepMediaTypes
        .addAll(XtreamRefreshLogic.typesToKeepOnFetchFailure(failedMediaTypes));
    if (keepMediaTypes.isNotEmpty) {
      AppLog.warn(
        'Xtream.fix321: preserving existing rows for media types '
        '${keepMediaTypes.toList()} on "${source.name}" '
        '(fetch still empty after retry)',
      );
    }
    // Splice the wipe (honouring preserved types) in front of the content
    // inserts captured above.
    statements.add(Sql.wipeSource(source.id!, keepMediaTypes: keepMediaTypes));
  }
  statements.addAll(contentStatements);

  // fix322: only treat this as a hard failure when every content type failed
  // AND none of them were preserved from a prior refresh. If fix321 preserved
  // existing rows for the empty types (source had prior data), the refresh is
  // a successful no-op for those types — keep the old catalogue, don't throw a
  // scary error or abort the commit of any type that did come back.
  final everythingFailedWithNothingToKeep =
      XtreamRefreshLogic.shouldThrowAllFailed(
          failCount: failCount, keepMediaTypes: keepMediaTypes);
  if (everythingFailedWithNothingToKeep) {
    AppLog.warn(
      'Xtream: fetch failed source="${source.name}"'
      ' error=all content types failed ($failCount/3)',
    );
    throw Exception(
      "Failed to fetch source: all content types failed ($failCount/3)",
    );
  }
  if (failCount >= 3 && keepMediaTypes.isNotEmpty) {
    AppLog.warn(
      'Xtream: all fresh fetches empty for source="${source.name}" but '
      'existing rows preserved (${keepMediaTypes.toList()}) — keeping prior '
      'catalogue, not treating as failure',
    );
  }
  AppLog.info(
    'Xtream: fetched source="${source.name}"'
    ' live=$liveCount movies=$movieCount series=$seriesCount'
    '${keepMediaTypes.isEmpty ? '' : ' (preserved: ${keepMediaTypes.toList()})'}',
  );
  // fix752: a PARTIAL refresh (some types fetched, others failed) still
  // commits — the successful types are legitimately fresh — but the user must
  // be told, or a provider hiccup silently leaves a stale/empty catalogue
  // looking like a successful refresh. Thrown AFTER the commit statements are
  // assembled but reported by the caller once the write completes.
  if (XtreamRefreshLogic.isPartialRefresh(
      failedMediaTypes: failedMediaTypes, typeCount: 3)) {
    final names = failedMediaTypes
        .map((i) => const {0: 'Live channels', 1: 'Movies', 2: 'Series'}[i] ??
            'Content')
        .join(', ');
    partialWarning = '$names could not be fetched — existing content kept. '
        'Check the provider and refresh again (a max_connections=1 line can '
        'fail this call while a stream is playing).';
    AppLog.warn('Xtream.fix752: PARTIAL refresh source="${source.name}" — '
        'failed types=${failedMediaTypes.toList()} preserved from wipe');
  }
  statements.add(Sql.updateGroups());
  if (preserve != null) {
    statements.add(Sql.restorePreserve(preserve));
  }
  // fix184: detect and persist the provider's connection limit.
  // fix268: also persist the live/movie/series counts from this refresh.
  // fix641: the same player_api.php user_info response also carries exp_date +
  // status, so fetch all three in one call and persist them.
  final info = await fetchXtreamAccountInfo(source);
  if (source.id != null) {
    if (info.maxConnections != null) {
      source.maxConnections = info.maxConnections;
    }
    // fix641: record expiry + status (null = unknown; leave prior value).
    if (info.expDate != null) source.expDate = info.expDate;
    if (info.status != null) source.status = info.status;
    // fix321: for preserved types the fresh count is 0 but the old rows remain,
    // so keep the previous count rather than recording 0.
    if (!keepMediaTypes.contains(MediaType.livestream.index)) {
      source.lastLiveCount = liveCount;
    }
    if (!keepMediaTypes.contains(MediaType.movie.index)) {
      source.lastMovieCount = movieCount;
    }
    if (!keepMediaTypes.contains(MediaType.serie.index)) {
      source.lastSeriesCount = seriesCount;
    }
    // fix641: auto-disable an expired/banned line. Trust an explicit bad
    // status; otherwise fall back to the epoch (present, non-zero, past UTC).
    // A null/0 exp_date is NEVER treated as expired (lifetime lines report
    // that). Channels just fetched are kept — only the source is disabled — so
    // the user can still see (stale) content and re-enable after renewing.
    if (source.enabled && isSourceExpired(source)) {
      source.enabled = false;
      AppLog.warn('Xtream: source "${source.name}" auto-disabled — '
          'status=${source.status} exp_date=${source.expDate} '
          '(expired subscription)');
      onProgress?.call('Subscription expired — source disabled');
      // updateSource() below does NOT write `enabled` (that's setSourceEnabled's
      // job), so persist the disable explicitly.
      await Sql.setSourceEnabled(false, source.id!);
    }
    // finding 64: updateSource (counts/maxConnections/expDate/status) is moved
    // to AFTER the commit below, so lastLiveCount/lastMovieCount/lastSeriesCount
    // are only persisted once the wipe+inserts+restorePreserve have committed.
    // A crash mid-commit then leaves the OLD counts, so fix321/shouldRetryType
    // still sees lastCount>0 on retry and the preserve path fires.
  }
  onProgress?.call('Saving to database…');
  final totalRows = liveCount + movieCount + seriesCount;
  // fix204: instrumentation only. Log statement composition + commit duration
  // so the refresh log isolates the DB-write phase (the wipe→restore gap).
  AppLog.info('getXtream: committing ${statements.length} statement-closures '
      'for source="${source.name}" totalRows=$totalRows');
  // fix222: one-shot EXPLAIN QUERY PLAN for the index-sensitive refresh
  // statements (does not run per row; pure diagnostic).
  if (source.id != null) {
    await Sql.logRefreshQueryPlans(source.id!);
  }
  // Review finding 143: a cancel during download skips the write entirely for
  // the in-flight source (recoverable — next refresh wipes+reinserts).
  if (shouldCancel?.call() ?? false) {
    onProgress?.call('Cancelled');
    AppLog.info('getXtream: cancelled before write phase'
        ' source="${source.name}"');
    return;
  }
  final swCommit = Stopwatch()..start();
  // Review finding 142: browse-index drop now wraps ONLY this DB-write phase
  // (was around the whole fetch dispatch in Utils.processSource), so on the
  // single-source path browse stays indexed through the entire download.
  // Re-entrant — a pass-through during a batch refresh. Nested OUTSIDE
  // withSuspendedFtsTriggers to preserve the single-source ordering the
  // fix521/fix518 wrappers expect.
  await Sql.withDroppedBrowseIndexes(() async {
  // fix361/Issue4: suspend FTS triggers around the bulk wipe+reinsert so a
  // large catalog (Dino ~148K rows) doesn't fire per-row FTS maintenance;
  // index rebuilt once afterwards. No-op when no FTS method is active.
  await Sql.withSuspendedFtsTriggers(() async {
    await Sql.commitWriteBatched(
      statements,
      memory: memory,
      shouldCancel: shouldCancel, // review finding 143
      onBatchCommitted: onRowProgress == null
          ? null
          : (committedClosures) {
              final approxRows = committedClosures * bulkInsertRows;
              onRowProgress(
                  approxRows > totalRows ? totalRows : approxRows, totalRows);
            },
    );
  }, refreshedSourceId: source.id);
  }, onProgress: onProgress);
  swCommit.stop();
  AppLog.info('getXtream: DB commit phase for source="${source.name}" '
      'took ${swCommit.elapsedMilliseconds}ms ($totalRows fetched rows)');
  // finding 64: persist source counts/status ONLY after a successful commit.
  // If commitWriteBatched threw above we never reach here, so the old counts
  // survive and the retry preserve path stays protected. Residual risk: a
  // single commit is still split at importBatchSize so process death mid-commit
  // can leave a partial catalog — a shadow/generation column is a larger
  // follow-up, not done here.
  if (source.id != null) {
    await Sql.updateSource(source);
  }
  // fix752: everything that WAS fetched is now committed, and the failed types
  // kept their previous rows — the data is safe. Only now surface the partial
  // failure, so the caller can warn the user. Silently reporting success here
  // is what let an empty catalogue masquerade as a completed refresh
  // (2026-07-14): the user saw "refresh complete" and no channels.
  if (partialWarning != null) {
    throw XtreamPartialRefreshException(partialWarning);
  }
}

/// fix752: thrown AFTER a successful commit when some content types could not
/// be fetched. Everything retrieved WAS written and the failed types kept
/// their existing rows — this is a warning, not a data-loss error, and callers
/// must render it as such rather than treating the whole refresh as failed.
class XtreamPartialRefreshException implements Exception {
  final String message;
  XtreamPartialRefreshException(this.message);
  @override
  String toString() => message;
}

List<T> processJsonList<T>(
  dynamic jsonData,
  T Function(Map<String, dynamic>) fromJson,
) {
  // finding 65: an HTTP-200 non-array body (auth error object, HTML,
  // {user_info:{auth:0}}) is a provider failure, NOT a legitimately empty
  // content type. Log the shape and throw so the caller's catch increments
  // failCount and the preserve/retry path runs. A genuine empty array ([])
  // still returns [] below.
  if (jsonData is! List) {
    AppLog.warn('Xtream.processJsonList: expected a JSON array but got '
        '${jsonData.runtimeType}'
        '${jsonData is Map ? ' keys=${jsonData.keys.take(5).toList()}' : ''}');
    throw const FormatException('Xtream response was not a JSON array');
  }
  return jsonData
      .map((json) => fromJson(json as Map<String, dynamic>))
      .toList();
}

Future<dynamic> getXtreamHttpData(
  String action,
  Source source, [
  Map<String, String>? extraQueryParams,
]) async {
  try {
    final url = buildXtreamUrl(source, action, extraQueryParams);
    // fix614: honour the user-tunable import fetch timeout (default 60s).
    // SettingsService.cached is populated at startup; fall back to a fresh load
    // if somehow null. 0 means "use AppHttp's own default".
    final settings =
        SettingsService.cached ?? await SettingsService.getSettings();
    final timeoutSecs = settings.devImportFetchTimeoutSecs;
    // Review finding 150: distinguish PERMANENT auth failures (401/403/407)
    // from transient network/timeout — a rejected line must surface as
    // disabled/expired instead of silently preserving a stale catalog forever.
    HttpFailureKind? failKind;
    final response = await AppHttp.getWithRetry(
      url,
      timeout: timeoutSecs > 0
          ? Duration(seconds: timeoutSecs)
          : const Duration(seconds: 20),
      onFailure: (k, sc) => failKind = k,
    );
    if (response == null) {
      if (failKind == HttpFailureKind.authRejected) {
        AppLog.warn('Xtream: credentials REJECTED (auth) action="$action" '
            'source="${source.name}" — flagging source disabled');
        // Reuses the existing Source.status field; isSourceExpired() already
        // treats 'disabled' as expired, so the guide/UI surfaces the dead line
        // with no new plumbing. (An auth reject means the account-info call
        // also 401s, so a later user_info fetch cannot clobber this back.)
        source.status = 'disabled';
      }
      return null;
    }
    // fix222: when debug logging is on, dump the raw response body to a file in
    // the app dir so it can be exported and replayed in a sandbox for true
    // apples-to-apples timing. One file per action+source; overwritten each run.
    if (AppLog.enabled) {
      try {
        final dir = await Utils.appDir;
        final safeAction = action.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
        // finding 66: cap the dump to the first 256 KB (enough to diagnose the
        // JSON shape) so a huge catalog body doesn't write hundreds of MB.
        final body = response.body;
        final dump = body.length > _kMaxDumpBytes
            ? '${body.substring(0, _kMaxDumpBytes)}'
                '\n/*…truncated ${body.length - _kMaxDumpBytes} bytes…*/'
            : body;
        final f = File('$dir/xtream_dump_${source.id}_$safeAction.json');
        await f.writeAsString(dump);
        AppLog.info('Xtream: dumped raw response action="$action" '
            'source=${source.id} bytes=${body.length} (capped to '
            '${dump.length}) to ${f.path}');
      } catch (e) {
        AppLog.warn('Xtream: raw-dump failed action="$action" error=$e');
      }
    }
    // finding 62 (UI-BLOCK): a large provider catalog (400k+ channels) decodes
    // to tens of MB of JSON; running jsonDecode synchronously on the UI/root
    // isolate stalls the refresh progress dialog for seconds. Offload the decode
    // to a worker isolate (same pattern the repo uses elsewhere). Isolate.run is
    // preferred over flutter `compute` to avoid a Flutter dependency in this
    // backend file. The return type stays `dynamic`, so every caller
    // (fetchXtreamAccountInfo, checkXtreamAuth, getEpisodes, the fix321 retry
    // Future.wait, _fetchVodPerCategory) is unaffected.
    final bodyStr = response.body;
    return await Isolate.run(() => jsonDecode(bodyStr));
  } catch (e) {
    AppLog.warn('Xtream: HTTP/JSON failed action="$action" error=$e');
    return null;
  }
}

// finding 67: the old max_connections-only probe was dead code (no callers) —
// removed. max_connections is now pulled via fetchXtreamAccountInfo below.

/// fix641: account info pulled from a single player_api.php user_info response
/// — max_connections (fix184), plus exp_date + status. Each field is null when
/// not reported or on any failure, so the caller keeps prior values.
typedef XtreamAccountInfo = ({int? maxConnections, int? expDate, String? status});

Future<XtreamAccountInfo> fetchXtreamAccountInfo(Source source) async {
  try {
    // Empty action → base player_api.php auth call that returns user_info.
    final data = await getXtreamHttpData('', source);
    if (data is Map && data['user_info'] is Map) {
      final ui = data['user_info'] as Map;
      final rawMc = ui['max_connections'];
      final mc = rawMc is int ? rawMc : int.tryParse(rawMc?.toString() ?? '');
      final rawExp = ui['exp_date'];
      final exp = rawExp is int ? rawExp : int.tryParse(rawExp?.toString() ?? '');
      final st = ui['status']?.toString();
      AppLog.info('Xtream: source "${source.name}" account info '
          'max_connections=$mc exp_date=$exp status=$st');
      return (
        maxConnections: (mc != null && mc > 0) ? mc : null,
        expDate: (exp != null && exp > 0) ? exp : null,
        status: (st != null && st.trim().isNotEmpty) ? st : null,
      );
    }
  } catch (e) {
    AppLog.warn(
        'Xtream: account info fetch failed for "${source.name}" — $e');
  }
  return (maxConnections: null, expDate: null, status: null);
}

/// fix641: whether a source's subscription is expired. Trusts an explicit bad
/// [status] first; otherwise uses [expDate] (present, non-zero, past UTC). A
/// null/0 exp_date is NEVER expired — lifetime lines report that.
bool isSourceExpired(Source source) {
  final st = source.status?.trim().toLowerCase();
  if (st != null &&
      (st == 'expired' || st == 'banned' || st == 'disabled')) {
    return true;
  }
  final exp = source.expDate;
  if (exp != null && exp > 0) {
    final expiresUtc = DateTime.fromMillisecondsSinceEpoch(exp * 1000,
        isUtc: true);
    return expiresUtc.isBefore(DateTime.now().toUtc());
  }
  return false;
}

/// fix388: probe the Xtream server to verify auth.
/// Returns true if the server accepts the credentials (HTTP 200 +
/// user_info.auth == 1). Distinguishes "login failed" from "login
/// OK but provider doesn't report max_connections" — previously the
/// dialog said "Login failed" for any user whose user_info was
/// auth=1 but max_connections was missing or 0 (e.g. A3000/Media4u
/// test users with limited permissions — their user_info reports
/// auth=1 but max_connections=0, which the old
/// max_connections-only probe reported as null).
Future<bool> checkXtreamAuth(Source source) async {
  try {
    final data = await getXtreamHttpData('', source);
    return parseXtreamAuthResponse(data);
  } catch (e) {
    AppLog.warn('Xtream: test auth failed for "${source.name}" — $e');
    return false;
  }
}

/// fix388: pure parser for the Xtream test probe response. Exposed
/// for unit testing; the dialog's [checkXtreamAuth] is the public
/// entry point but tests can exercise this directly.
bool parseXtreamAuthResponse(dynamic data) {
  if (data is Map && data['user_info'] is Map) {
    // finding 68: coerce string/bool auth values — panels return auth as int 1,
    // string "1", or bool true. auth==0 (int or string) still returns false.
    final a = (data['user_info'] as Map)['auth'];
    return a == 1 || a == '1' || a == true;
  }
  return false;
}

// fix299: derive a clean category-name prefix from a stream name. Splits on the
// first '|', then collapses a trailing feed-number tail like "(Peacock 016)" to
// "(Peacock)" so numbered feeds of one category share a prefix instead of
// fragmenting into one tile per feed.
String _categoryPrefix(String name) {
  var p = name.contains('|') ? name.split('|').first.trim() : name.trim();
  // "US (Peacock 016)" -> "US (Peacock)"; "Foo (Bar)" stays "Foo (Bar)".
  p = p
      .replaceAllMapped(
        RegExp(r'\s*\(([^)]*?)\s+\d+\)\s*$'),
        (m) => ' (${m[1]})',
      )
      .trim();
  return p;
}

// fix299: for every category_id referenced by a stream but missing from
// [catsMap], pick the dominant [_categoryPrefix] among that category's streams
// and add it to [catsMap] as the synthetic name. Streams whose name has no
// usable prefix fall back to "Category <id>". Mutates [catsMap] in place.
void _resolveMissingCategories(
  List<XtreamStream> streams,
  Map<String, String> catsMap,
) {
  // categoryId -> (prefix -> count)
  final prefixCounts = <String, Map<String, int>>{};
  for (final s in streams) {
    final cid = s.categoryId ?? "";
    if (cid.isEmpty || catsMap.containsKey(cid)) continue;
    final name = s.name?.trim() ?? "";
    if (name.isEmpty) continue;
    final prefix = _categoryPrefix(name);
    if (prefix.isEmpty) continue;
    (prefixCounts[cid] ??= <String, int>{})
        .update(prefix, (c) => c + 1, ifAbsent: () => 1);
  }
  for (final entry in prefixCounts.entries) {
    String? best;
    int bestCount = -1;
    entry.value.forEach((prefix, count) {
      if (count > bestCount) {
        best = prefix;
        bestCount = count;
      }
    });
    catsMap[entry.key] = best ?? 'Category ${entry.key}';
  }
  if (AppLog.enabled && prefixCounts.isNotEmpty) {
    AppLog.info(
      'Xtream.fix299: synthesized ${prefixCounts.length} missing'
      ' category name(s) from stream prefixes',
    );
  }
}

// fix301: heuristic for a truncated bulk get_vod_streams response. Fires only
// when the provider lists many VOD categories but returned very few movies —
// an average well below what a real catalog of that many categories holds.
// Tuned to avoid firing on small/legit providers: needs >20 categories AND an
// average of fewer than 15 movies per category.
bool _vodLooksTruncated(int movieCount, int categoryCount) {
  if (categoryCount <= 20) return false;
  return movieCount < categoryCount * 15;
}

// fix301: refetch VOD per category_id and merge with the bulk result, deduped
// by stream_id. Returns the merged list. On a category fetch failure, that
// category is skipped (best-effort — we keep whatever we got).
Future<List<XtreamStream>> _fetchVodPerCategory(
  Source source,
  List<XtreamCategory> vodCats,
  List<XtreamStream> bulk,
  void Function(String)? onProgress, {
  bool Function()? shouldCancel, // review finding 143
}) async {
  final byId = <String, XtreamStream>{};
  void add(XtreamStream s) {
    final id = s.streamId;
    if (id != null && id.isNotEmpty) byId[id] = s;
  }

  for (final s in bulk) {
    add(s);
  }
  var done = 0;
  for (final cat in vodCats) {
    // Review finding 143: mid-source cancel — stop issuing per-category HTTP
    // calls; the partial collection is treated like any truncated fetch.
    if (shouldCancel?.call() ?? false) break;
    final cid = cat.categoryId;
    if (cid == null || cid.isEmpty) continue;
    final raw =
        await getXtreamHttpData(getVods, source, {'category_id': cid});
    if (raw != null) {
      try {
        for (final s in processJsonList(raw, XtreamStream.fromJson)) {
          add(s);
        }
      } catch (_) {
        // skip a malformed category response
      }
    }
    done++;
    if (done % 25 == 0) {
      onProgress?.call('Loading movies… ${byId.length} so far');
    }
  }
  return byId.values.toList(growable: false);
}

void processXtream(
  List<Future<void> Function(SqliteWriteContext, Map<String, String>)>
  statements,
  List<XtreamStream> streams,
  List<XtreamCategory> cats,
  Source source,
  MediaType mediaType,
) {
  Map<String, String> catsMap = Map.fromEntries(
    cats.map(
      (x) => MapEntry(x.categoryId ?? "", x.categoryName ?? "Unknown Category"),
    ),
  );
  // fix299: some providers reference category_ids on streams that are absent
  // from get_*_categories. Those channels would otherwise get a null group and
  // become invisible/un-enable-able on the Categories screen. Synthesize a name
  // for each missing category from the dominant cleaned name-prefix of its
  // streams (grouping stays whole because all streams of that category get the
  // same synthetic name; same-prefix orphans merge into one tile by design).
  _resolveMissingCategories(streams, catsMap);
  // fix174.3: buffer channels into bulk-insert closures
  final buffer = <Channel>[];
  void flush() {
    if (buffer.isEmpty) return;
    statements.add(Sql.insertChannelsBulk(List<Channel>.from(buffer)));
    buffer.clear();
  }
  for (var live in streams) {
    if (live.name == null || live.name!.trim().isEmpty) continue;
    // fix546: discard "##### HEADER #####" divider entries at import so they
    // never enter the DB. They were cosmetic separators with no playable URL;
    // dropping them removes ~2.5k junk rows on a large catalog and lets the
    // browse queries drop their per-row is_divider/hide_dividers filter.
    if (Channel.nameIsDivider(live.name)) continue;
    if (mediaType == MediaType.serie) {
      if (live.seriesId == null || live.seriesId!.isEmpty) continue;
    } else {
      if (live.streamId == null || live.streamId!.isEmpty) continue;
    }
    var cname = catsMap[live.categoryId ?? ""];
    try {
      var channel = xtreamToChannel(live, source, mediaType, cname);
      buffer.add(channel);
      if (buffer.length >= bulkInsertRows) flush();
    } catch (e) {
      if (AppLog.enabled) {
        AppLog.warn(
          'Xtream: skipped malformed stream'
          ' streamId="${live.streamId}" name="${live.name}" error=$e',
        );
      }
    }
  }
  flush();
}

Channel xtreamToChannel(
  XtreamStream stream,
  Source source,
  MediaType streamType,
  String? categoryName,
) {
  // with type "xc" so catchup_url.dart knows to build the Xtream-style
  // /streaming/timeshift.php URL on the fly.
  final isLive = streamType == MediaType.livestream;
  final hasCatchup = isLive && stream.hasCatchup;

  return Channel(
    name: stream.name!.trim(),
    mediaType: streamType,
    sourceId: -1,
    favorite: false,
    // fix320: providers occasionally return a stream with a null category_id,
    // which would otherwise create a nameless group (null group_name). Default
    // to "Uncategorized" so the channel stays browsable and groups never carry
    // a null name (which crashed wipeSource).
    group: categoryName ?? 'Uncategorized',
    image: stream.streamIcon?.trim() ?? stream.cover?.trim(),
    url: streamType == MediaType.serie
        ? (stream.seriesId ?? "").toString()
        : getUrl(
            stream.streamId?.trim(),
            source,
            streamType,
            stream.containerExtension,
          ),
    streamId: int.tryParse(stream.streamId ?? "") ?? -1,
    catchupType: hasCatchup ? 'xc' : null,
    catchupDays: hasCatchup ? stream.tvArchiveDuration : null,
    providerOrder: stream.providerNum, // fix256: preserve provider display order
    isDivider: Channel.nameIsDivider(stream.name), // fix272
    isAdult: stream.isAdult == 1 ||
        Channel.nameIsAdult(stream.name, categoryName), // fix300
  );
}

String getUrl(
  String? streamId,
  Source source,
  MediaType streamType,
  String? extension,
) {
  return "${source.urlOrigin}/${getXtreamMediaTypeStr(streamType)}/${source.username}/${source.password}/$streamId.${extension ?? liveStreamExtension}";
}

String getXtreamMediaTypeStr(MediaType type) {
  switch (type) {
    case MediaType.livestream:
      return "live";
    case MediaType.movie:
      return "movie";
    case MediaType.serie:
      return "series";
    default:
      return "";
  }
}

Uri buildXtreamUrl(
  Source source,
  String action, [
  Map<String, String>? extraQueryParams,
]) {
  var params = {
    'username': source.username,
    'password': source.password,
    'action': action,
  };
  if (extraQueryParams != null) {
    params.addAll(extraQueryParams);
  }
  var url = Uri.parse(source.url!).replace(queryParameters: params);
  return url;
}

Future<void> getEpisodes(Channel channel) async {
  List<Future<void> Function(SqliteWriteContext, Map<String, String>)>
  statements = [];
  var seriesId = int.parse(channel.url!);
  var source = await Sql.getSourceFromId(channel.sourceId);
  source.urlOrigin = Uri.parse(source.url!).origin;
  // finding 69: null-check the response before fromJson (its param type is
  // non-nullable Map<String,dynamic>). `is! Map<String, dynamic>` also guards
  // the finding-65 case where the provider returns a 200 non-Map error body.
  // The thrown Exception surfaces as a readable message instead of a raw
  // TypeError via channel_tile's Error.tryAsync.
  final seriesData = await getXtreamHttpData(getSeriesInfo, source, {
    'series_id': seriesId.toString(),
  });
  if (seriesData is! Map<String, dynamic>) {
    throw Exception(
        'Could not load episodes — provider unreachable or returned no data');
  }
  var episodes = XtreamSeries.fromJson(seriesData).episodes;
  episodes.sort((a, b) {
    int seasonA = int.tryParse(a.season ?? "") ?? 0;
    int seasonB = int.tryParse(b.season ?? "") ?? 0;
    int seasonComparison = seasonA.compareTo(seasonB);
    if (seasonComparison != 0) {
      return seasonComparison;
    }
    int epA = int.tryParse(a.episodeNum ?? "") ?? 0;
    int epB = int.tryParse(b.episodeNum ?? "") ?? 0;
    return epA.compareTo(epB);
  });
  for (var episode in episodes) {
    if (episode.title == null || episode.title!.trim().isEmpty) continue;
    if (episode.id == null || episode.id!.isEmpty) continue;
    try {
      statements.add(
        Sql.insertChannel(episodeToChannel(episode, source, seriesId)),
      );
    } catch (e) {
      if (AppLog.enabled) {
        AppLog.warn(
          'Xtream: skipped malformed episode'
          ' id="${episode.id}" title="${episode.title}" error=$e',
        );
      }
    }
  }
  await Sql.commitWrite(statements);
}


Channel episodeToChannel(XtreamEpisode episode, Source source, int seriesId) {
  return Channel(
    image: episode.info?.movieImage,
    mediaType: MediaType.movie,
    name: episode.title!.trim(),
    sourceId: source.id!,
    favorite: false,
    url: getUrl(
      episode.id,
      source,
      MediaType.serie,
      episode.containerExtension,
    ),
    seriesId: seriesId,
  );
}
