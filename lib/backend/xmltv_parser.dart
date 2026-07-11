import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/http_client.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/models/program.dart';
import 'package:xml/xml_events.dart';

/// Emitted during a streaming XMLTV parse so callers can show progress.
class XmltvProgress {
  final int channelMapSize;
  final int programsInserted;
  final int programsSkipped;
  final bool done;
  final String? error;
  final String? statusMessage;

  // Matching-phase progress (populated after download completes)
  final int matchingChannelsDone;
  final int matchingChannelsTotal;

  const XmltvProgress({
    this.channelMapSize = 0,
    this.programsInserted = 0,
    this.programsSkipped = 0,
    this.done = false,
    this.error,
    this.statusMessage,
    this.matchingChannelsDone = 0,
    this.matchingChannelsTotal = 0,
  });

  bool get isMatching => matchingChannelsTotal > 0;
}

/// finding 46: result of a streaming XMLTV parse. `truncated` is true when the
/// body stream stalled (idle timeout) and the feed is only partial — the caller
/// must then NOT delete stale programmes and must log the refresh as partial so
/// it isn't treated as a clean, complete refresh.
class XmltvParseResult {
  final Map<String, String> channelMap;
  final bool truncated;
  final int inserted;
  // fix695: when true, the feed was unchanged (HTTP 304 or an identical body
  // hash) — nothing was parsed/inserted and the caller should skip matching.
  final bool notModified;
  // fix695: HTTP validators + body hash to persist for the next conditional
  // request. On a notModified result the hash is the prior one (unchanged).
  final String? etag;
  final String? lastModified;
  final String? bodyHash;
  const XmltvParseResult(
    this.channelMap,
    this.truncated,
    this.inserted, {
    this.notModified = false,
    this.etag,
    this.lastModified,
    this.bodyHash,
  });
}

/// Streams and event-parses an XMLTV file.
///
/// Emits progress via [onProgress] and delivers programs in batches of
/// [batchSize] to [onBatch]. Filters programs outside
/// [windowStartEpoch, windowEndEpoch] to keep DB size manageable.
///
/// Handles both plain XML and gzip-compressed XML transparently
/// (checks Content-Encoding header, falling back to URL suffix).
class XmltvParser {
  static const int defaultBatchSize = 1000;

  /// Returns a map of EPG channel-id → display-name from the file.
  /// Also calls [onBatch] for each batch of in-window programs.
  static Future<XmltvParseResult> parse({
    required String url,
    required int sourceId,
    required int windowStartEpoch,
    required int windowEndEpoch,
    required Future<void> Function(List<Program>) onBatch,
    void Function(XmltvProgress)? onProgress,
    int batchSize = defaultBatchSize,
    // fix695: HTTP validators from the previous refresh (conditional GET).
    String? priorEtag,
    String? priorLastModified,
    // fix695: SHA-256 of the previous body — if the new body hashes the same,
    // skip parse+insert entirely (the feed is byte-identical).
    String? priorHash,
    // fix695: only keep programmes for xmltv channel-ids we actually carry
    // (the channels already matched to an epg_channel_id on this source). Null
    // or empty ⇒ no filter (first-ever EPG for the source, before any match).
    Set<String>? boundEpgIds,
  }) async {
    onProgress?.call(const XmltvProgress(statusMessage: 'Connecting…'));
    AppLog.info('XMLTV: GET $url');

    final uri = Uri.parse(url);
    // fix695: conditional GET — If-None-Match / If-Modified-Since so a
    // provider that supports validators can answer 304 and we skip the whole
    // download. (Many Xtream xmltv.php endpoints are dynamic and won't; the
    // body-hash below is the provider-independent fallback.)
    final request = await AppHttp.buildGetRequest(uri, headers: {
      if (priorEtag != null && priorEtag.isNotEmpty) 'If-None-Match': priorEtag,
      if (priorLastModified != null && priorLastModified.isNotEmpty)
        'If-Modified-Since': priorLastModified,
    });
    final response = await AppHttp.sendStreaming(
      request,
      timeout: const Duration(seconds: 60),
    );
    if (response == null) {
      // finding 49: log/throw the host only, never the credentialed $url — the
      // thrown message is persisted verbatim into the epg_refresh_log error
      // column, which AppLogger does NOT scrub.
      final host = _hostOnly(url);
      AppLog.error(
        'XMLTV: connection failed (timeout / DNS / refused) — host=$host',
      );
      throw Exception(
          'Failed to fetch EPG feed (connection failed): host=$host');
    }
    AppLog.info(
      'XMLTV: HTTP ${response.statusCode}, '
      'content-length=${response.contentLength ?? "?"}, '
      'encoding=${response.headers['content-encoding'] ?? "none"}',
    );
    // fix695: 304 Not Modified — provider confirmed the feed is unchanged.
    // Nothing to download or parse; keep the existing programmes as-is.
    if (response.statusCode == 304) {
      AppLog.info('XMLTV: 304 Not Modified — skipping parse (feed unchanged)');
      // Drain the (empty) body so the socket is released.
      try {
        await response.stream.drain<void>();
      } catch (_) {}
      return XmltvParseResult(const {}, false, 0,
          notModified: true, etag: priorEtag, lastModified: priorLastModified,
          bodyHash: priorHash);
    }
    if (response.statusCode != 200) {
      throw Exception(
        'EPG feed returned HTTP ${response.statusCode}: host=${_hostOnly(url)}',
      );
    }
    final newEtag = response.headers['etag'];
    final newLastModified = response.headers['last-modified'];
    onProgress?.call(
      const XmltvProgress(statusMessage: 'Downloading…'),
    );

    // fix695: stream the body to a temp file while hashing it (SHA-256), so we
    // can (a) skip parse+insert when the body is byte-identical to last time
    // and (b) persist the hash for the next conditional request. Buffering to
    // disk (not RAM) keeps the memory-bounded streaming property on 2GB boxes.
    // The 60s per-chunk stall watchdog (findings 46/47/48) is preserved.
    bool truncated = false;
    final tmpPath = await Utils.getTempPath('epg_src_$sourceId.xml');
    final tmpFile = File(tmpPath);
    final sink = tmpFile.openWrite();
    // crypto's DigestSink is not exported; capture the single emitted Digest
    // via a tiny ChunkedConversionSink (same idiom as update_checker.dart).
    Digest? digest;
    final hashInput = sha256.startChunkedConversion(
      ChunkedConversionSink<Digest>.withCallback((digests) {
        if (digests.isNotEmpty) digest = digests.last;
      }),
    );
    try {
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 60),
        onTimeout: (s) {
          AppLog.warn('XMLTV: body stream stalled — no data for 60 s, marking'
              ' truncated (partial download kept, source NOT marked fresh)');
          truncated = true;
          s.close();
        },
      )) {
        sink.add(chunk);
        hashInput.add(chunk);
      }
    } finally {
      await sink.close();
      hashInput.close();
    }
    final bodyHash = digest?.toString();

    // fix695: identical body → skip the expensive parse/insert/checkpoint.
    // Never skip on a truncated download (a stalled partial would hash
    // differently anyway, but guard explicitly).
    if (!truncated && bodyHash != null && bodyHash == priorHash) {
      AppLog.info('XMLTV: body unchanged (hash match) — skipping parse/insert');
      try {
        await tmpFile.delete();
      } catch (_) {}
      return XmltvParseResult(const {}, false, 0,
          notModified: true, etag: newEtag, lastModified: newLastModified,
          bodyHash: bodyHash);
    }

    onProgress?.call(
      const XmltvProgress(statusMessage: 'Parsing…'),
    );
    // Detect gzip by sniffing magic bytes (0x1f 0x8b) on the first chunk
    // rather than trusting Content-Encoding (autoUncompress already strips it
    // but leaves the header, which would double-decode). The temp file holds
    // whatever the socket delivered; sniff it the same way.
    Stream<List<int>> byteStream = await _maybeUngzip(tmpFile.openRead());

    final channelMap = <String, String>{}; // epg-id → display-name
    final batch = <Program>[];
    int inserted = 0;
    int skipped = 0;

    // State machine
    String? currentChannelId;
    _ProgramBuilder? prog;
    final textBuf = StringBuffer();

    Future<void> flushBatch() async {
      if (batch.isEmpty) return;
      await onBatch(List.unmodifiable(batch));
      inserted += batch.length;
      batch.clear();
      onProgress?.call(XmltvProgress(
        channelMapSize: channelMap.length,
        programsInserted: inserted,
        programsSkipped: skipped,
      ));
    }

    // XmlEventDecoder (xml ^6) emits List<XmlEvent> per chunk; expand to
    // get individual events.
    final eventStream = byteStream
        // finding 50: lenient decode — a stray non-UTF-8 byte (ISO-8859-1 /
        // windows-1251 European feeds) yields U+FFFD instead of throwing and
        // killing the entire refresh.
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(XmlEventDecoder())
        .expand((list) => list);

    await for (final event in eventStream) {
      if (event is XmlStartElementEvent) {
        textBuf.clear();
        switch (event.name) {
          case 'channel':
            currentChannelId = _attr(event, 'id');
          case 'programme':
            final startRaw = _attr(event, 'start');
            final stopRaw = _attr(event, 'stop');
            final channelId = _attr(event, 'channel');
            if (startRaw != null && stopRaw != null && channelId != null) {
              // fix695: decide keep/skip HERE, from the already-parsed times +
              // channel id, BEFORE allocating the builder or accumulating any
              // title/desc/category text. Two filters, both applied up front:
              //  - window: interval-overlap (finding 51) so a currently-airing
              //    programme (started before windowStart, ends after) is kept.
              //  - bound: only channels we carry (matched to an epg id). Null/
              //    empty boundEpgIds ⇒ no filter (first EPG, before any match).
              final st = _parseXmltvTime(startRaw);
              final sp = _parseXmltvTime(stopRaw);
              final inWindow =
                  sp > windowStartEpoch && st <= windowEndEpoch;
              final bound = boundEpgIds == null ||
                  boundEpgIds.isEmpty ||
                  boundEpgIds.contains(channelId);
              if (inWindow && bound) {
                prog = _ProgramBuilder(
                  epgChannelId: channelId,
                  sourceId: sourceId,
                  startUtc: st,
                  stopUtc: sp,
                );
              } else {
                skipped++; // prog stays null → text below is a no-op, no build
              }
            }
        }
      } else if (event is XmlTextEvent) {
        // fix695: only accumulate text we will actually use — inside a
        // <channel> (for display-name) or inside a KEPT <programme>. Skips the
        // (often large) <desc> string work for filtered-out programmes.
        if (prog != null || currentChannelId != null) textBuf.write(event.value);
      } else if (event is XmlCDATAEvent) {
        if (prog != null || currentChannelId != null) textBuf.write(event.value);
      } else if (event is XmlEndElementEvent) {
        final text = textBuf.toString().trim();
        switch (event.name) {
          case 'channel':
            currentChannelId = null;
          case 'display-name':
            if (currentChannelId != null && text.isNotEmpty) {
              channelMap.putIfAbsent(currentChannelId, () => text);
            }
          case 'title':
            prog?.title = text;
          case 'desc':
            prog?.description = text.isNotEmpty ? text : null;
          case 'category':
            prog?.category = text.isNotEmpty ? text : null;
          case 'episode-num':
            prog?.episodeNum = text.isNotEmpty ? text : null;
          case 'programme':
            final p = prog;
            prog = null;
            // fix695: window + bound filtering already happened at <programme>
            // start (prog is only non-null for kept programmes), so here we
            // just require a title and emit.
            if (p != null && p.title != null) {
              batch.add(p.build());
              if (batch.length >= batchSize) await flushBatch();
            }
        }
        textBuf.clear();
      }
    }

    await flushBatch(); // flush remainder

    onProgress?.call(XmltvProgress(
      channelMapSize: channelMap.length,
      programsInserted: inserted,
      programsSkipped: skipped,
      done: true,
    ));

    // fix695: drop the buffered body now that parsing is complete.
    try {
      await tmpFile.delete();
    } catch (_) {}

    AppLog.info(
      'XMLTV: parse done — ${channelMap.length} channels, '
      '$inserted programs inserted, $skipped skipped (out-of-window or unbound)'
      '${truncated ? " (TRUNCATED — body stalled)" : ""}',
    );
    return XmltvParseResult(channelMap, truncated, inserted,
        etag: newEtag, lastModified: newLastModified, bodyHash: bodyHash);
  }

  /// Peeks at the first chunk of [source] and, if it starts with the gzip
  /// magic bytes (0x1f 0x8b), returns a stream that decompresses on the fly.
  /// Otherwise returns the original byte stream unchanged.
  static Future<Stream<List<int>>> _maybeUngzip(
    Stream<List<int>> source,
  ) async {
    final controller = StreamController<List<int>>();
    bool? isGzip;
    final completer = Completer<Stream<List<int>>>();

    late final StreamSubscription<List<int>> sub;
    sub = source.listen(
      (chunk) {
        if (isGzip == null && chunk.isNotEmpty) {
          isGzip = chunk.length >= 2 &&
              chunk[0] == 0x1f &&
              chunk[1] == 0x8b;
          AppLog.info(
            'XMLTV: gzip-sniff → ${isGzip! ? "compressed" : "plain"} '
            '(first bytes 0x${chunk[0].toRadixString(16).padLeft(2, "0")} '
            '0x${chunk.length > 1 ? chunk[1].toRadixString(16).padLeft(2, "0") : "??"})',
          );
          if (isGzip!) {
            completer.complete(
              controller.stream.transform(gzip.decoder),
            );
          } else {
            completer.complete(controller.stream);
          }
        }
        controller.add(chunk);
      },
      onError: (Object e, StackTrace st) {
        controller.addError(e, st);
        if (!completer.isCompleted) {
          completer.complete(controller.stream);
        }
      },
      onDone: () {
        // an empty body or a timeout-closed stream never leaves the caller
        // awaiting _maybeUngzip() forever. An empty controller.stream is a
        // valid (zero-program) result; the XML parser will emit no events
        // and downloadAndParseEpg will log inserted=0 and surface normally.
        if (!completer.isCompleted) {
          completer.complete(controller.stream);
        }
        controller.close();
        sub.cancel();
      },
      cancelOnError: false,
    );
    // findings 47/48: propagate backpressure + cancellation to the upstream
    // HTTP subscription. Without this, the consumer pausing during each DB
    // flushBatch never stops the socket read (whole body buffers in RAM → OOM
    // on 2GB boxes), and a downstream parse error/cancel leaves the socket
    // pumping into an abandoned controller. Assigned AFTER `sub = source.listen`
    // so the closures capture the now-assigned `sub`.
    controller.onPause = sub.pause;
    controller.onResume = sub.resume;
    controller.onCancel = () async => sub.cancel();

    return completer.future;
  }

  static String? _attr(XmlStartElementEvent event, String name) {
    for (final a in event.attributes) {
      if (a.name == name) return a.value;
    }
    return null;
  }

  /// finding 49: bare host for error messages so a credentialed URL never
  /// lands in a thrown/persisted string.
  static String _hostOnly(String url) {
    try {
      final h = Uri.parse(url).host;
      return h.isEmpty ? '<url>' : h;
    } catch (_) {
      return '<url>';
    }
  }

  /// Parses XMLTV timestamp `YYYYMMDDHHmmss +HHMM` → Unix epoch seconds (UTC).
  static int _parseXmltvTime(String s) {
    final trimmed = s.trim();
    // Split on any whitespace
    final spaceIdx = trimmed.indexOf(' ');
    final dt = spaceIdx > 0 ? trimmed.substring(0, spaceIdx) : trimmed;
    final tz = spaceIdx > 0 ? trimmed.substring(spaceIdx + 1).trim() : '+0000';

    // finding 52: XMLTV allows right-truncated date-times; pad missing
    // lower-order fields to their MINIMUM (month/day=01, time=00) rather than
    // zeroing the whole timestamp (which silently dropped whole feeds whose
    // programmes then all failed the window filter).
    const tmpl = '00000101000000'; // YYYY MM DD HH mm ss minimums
    var d = dt;
    if (d.length < 14) {
      if (d.length < 4) return 0; // no usable year → unparseable
      d = d + tmpl.substring(d.length);
    } else if (d.length > 14) {
      d = d.substring(0, 14);
    }

    final year = int.tryParse(d.substring(0, 4)) ?? 0;
    final month = int.tryParse(d.substring(4, 6)) ?? 1;
    final day = int.tryParse(d.substring(6, 8)) ?? 1;
    final hour = int.tryParse(d.substring(8, 10)) ?? 0;
    final min = int.tryParse(d.substring(10, 12)) ?? 0;
    final sec = int.tryParse(d.substring(12, 14)) ?? 0;

    final utcDt = DateTime.utc(year, month, day, hour, min, sec);
    int epochSecs = utcDt.millisecondsSinceEpoch ~/ 1000;

    // Adjust for timezone offset (e.g. "+0500" means 5 hours ahead of UTC).
    // finding 53: tolerate colon-form offsets like "+05:30" by stripping the
    // colon before slicing HH/MM; a missing offset already defaulted to UTC.
    final tzClean = tz.replaceAll(':', '');
    if (tzClean.length >= 5) {
      final sign = tzClean[0] == '-' ? 1 : -1; // subtract east offset for UTC
      final tzH = int.tryParse(tzClean.substring(1, 3)) ?? 0;
      final tzM = int.tryParse(tzClean.substring(3, 5)) ?? 0;
      epochSecs += sign * (tzH * 3600 + tzM * 60);
    }

    return epochSecs;
  }
}

class _ProgramBuilder {
  final String epgChannelId;
  final int sourceId;
  final int startUtc;
  final int stopUtc;
  String? title;
  String? description;
  String? category;
  String? episodeNum;

  _ProgramBuilder({
    required this.epgChannelId,
    required this.sourceId,
    required this.startUtc,
    required this.stopUtc,
  });

  Program build() => Program(
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
