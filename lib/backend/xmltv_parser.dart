import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/http_client.dart';
import 'package:open_tv/models/programme.dart';
import 'package:xml/xml_events.dart';

/// Emitted during a streaming XMLTV parse so callers can show progress.
class XmltvProgress {
  final int channelMapSize;
  final int programmesInserted;
  final int programmesSkipped;
  final bool done;
  final String? error;
  final String? statusMessage;

  const XmltvProgress({
    this.channelMapSize = 0,
    this.programmesInserted = 0,
    this.programmesSkipped = 0,
    this.done = false,
    this.error,
    this.statusMessage,
  });
}

/// Streams and event-parses an XMLTV file.
///
/// Emits progress via [onProgress] and delivers programmes in batches of
/// [batchSize] to [onBatch]. Filters programmes outside
/// [windowStartEpoch, windowEndEpoch] to keep DB size manageable.
///
/// Handles both plain XML and gzip-compressed XML transparently
/// (checks Content-Encoding header, falling back to URL suffix).
class XmltvParser {
  static const int defaultBatchSize = 1000;

  /// Returns a map of EPG channel-id → display-name from the file.
  /// Also calls [onBatch] for each batch of in-window programmes.
  static Future<Map<String, String>> parse({
    required String url,
    required int sourceId,
    required int windowStartEpoch,
    required int windowEndEpoch,
    required Future<void> Function(List<Programme>) onBatch,
    void Function(XmltvProgress)? onProgress,
    int batchSize = defaultBatchSize,
  }) async {
    onProgress?.call(const XmltvProgress(statusMessage: 'Connecting…'));
    AppLog.info('XMLTV: GET $url');

    final uri = Uri.parse(url);
    final request = await AppHttp.buildGetRequest(uri);
    final response = await AppHttp.sendStreaming(
      request,
      timeout: const Duration(seconds: 60),
    );
    if (response == null) {
      AppLog.error(
        'XMLTV: connection failed (timeout / DNS / refused) — $url',
      );
      throw Exception('Failed to fetch EPG feed (connection failed): $url');
    }
    AppLog.info(
      'XMLTV: HTTP ${response.statusCode}, '
      'content-length=${response.contentLength ?? "?"}, '
      'encoding=${response.headers['content-encoding'] ?? "none"}',
    );
    if (response.statusCode != 200) {
      throw Exception(
        'EPG feed returned HTTP ${response.statusCode}: $url',
      );
    }
    onProgress?.call(
      const XmltvProgress(statusMessage: 'Downloading & parsing…'),
    );

    final isGzip = (response.headers['content-encoding'] ?? '')
            .toLowerCase()
            .contains('gzip') ||
        url.toLowerCase().endsWith('.gz');

    Stream<List<int>> byteStream = response.stream;
    if (isGzip) byteStream = byteStream.transform(gzip.decoder);

    final channelMap = <String, String>{}; // epg-id → display-name
    final batch = <Programme>[];
    int inserted = 0;
    int skipped = 0;

    // State machine
    String? _currentChannelId;
    String? _currentChildElement; // 'display-name' | 'title' | 'desc' | etc.
    _ProgrammeBuilder? _prog;
    final _text = StringBuffer();

    Future<void> flushBatch() async {
      if (batch.isEmpty) return;
      await onBatch(List.unmodifiable(batch));
      inserted += batch.length;
      batch.clear();
      onProgress?.call(XmltvProgress(
        channelMapSize: channelMap.length,
        programmesInserted: inserted,
        programmesSkipped: skipped,
      ));
    }

    // XmlEventDecoder (xml ^6) emits List<XmlEvent> per chunk; expand to
    // get individual events.
    final eventStream = byteStream
        .transform(utf8.decoder)
        .transform(XmlEventDecoder())
        .expand((list) => list);

    await for (final event in eventStream) {
      if (event is XmlStartElementEvent) {
        _text.clear();
        switch (event.name) {
          case 'channel':
            _currentChannelId = _attr(event, 'id');
            _currentChildElement = null;
          case 'programme':
            final startRaw = _attr(event, 'start');
            final stopRaw = _attr(event, 'stop');
            final channelId = _attr(event, 'channel');
            if (startRaw != null && stopRaw != null && channelId != null) {
              _prog = _ProgrammeBuilder(
                epgChannelId: channelId,
                sourceId: sourceId,
                startUtc: _parseXmltvTime(startRaw),
                stopUtc: _parseXmltvTime(stopRaw),
              );
            }
            _currentChildElement = null;
          case 'display-name' || 'title' || 'desc' || 'category' || 'episode-num':
            _currentChildElement = event.name;
        }
      } else if (event is XmlTextEvent) {
        _text.write(event.value);
      } else if (event is XmlCDATAEvent) {
        _text.write(event.value);
      } else if (event is XmlEndElementEvent) {
        final text = _text.toString().trim();
        switch (event.name) {
          case 'channel':
            _currentChannelId = null;
            _currentChildElement = null;
          case 'display-name':
            if (_currentChannelId != null && text.isNotEmpty) {
              channelMap.putIfAbsent(_currentChannelId!, () => text);
            }
            _currentChildElement = null;
          case 'title':
            _prog?.title = text;
            _currentChildElement = null;
          case 'desc':
            _prog?.description = text.isNotEmpty ? text : null;
            _currentChildElement = null;
          case 'category':
            _prog?.category = text.isNotEmpty ? text : null;
            _currentChildElement = null;
          case 'episode-num':
            _prog?.episodeNum = text.isNotEmpty ? text : null;
            _currentChildElement = null;
          case 'programme':
            final p = _prog;
            _prog = null;
            if (p != null && p.title != null) {
              if (p.startUtc >= windowStartEpoch &&
                  p.startUtc <= windowEndEpoch) {
                batch.add(p.build());
                if (batch.length >= batchSize) await flushBatch();
              } else {
                skipped++;
              }
            }
        }
        _text.clear();
      }
    }

    await flushBatch(); // flush remainder

    onProgress?.call(XmltvProgress(
      channelMapSize: channelMap.length,
      programmesInserted: inserted,
      programmesSkipped: skipped,
      done: true,
    ));

    AppLog.info(
      'XMLTV: parse done — ${channelMap.length} channels, '
      '$inserted programmes inserted, $skipped outside window',
    );
    debugPrint(
      'XMLTV parse done: ${channelMap.length} channels, '
      '$inserted programmes inserted, $skipped skipped',
    );
    return channelMap;
  }

  static String? _attr(XmlStartElementEvent event, String name) {
    for (final a in event.attributes) {
      if (a.name == name) return a.value;
    }
    return null;
  }

  /// Parses XMLTV timestamp `YYYYMMDDHHmmss +HHMM` → Unix epoch seconds (UTC).
  static int _parseXmltvTime(String s) {
    final trimmed = s.trim();
    // Split on any whitespace
    final spaceIdx = trimmed.indexOf(' ');
    final dt = spaceIdx > 0 ? trimmed.substring(0, spaceIdx) : trimmed;
    final tz = spaceIdx > 0 ? trimmed.substring(spaceIdx + 1).trim() : '+0000';

    if (dt.length < 14) return 0;

    final year = int.tryParse(dt.substring(0, 4)) ?? 0;
    final month = int.tryParse(dt.substring(4, 6)) ?? 1;
    final day = int.tryParse(dt.substring(6, 8)) ?? 1;
    final hour = int.tryParse(dt.substring(8, 10)) ?? 0;
    final min = int.tryParse(dt.substring(10, 12)) ?? 0;
    final sec = int.tryParse(dt.substring(12, 14)) ?? 0;

    final utcDt = DateTime.utc(year, month, day, hour, min, sec);
    int epochSecs = utcDt.millisecondsSinceEpoch ~/ 1000;

    // Adjust for timezone offset (e.g. "+0500" means 5 hours ahead of UTC)
    if (tz.length >= 5) {
      final sign = tz[0] == '-' ? 1 : -1; // subtract east offset to get UTC
      final tzH = int.tryParse(tz.substring(1, 3)) ?? 0;
      final tzM = int.tryParse(tz.substring(3, 5)) ?? 0;
      epochSecs += sign * (tzH * 3600 + tzM * 60);
    }

    return epochSecs;
  }
}

class _ProgrammeBuilder {
  final String epgChannelId;
  final int sourceId;
  final int startUtc;
  final int stopUtc;
  String? title;
  String? description;
  String? category;
  String? episodeNum;

  _ProgrammeBuilder({
    required this.epgChannelId,
    required this.sourceId,
    required this.startUtc,
    required this.stopUtc,
  });

  Programme build() => Programme(
        epgChannelId: epgChannelId,
        sourceId: sourceId,
        title: title ?? '',
        description: description,
        category: category,
        startUtc: startUtc,
        stopUtc: stopUtc,
        episodeNum: episodeNum,
      );
}
