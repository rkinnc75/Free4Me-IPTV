import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/epg_discovery/epg_discovery_result.dart';
import 'package:open_tv/backend/epg_discovery/epg_validator.dart';

/// fix386 / variant 2: Stalker portal cookie auth — handshake then
/// xmltv.php?type=itv.
///
/// Step A: GET `<host>/server/load.php?type=stb&action=handshake`
///   Headers: Cookie: mac=00:1A:79:XX:XX:XX; stb_lang=en;
///            timezone=Europe/London
///            User-Agent: Mozilla/5.0
///   Parse the JSON response and extract `js.token`.
///
/// Step B: GET `<host>/xmltv.php?type=itv`
///   Headers: Cookie: mac=00:1A:79:XX:XX:XX; Bearer `token`
///
/// Some Stalker portals don't expose variant 1 (no `xmltv.php?u=&p=`)
/// but DO expose the cookie-auth path. This variant is the fallback.
///
/// Returns null on any failure: handshake non-200, missing token,
/// xmltv.php non-200, or non-XMLTV body. The walker then tries
/// variant 3.
class StalkerXmltvCookieAuth {
  /// Total budget for the pair of requests. Both share this so a slow
  /// handshake still leaves room for the xmltv fetch.
  static const Duration _totalTimeout = Duration(seconds: 8);

  /// Placeholder MAC that satisfies the Stalker portal cookie shape
  /// (`00:1A:79:XX:XX:XX`). Real portals don't validate the value,
  /// just the format; this is a deterministic per-build constant so
  /// every probe from this client uses the same MAC, which some
  /// portals expect for session stickiness.
  static const String _mac = '00:1A:79:AB:CD:EF';

  /// Returns a result iff the portal's cookie-auth path yields a
  /// valid XMLTV document. Total time budget: 8 seconds.
  static Future<EpgDiscoveryResult?> probe(
    String host,
    String username,
    String password,
  ) async {
    final start = DateTime.now();

    final handshakeUrl = Uri.tryParse(
      '$host/server/load.php?type=stb&action=handshake',
    );
    final xmltvUrl = Uri.tryParse('$host/xmltv.php?type=itv');
    if (handshakeUrl == null || xmltvUrl == null) {
      AppLog.warn(
          'EpgDiscovery: variant2 — cannot build urls for host=$host');
      return null;
    }

    final client = http.Client();
    try {
      // Step A — handshake.
      final handshakeStart = DateTime.now();
      final handshakeResp = await client
          .get(
            handshakeUrl,
            headers: {
              'Cookie':
                  'mac=$_mac; stb_lang=en; timezone=Europe/London',
              'User-Agent': 'Mozilla/5.0',
            },
          )
          .timeout(_totalTimeout);
      if (handshakeResp.statusCode != 200) {
        AppLog.info(
            'EpgDiscovery: variant2 — handshake non-200 '
            '(${handshakeResp.statusCode}) for host=$host');
        return null;
      }

      String? token;
      try {
        final json = jsonDecode(handshakeResp.body);
        if (json is Map && json['js'] is Map) {
          token = (json['js'] as Map)['token'] as String?;
        }
      } catch (e) {
        AppLog.info(
            'EpgDiscovery: variant2 — handshake JSON parse failed: $e');
        return null;
      }
      if (token == null || token.isEmpty) {
        AppLog.info(
            'EpgDiscovery: variant2 — no token in handshake for host=$host');
        return null;
      }

      // Step B — xmltv with bearer cookie. Honour the remaining
      // budget so a slow handshake doesn't starve the fetch.
      final remaining = _totalTimeout - DateTime.now().difference(handshakeStart);
      if (remaining <= Duration.zero) {
        AppLog.info(
            'EpgDiscovery: variant2 — handshake ate the full budget, '
            'skipping xmltv');
        return null;
      }
      final xmltvResp = await client
          .get(
            xmltvUrl,
            headers: {
              'Cookie': 'mac=$_mac; Bearer $token',
              'User-Agent': 'Mozilla/5.0',
            },
          )
          .timeout(remaining);
      final bodyBytes = xmltvResp.bodyBytes;
      if (!EpgValidator.isValidEpgResponse(xmltvResp, bodyBytes)) {
        AppLog.info(
            'EpgDiscovery: variant2 — host=$host rejected by validator');
        return null;
      }
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      AppLog.info(
          'EpgDiscovery: variant2 — hit at $host in ${elapsed}ms');
      return EpgDiscoveryResult(
        variant: 'stalker-xmltv-cookie',
        url: xmltvUrl.toString(),
        probedAt: start,
        elapsedMs: elapsed,
      );
    } on TimeoutException {
      AppLog.info('EpgDiscovery: variant2 — timeout for host=$host');
      return null;
    } catch (e) {
      AppLog.warn('EpgDiscovery: variant2 — error for host=$host: $e');
      return null;
    } finally {
      client.close();
    }
  }
}
