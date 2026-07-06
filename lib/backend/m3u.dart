import 'dart:convert';
import 'dart:io';

import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/sql.dart' show Sql, importBatchSize, bulkInsertRows;
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/channel_http_headers.dart';
import 'package:open_tv/models/channel_preserve.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/source.dart';
import 'package:sqlite_async/sqlite_async.dart';
import 'package:http/http.dart' as http;
import 'package:open_tv/backend/http_client.dart';

final nameRegex = RegExp(r'tvg-name="([^"]*)"');
// finding 83: capture everything after the FIRST comma (the display title may
// itself contain commas, e.g. "Cosmos, A Spacetime Odyssey"); firstMatch binds
// to the leftmost comma so no-comma titles are unchanged.
final nameRegexAlt = RegExp(r',(.+)$');
final idRegex = RegExp(r'tvg-id="([^"]*)"');
final logoRegex = RegExp(r'tvg-logo="([^"]*)"');
final groupRegex = RegExp(r'group-title="([^"]*)"');
final httpOriginRegex = RegExp(r'http-origin=(.+)');
final httpReferrerRegex = RegExp(r'http-referrer=(.+)');
final httpUserAgentRegex = RegExp(r'http-user-agent=(.+)');

final catchupTypeRegex = RegExp(r'catchup="([^"]*)"');
final catchupSourceRegex = RegExp(r'catchup-source="([^"]*)"');
final catchupDaysRegex = RegExp(r'catchup-days="([^"]*)"');

Future<void> processM3U(
  Source source,
  bool wipe, [
  String? path,
  void Function(String)? onProgress,
]) async {
  path ??= source.url;
  List<ChannelPreserve>? preserve;
  final memory = <String, String>{};
  AppLog.info(
    'M3U: processing source="${source.name}"'
    ' wipe=$wipe path="${path ?? source.url}"',
  );
  onProgress?.call('Connecting…');
  await Sql.commitWrite([Sql.getOrCreateSourceByName(source)], memory: memory);
  final sourceId = int.parse(memory['sourceId']!);
  source.id = sourceId;
  // finding 78: capture preserve, but DO NOT wipe up front. A transient/empty/
  // HTML/truncated download would otherwise permanently destroy the catalog +
  // favorites. The wipe is deferred and spliced in front of the inserts (one
  // atomic transaction) only after a plausible non-zero count is confirmed.
  if (wipe) {
    preserve = await Sql.getChannelsPreserve(sourceId);
    AppLog.info(
      'M3U: preserve captured — source="${source.name}"'
      ' epg=${preserve.where((p) => p.epgChannelId != null).length}'
      ' favorites=${preserve.where((p) => p.favorite == 1).length}'
      ' total=${preserve.length}',
    );
  }

  // finding 78: allowMalformed so a single bad byte mid-stream doesn't abort
  // the whole parse (and drop every surrounding valid channel).
  var file = File(path!)
      .openRead()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());

  // finding 78/79: accumulate every insert closure WITHOUT committing during
  // the parse, so the deferred wipe can be gated on the final parsed count and
  // made atomic with the inserts. finding 79: plain channels go through
  // insertChannelsBulk (1000 rows/statement, no per-row last_insert_rowid);
  // only a header-bearing channel uses insertChannel (its header row needs the
  // rowid). M3U playlists are small (the 450k catalog case is Xtream, handled
  // in xtream.dart), so holding the bulk closures here is fine.
  final contentStatements =
      <Future<void> Function(SqliteWriteContext, Map<String, String>)>[];
  final channelBuffer = <Channel>[];
  var channelCount = 0;
  // fix256: provider order for M3U = line sequence (the playlist's intended
  // order, the M3U analogue of Xtream's `num`).
  var order = 0;

  void flushChannelBuffer() {
    if (channelBuffer.isEmpty) return;
    contentStatements.add(Sql.insertChannelsBulk(List<Channel>.from(channelBuffer)));
    channelBuffer.clear();
  }

  void emitChannel(String l1, String last, ChannelHttpHeaders? headers) {
    final channel = getChannelFromLines(l1, last, order);
    if (channel == null) return;
    // fix546: discard "##### HEADER #####" divider entries at import.
    if (channel.isDivider) return;
    order++;
    channelCount++;
    if (headers != null) {
      // finding 79: flush the bulk buffer first so provider_order stays
      // contiguous and insertChannelHeaders sees this channel's rowid as the
      // immediately-preceding INSERT.
      flushChannelBuffer();
      contentStatements.add(Sql.insertChannel(channel));
      contentStatements.add(Sql.insertChannelHeaders(headers));
    } else {
      channelBuffer.add(channel);
      if (channelBuffer.length >= bulkInsertRows) flushChannelBuffer();
    }
  }

  String? lastLine;
  String? channelLine;
  ChannelHttpHeaders? headers;
  var httpHeadersSet = false;
  await for (var line in file) {
    final lineUpper = line.toUpperCase();
    if (lineUpper.startsWith("#EXTINF")) {
      if (channelLine != null &&
          lastLine != null &&
          lastLine.trim().isNotEmpty) {
        emitChannel(channelLine, lastLine, httpHeadersSet ? headers : null);
        if (channelCount % importBatchSize == 0) {
          onProgress?.call('Parsing channels: $channelCount…');
        }
      }
      channelLine = line;
      lastLine = null;
      httpHeadersSet = false;
      headers = null;
    } else if (lineUpper.startsWith("#EXTVLCOPT")) {
      headers ??= ChannelHttpHeaders();
      if (setChannelHeaders(line, headers)) {
        httpHeadersSet = true;
      }
    } else {
      // finding 84: only a bare, non-'#' line is the channel URL — a directive
      // or comment line after the URL must never overwrite it (the M3U spec has
      // no non-'#' directive, so skipping all remaining '#' lines is correct).
      final t = line.trim();
      if (t.isNotEmpty && !t.startsWith('#')) {
        lastLine = t;
      }
    }
  }
  if (channelLine != null && lastLine != null && lastLine.trim().isNotEmpty) {
    emitChannel(channelLine, lastLine, httpHeadersSet ? headers : null);
  }
  flushChannelBuffer();

  // finding 78: count gate — refuse to wipe/replace when the parse produced
  // nothing plausible, so a failed/empty/HTML/truncated download keeps the
  // existing catalog + favorites instead of destroying them.
  if (channelCount == 0) {
    AppLog.warn(
      'M3U: parsed 0 channels for source="${source.name}" — keeping existing '
      'catalog (download likely empty/HTML/failed)',
    );
    return;
  }
  if (wipe &&
      source.lastLiveCount != null &&
      source.lastLiveCount! > 100 &&
      channelCount < source.lastLiveCount! ~/ 5) {
    AppLog.warn(
      'M3U: refusing to replace ${source.lastLiveCount} prior channels with '
      '$channelCount (<20%) for source="${source.name}" — keeping existing '
      'catalog',
    );
    return;
  }

  // finding 78: splice the wipe in front of the inserts so wipe + first inserts
  // commit in the same batched transaction (a mid-commit throw rolls it back).
  if (wipe) {
    contentStatements.insert(0, Sql.wipeSource(sourceId));
  }
  onProgress?.call('Loading channels: $channelCount…');
  await Sql.commitWriteBatched(contentStatements, memory: memory);

  final tail = <Future<void> Function(SqliteWriteContext, Map<String, String>)>[
    Sql.updateGroups(),
  ];
  if (preserve != null) {
    tail.add(Sql.restorePreserve(preserve));
  }
  await Sql.commitWrite(tail, memory: memory);
  // fix268: persist the channel count from this refresh. M3U is a flat list
  // (no movie/series split at parse time), so only the total is recorded.
  if (source.id != null) {
    source.lastLiveCount = channelCount;
    source.lastMovieCount = null;
    source.lastSeriesCount = null;
    await Sql.updateSource(source);
  }
  AppLog.info(
    'M3U: parsed source="${source.name}"'
    ' channels=$channelCount',
  );
  if (preserve != null) {
    AppLog.info(
      'M3U: preserve restored — source="${source.name}"'
      ' channels=$channelCount',
    );
  }
}

MediaType getMediaType(String url) {
  if (url.endsWith('.mp4') || url.endsWith('.mkv')) {
    return MediaType.movie;
  }
  return MediaType.livestream;
}

Channel? getChannelFromLines(String l1, String last, int order) {
  var url = last.trim();
  if (url.isEmpty) return null;

  var name = getName(l1)?.trim();
  if (name == null || name.isEmpty) return null;

  final epgId = idRegex.firstMatch(l1)?[1]?.trim();
  final catchupType = catchupTypeRegex.firstMatch(l1)?[1]?.trim();
  final catchupSource = catchupSourceRegex.firstMatch(l1)?[1]?.trim();
  final catchupDaysStr = catchupDaysRegex.firstMatch(l1)?[1]?.trim();

  final group = groupRegex.firstMatch(l1)?[1]?.trim();
  return Channel(
    name: name,
    group: (group == null || group.isEmpty) ? 'Uncategorized' : group,
    image: logoRegex.firstMatch(l1)?[1]?.trim(),
    favorite: false,
    mediaType: getMediaType(url),
    sourceId: -1,
    url: url,
    epgChannelId: (epgId != null && epgId.isNotEmpty) ? epgId : null,
    catchupType:
        (catchupType != null && catchupType.isNotEmpty) ? catchupType : null,
    catchupSource: (catchupSource != null && catchupSource.isNotEmpty)
        ? catchupSource
        : null,
    catchupDays:
        catchupDaysStr != null ? int.tryParse(catchupDaysStr) : null,
    providerOrder: order, // fix256: M3U line sequence
    isDivider: Channel.nameIsDivider(name), // fix272
    isAdult: Channel.nameIsAdult(name, group), // fix300 (M3U has no is_adult)
  );
}

String? getName(String l1) {
  var name = nameRegex.firstMatch(l1)?[1];
  if (name != null && name.trim().isNotEmpty) return name;

  name = nameRegexAlt.firstMatch(l1)?[1];
  if (name != null && name.trim().isNotEmpty) return name;

  name = idRegex.firstMatch(l1)?[1];
  if (name != null && name.trim().isNotEmpty) return name;

  return null;
}

bool setChannelHeaders(String headerLine, ChannelHttpHeaders headers) {
  final userAgent = httpUserAgentRegex.firstMatch(headerLine)?[1];
  if (userAgent != null) {
    headers.userAgent = userAgent;
    return true;
  }
  final referrer = httpReferrerRegex.firstMatch(headerLine)?[1];
  if (referrer != null) {
    headers.referrer = referrer;
    return true;
  }
  final origin = httpOriginRegex.firstMatch(headerLine)?[1];
  if (origin != null) {
    headers.httpOrigin = origin;
    return true;
  }
  return false;
}

Future<void> processM3UUrl(
  Source source,
  bool wipe, [
  void Function(String)? onProgress,
]) async {
  AppLog.info('M3U: downloading source="${source.name}" url="${source.url}"');
  onProgress?.call('Downloading playlist…');
  // finding 80: delete the downloaded temp file on BOTH success and failure —
  // only the file downloaded here (never a caller-supplied local path, which
  // is why cleanup lives in processM3UUrl not processM3U).
  String? path;
  try {
    path = await downloadM3U(source.url!);
    await processM3U(source, wipe, path, onProgress);
  } catch (e) {
    AppLog.warn('M3U: download failed source="${source.name}" error=$e');
    rethrow;
  } finally {
    if (path != null) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (e) {
        AppLog.warn('M3U: temp cleanup failed path="$path" error=$e');
      }
    }
  }
}

Future<String> downloadM3U(String urlStr) async {
  // headers, and use a unique-per-request temp filename to avoid collisions.
  final url = Uri.parse(urlStr);
  final request = http.Request('GET', url);
  final response = await AppHttp.sendStreaming(
    request,
    timeout: const Duration(seconds: 30),
  );
  if (response == null) {
    throw Exception('Failed to download M3U (network error or timeout)');
  }
  if (response.statusCode != 200) {
    throw Exception('Failed to download file: ${response.statusCode}');
  }
  final unique = DateTime.now().microsecondsSinceEpoch;
  final path = await Utils.getTempPath("get_$unique.m3u");
  final file = File(path);
  // finding 80: sweep any leaked prior downloads (always this function's
  // `get_*.m3u` output) before writing the new one, so a past crash between
  // download and cleanup doesn't accumulate multi-MB files.
  try {
    await for (final e in file.parent.list(followLinks: false)) {
      if (e is File &&
          e.path != path &&
          e.uri.pathSegments.last.startsWith('get_') &&
          e.path.endsWith('.m3u')) {
        try {
          await e.delete();
        } catch (_) {}
      }
    }
  } catch (_) {}
  final sink = file.openWrite();
  try {
    await for (var chunk in response.stream.timeout(
      const Duration(seconds: 60),
      // finding 81: emit an ERROR on idle timeout (not a clean close) so the
      // `await for` throws and the caller keeps the old catalog, instead of
      // persisting a silently-truncated playlist as a complete refresh. Note
      // `eventSink` is the transformed-stream sink, distinct from the file sink.
      onTimeout: (eventSink) =>
          eventSink.addError(Exception('M3U download stalled: no data for 60s')),
    )) {
      sink.add(chunk);
    }
  } finally {
    await sink.close();
  }
  final length = await file.length();
  if (length == 0) {
    throw Exception('Downloaded M3U file is empty');
  }
  return path;
}
