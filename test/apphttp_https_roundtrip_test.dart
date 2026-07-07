// fix666 regression guard for the fix663 (v3.0.8) HTTPS breakage.
//
// fix663 set an HttpClient.connectionFactory that returned a plain
// Socket.startConnect. When a connectionFactory is set, the Dart SDK uses the
// returned socket AS-IS for direct connections and never upgrades it to TLS —
// so EVERY HTTPS request through AppHttp (update check, Xtream login/refresh,
// XMLTV EPG, M3U import, prewarm) sent plaintext to :443 and failed with an
// instant null. There was NO test round-tripping HTTPS through AppHttp, so it
// shipped silently. This is that test.
//
// It performs a real HTTPS GET through AppHttp against the app's own
// version.json (the exact call update_checker.dart makes). It is network-gated:
// a raw TCP pre-connect to the host proves connectivity, so a null result can
// only mean the TLS regression — not "offline". Skips cleanly when offline.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/http_client.dart';

const _host = 'raw.githubusercontent.com';
const _url =
    'https://$_host/rkinnc75/Free4Me-IPTV/main/version.json';

void main() {
  var online = false;

  setUpAll(() async {
    // Prove network + DNS + TCP to the host work. If this fails we're offline
    // and the HTTPS assertion below is skipped (not failed).
    try {
      final s = await Socket.connect(_host, 443,
          timeout: const Duration(seconds: 5));
      s.destroy();
      online = true;
    } catch (_) {
      online = false;
    }
  });

  test('AppHttp.getWithRetry completes a real HTTPS request (TLS not broken)',
      () async {
    if (!online) {
      markTestSkipped('offline — cannot reach $_host:443');
      return;
    }
    final resp = await AppHttp.getWithRetry(
      Uri.parse(_url),
      timeout: const Duration(seconds: 10),
    );
    // TCP to :443 succeeded in setUpAll, so a null here is the fix663
    // plaintext-to-TLS-port regression, NOT a connectivity problem.
    expect(resp, isNotNull,
        reason: 'HTTPS through AppHttp returned null despite reachable host — '
            'this is the fix663 connectionFactory-broke-TLS regression');
    expect(resp!.statusCode, 200);
    expect(resp.body, contains('latest'));
  });
}
