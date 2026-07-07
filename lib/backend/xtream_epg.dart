import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/models/source.dart';

/// Fetches EPG data from an Xtream API endpoint.
///
/// Xtream Codes exposes `/xmltv.php?username=&password=` which returns
/// standard XMLTV XML (often gzip-compressed).  We return the URL so the
/// caller can hand it off to [XmltvParser].
class XtreamEpg {
  /// Returns the XMLTV URL for an Xtream source, or null if the source has
  /// no URL / credentials.
  ///
  /// Uses [Source.urlOrigin] when pre-filled; otherwise derives the origin
  /// from [Source.url] (DB-loaded sources don't persist urlOrigin).
  static String? xmltvUrl(Source source) {
    final url = source.url;
    if (url == null) {
      AppLog.warn(
        'XtreamEpg: "${source.name}" has no url — cannot derive XMLTV URL',
      );
      return null;
    }
    String? origin;
    if (source.urlOrigin?.isNotEmpty == true) {
      origin = source.urlOrigin;
    } else {
      try {
        final parsed = Uri.parse(url);
        // Uri.origin throws if scheme isn't http/https, so guard it.
        if (parsed.scheme == 'http' || parsed.scheme == 'https') {
          origin = parsed.origin;
        }
      } catch (e) {
        AppLog.warn(
          'XtreamEpg: cannot parse url for "${source.name}": $url ($e)',
        );
      }
    }
    if (origin == null || origin.isEmpty) {
      AppLog.warn(
        'XtreamEpg: cannot derive origin from "$url" for "${source.name}"',
      );
      return null;
    }
    final u = source.username;
    final p = source.password;
    if (u == null || p == null) {
      AppLog.warn(
        'XtreamEpg: "${source.name}" missing username/password — '
        'cannot build XMLTV URL',
      );
      return null;
    }
    final built =
        '$origin/xmltv.php?username=${Uri.encodeComponent(u)}&password=${Uri.encodeComponent(p)}';
    AppLog.info('XtreamEpg: built XMLTV URL → $origin/xmltv.php?...');
    return built;
  }
}
