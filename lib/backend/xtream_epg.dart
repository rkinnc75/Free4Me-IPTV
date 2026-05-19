import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:open_tv/backend/http_client.dart';
import 'package:open_tv/models/programme.dart';
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
    if (url == null) return null;
    // Compute origin lazily — urlOrigin is only set during an active Xtream
    // refresh session, not persisted to DB.
    final origin = source.urlOrigin?.isNotEmpty == true
        ? source.urlOrigin!
        : Uri.tryParse(url)?.origin;
    if (origin == null || origin.isEmpty) return null;
    final u = source.username;
    final p = source.password;
    if (u == null || p == null) return null;
    return '$origin/xmltv.php?username=${Uri.encodeComponent(u)}&password=${Uri.encodeComponent(p)}';
  }

  /// Fetches Xtream short EPG for a single stream id.
  /// Returns a list of [Programme]s for the next few hours.
  static Future<List<Programme>> fetchShortEpg(
    Source source,
    int streamId,
    int sourceId,
  ) async {
    final base = source.urlOrigin ?? source.url;
    if (base == null) return [];
    final u = source.username;
    final p = source.password;
    if (u == null || p == null) return [];

    final url = Uri.tryParse(
      '$base/player_api.php?username=${Uri.encodeComponent(u)}'
      '&password=${Uri.encodeComponent(p)}&action=get_short_epg'
      '&stream_id=$streamId&limit=4',
    );
    if (url == null) return [];

    try {
      final resp = await AppHttp.getWithRetry(url, timeout: const Duration(seconds: 10));
      if (resp == null) return [];
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final epgListings = json['epg_listings'] as List<dynamic>?;
      if (epgListings == null) return [];
      return epgListings.map((e) {
        final m = e as Map<String, dynamic>;
        final start = _parseEpochSecs(m['start'] as String? ?? '');
        final end = _parseEpochSecs(m['end'] as String? ?? '');
        return Programme(
          epgChannelId: (m['stream_id'] ?? streamId).toString(),
          sourceId: sourceId,
          title: _decodeBase64(m['title'] as String? ?? ''),
          description: _decodeBase64(m['description'] as String? ?? ''),
          category: null,
          startUtc: start,
          stopUtc: end,
        );
      }).toList();
    } catch (e) {
      debugPrint('XtreamEpg.fetchShortEpg error: $e');
      return [];
    }
  }

  static int _parseEpochSecs(String s) {
    // Xtream returns timestamps as "YYYY-MM-DD HH:MM:SS"
    try {
      final dt = DateTime.parse(s.replaceFirst(' ', 'T'));
      return dt.millisecondsSinceEpoch ~/ 1000;
    } catch (_) {
      return 0;
    }
  }

  static String _decodeBase64(String s) {
    if (s.isEmpty) return s;
    try {
      return utf8.decode(base64.decode(s));
    } catch (_) {
      return s;
    }
  }
}
