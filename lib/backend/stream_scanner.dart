import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel.dart';

/// Stream validity probe.
///
/// Each probe makes a streaming HTTP GET on the channel URL and reads the
/// first ~16 KB of the response body to validate that the bytes really are
/// a media payload (MPEG-TS sync bytes, an HLS playlist with `#EXTM3U`, an
/// MP4 `ftyp` box, or a DASH manifest). Plain HTTP 200 with HTML/text is
/// rejected — that's how we filter out portal pages, CDN error pages, and
/// auth redirects that would 200 OK but wouldn't actually play.
///
/// Results are stored in a static map so they survive widget rebuilds and
/// navigation; call [clearResults] before re-scanning.
class StreamScanner {
  StreamScanner._();

  /// Channel ID → true (validated as media) / false (failed / not media).
  static final Map<int, bool> results = {};

  static void clearResults() => results.clear();

  /// Probe up to [maxChannels] channels from [channels], calling
  /// [onProgress] after each probe. Returns early if [isCancelled]
  /// returns true.
  static Future<void> scan({
    required List<Channel> channels,
    required void Function(int done, int total) onProgress,
    required bool Function() isCancelled,
    Duration timeout = const Duration(seconds: 8),
    int maxChannels = 20,
  }) async {
    final toScan = channels
        .where((c) => c.url?.isNotEmpty == true && c.id != null)
        .take(maxChannels)
        .toList();

    for (int i = 0; i < toScan.length; i++) {
      if (isCancelled()) break;
      final ch = toScan[i];
      final ok = await _probe(ch.url!, timeout);
      results[ch.id!] = ok;
      await Sql.setStreamValidated(ch.id!, ok);
      AppLog.info('StreamScanner: "${ch.name}" → ${ok ? "OK" : "FAIL"}');
      onProgress(i + 1, toScan.length);
    }
  }

  static Future<bool> _probe(String url, Duration timeout) async {
    final client = http.Client();
    try {
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) return false;

      final request = http.Request('GET', uri);
      // Some IPTV servers reject default Dart UA; pretend to be a player.
      request.headers['User-Agent'] = 'Lavf/61.7.100';
      request.headers['Accept'] = '*/*';

      final response = await client.send(request).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 400) {
        await _drain(response.stream);
        return false;
      }

      final contentType =
          (response.headers['content-type'] ?? '').toLowerCase();

      // Fast-fail HTML/JSON error pages served as 200 OK (captive portals,
      // CDN error pages, expired-token responses). These would otherwise
      // pass byte validation only by coincidence, and we want to flag them
      // as failed even before reading the body.
      if (contentType.contains('text/html') ||
          contentType.contains('application/json') ||
          contentType.startsWith('text/plain')) {
        await _drain(response.stream);
        return false;
      }

      final lowerUrl = url.toLowerCase();
      final lowerPath = uri.path.toLowerCase();

      // Match HLS via .m3u8 extension, "m3u8" anywhere in URL (Xtream-style
      // /live/.../1.m3u8 paths still work, but so do URLs with query strings
      // that strip the dot), or an mpegurl Content-Type.
      final isHls = lowerUrl.contains('m3u8') ||
          contentType.contains('mpegurl');
      final isMp4 = lowerPath.endsWith('.mp4') ||
          contentType.contains('mp4');
      final isDash = lowerPath.endsWith('.mpd') ||
          contentType.contains('dash+xml');

      // Read first chunks (cap ~16 KB) under the same timeout budget.
      final body = await _readPrefix(response.stream, 16 * 1024)
          .timeout(timeout, onTimeout: () => Uint8List(0));
      return _validateMediaPayload(body, isHls: isHls, isMp4: isMp4, isDash: isDash);
    } catch (e) {
      if (AppLog.enabled) {
        AppLog.info('StreamScanner: probe failed url="$url" error=$e');
      }
      return false;
    } finally {
      client.close();
    }
  }

  /// Reads up to [maxBytes] from [stream], then cancels the subscription so
  /// we don't keep pulling on a long live stream. Returns whatever was
  /// collected at the moment we hit the cap (or end-of-stream).
  static Future<Uint8List> _readPrefix(
    Stream<List<int>> stream,
    int maxBytes,
  ) async {
    final completer = Completer<Uint8List>();
    final buffer = BytesBuilder();
    late final StreamSubscription<List<int>> sub;
    sub = stream.listen(
      (chunk) {
        buffer.add(chunk);
        if (buffer.length >= maxBytes) {
          if (!completer.isCompleted) {
            completer.complete(buffer.takeBytes());
          }
          sub.cancel();
        }
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(buffer.takeBytes());
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(buffer.takeBytes());
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  /// Drain a response stream we don't care about, so the underlying socket
  /// can be returned to the pool / closed cleanly.
  static Future<void> _drain(Stream<List<int>> stream) async {
    try {
      await stream.listen(null, cancelOnError: true).cancel();
    } catch (_) {
      // best-effort
    }
  }

  /// Validate that [bytes] looks like a real media payload.
  ///
  /// Order of checks:
  /// 1. HLS playlist (`#EXTM3U` at start).
  /// 2. DASH manifest (XML root with `<MPD`).
  /// 3. MP4 (`ftyp` box at offset 4).
  /// 4. MPEG-TS sync bytes (0x47 every 188 bytes for at least 2 packets).
  /// 5. fMP4/CMAF (starts with `styp` or `moof` box header).
  static bool _validateMediaPayload(
    Uint8List bytes, {
    required bool isHls,
    required bool isMp4,
    required bool isDash,
  }) {
    if (bytes.isEmpty) return false;

    // Decode the first chunk as text for HLS / DASH / hint detection.
    String head = '';
    try {
      head = utf8.decode(
        bytes.sublist(0, bytes.length < 1024 ? bytes.length : 1024),
        allowMalformed: true,
      );
    } catch (_) {}

    final headTrim = head.trimLeft();

    // 1. HLS playlist — applies to .m3u8 and any text starting with #EXTM3U.
    if (isHls || headTrim.startsWith('#EXTM3U')) {
      return headTrim.startsWith('#EXTM3U');
    }

    // 2. DASH manifest.
    if (isDash || headTrim.contains('<MPD')) {
      return headTrim.contains('<MPD');
    }

    // 3. MP4 / fMP4 — ISO BMFF box at offset 4 (4-byte size prefix).
    if (bytes.length >= 8) {
      final boxType = String.fromCharCodes(bytes.sublist(4, 8));
      const validBoxes = {'ftyp', 'styp', 'moof', 'sidx', 'moov', 'free'};
      if (validBoxes.contains(boxType)) return true;
      if (isMp4) return false; // claimed MP4 but no box header → not playable
    }

    // 4. MPEG-TS sync byte 0x47 every 188 bytes. Most IPTV livestreams hit
    //    this branch — they have no extension and Content-Type is often a
    //    lie ("application/octet-stream"). Require at least 2 consecutive
    //    sync points to avoid false-positives on text containing 0x47 (G).
    if (bytes.length >= 188 * 2) {
      // Allow up to 187 bytes of preamble before the first sync (some
      // origins prepend a small header).
      for (int start = 0; start < 188 && start + 188 < bytes.length; start++) {
        if (bytes[start] == 0x47 && bytes[start + 188] == 0x47) {
          // Confirm a 3rd sync byte if we have the room — kills the
          // accidental-G-character case.
          if (start + 376 >= bytes.length || bytes[start + 376] == 0x47) {
            return true;
          }
        }
      }
    }

    // Reject anything else — HTML, JSON error pages, captive portals, etc.
    return false;
  }
}
