import 'package:flutter/material.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// Per-version changelog entries shown in the What's New dialog.
/// Key format: major.minor.patch — patch can be omitted to mean "any patch
/// in that minor". The dialog shows all entries for [version] whose key is
/// a prefix of the running version string.
const _changelog = <String, List<String>>{
  '1.11.11': [
    'Fix (fix11): eliminated residual "Cannot seek in this stream." reconnects '
        'on MPEG-TS livestreams. The force-seekable=no property was being reset '
        'by mpv\'s internal demuxer init on every open(). Now passed via '
        'media_kit extras so it travels with the open command itself and '
        'survives the reset. A startup-grace guard suppresses any slip-through.',
    'Fix (fix10): stableThresholdSecs setting was not persisted to SQLite — '
        'every app restart silently reset it to 30 regardless of what was '
        'configured. Persistence wired in settings_service.dart.',
    'Fix (fix10): app version and build number are now logged on every startup '
        '("App started — version=1.11.11 build=44"). Log files are now '
        'self-identifying — no more guessing which build produced a given log.',
  ],
  '1.11.10': [
    'Fix (fix9): eliminated the "Cannot seek in this stream." reconnect on '
        'every channel open — mpv probes seekability during demuxer init by '
        'attempting a seek; MPEG-TS livestreams reject it. Adding '
        'force-seekable=no suppresses the probe entirely. Every channel '
        'should now open cleanly on the first attempt with no reconnect.',
    'Fix (fix8 #2): reconnect counter was incrementing by 2 per permanent '
        'failure (pre-increment in errorStream + increment in onDisconnect). '
        'Removed the pre-increment; onDisconnect is now the single source '
        'of truth, giving the correct 1/6 → 2/6 → … sequence.',
    'Fix (fix8 #3): after "max reconnects reached", the stream could '
        'automatically re-open ~60 s later via a background timer. '
        'Give-up path now sets exiting=true and cancels all timers.',
  ],
  '1.11.9': [
    'Fix: update dialog now shows "v1.x.x → v1.y.y" instead of a static '
        'description; build script now auto-extracts per-version release notes '
        'from the in-app changelog and writes them to version.json',
    'Settings: "Stable playback threshold" slider (5–60 s, default 30 s) — '
        'controls how long a stream must play without interruption before the '
        'reconnect retry counter resets; replaces the previous hardcoded 30 s',
  ],
  '1.11.8': [
    'Fix: infinite reconnect loop still occurred after fix7 — the brief '
        'buffering=false event that fires immediately after open() was '
        'resetting the reconnect counter before the async "Failed to open" '
        'error arrived, causing the counter to stick at 2/6 indefinitely. '
        'Counter now resets only after 30 seconds of confirmed stable playback.',
  ],
  '1.11.7': [
    'Fix (fix6): eliminated the "Cannot seek in this stream" reconnect loop '
        'caused by _applyMpvOptions() running twice on reconnect — mpv properties '
        'are now applied only before open(), never mid-stream',
    'Fix (fix6): cast resume path now also calls reapplyOptions() before open()',
    'Fix (fix7): infinite reconnect loop on permanently unavailable streams '
        '(geo-blocked, offline, expired token) — a new _totalReconnectAttempts '
        'counter catches the async error path that bypassed the existing '
        '_consecutiveOpenFailures guard; stops after 6 attempts and shows '
        '"Stream unavailable" instead of looping forever',
    'Fix (fix7): permanent errors (Failed to open, 403, 404, Connection refused) '
        'are classified separately and exhaust the retry budget faster',
    'Fix (fix7): reconnect counters reset when stable playback is confirmed '
        'so a brief blip does not permanently consume the retry budget',
  ],
  '1.11.6': [
    'Fix: dual audio during PiP swap — three root causes addressed:\n'
        '  1. Overlay engine now muted BEFORE open() so the stream never '
        'starts at full volume (was muted after, leaving a window)\n'
        '  2. unregisterMain() is now engine-scoped — the old Player\'s '
        'dispose() no longer wipes the new Player\'s registration, fixing '
        'broken swap on 2nd and subsequent uses\n'
        '  3. muteMain() is now called before any navigation so the pop '
        'transition animation plays silently',
  ],
  '1.11.5': [
    'Settings: tap the App version tile to open the full version history',
    'Mini-player: audio from the main player is now muted before the swap '
        'transition, preventing dual-audio bleed during navigation',
    'EPG: maximum refresh interval raised from 48 h to 168 h (7 days)',
    'Diagnostics: when debug logging is enabled, tab/filter switches '
        '(All → Categories → Favorites → History) are now logged with full '
        'filter state to help diagnose blank-category issues',
    'History: confirmed already sorted by most-recently-watched first '
        '(ORDER BY last_watched DESC)',
  ],
  '1.11.4': [
    'Fix: eliminated the 3-second reconnect on every livestream open — '
        'mpv was allocating a rewind buffer and probing a seek on non-seekable '
        'MPEG-TS streams, which the server rejected as a fatal error. '
        'Back buffer is now set to 0 for all live streams '
        '(confirmed via exported debug log).',
  ],
  '1.11.3': [
    'Fix: mini-player restore and swap buttons now correctly open full-screen '
        '(root cause: overlay widget lives outside the Navigator subtree — '
        'now uses the app navigator key directly)',
    'Fix: stream startup delay is back to normal — buffering indicator is '
        'visible immediately again; only the reconnect watchdog is suppressed '
        'during the 3-second stabilisation window',
    'Layout: native PiP button stays top-right; mini-player (⧉) button '
        'moved to bottom-right so the two icons are clearly separated',
  ],
  '1.11.2': [
    'Mini-player: buttons are now 44 px touch targets — no more accidental close when tapping swap',
    'Mini-player: drag is now on the video surface only, so button taps are never swallowed',
    'Mini-player: added ⤢ Restore button (far left) — tap to expand the overlay back to full screen; tap the video does the same',
    'Mini-player: close button (✕) is now red so it is visually distinct from swap (⇄)',
  ],
  '1.11.1': [
    'New app icon — updated to the Free4Me-IPTV brand logo',
    'Full Changelog — tap "Full changelog" in the What\'s New dialog to see '
        'all release notes for every version',
    'Fix: hardware decode (HW) now uses the correct decoder per platform '
        '(mediacodec on Android, VideoToolbox on iOS)',
    'Fix: eliminated false reconnect loop on stream open — '
        '3-second startup grace period prevents buffering/completion events '
        'from firing before the stream has stabilized',
    'Player events (engine selection, open success/failure, buffering, reconnect) '
        'are now written to the debug log for remote diagnosis',
    'EPG background refresh scheduling is now logged so over-refresh can be diagnosed',
  ],
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

/// All versions sorted newest-first using semver-style comparison.
List<String> get _allVersionsSorted {
  final keys = _changelog.keys.toList();
  keys.sort((a, b) {
    final aParts = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final bParts = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final len = aParts.length > bParts.length ? aParts.length : bParts.length;
    for (var i = 0; i < len; i++) {
      final av = i < aParts.length ? aParts[i] : 0;
      final bv = i < bParts.length ? bParts[i] : 0;
      if (av != bv) return bv.compareTo(av); // descending
    }
    return 0;
  });
  return keys;
}

/// Bullet list widget reused in both the "What's New" and "Full Changelog" views.
Widget _bulletList(List<String> bullets) {
  return Column(
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
  );
}

class WhatsNewModal extends StatelessWidget {
  final String version;
  const WhatsNewModal({super.key, required this.version});

  @override
  Widget build(BuildContext context) {
    final entries = _entriesForVersion(version);

    final bullets = entries.isEmpty
        ? ['See the GitHub releases page for details.']
        : entries.expand((e) => e.value).toList();

    return AlertDialog(
      title: Text("What's new in $version"),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FullChangelogPage()),
            );
          },
          child: const Text('Full changelog'),
        ),
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
            child: _bulletList(bullets),
          ),
        ),
      ),
    );
  }
}

/// Full scrollable changelog — all versions newest-first.
class FullChangelogPage extends StatelessWidget {
  const FullChangelogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final versions = _allVersionsSorted;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Full Changelog'),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        itemCount: versions.length,
        itemBuilder: (context, index) {
          final ver = versions[index];
          final bullets = _changelog[ver]!;
          return Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'v$ver',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
                const SizedBox(height: 6),
                _bulletList(bullets),
                const Divider(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }
}
