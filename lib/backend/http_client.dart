import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

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
      _client = IOClient(_inner!);
    }
    return _client!;
  }

  /// GET with timeout. Retries once on socket / 5xx errors.
  static Future<http.Response?> getWithRetry(
    Uri url, {
    Duration timeout = const Duration(seconds: 20),
    Map<String, String>? headers,
  }) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final resp = await client.get(url, headers: headers).timeout(timeout);
        if (resp.statusCode >= 500 && resp.statusCode < 600 && attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
        if (resp.statusCode != 200) return null;
        return resp;
      } on TimeoutException catch (_) {
        if (attempt == 1) return null;
      } on SocketException catch (_) {
        if (attempt == 1) return null;
        await Future.delayed(const Duration(milliseconds: 500));
      } on HttpException catch (_) {
        return null;
      } catch (_) {
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
