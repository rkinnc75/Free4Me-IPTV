import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/epg_discovery/epg_discovery_result.dart';
import 'package:open_tv/backend/epg_discovery/epg_validator.dart';

/// fix386 / variant 3: scrape the `url-tvg="..."` attribute from the
/// first 64KB of an Xtream Codes `get.php?type=m3u_plus&output=ts`.
///
/// Xtream's m3u export includes the EPG URL inline in the M3U header
/// as `url-tvg="..."` (Xtream standard) or `tvg-url="..."` (some
/// forks). If found, the embedded URL is then fetched and validated
/// via [EpgValidator] before being returned — a non-XMLTV response
/// returns null and the walk ends.
///
/// On 404 (some portals disable m3u_plus) or no url-tvg, returns null.
class XtreamM3uTvgUrl {
  /// Total budget for the pair of requests. The m3u scrape is usually
  /// fast (a few hundred KB) but the EPG validation can be slow on
  /// big feeds — keep this tight.
  static const Duration _totalTimeout = Duration(seconds: 5);

  /// The first 64KB of the m3u response is enough to capture the
  /// header line. Real Xtream m3u_plus files are multi-MB but the
  /// `url-tvg=` attribute is on line 1.
  static const int _m3uHeadBytes = 65536;

  /// Returns a result iff the portal's m3u_plus export exposes an
  /// `url-tvg`/`tvg-url` attribute AND that URL yields a valid
  /// XMLTV document.
  static Future<EpgDiscoveryResult?> probe(
    String host,
    String username,
    String password,
  ) async {
    final start = DateTime.now();

    final m3uUrl = Uri.tryParse(
      '$host/get.php?username=${Uri.encodeComponent(username)}'
      '&password=${Uri.encodeComponent(password)}'
      '&type=m3u_plus&output=ts',
    );
    if (m3uUrl == null) {
      AppLog.warn(
          'EpgDiscovery: variant3 — cannot build m3u url for host=$host');
      return null;
    }

    final client = http.Client();
    try {
      // Range request — many Xtream servers honour Range and return
      // just the head. If they don't, the body is the full m3u and
      // we cap it client-side.
      final m3uResp = await client
          .get(
            m3uUrl,
            headers: {
              'Range': 'bytes=0-${_m3uHeadBytes - 1}',
              'User-Agent': 'Free4Me-IPTV/1.0',
            },
          )
          .timeout(_totalTimeout);
      if (m3uResp.statusCode != 200 && m3uResp.statusCode != 206) {
        AppLog.info(
            'EpgDiscovery: variant3 — m3u non-200 '
            '(${m3uResp.statusCode}) for host=$host');
        return null;
      }

      final head = m3uResp.bodyBytes.length > _m3uHeadBytes
          ? m3uResp.bodyBytes.sublist(0, _m3uHeadBytes)
          : m3uResp.bodyBytes;
      final asString = String.fromCharCodes(head);

      final tvgUrl = _extractTvgUrl(asString);
      if (tvgUrl == null) {
        AppLog.info(
            'EpgDiscovery: variant3 — no url-tvg/tvg-url in m3u '
            'for host=$host');
        return null;
      }
      AppLog.info(
          'EpgDiscovery: variant3 — found tvg url $tvgUrl at $host');

      // Validate the embedded URL by fetching it. The head-bytes
      // check is what catches the empty <tv/> case.
      final tvgUri = Uri.tryParse(tvgUrl);
      if (tvgUri == null) return null;
      final tvgResp = await client
          .get(tvgUri,
              headers: const {'User-Agent': 'Free4Me-IPTV/1.0'})
          .timeout(_totalTimeout);
      if (!EpgValidator.isValidEpgResponse(tvgResp, tvgResp.bodyBytes)) {
        AppLog.info(
            'EpgDiscovery: variant3 — embedded tvg url rejected by '
            'validator for host=$host');
        return null;
      }

      final elapsed = DateTime.now().difference(start).inMilliseconds;
      AppLog.info(
          'EpgDiscovery: variant3 — hit at $host in ${elapsed}ms');
      return EpgDiscoveryResult(
        variant: 'xtream-m3u-tvg-url',
        url: tvgUrl,
        probedAt: start,
        elapsedMs: elapsed,
      );
    } on TimeoutException {
      AppLog.info('EpgDiscovery: variant3 — timeout for host=$host');
      return null;
    } catch (e) {
      AppLog.warn('EpgDiscovery: variant3 — error for host=$host: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// Test-only public shim for [_extractTvgUrl]. Kept named with
  /// `ForTest` so a `grep -E "ForTest\\("` finds the test
  /// surface; do not call from production code.
  static String? extractTvgUrlForTest(String m3uHead) =>
      _extractTvgUrl(m3uHead);

  /// Extracts the first `url-tvg="..."` or `tvg-url="..."` attribute
  /// from [m3uHead]. If the value is a comma-separated list (some
  /// forks emit two feeds), only the first is returned. Returns null
  /// if neither attribute is present.
  static String? _extractTvgUrl(String m3uHead) {
    // Xtream standard: url-tvg=
    final r1 = RegExp(r'url-tvg="([^"]+)"');
    final m1 = r1.firstMatch(m3uHead);
    if (m1 != null) {
      final raw = m1.group(1)!.trim();
      if (raw.isEmpty) return null;
      // Take the first comma-separated entry.
      return raw.split(',').first.trim();
    }
    // Fork: tvg-url=
    final r2 = RegExp(r'tvg-url="([^"]+)"');
    final m2 = r2.firstMatch(m3uHead);
    if (m2 != null) {
      final raw = m2.group(1)!.trim();
      if (raw.isEmpty) return null;
      return raw.split(',').first.trim();
    }
    return null;
  }
}
