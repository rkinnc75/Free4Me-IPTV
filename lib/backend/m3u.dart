import 'dart:convert';
import 'dart:io';

import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/sql.dart' show Sql, importBatchSize;
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
final nameRegexAlt = RegExp(r',([^,\n\r\t]*)$');
final idRegex = RegExp(r'tvg-id="([^"]*)"');
final logoRegex = RegExp(r'tvg-logo="([^"]*)"');
final groupRegex = RegExp(r'group-title="([^"]*)"');
final httpOriginRegex = RegExp(r'http-origin=(.+)');
final httpReferrerRegex = RegExp(r'http-referrer=(.+)');
final httpUserAgentRegex = RegExp(r'http-user-agent=(.+)');

// v1.3: catchup attributes — see https://github.com/iptv-org/iptv#catchup
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
  onProgress?.call('Connecting…');
  await Sql.commitWrite([Sql.getOrCreateSourceByName(source)], memory: memory);
  final sourceId = int.parse(memory['sourceId']!);
  source.id = sourceId;
  if (wipe) {
    preserve = await Sql.getChannelsPreserve(sourceId);
    AppLog.info(
      'M3U: preserve captured — source="${source.name}"'
      ' epg=${preserve.where((p) => p.epgChannelId != null).length}'
      ' favorites=${preserve.where((p) => p.favorite == 1).length}'
      ' total=${preserve.length}',
    );
    await Sql.commitWrite([Sql.wipeSource(sourceId)], memory: memory);
  }

  var file = File(
    path!,
  ).openRead().transform(utf8.decoder).transform(const LineSplitter());

  var batch = <Future<void> Function(SqliteWriteContext, Map<String, String>)>[];
  String? lastLine;
  String? channelLine;
  ChannelHttpHeaders? headers;
  var httpHeadersSet = false;
  int channelCount = 0;

  Future<void> flushBatch() async {
    if (batch.isEmpty) return;
    await Sql.commitWriteBatched(batch, memory: memory);
    channelCount += batch.length;
    batch = [];
    onProgress?.call('Loading channels: $channelCount…');
  }

  await for (var line in file) {
    final lineUpper = line.toUpperCase();
    if (lineUpper.startsWith("#EXTINF")) {
      if (channelLine != null &&
          lastLine != null &&
          lastLine.trim().isNotEmpty) {
        commitChannel(
          channelLine,
          lastLine,
          httpHeadersSet ? headers : null,
          batch,
        );
        if (batch.length >= importBatchSize) await flushBatch();
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
      if (line.trim().isNotEmpty) {
        lastLine = line;
      }
    }
  }
  if (channelLine != null && lastLine != null && lastLine.trim().isNotEmpty) {
    commitChannel(channelLine, lastLine, headers, batch);
  }
  await flushBatch();

  final tail = <Future<void> Function(SqliteWriteContext, Map<String, String>)>[
    Sql.updateGroups(),
  ];
  if (preserve != null) {
    tail.add(Sql.restorePreserve(preserve));
  }
  await Sql.commitWrite(tail, memory: memory);
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

void commitChannel(
  String l1,
  String last,
  ChannelHttpHeaders? headers,
  List<Future<void> Function(SqliteWriteContext, Map<String, String>)>
  statements,
) {
  var channel = getChannelFromLines(l1, last);
  if (channel == null) return;
  statements.add(Sql.insertChannel(channel));
  if (headers != null) {
    statements.add(Sql.insertChannelHeaders(headers));
  }
}

MediaType getMediaType(String url) {
  if (url.endsWith('.mp4') || url.endsWith('.mkv')) {
    return MediaType.movie;
  }
  return MediaType.livestream;
}

Channel? getChannelFromLines(String l1, String last) {
  var url = last.trim();
  if (url.isEmpty) return null;

  var name = getName(l1)?.trim();
  if (name == null || name.isEmpty) return null;

  final epgId = idRegex.firstMatch(l1)?[1]?.trim();
  final catchupType = catchupTypeRegex.firstMatch(l1)?[1]?.trim();
  final catchupSource = catchupSourceRegex.firstMatch(l1)?[1]?.trim();
  final catchupDaysStr = catchupDaysRegex.firstMatch(l1)?[1]?.trim();

  return Channel(
    name: name,
    group: groupRegex.firstMatch(l1)?[1]?.trim(),
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
  try {
    var path = await downloadM3U(source.url!);
    await processM3U(source, wipe, path, onProgress);
  } catch (e) {
    AppLog.warn('M3U: download failed source="${source.name}" error=$e');
    rethrow;
  }
}

Future<String> downloadM3U(String urlStr) async {
  // FIX (Tier 2, #5): use shared client, add timeout on initial response
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
  final sink = file.openWrite();
  await for (var chunk in response.stream.timeout(
    const Duration(seconds: 60),
    onTimeout: (sink) => sink.close(),
  )) {
    sink.add(chunk);
  }
  await sink.close();
  final length = await file.length();
  if (length == 0) {
    throw Exception('Downloaded M3U file is empty');
  }
  return path;
}
