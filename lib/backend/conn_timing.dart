import 'dart:io';

import 'package:open_tv/backend/app_logger.dart';

/// fix421: one-shot connection-setup timing diagnostic. Measures the cold
/// pre-first-byte phases — DNS resolve, TCP connect, TLS handshake — for a
/// stream's host, so a log shows whether channel-start latency lives in
/// connection setup (where DNS pre-resolution could help) or somewhere else.
///
/// Deliberately sends NO HTTP request: a bare TCP+TLS handshake carries no
/// credentials, so it does not consume a provider "max connections" slot the
/// way an authenticated GET would. Gated behind debug logging, fire-and-forget,
/// and never blocks or fails playback. The host is redacted by the logger
/// (fix415) like every other line.
class ConnTiming {
  static Future<void> probe(String url) async {
    if (!AppLog.enabled) return;
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') return;
    final host = uri.host;
    if (host.isEmpty) return;
    final isTls = uri.scheme == 'https';
    final port = uri.hasPort ? uri.port : (isTls ? 443 : 80);
    const limit = Duration(seconds: 5);
    final sw = Stopwatch()..start();
    int dns = -1, tcp = -1, tls = -1;
    Socket? sock;
    try {
      final addrs = await InternetAddress.lookup(host).timeout(limit);
      dns = sw.elapsedMilliseconds;
      if (addrs.isEmpty) {
        AppLog.info('CONNPROBE host=$host dns=${dns}ms (no address)');
        return;
      }
      sw.reset();
      sock = await Socket.connect(addrs.first, port).timeout(limit);
      tcp = sw.elapsedMilliseconds;
      if (isTls) {
        sw.reset();
        sock = await SecureSocket.secure(sock, host: host).timeout(limit);
        tls = sw.elapsedMilliseconds;
      }
      final total = dns + tcp + (tls < 0 ? 0 : tls);
      AppLog.info('CONNPROBE host=$host dns=${dns}ms tcp=${tcp}ms'
          '${isTls ? ' tls=${tls}ms' : ''} total=${total}ms');
    } catch (e) {
      // Never log the raw exception — it can contain the resolved IP. The phase
      // values already show how far the handshake got before failing.
      AppLog.info('CONNPROBE host=$host dns=${dns}ms tcp=${tcp}ms'
          '${isTls ? ' tls=${tls}ms' : ''} aborted=${e.runtimeType}');
    } finally {
      try {
        sock?.destroy();
      } catch (_) {}
    }
  }
}
