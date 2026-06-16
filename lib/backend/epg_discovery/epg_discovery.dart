import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/epg_discovery/epg_discovery_result.dart';
import 'package:open_tv/backend/epg_discovery/variants/stalker_xmltv_cookie_auth.dart';
import 'package:open_tv/backend/epg_discovery/variants/stalker_xmltv_query_auth.dart';
import 'package:open_tv/backend/epg_discovery/variants/xtream_m3u_tvg_url.dart';

/// fix386: orchestrates EPG auto-discovery for an Xtream source.
///
/// The walker tries three variants in order, returning the first valid
/// result. The walk stops on the first hit OR when all three miss.
///
///   1. [StalkerXmltvQueryAuth] — GET xmltv.php?u=&p= (5s budget)
///   2. [StalkerXmltvCookieAuth] — handshake + xmltv.php?type=itv
///                                (8s budget, shared between the pair)
///   3. [XtreamM3uTvgUrl] — m3u_plus url-tvg scrape + validation
///                          (5s budget, shared between the pair)
///
/// Total worst case: ~18.4s. Sequential, not parallel — Stalker
/// portals rate-limit on burst, and a parallel scan looks like a
/// brute-force probe. The user is told a toast on completion; the
/// source-list row shows a spinner during the walk.
class EpgDiscovery {
  /// Run the variant walk against [host] (full origin, e.g.
  /// `http://example.com:8080`) with the Xtream [username] and
  /// [password]. Returns the first valid result, or null if all
  /// three variants miss.
  static Future<EpgDiscoveryResult?> discover(
    String host,
    String username,
    String password,
  ) async {
    AppLog.info('EpgDiscovery: starting walk for host=$host');

    final r1 = await StalkerXmltvQueryAuth.probe(host, username, password);
    if (r1 != null) return r1;

    final r2 = await StalkerXmltvCookieAuth.probe(host, username, password);
    if (r2 != null) return r2;

    final r3 = await XtreamM3uTvgUrl.probe(host, username, password);
    if (r3 != null) return r3;

    AppLog.info('EpgDiscovery: walk completed with no hit for host=$host');
    return null;
  }
}
