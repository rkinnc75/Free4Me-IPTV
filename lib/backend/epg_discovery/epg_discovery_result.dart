/// fix386: result of an EPG auto-discovery probe.
///
/// One of three variants can produce a valid result (see
/// [EpgDiscovery.discover] in `epg_discovery.dart`):
///   - 'stalker-xmltv-query'   — direct xmltv.php?u=&p= GET (variant 1)
///   - 'stalker-xmltv-cookie'  — handshake + xmltv.php?type=itv (variant 2)
///   - 'xtream-m3u-tvg-url'    — m3u_plus url-tvg scrape (variant 3)
///
/// The [url] field is what gets persisted to `sources.epg_url` when the
/// caller accepts an auto-detection.
class EpgDiscoveryResult {
  /// Which variant produced this result. One of the strings above.
  final String variant;

  /// The auto-detected XMLTV URL to persist in `sources.epg_url`.
  final String url;

  /// When the probe was run. Used for the human-readable "auto · variant"
  /// display, and to enforce the "no re-probe" stickiness rule (a result
  /// is sticky for the lifetime of the source row).
  final DateTime probedAt;

  /// How long the probe took in milliseconds. Surfaced in app logs only;
  /// not persisted.
  final int elapsedMs;

  const EpgDiscoveryResult({
    required this.variant,
    required this.url,
    required this.probedAt,
    required this.elapsedMs,
  });

  /// Short tag for the source list pill — "auto · cookie" / "auto ·
  /// query" / "auto · tvg". Kept short to fit a 1-line row.
  String shortLabel() {
    switch (variant) {
      case 'stalker-xmltv-query':
        return 'auto · query';
      case 'stalker-xmltv-cookie':
        return 'auto · cookie';
      case 'xtream-m3u-tvg-url':
        return 'auto · tvg';
      default:
        return 'auto';
    }
  }
}
