import 'package:flutter/material.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// Per-version changelog entries shown in the What's New dialog.
/// Key format: major.minor.patch — patch can be omitted to mean "any patch
/// in that minor". The dialog shows all entries for [version] whose key is
/// a prefix of the running version string.
const _changelog = <String, List<String>>{
  '1.11.0': [
    'Dual-stream mini-player: long-press any live channel tile → '
        '"Watch in mini-player" to open a floating, muted overlay while '
        'you keep browsing',
    'Mini-player is draggable and snaps to any corner of the screen',
    'Swap button (⇄) in the mini-player swaps the overlay and full-screen '
        'channels instantly',
    'In-player minimize button — press the mini-player icon in the top bar '
        'to shrink the current channel to a corner overlay',
  ],
  '1.0': [
    'Configurable buffer (cache seconds, demuxer size) for live and VOD',
    'Player startup timeout + proper reconnect on error or stall',
    'Hardware decode (mediacodec) enabled by default',
    'Watchdog reconnect after sustained buffering',
    'Network connectivity awareness',
    'HTTP timeouts and retry on source refresh',
    'Fixed groups/categories SQL bug',
    'FTS5-backed channel search',
    'Pre-warm channel URL on focus',
  ],
  '1.5': [
    'In-app update checker — notifies when a new build is on GitHub',
    'Settings backup / restore — export and import all settings and sources',
    'Friendlier error messages throughout the app',
    'Setting help tooltips — tap any setting label for a full explanation',
  ],
  '1.6.0': [
    'EPG / Electronic Program Guide support',
    'XMLTV feed download and streaming parse (handles gzip feeds)',
    'Automatic channel ↔ EPG matching with 7 tiers of heuristics',
    'Now / Next strip on channel tiles',
    'Full program schedule screen per channel',
    'Per-source EPG URL setting with benchmark default',
    'Manual EPG channel mapping override screen',
    'Background EPG auto-refresh (configurable interval and time-of-day)',
  ],
  '1.6.1': [
    'Debug logging: enable from Settings → Diagnostics, then export the log',
    'Log file rotation increased to 20 MB',
  ],
  '1.6.2': [
    'Fixed: log export on Android (Storage Access Framework path handling)',
    'Fixed: EPG refresh now shows live progress (Connecting… / Downloading…)',
  ],
  '1.6.3': [
    'Fixed: EPG gzip double-decode that caused "Filter error, bad data"',
  ],
  '1.6.4': [
    'Fuzzy EPG channel matching: normalized name, token superset, and '
        'Jaccard similarity tiers — maps more channels automatically',
    'Per-tier match breakdown in the debug log after each refresh',
  ],
  '1.6.5': [
    'US callsign-aware EPG matching — e.g. "KXDF" → CBSKXDF.us',
    'Fuzzy tiers now skip ambiguous matches (tie = no match) to avoid '
        'assigning the wrong EPG data',
  ],
  '1.7': [
    'Catchup / time-shift playback',
    'Xtream sources with tv_archive=1 show a "Watch from beginning" button '
        'on past and currently-airing programs',
    'M3U sources with catchup-source/catchup-days attributes are fully '
        'supported (append / shift / default / flussonic engines)',
    'Tap the Now/Next strip on a channel tile to open the full schedule',
    'Catchup respects the provider\'s archive window (catchup-days)',
    'EPG channel matching now runs in a background thread — no more ANR '
        'dialogs during refresh on large feeds',
  ],
  '1.10.1': [
    'Update checker: manual "Check for updates" button now always runs '
        'regardless of throttle, and shows "up to date" confirmation',
    'Update checker: shortened to 1-hour interval when debug logging is on',
    'Update checker: all steps now logged to the debug log for diagnosis',
  ],
  '1.10.0': [
    'Picture-in-picture: press the PiP button or Home to keep watching in a '
        'floating mini-window while you use other apps',
    'PiP activates automatically on Android 12+ when you navigate away mid-stream',
  ],
  '1.9.2': [
    'TV mode: pressing OK/Enter on the EPG URL field now saves immediately',
    'TV mode: Save button is the first action in the EPG URL dialog (one D-pad press away)',
  ],
  '1.9.1': [
    'XMLTV parser now correctly matches <programme> tags',
    'Android TV D-pad no longer gets stuck on settings sliders and text fields',
    'Engine picker and source-name entry now work with D-pad in TV mode',
  ],
  '1.9.0': [
    'Xtream catchup stream IDs now correctly read from the database',
    'EPG auto-matcher no longer locks user-set channel mappings on every refresh',
    'ExoPlayer no longer triggers false reconnects on live HLS streams',
    'Player engine selection now uses per-source default when opening from grid',
    'Editing a source URL no longer clears the per-source engine preference',
    'Settings backup now includes EPG, debug, and per-source preferences',
    'EPG background refresh now registers correctly on first launch',
    'Cast errors surface as snackbar messages instead of silent failures',
    'Issue-report and donate links updated to Free4Me-IPTV repository',
    'EPG program import up to 100× faster (batched multi-row SQL inserts)',
    'Eliminated redundant settings database read on every cold start',
  ],
  '1.8.2': [
    'In-app update checker now active — you will be notified when a new '
        'version is available on GitHub',
  ],
  '1.8': [
    'ExoPlayer engine for HLS, DASH, and MP4 streams — better adaptive '
        'bitrate and battery efficiency on compatible streams',
    'Automatic engine selection: HLS/.m3u8, DASH/.mpd, and .mp4 URLs route '
        'to ExoPlayer; everything else (MPEG-TS, RTMP) stays on libmpv',
    'Per-channel engine override (long-press a channel tile in a future update)',
    'Global engine override in Settings (Auto / libmpv / ExoPlayer)',
    'Chromecast support — cast HLS, DASH, and MP4 streams to any Chromecast '
        'or Google TV device on your network',
    'Unsupported formats (MPEG-TS) show a clear "not supported" message '
        'instead of silently failing',
    'On Cast disconnect, local playback resumes from the Cast-reported position',
  ],
};

/// Returns all changelog entries whose version key is a prefix of [version].
List<MapEntry<String, List<String>>> _entriesForVersion(String version) {
  return _changelog.entries
      .where((e) => version.startsWith(e.key))
      .toList();
}

class WhatsNewModal extends StatelessWidget {
  final String version;
  const WhatsNewModal({super.key, required this.version});

  @override
  Widget build(BuildContext context) {
    final entries = _entriesForVersion(version);

    // Build bullet-point content for this version
    final bullets = entries.isEmpty
        ? ['See the GitHub releases page for details.']
        : entries.expand((e) => e.value).toList();

    return AlertDialog(
      title: Text("What's new in $version"),
      actions: [
        TextButton(
          onPressed: () async {
            await launchUrl(
              Uri.parse(
                'https://github.com/rkinnc75/Free4Me-IPTV/discussions',
              ),
              mode: LaunchMode.externalApplication,
            );
            if (context.mounted) Navigator.pop(context, false);
          },
          child: const Text('Donate'),
        ),
        TextButton(
          onPressed: () async {
            await SettingsService.updateLastSeenVersion();
            if (context.mounted) Navigator.pop(context, true);
          },
          child: const Text("Don't show again"),
        ),
      ],
      content: Scrollbar(
        thumbVisibility: true,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final bullet in bullets)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('• ', style: TextStyle(fontSize: 14)),
                        Expanded(
                          child: Text(bullet, style: const TextStyle(fontSize: 14)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
