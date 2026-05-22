import 'package:flutter/material.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// Per-version changelog entries shown in the What's New dialog.
/// Key format: major.minor.patch — patch can be omitted to mean "any patch
/// in that minor". The dialog shows all entries for [version] whose key is
/// a prefix of the running version string.
const _changelog = <String, List<String>>{
  '1.15.2': [
    'New: Multi-view cells now show a "Now / Next" program guide strip '
        'at the bottom of each playing cell. Displays the current program '
        'title and the next programme with its start time for any channel '
        'that has EPG data. Cells without EPG data or non-live channels '
        'show just the channel name as before.',
  ],
  '1.15.1': [
    'New: Multi-view audio focus — the app now requests OS audio focus '
        'when multi-view is open. Background music and podcast apps are '
        'properly interrupted. Incoming calls, Siri, and alarms mute all '
        'cells automatically and restore volume when the interruption ends.',
    'Fix: Stream-scanner green highlight now appears in every view '
        '(all channels, livestreams, movies, history) — not just while '
        'the search box is active. Validated channels also show a green '
        'check badge in the multi-view channel picker.',
  ],
  '1.15.0': [
    'Fix: "Cannot seek in this stream" error now suppressed unconditionally '
        '(not just during startup grace). Eliminates false reconnects on every '
        'channel open for MPEG-TS livestreams.',
    'Fix: Concurrent reconnect race condition — _isReconnecting flag is now '
        'set synchronously before any await, so two simultaneous onDisconnect '
        'calls can no longer both slip through the guard.',
    'New: Stream-Ended Reconnect Delay (Settings → Buffering). Waits '
        'up to 10 s before reconnecting when the stream signals it has ended — '
        'gives IPTV providers time to re-establish TCP before triggering a '
        'full reconnect. Default: 2 000 ms.',
    'New: Mini-Player Demuxer Cache slider (Settings → Buffering). '
        'Independently tune the forward buffer for the overlay / mini-player '
        'stream. Default is auto-detected from device RAM.',
    'New: Player Buffer Size slider (Settings → Buffering). Controls the '
        'libmpv read-ahead buffer per player instance. Mini-player uses half '
        'automatically. Default is auto-detected from device RAM.',
    'New: DeviceMemory — reads /proc/meminfo on Android to detect total '
        'RAM and set smart buffer defaults on first run. All buffer slider '
        'maximums are now capped at 75 % of device RAM.',
    'Updated: All settings help messages rewritten with ↑/↓ guidance, '
        'real defaults, and device-specific context for Onn 4K / Shield.',
  ],
  '1.14.2': [
    'Fix: Multi-view 1×2 and 2×2 now fill the screen correctly in both '
        'portrait and landscape. 1×2 switches between side-by-side (landscape) '
        'and stacked (portrait) automatically. 2×2 computes its cell aspect '
        'ratio from actual screen dimensions so the grid always fills edge '
        'to edge with no black bars.',
  ],
  '1.14.1': [
    'Fix: 1×2 multi-view cells now show video correctly. Previously the '
        'Row layout gave cells no width, so mpv had no surface to render '
        'on — audio played but the screen was black.',
    'Fix: Long-press any playing multi-view cell to get a menu: '
        '"Replace channel", "Full screen", or "Close cell". Tap "More" '
        'on an errored cell for the same options. This unblocks a stuck '
        'cell without having to exit the screen.',
    'Fix: Mini-player and picture-in-picture buttons are now hidden '
        'while multi-view is enabled. The floating overlay is stopped '
        'automatically when you enter the multi-view screen.',
  ],
  '1.14.0': [
    'New: Multi-view — watch 1×2 (side-by-side) or 2×2 (quad grid) live '
        'streams simultaneously. Enable in Settings → Multi-view layout, '
        'then tap the grid icon in the channel list toolbar.',
    'New: Each multi-view cell independently plays, mutes, and reconnects. '
        'Tap a cell to give it audio focus. Double-tap to promote it to '
        'full-screen. Tap + to assign a channel to an empty cell.',
    'New: Cell assignments persist across exits — the last channels you '
        'picked for each layout are restored on re-entry.',
    'New: Multi-view cells use reduced buffers (32 MB each) and software '
        'decoding to avoid hardware surface conflicts on Android TV.',
    'New: Channel picker for multi-view is a lightweight search screen — '
        'no modification to the main channel list.',
  ],
  '1.13.4': [
    'Fix (fix16): PIP swap and maximize now clear any stale give-up cooldown '
        'for the channel being promoted. Previously, if a channel had hit '
        'max reconnects earlier in the session, swapping it from the mini-'
        'player to full-screen would block playback with a "please wait" '
        'message even though the overlay was actively streaming it.',
    'Fix (fix16): Cooldown and "Unable to connect" overlays now show a '
        '"Go back" button so the user can leave a dead channel without '
        'using the system back gesture. The spinner is hidden in those '
        'terminal states since nothing is in progress.',
    'Fix (fix16): ExoPlayer now falls back to libmpv after the first '
        'Source error / VideoError on a stream, instead of retrying the '
        'same incompatible engine 5 more times. Big improvement on '
        'Android TV (Shield, Fire TV) for IPTV MPEG-TS variants where '
        'ExoPlayer cannot demux the stream.',
    'Fix (fix15): Stream scanner now fast-fails responses served as '
        'text/html, application/json, or text/plain regardless of HTTP '
        'status. Captive portal "200 OK" pages no longer slip through to '
        'byte validation.',
    'Fix (fix15): Stream scanner now detects HLS playlists by URL '
        'substring "m3u8" (covers query-string variants) and by '
        'Content-Type "mpegurl", in addition to the existing .m3u8 '
        'extension match. DASH and MP4 detection are also '
        'Content-Type-aware.',
  ],
  '1.13.3': [
    'Feature: Debug log file is now cleared automatically the first time '
        'the app boots on a new version. The cleared-for version is tracked '
        'separately so this fires exactly once per build — restarts within '
        'the same version do not touch the log. Useful when sharing a log '
        'for triage so you only see entries from the new build.',
    'Confirmed: All Stream Scanner settings (Streams per scan, Scan '
        'timeout) persist across app restarts and version updates. The '
        'settings table uses an upsert pattern, so new keys are stored on '
        'first save without any database migration.',
  ],
  '1.13.2': [
    'Feature: Stream scanner now performs true media validation. Each '
        'probe streams the first ~16 KB of bytes and verifies them against '
        'real format signatures: MPEG-TS sync byte 0x47 every 188 bytes '
        '(most IPTV livestreams), HLS playlists starting with #EXTM3U, '
        'DASH manifests, and MP4/fMP4 ftyp/styp/moof box headers. Captive '
        'portal pages, CDN error HTML, and auth redirects that returned '
        'HTTP 200 OK are now correctly flagged as failed even though the '
        'status code looked fine.',
    'Feature: Two new sliders in Settings → Stream Scanner: '
        '"Streams per scan" (1–100, default 20) and "Scan timeout" '
        '(3–30 s, default 8 s). Tune these for your network and how '
        'thoroughly you want to validate.',
    'Fix: Scan progress dialog now updates reliably after every probe. '
        'Replaced the captured StatefulBuilder.setState with a '
        'ValueNotifier + ValueListenableBuilder so the dialog rebuilds on '
        'its own progress events regardless of parent state timing.',
    'Internal: scanner now sends a player-style User-Agent (Lavf/61.7.100) '
        'so origins that gate on UA do not 403 the probe.',
  ],
  '1.13.1': [
    'Fix: Stream scanner progress dialog now updates live. The radar scan '
        'previously showed "0 / N streams tested" until completion because '
        'the StatefulBuilder inside the dialog never received a rebuild. '
        'It now refreshes after each probe alongside the channel tile '
        'green outlines.',
    'Fix: Setup wizard no longer double-submits a source if the Add Source '
        'button is tapped twice rapidly. The button is now disabled while '
        'the source is being added, and a guard prevents re-entry into '
        'finish().',
    'Cleanup: dead code removed — unused clearSearch() helper, unreachable '
        'EngineType.auto branch in the player video area, and a no-op '
        'setState block in settings reload.',
    'Cleanup: replaced source-type magic numbers (sourceType.index == 0) '
        'with the SourceType.xtream enum value for readability.',
    'Cleanup: deduplicated channel schedule navigation in the channel tile '
        '(now goes through a single _openSchedule() helper) and shared the '
        'pageSize=36 constant between Home and Sql so pagination stays in '
        'sync.',
    'Cleanup: tightened null-safety in the player and home — guarded '
        'channel.id before reconnect and movie position save, replaced '
        'titleMedium?.fontSize! with a 16px fallback, wrapped a missing '
        'unawaited() on PipController in dispose().',
    'Cleanup: super.initState() now correctly runs first in Setup.',
  ],
  '1.13.0': [
    'Cleanup: flutter analyze now reports zero warnings and zero infos. '
        'Fixed unused variables, removed unnecessary null assertions, '
        'corrected BuildContext-across-async-gap lint with proper mounted '
        'checks, removed stale dart:typed_data import, registered xml as an '
        'explicit dependency, and updated deprecated Matrix4.scale() to '
        'scaleByDouble().',
    'Cleanup: all debugPrint() calls replaced with AppLog — logs now '
        'consistently appear in the in-app debug log file as well as the '
        'console. Removed duplicate log lines that appeared for the same '
        'event in both systems.',
    'Cleanup: removed unused _currentChildElement state-machine variable '
        'from the XMLTV streaming parser. Renamed underscore-prefixed local '
        'variables to follow Dart lowerCamelCase style.',
  ],
  '1.12.3': [
    'Fix (fix13): Android TV devices (Shield, Fire TV, Onn 4K) now use '
        'mediacodec-copy instead of mediacodec for hardware decoding. '
        'mediacodec surface mode silently produces audio-only on Tegra X1 '
        'and similar SoCs; copy mode decodes in hardware but bypasses the '
        'broken surface binding. Phone/tablet users are unaffected.',
    'Feature (fix14-1): EPG matching is now incremental — only channels '
        'with no existing EPG assignment are re-matched on each refresh. '
        'Already-matched channels are skipped entirely, making background '
        'refreshes dramatically faster on large sources (e.g. 92k channels '
        'goes from ~185 isolate batches to ~9 on a typical refresh).',
    'Feature (fix14-1): New "Re-match all channels" button in Settings → '
        'EPG section to force a full re-match after a feed change or matcher '
        'update.',
    'Feature (fix14-2): Startup grace window is now user-configurable '
        '(100–3000 ms, default 500 ms). TV users on slower hardware (Onn 4K, '
        'Fire TV Stick) can increase this if streams still double-start after '
        'the grace window expires before the mpv seek probe arrives.',
    'Docs: README fully rewritten to document all features, build '
        'instructions, and credits to the original open-tv project by Fredolx.',
  ],
  '1.12.2': [
    'Feature: Stream scanner — tap the radar icon next to the search bar '
        'to probe up to 20 visible streams for validity (10 s per stream, '
        'no video playback). Valid streams get a green outline. Progress '
        'dialog shows "X / Y streams tested" with a Cancel button. Results '
        'persist across navigation and are cleared automatically when you '
        'start a new scan.',
  ],
  '1.12.1': [
    'Feature: per-source enable/disable toggle is now a visible Switch '
        'in the source list. Disabled sources are grayed out. All features '
        '(channel listings, movies, series, EPG refresh) already respected '
        'the enabled state; the toggle is now clearly visible instead of '
        'hidden behind a long-press.',
    'Feature: long-press a channel in the History tab to remove it from '
        'history. A "Remove from history" option appears in the action sheet '
        'alongside the existing Favorite and Mini-player options.',
    'Feature: EPG refresh results now show channel match count alongside '
        'program count — e.g. "12,450 programs · 387/1,204 channels matched".',
  ],
  '1.12.0': [
    'Feature: when adding a source, http:// is now automatically prepended '
        'to M3U URLs that are missing a scheme — no manual correction needed.',
    'Feature: adding a source now shows a live progress dialog ("Loading '
        'channels: 1,200…", "Loading movies: 340…") instead of a plain '
        'spinner, giving real-time feedback during source import.',
    'Feature: new optional EPG URL step in the add-source wizard. Enter '
        'your programme guide URL at setup time alongside URL/user/password. '
        'If provided, EPG import starts immediately in the background once '
        'the source is saved.',
  ],
  '1.11.13': [
    'Fix (fix12 #1): eliminated the "double-start" reconnect on every channel '
        'open. The startup grace window was anchored to open() (3s fixed), but '
        'the mpv seek probe fires relative to buffering=false. If buffering '
        'took >3s, grace expired before the error arrived. Grace now expires '
        '500ms after buffering=false instead, ensuring the suppression guard '
        'is always active when the probe fires.',
    'Fix (fix12 #2): mpv emits two messages on every seek rejection: '
        '"Cannot seek in this stream." and "You can force it with '
        '\'--force-seekable=yes\'." Only the first was suppressed — the second '
        'was slipping through to onDisconnect() and causing a reconnect. Both '
        'messages are now suppressed during startup grace.',
    'Fix (fix12 #3): eliminated the force-close loop when a stream hits max '
        'reconnects. After give-up, navigating away and back created a fresh '
        'widget that immediately re-hammered a rate-limited provider. A 60s '
        'cross-session cooldown (static map) now prevents any new player '
        'instance from retrying within that window, showing a countdown '
        'instead.',
  ],
  '1.11.12': [
    'Maintenance: removed deprecated isInDebugMode parameter from Workmanager '
        'initializer (parameter was a no-op; replaced by WorkmanagerDebug handlers).',
    'Maintenance: upgraded Gradle wrapper 8.13 → 8.14 and Kotlin plugin 2.1.0 '
        '→ 2.2.20 to satisfy upcoming Flutter minimum version requirements.',
    'Maintenance: migrated app\'s own Android build to Built-in Kotlin support '
        '(removed explicit id "kotlin-android" from build.gradle). This '
        'eliminates the "Your Android app project applies the Kotlin Gradle '
        'Plugin" build warning, which would have become a build failure in a '
        'future Flutter version.',
    'Note: third-party plugin KGP warnings (file_picker, video_player, '
        'workmanager) remain until their authors publish Built-in Kotlin '
        'compatible versions — blocked by a win32 version split in the '
        'Flutter plugin ecosystem that will resolve when file_picker 12.0.0 '
        'stable ships.',
  ],
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
