import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:open_tv/backend/doh_resolver.dart';

/// Review finding 150: classifies why an AppHttp request did not yield a 200
/// body, so callers can distinguish PERMANENT failures (auth/credentials/gone
/// — do not keep retrying forever) from TRANSIENT ones (timeout/socket/5xx —
/// safe to preserve prior data and try again later).
enum HttpFailureKind {
  /// 401/403 (and 407): credentials rejected. Permanent until fixed.
  authRejected,

  /// 404/410: resource/line gone. Permanent.
  notFound,

  /// Any other non-200 (incl. 5xx that survived the one retry). Transient-ish.
  httpError,

  /// TimeoutException after the final attempt.
  timeout,

  /// SocketException / HttpException / other network error after final attempt.
  network,
}

/// Free4Me-IPTV: a single shared HTTP client with sane timeouts, keep-alive,
/// and a one-shot retry helper. Used by all source-refresh and pre-warm code.
class AppHttp {
  static http.Client? _client;
  static HttpClient? _inner;

  static http.Client get client {
    if (_client == null) {
      _inner = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..idleTimeout = const Duration(seconds: 30)
        ..autoUncompress = true
        ..maxConnectionsPerHost = 6;
      // fix663: route Dart-side HTTP host resolution through DoH when a
      // provider is selected (routes around ISP DNS blocking of provider
      // portal/API/EPG hosts). connectionFactory runs per connection: we
      // resolve the host ourselves, connect to the resolved IP, and set the
      // TLS SNI/host to the ORIGINAL hostname so certificate validation still
      // matches. When DoH is off (default) or resolution yields nothing, this
      // falls straight through to the system connect. The mpv media host is
      // NOT covered here (libmpv resolves internally) — see fix663 notes.
      _inner!.connectionFactory = _dohConnectionFactory;
      _client = IOClient(_inner!);
    }
    return _client!;
  }

  /// fix663: per-connection factory that resolves the destination host via
  /// [DohResolver] (which itself falls back to system DNS on any failure), then
  /// opens a socket to the first resolved address. TLS handshakes still use the
  /// original hostname for SNI/cert checks because [ConnectionTask] carries the
  /// [uri] host through unchanged — we only substitute the socket's target IP.
  static Future<ConnectionTask<Socket>> _dohConnectionFactory(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    // Proxied connections: let the system handle proxy host resolution.
    if (proxyHost != null) {
      return Socket.startConnect(proxyHost, proxyPort ?? uri.port);
    }
    if (!DohResolver.enabled) {
      return Socket.startConnect(uri.host, uri.port);
    }
    try {
      final addrs = await DohResolver.lookup(uri.host);
      if (addrs.isEmpty) {
        return Socket.startConnect(uri.host, uri.port);
      }
      // Connect to the resolved IP. HttpClient applies SNI from the request's
      // Host (the original uri.host), so cert validation is unaffected.
      return Socket.startConnect(addrs.first, uri.port);
    } catch (_) {
      // Any resolver hiccup → behave exactly as the default factory would.
      return Socket.startConnect(uri.host, uri.port);
    }
  }

  /// GET with timeout. Retries once on socket / 5xx errors.
  static Future<http.Response?> getWithRetry(
    Uri url, {
    Duration timeout = const Duration(seconds: 20),
    Map<String, String>? headers,
    void Function(HttpFailureKind kind, int? statusCode)? onFailure,
  }) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final resp = await client.get(url, headers: headers).timeout(timeout);
        if (resp.statusCode >= 500 && resp.statusCode < 600 && attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
        if (resp.statusCode != 200) {
          final sc = resp.statusCode;
          if (sc == 401 || sc == 403 || sc == 407) {
            onFailure?.call(HttpFailureKind.authRejected, sc);
          } else if (sc == 404 || sc == 410) {
            onFailure?.call(HttpFailureKind.notFound, sc);
          } else {
            onFailure?.call(HttpFailureKind.httpError, sc);
          }
          return null;
        }
        return resp;
      } on TimeoutException catch (_) {
        if (attempt == 1) {
          onFailure?.call(HttpFailureKind.timeout, null);
          return null;
        }
      } on SocketException catch (_) {
        if (attempt == 1) {
          onFailure?.call(HttpFailureKind.network, null);
          return null;
        }
        await Future.delayed(const Duration(milliseconds: 500));
      } on HttpException catch (_) {
        onFailure?.call(HttpFailureKind.network, null);
        return null;
      } catch (_) {
        onFailure?.call(HttpFailureKind.network, null);
        return null;
      }
    }
    return null;
  }

  /// HEAD that follows redirects manually. Used for URL pre-warm.
  /// Returns the final URL after redirects, or null on failure.
  /// Short timeout because this is a UX hint, not a hard dependency.
  static Future<String?> resolveRedirects(
    String urlStr, {
    int maxHops = 4,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    var current = urlStr;
    for (int hop = 0; hop < maxHops; hop++) {
      try {
        final uri = Uri.parse(current);
        final req = http.Request('HEAD', uri)..followRedirects = false;
        final streamed = await client.send(req).timeout(timeout);
        final code = streamed.statusCode;
        if (code >= 300 && code < 400) {
          final loc = streamed.headers['location'];
          if (loc == null) return current;
          current = Uri.parse(current).resolve(loc).toString();
          continue;
        }
        return current;
      } catch (_) {
        return null;
      }
    }
    return current;
  }

  /// Build a GET request object (without sending) for use with [sendStreaming].
  static Future<http.Request> buildGetRequest(
    Uri url, {
    Map<String, String>? headers,
  }) async {
    final req = http.Request('GET', url);
    if (headers != null) req.headers.addAll(headers);
    return req;
  }

  /// Send a streaming request with a timeout on initial response headers.
  static Future<http.StreamedResponse?> sendStreaming(
    http.BaseRequest req, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      return await client.send(req).timeout(timeout);
    } catch (_) {
      return null;
    }
  }
}
