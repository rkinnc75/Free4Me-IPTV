import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:open_tv/backend/app_logger.dart';

/// fix663: DNS-over-HTTPS resolver.
///
/// Resolves A/AAAA records via a provider's DoH JSON API instead of the
/// system resolver, so a provider whose PORTAL/API host is DNS-blocked by the
/// user's ISP still works. Wired into [AppHttp] via
/// `HttpClient.connectionFactory` (Dart-side HTTP only — the mpv media host is
/// out of scope; libmpv resolves internally in native code).
///
/// Design constraints:
///   - **Never hard-fail.** Any DoH error (network, parse, empty answer) falls
///     back to `InternetAddress.lookup` (system DNS). DoH is an optional route
///     around blocking, not a new point of failure.
///   - **Own DoH-host resolution must not recurse.** The DoH endpoint's own
///     hostname is resolved by the SYSTEM resolver (a plain https GET via a
///     private client with NO connectionFactory), so we never DoH-resolve the
///     DoH host through ourselves.
///   - **Short in-memory TTL cache** keyed by host, so a burst of requests
///     (import + EPG + catch-up) doesn't issue one DoH lookup each.
class DohResolver {
  DohResolver._();

  /// Provider ids persisted in settings. `off` disables DoH entirely.
  static const String off = 'off';
  static const String cloudflare = 'cloudflare';
  static const String google = 'google';
  static const String nextdns = 'nextdns';
  static const String quad9 = 'quad9';

  static const Set<String> providers = {
    off,
    cloudflare,
    google,
    nextdns,
    quad9,
  };

  /// Human labels for the settings UI.
  static const Map<String, String> labels = {
    off: 'Off (system DNS)',
    cloudflare: 'Cloudflare (1.1.1.1)',
    google: 'Google (8.8.8.8)',
    nextdns: 'NextDNS',
    quad9: 'Quad9 (9.9.9.9)',
  };

  static String _endpoint(String provider, String host, String type) {
    final n = Uri.encodeComponent(host);
    switch (provider) {
      case google:
        return 'https://dns.google/resolve?name=$n&type=$type';
      case nextdns:
        return 'https://dns.nextdns.io/resolve?name=$n&type=$type';
      case quad9:
        // Quad9's DoH JSON endpoint (RFC 8484 host also serves the JSON API).
        return 'https://dns.quad9.net:5053/dns-query?name=$n&type=$type';
      case cloudflare:
      default:
        return 'https://cloudflare-dns.com/dns-query?name=$n&type=$type';
    }
  }

  /// The active provider id. `off` by default; updated from settings.
  static String activeProvider = off;

  static bool get enabled => activeProvider != off;

  // ── cache ──────────────────────────────────────────────────────────────
  static final Map<String, _CacheEntry> _cache = {};
  static const Duration _ttl = Duration(minutes: 5);

  /// A private client used ONLY to talk to the DoH endpoint. It has no
  /// connectionFactory, so its own (system-DNS) resolution can never recurse
  /// back into DohResolver.
  static HttpClient? _dohClient;
  static HttpClient get _client => _dohClient ??= (HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    ..idleTimeout = const Duration(seconds: 20));

  /// Resolve [host] to a list of addresses. Returns system-DNS results when
  /// DoH is off, on any DoH failure, or when DoH returns no usable answer.
  static Future<List<InternetAddress>> lookup(String host) async {
    // A literal IP needs no resolution.
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return [literal];

    if (!enabled) return _systemLookup(host);

    final cached = _cache[host];
    if (cached != null && !cached.isExpired) {
      return cached.addresses;
    }

    try {
      final provider = activeProvider;
      final v4 = await _query(provider, host, 'A');
      // Best-effort AAAA; ignore failures (many IPTV hosts are v4-only).
      List<InternetAddress> v6 = const [];
      try {
        v6 = await _query(provider, host, 'AAAA');
      } catch (_) {}
      final all = [...v4, ...v6];
      if (all.isEmpty) {
        // DoH answered but with nothing usable — fall back rather than fail.
        return _systemLookup(host);
      }
      _cache[host] = _CacheEntry(all, DateTime.now().add(_ttl));
      return all;
    } catch (e) {
      AppLog.warn('DohResolver: DoH lookup failed for $host — $e; '
          'falling back to system DNS');
      return _systemLookup(host);
    }
  }

  static Future<List<InternetAddress>> _systemLookup(String host) async {
    // Let the OS resolver run; if IT throws, the caller's connect will surface
    // the same error it would have without DoH.
    return InternetAddress.lookup(host);
  }

  static Future<List<InternetAddress>> _query(
      String provider, String host, String type) async {
    final uri = Uri.parse(_endpoint(provider, host, type));
    final req = await _client.getUrl(uri);
    // The application/dns-json content type is required by Google/Quad9 and
    // accepted by Cloudflare/NextDNS.
    req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
    final resp = await req.close().timeout(const Duration(seconds: 6));
    if (resp.statusCode != 200) {
      throw HttpException('DoH HTTP ${resp.statusCode}', uri: uri);
    }
    final body = await resp.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final answers = json['Answer'];
    if (answers is! List) return const [];
    final out = <InternetAddress>[];
    for (final a in answers) {
      if (a is! Map) continue;
      // type 1 = A, 28 = AAAA. Skip CNAME (5) and anything else.
      final t = a['type'];
      final data = a['data'];
      if (data is! String) continue;
      if ((type == 'A' && t == 1) || (type == 'AAAA' && t == 28)) {
        final addr = InternetAddress.tryParse(data);
        if (addr != null) out.add(addr);
      }
    }
    return out;
  }

  /// Test/diagnostic hook — clears the in-memory cache.
  static void clearCache() => _cache.clear();
}

class _CacheEntry {
  final List<InternetAddress> addresses;
  final DateTime expiresAt;
  _CacheEntry(this.addresses, this.expiresAt);
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}
