import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/epg_discovery/epg_discovery_result.dart';
import 'package:open_tv/backend/epg_discovery/epg_validator.dart';

/// fix386 / variant 1: GET `<host>/xmltv.php?username=&password=` directly.
///
/// This is the cheapest probe — Stalker portals that expose the XMLTV
/// feed at the standard Xtream Codes endpoint return here in well
/// under 5s. Returns null on any failure (timeout, non-200, empty
/// body, non-XMLTV content). The walker then tries variant 2.
class StalkerXmltvQueryAuth {
  static const Duration _timeout = Duration(seconds: 5);

  /// Returns a result iff the host returns a valid XMLTV document at
  /// the standard `/xmltv.php?username=&password=` endpoint.
  static Future<EpgDiscoveryResult?> probe(
    String host,
    String username,
    String password,
  ) async {
    final start = DateTime.now();
    final url = Uri.tryParse(
      '$host/xmltv.php?username=${Uri.encodeComponent(username)}'
      '&password=${Uri.encodeComponent(password)}',
    );
    if (url == null) {
      AppLog.warn(
          'EpgDiscovery: variant1 — cannot build url for host=$host');
      return null;
    }
    try {
      // Review finding 149: stream the body and stop after headBytesCap bytes
      // (the validator only inspects the first 64 KB), instead of buffering a
      // multi-MB feed just to validate its head. A synthetic http.Response
      // carries the streamed status + headers so the validator is unchanged.
      final request = http.Request('GET', url)
        ..headers['User-Agent'] = 'Free4Me-IPTV/1.0';
      final client = http.Client();
      final List<int> bodyBytes = [];
      try {
        final streamed = await client.send(request).timeout(_timeout);
        final completer = Completer<void>();
        late final StreamSubscription<List<int>> sub;
        sub = streamed.stream.timeout(_timeout).listen(
          (chunk) {
            bodyBytes.addAll(chunk);
            if (bodyBytes.length >= EpgValidator.headBytesCap) {
              sub.cancel();
              if (!completer.isCompleted) completer.complete();
            }
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          onError: (Object e) {
            if (!completer.isCompleted) completer.completeError(e);
          },
          cancelOnError: true,
        );
        await completer.future;
        final capped = bodyBytes.length > EpgValidator.headBytesCap
            ? bodyBytes.sublist(0, EpgValidator.headBytesCap)
            : bodyBytes;
        final resp = http.Response.bytes(
          capped,
          streamed.statusCode,
          headers: streamed.headers,
        );
        if (!EpgValidator.isValidEpgResponse(resp, capped)) {
          AppLog.info(
              'EpgDiscovery: variant1 — host=$host rejected by validator');
          return null;
        }
        final elapsed = DateTime.now().difference(start).inMilliseconds;
        AppLog.info(
            'EpgDiscovery: variant1 — hit at $host in ${elapsed}ms');
        return EpgDiscoveryResult(
          variant: 'stalker-xmltv-query',
          url: url.toString(),
          probedAt: start,
          elapsedMs: elapsed,
        );
      } finally {
        client.close();
      }
    } on TimeoutException {
      AppLog.info('EpgDiscovery: variant1 — timeout for host=$host');
      return null;
    } catch (e) {
      AppLog.warn('EpgDiscovery: variant1 — error for host=$host: $e');
      return null;
    }
  }
}
