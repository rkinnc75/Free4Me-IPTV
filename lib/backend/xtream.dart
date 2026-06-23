import 'dart:convert';
import 'dart:io';

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

const String getLiveStreams = "get_live_streams";
const String getVods = "get_vod_streams";
const String getSeries = "get_series";
const String getSeriesInfo = "get_series_info";
const String getSeriesCategories = "get_series_categories";
const String getLiveStreamCategories = "get_live_categories";
const String getVodCategories = "get_vod_categories";
const String liveStreamExtension = "ts";

Future<void> getXtream(
  Source source,
  bool wipe, [
  void Function(String)? onProgress,
  void Function(int done, int total)? onRowProgress,
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
  var results = await Future.wait([
    getXtreamHttpData(getLiveStreams, source),
    getXtreamHttpData(getLiveStreamCategories, source),
    getXtreamHttpData(getVods, source),
    getXtreamHttpData(getVodCategories, source),
    getXtreamHttpData(getSeries, source),
    getXtreamHttpData(getSeriesCategories, source),
  ]);
  int failCount = 0;
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
  if (results[0] != null && results[1] != null) {
    try {
      final streams = processJsonList(results[0], XtreamStream.fromJson);
      liveCount = streams.length;
      onProgress?.call('Loading $liveCount live channels…');
      processXtream(
        contentStatements,
        streams,
        processJsonList(results[1], XtreamCategory.fromJson),
        source,
        MediaType.livestream,
      );
    } catch (e) {
      failCount++;
    }
  } else {
    failCount++;
  }
  if (results[2] != null && results[3] != null) {
    try {
      final vodCats = processJsonList(results[3], XtreamCategory.fromJson);
      var vods = processJsonList(results[2], XtreamStream.fromJson);
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
        vods = await _fetchVodPerCategory(source, vodCats, vods, onProgress);
      }
      movieCount = vods.length;
      onProgress?.call('Loading $movieCount movies…');
      processXtream(
        contentStatements,
        vods,
        vodCats,
        source,
        MediaType.movie,
      );
    } catch (e) {
      failCount++;
    }
  } else {
    failCount++;
  }

  if (results[4] != null && results[5] != null) {
    try {
      final series = processJsonList(results[4], XtreamStream.fromJson);
      seriesCount = series.length;
      onProgress?.call('Loading $seriesCount series…');
      processXtream(
        contentStatements,
        series,
        processJsonList(results[5], XtreamCategory.fromJson),
        source,
        MediaType.serie,
      );
    } catch (e) {
      failCount++;
    }
  } else {
    failCount++;
  }

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
  statements.add(Sql.updateGroups());
  if (preserve != null) {
    statements.add(Sql.restorePreserve(preserve));
  }
  // fix184: detect and persist the provider's connection limit.
  // fix268: also persist the live/movie/series counts from this refresh.
  final mc = await fetchXtreamMaxConnections(source);
  if (source.id != null) {
    if (mc != null) source.maxConnections = mc;
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
    await Sql.updateSource(source);
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
  final swCommit = Stopwatch()..start();
  // fix361/Issue4: suspend FTS triggers around the bulk wipe+reinsert so a
  // large catalog (Dino ~148K rows) doesn't fire per-row FTS maintenance;
  // index rebuilt once afterwards. No-op when no FTS method is active.
  await Sql.withSuspendedFtsTriggers(() async {
    await Sql.commitWriteBatched(
      statements,
      memory: memory,
      onBatchCommitted: onRowProgress == null
          ? null
          : (committedClosures) {
              final approxRows = committedClosures * bulkInsertRows;
              onRowProgress(
                  approxRows > totalRows ? totalRows : approxRows, totalRows);
            },
    );
  }, refreshedSourceId: source.id);
  swCommit.stop();
  AppLog.info('getXtream: DB commit phase for source="${source.name}" '
      'took ${swCommit.elapsedMilliseconds}ms ($totalRows fetched rows)');
}

List<T> processJsonList<T>(
  dynamic jsonData,
  T Function(Map<String, dynamic>) fromJson,
) {
  if (jsonData is! List) return [];
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
    final response = await AppHttp.getWithRetry(url);
    if (response == null) return null;
    // fix222: when debug logging is on, dump the raw response body to a file in
    // the app dir so it can be exported and replayed in a sandbox for true
    // apples-to-apples timing. One file per action+source; overwritten each run.
    if (AppLog.enabled) {
      try {
        final dir = await Utils.appDir;
        final safeAction = action.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
        final f = File('$dir/xtream_dump_${source.id}_$safeAction.json');
        await f.writeAsString(response.body);
        AppLog.info('Xtream: dumped raw response action="$action" '
            'source=${source.id} bytes=${response.body.length} to ${f.path}');
      } catch (e) {
        AppLog.warn('Xtream: raw-dump failed action="$action" error=$e');
      }
    }
    return jsonDecode(response.body);
  } catch (e) {
    AppLog.warn('Xtream: HTTP/JSON failed action="$action" error=$e');
    return null;
  }
}

/// fix184/186: fetch the Xtream account's max_connections from user_info.
/// Returns null on any failure (unknown → caller leaves the limit unset).
Future<int?> fetchXtreamMaxConnections(Source source) async {
  try {
    // Empty action → base player_api.php auth call that returns user_info.
    final data = await getXtreamHttpData('', source);
    if (data is Map && data['user_info'] is Map) {
      final raw = data['user_info']['max_connections'];
      final n = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
      if (n != null && n > 0) {
        AppLog.info(
            'Xtream: source "${source.name}" max_connections=$n');
        return n;
      }
    }
  } catch (e) {
    AppLog.warn(
        'Xtream: max_connections fetch failed for "${source.name}" — $e');
  }
  return null;
}

/// fix388: probe the Xtream server to verify auth.
/// Returns true if the server accepts the credentials (HTTP 200 +
/// user_info.auth == 1). Distinguishes "login failed" from "login
/// OK but provider doesn't report max_connections" — previously the
/// dialog said "Login failed" for any user whose user_info was
/// auth=1 but max_connections was missing or 0 (e.g. A3000/Media4u
/// test users with limited permissions — their user_info reports
/// auth=1 but max_connections=0, which the old
/// fetchXtreamMaxConnections reported as null).
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
    return (data['user_info'] as Map)['auth'] == 1;
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
  void Function(String)? onProgress,
) async {
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
  var episodes = XtreamSeries.fromJson(
    await getXtreamHttpData(getSeriesInfo, source, {
      'series_id': seriesId.toString(),
    }),
  ).episodes;
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
