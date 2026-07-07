// fix666 regression guard for the fix663 (v3.0.8) HTTPS breakage.
//
// fix663 set an HttpClient.connectionFactory that returned a plain
// Socket.startConnect. When a connectionFactory is set, the Dart SDK uses the
// returned socket AS-IS for direct connections and never upgrades it to TLS —
// so EVERY HTTPS request through AppHttp (update check, Xtream login/refresh,
// XMLTV EPG, M3U import, prewarm) sent plaintext to :443 and failed with an
// instant null on v3.0.8/v3.0.9.
//
// A live HTTPS round-trip is the ideal test, but it is CI-flaky (a transient
// non-200 / slow egress on a runner is indistinguishable from the regression at
// the getWithRetry level, and it wrongly failed the v3.0.10 release once). So
// this is an OFFLINE source invariant that pins the exact defect class instead:
// AppHttp's shared client must not install a connectionFactory that bypasses
// TLS. fix666 sets none; a correct future DoH redesign MUST return
// SecureSocket for https — that case still passes. The real end-to-end HTTPS
// path is verified on-device (update check + source/EPG refresh).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AppHttp installs no TLS-bypassing connectionFactory (fix666)', () {
    // Code only — strip comment lines so the fix666 explanatory comment (which
    // mentions both connectionFactory and SecureSocket) can't mask a real
    // code-level violation.
    final code = File('lib/backend/http_client.dart')
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    if (code.contains('connectionFactory')) {
      // A factory is allowed ONLY if it uses SecureSocket for the TLS path.
      // fix663's plain Socket.startConnect factory would fail this.
      expect(code.contains('SecureSocket'), isTrue,
          reason: 'AppHttp wires an HttpClient.connectionFactory that does not '
              'use SecureSocket — this is the fix663 plaintext-to-TLS-port '
              'regression. A connectionFactory MUST return '
              'SecureSocket.startConnect for https URIs, or be removed so the '
              'SDK default TLS path is used.');
    }
    // No factory (fix666 state) → nothing to check; the SDK default
    // SecureSocket path handles HTTPS.
  });
}
