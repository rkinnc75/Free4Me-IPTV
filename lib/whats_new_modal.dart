import 'package:flutter/material.dart';
import 'package:open_tv/backend/settings_service.dart';

/// Per-version changelog entries shown in the What's New dialog.
/// Key format: major.minor.patch — patch can be omitted to mean "any patch
/// in that minor". The dialog shows all entries for [version] whose key is
/// a prefix of the running version string.
const _changelog = <String, List<String>>{
  '1.35.17': [
    'Diagnostics: slow database queries now also record their query plan and a one-time data-size summary in the debug log, to help track down slow category loading on large playlists.',
  ],
  '1.35.16': [
    'Enabling "Log User/Pass" now requires typing INSECURE to confirm, since it writes your provider credentials to the log in plain text.',
  ],
  '1.35.15': [
    'New "Report an issue" button under Diagnostics: send a description and your debug log (with host, username and password removed) straight to the developer.',
  ],
  '1.35.14': [
    'Diagnostic logs now also strip your provider\'s server address (host), in addition to username and password, before they can be shared.',
  ],
  '1.35.13': [
    'Live streams that hiccup while the app is minimized (picture-in-picture) now recover automatically instead of dropping back to the menu.',
  ],
  '1.35.12': [
    'New app icon.',
    'App renamed to Free4Me.',
  ],
  '1.35.11': [
    'Updated app icon.',
  ],
  '1.35.10': [
    'New app icon.',
  ],
  '1.35.9': [
    'Diagnostic build: changes how the video picture is drawn on screen, to fix a black screen seen on NVIDIA Shield. If you see any display problems on your device after this update, please report them.',
  ],
  '1.35.8': [
    'Added a developer setting to control how long the on-screen controls stay visible before they auto-hide (0–30s; 0 keeps them up until you tap to dismiss).',
  ],
  '1.35.7': [
    'The on-screen playback controls are now a single row along the bottom of the screen instead of across the middle, so they cover much less of the picture. Rewind, forward and \'back to live\' appear there only while DVR is active.',
  ],
  '1.35.6': [
    'Fixed the playback controls not responding to taps after the previous update. The on-screen controls return to the centre of the screen, where they work reliably. (The current EPG programme still shows in the top bar.)',
  ],
  '1.35.5': [
    'The on-screen playback controls now sit lower on the screen instead of dead-centre, so they cover less of the picture.',
    'When EPG data is available, the channel\'s current programme now shows in the top bar next to the channel name.',
  ],
  '1.35.4': [
    'Player: the aspect-ratio button still cycles Fit / Stretch / Crop on each tap, but the icon stays the same — the 1.35.3 attempt to swap icons and tooltips per mode was defeated by media_kit\'s controls theme caching the button bar at mount. The 3-state cycle still works (the video frame changes immediately on tap); only the per-mode icon and tooltip were reverted. You can tell which mode is active by looking at the video frame.',
  ],
  '1.35.3': [
    'Player: the aspect-ratio icon is now a 3-way toggle — Fit (letterbox, default), Stretch to fill, and Fill with crop. Tap to cycle. Each mode has a distinct icon and tooltip so you can tell which one is active at a glance. The setting resets to Fit when the app restarts.',
  ],
  '1.35.2': [
    'Android TV fix: the debug log now clears on a version change and the What\'s New screen now appears after an update on TV devices. Previously both only happened on phones, so TV logs accumulated every version and release notes never showed.',
    'Diagnostics: playback logs now label the decoder state (hardware / software / initializing) so a normal first-frame software step while hardware decode spins up is no longer mistaken for a hardware-decode failure.',
  ],
  '1.35.1': [
    'Hardware video decoding now engages on phones. Previously the phone path requested a surface decode mode that silently fell back to software (using more CPU and battery); it now uses hardware decode with a copy step, the same proven path as Android TV devices.',
  ],
  '1.35.0': [
    'Searching the Categories list now works from 2 characters, matching the channel search. Previously a 2-character category search returned nothing until you typed a third character.',
  ],
  '1.34.28': [
    'Channel search now waits until you\'ve typed at least 2 characters before searching, skipping a slow full-catalogue scan on the first keystroke. Typing a single character leaves the current list as-is; clearing the box still shows everything.',
  ],
  '1.34.27': [
    'Live DVR now uses the current libmpv on-disk cache setting, replacing a deprecated one that newer libmpv versions warn about and may remove. No change to DVR behavior.',
  ],
  '1.34.26': [
    'TLS certificate verification for HTTPS streams now defaults to OFF, since many IPTV providers use self-signed certificates. You can re-enable it under Settings → Developer → TLS Verify. Existing saved preferences are unchanged.',
    'Removed a non-functional “Min resample FPS” developer tile. It mapped to a libmpv property that does not exist, so it never had any effect; existing settings are unaffected.',
  ],
  '1.34.25': [
    'Channel +/- while watching: open a channel from a list (search results, a category, favorites…) and you can now change channels without leaving the player. Tap the screen for the controls and use the new ▲/▼ buttons — or your remote\'s CH+/CH− keys — to move up and down through the same list the stream started on. Holding the button surfs quickly and only switches when you stop.',
  ],
  '1.34.24': [
    'Added deep native player diagnostics to track down the Shield/Android TV black-screen issue (no change to playback). When Debug Logging is on, the log now captures libmpv\'s own decode/video-output messages, what hardware decoder actually engaged, whether video frames are being produced, and a playback heartbeat that flags a frozen picture. To help: turn on Debug Logging, reproduce the black screen, then export the log.',
  ],
  '1.34.23': [
    'Fixed a black screen (audio playing, no picture) on NVIDIA Shield and other capable Android TV boxes during full-screen playback. The app was forcing software decoding on every Android TV; it now uses the device\'s hardware video decoder on Shield/Tegra and other capable boxes (low-RAM boxes like the onn 4K Plus keep software decoding, which is correct for them).',
  ],
  '1.34.22': [
    'New Developer section at the bottom of Settings: advanced libmpv tunables across 4 sub-headers (Refined buffering moved from Buffering, plus Demuxer/cache, Sync/image quality, Audio/network). Defaults match libmpv upstream exactly, so the section is a no-op until you opt in. Use it for the rare case where a specific provider or device needs a non-default libmpv setting.',
    'Live DVR is now its own folded menu between Buffering and Multi-view (was previously inside Buffering). Buffering now shows only the everyday knobs (live cache, VOD cache, pre-buffer, downmix, open timeout, buffering watchdog, max reconnect attempts).',
  ],
  '1.34.21': [
    'Faster first load of the Live, Movies, and Series lists for setups whose sources use different sort orders (for example some A–Z and some by category). Each list now opens from an index instead of sorting the whole catalog. Ordering is unchanged.',
  ],
  '1.34.20': [
    'Much faster first load of the Live, Movies, and Series lists when you have multiple sources — the channel grid now opens from an index instead of sorting the whole catalog each time (several seconds → instant on large setups). No change to what you see or its order.',
  ],
  '1.34.19': [
    'Low-RAM devices: search method is now auto-set to LIKE substring on first run (devices under 2300 MB, like the onn 4K Plus). The in-memory cache is never built on these devices, so the previous default of "in-memory" was misleading — the search silently fell through to FTS. The setting in the UI now matches the actual search path, with no extra cost on inserts (FTS triggers are dropped for LIKE).',
  ],
  '1.34.18': [
    'Fixed: in Categories, Select All / Unselect All now applies to your current search — every matching category across all pages, not just the ones visible on screen. With no search active it still toggles everything for the source, as before.',
  ],
  '1.34.17': [
    'Edit Source → Test connection now correctly reports "Connected" when the provider accepts your credentials, even if the provider does not report a max_connections value (or reports 0, which happens for permission-limited test users on A3000/Media4u and similar providers). Previously the dialog would say "Login failed" for these accounts even though the login actually succeeded.',
  ],
  '1.34.16': [
    'Fixed: renaming a source in Edit Source now saves. The new name was being discarded on save (other fields like URL, color, and sort order were unaffected).',
  ],
  '1.34.15': [
    'When you add a new Xtream source, the app now automatically probes the provider for an XMLTV feed at one of three common endpoints and fills in the EPG URL for you. The probe is silent (no spinner), runs in the background, and is sticky: a successful auto-detect never re-probes; if the provider has no EPG, the source is marked as such and you can set one manually or use the global EPG.',
  ],
  '1.34.14': [
    'Edit Source dialog: name and color are now editable, a Test connection button verifies the source still works before saving, and the connection counts (live TV / movies / series) appear at the top of the dialog for quick reference. Also fixed: opening the dialog no longer auto-fires Save on D-pad Center / Enter.',
  ],
  '1.34.13': [
    'Edit and Delete on a source are now always available in Settings → Sources, even when the source is disabled. Previously both were dimmed along with the rest of the source; you can now fix a broken URL or remove a source without re-enabling it first.',
  ],
  '1.34.12': [
    'Adding a source that gets rejected (wrong URL, username, or password) no longer leaves a broken, empty source behind. Previously the failed source stuck around, so correcting it and trying again hit a "name already exists" error or created a duplicate. Now a failed add cleans up after itself, and re-adding with the same name just works.',
  ],
  '1.34.11': [
    'Fixed search returning nothing when you open a disabled category and start typing — the channels are right there when you scroll, and now they show up in search too. (Browsing and the other search modes were already correct; only the default in-memory search was over-filtering.)',
    'A rare search-cache startup hiccup can no longer leave the search box permanently greyed out.',
  ],
  '1.34.10': [
    'Add Source screen is now a single page: pick the provider type and every field for it (URL, username/password for Xtream, M3U file picker, optional EPG URL) appears at once. The old 4–5 step wizard is gone, replaced by one form with an "Add Source" button.',
  ],
  '1.34.9': [
    'Toned down the log: the per-user-seek "suppressed seek probe" line is gone. The startup seek-probe (a one-time check at the start of each stream) still logs once, but rejected seeks during playback are silent — they were always benign, just not worth logging every time.',
  ],
  '1.34.8': [
    'Low-RAM phones (e.g. OPPO PGEM10, ~2 GB) now use software decoding for multi-view preview tiles, matching the existing behaviour for low-RAM TV boxes. Previously the low-RAM mitigation only kicked in on TVs, so phones hit shared-GPU texture exhaustion when running several previews at once.',
  ],
  '1.34.7': [
    'Categories screen now groups categories by source when your sources are set to "Provider order" — with multiple sources, your enabled categories interleave by source, matching how the rest of the app sorts in Provider mode. Alphabetical and By category modes are unchanged.',
  ],
  '1.34.6': [
    'Favorites view now follows the channel order you picked for each source (Provider order, By category, or Alphabetical) — it used to always sort favorites by source name then channel name, ignoring your channel order setting.',
  ],
  '1.34.5': [
    'When you add a new Xtream source, its Live TV / Movies / Series counts now appear right away in Settings → Sources → (edit), instead of showing a dash until the next refresh.',
  ],
  '1.34.4': [
    'Search now uses the same ordering as browsing when a source is set to Provider or Category order — previously search always fell back to a fixed favorite/A–Z order, so results could appear in a different sequence than the channel list.',
    'Validated favorites (the ones with a confirmed working stream) now rise to the top of your favorites in Provider and Category order, both when browsing and searching.',
  ],
  '1.34.2': [
    'Much faster first screen after opening the app, especially with multiple sources: the channel list was doing a full sort across every source on a cold start (several seconds). A new database index handles the common Live/Movies/Series views directly, and the list is now pre-warmed in the background at launch.',
  ],
  '1.34.1': [
    'Categories screen now lists your enabled categories first, with disabled ones (grayed out) below — previously enabled and disabled categories were mixed together alphabetically, so an enabled category could appear far down the list.',
  ],
  '1.34.0': [
    'Internal consolidation: the rules for which channels are shown (hiding episodes, dividers, and disabled categories) now live in one place shared by every search path. This also makes substring search faster on large catalogs, and prevents the kind of inconsistency that caused recent category-visibility bugs.',
  ],
  '1.33.5': [
    'Restoring a backup now correctly hides categories you had disabled — previously a restored hidden category could still show up in the grids until the next refresh.',
    'Live DVR now works even with Low Latency enabled: the DVR buffer is kept (and low latency is skipped) so rewind and back-to-live actually have something to seek through.',
  ],
  '1.33.4': [
    'Internal code-health pass: the app now passes static analysis cleanly (two long-standing analyzer hints about using a screen reference after a background operation were resolved). No change to how anything works.',
  ],
  '1.33.3': [
    'First-time setup can now receive your sources from another device over Wi-Fi: the welcome screen has a new "Receive via QR / Wi-Fi" option, so a fresh install can be set up by uploading a backup from your phone or PC without needing a local file.',
  ],
  '1.33.2': [
    'Live DVR controls now appear reliably. The video control bar was caching its buttons before the DVR buffer turned on; it is now refreshed the moment DVR becomes active, so rewind / forward / back-to-live show up as expected.',
  ],
  '1.33.1': [
    'Live DVR controls now actually appear: the rewind / forward / back-to-live buttons were being built a moment before the DVR buffer turned on, so they stayed hidden on channels that started cleanly. They now show as soon as playback begins.',
  ],
  '1.33.0': [
    'Major speed fix: Live, Movies, and Series grids now load almost instantly when you have most categories disabled. They were taking several seconds per switch because the app re-checked every channel’s category one row at a time; that check is now built into the database index.',
  ],
  '1.32.4': [
    'Fixed the Live DVR controls not appearing: rewind, forward, and back-to-live now show on live TV when the DVR buffer is on (they were silently hidden by a missing internal flag in the 1.32.0 release).',
  ],
  '1.32.3': [
    'Live DVR is now isolated per playback session, so quickly leaving one channel and opening another can no longer corrupt the new channel’s recording buffer.',
    'Channel picker search no longer tries to load an entire large catalog into memory for short queries.',
    'Smaller fixes from a code review: the export portal’s Back link keeps working, the updater no longer leaks a network connection on a failed download, and disk-space detection for DVR is more robust on devices with long storage names.',
  ],
  '1.32.2': [
    'Critical fix: opening a series now shows its episodes again. A guard added in 1.29.3 to keep episodes out of the Movies list was applied too broadly and accidentally made every series appear empty.',
    'Episodes also no longer leak into search results when you type a query in Movies, All, or Favorites (the default search path was missed by the earlier fix).',
  ],
  '1.32.1': [
    'Fixed channels with no sound on some TV boxes: surround (5.1) audio is now downmixed to stereo by default, which plays on every device (turn it off in Settings if you have an AV receiver).',
    'Faster source refresh on large catalogs: when search indexing is on, a refresh no longer updates the search index row-by-row — it rebuilds once at the end, cutting big-provider refresh time substantially.',
    'Multi-view on low-memory TV boxes (e.g. onn 4K) now uses software decode for the small preview tiles, avoiding the black/late tiles caused by too many hardware decoders at once.',
    'The diagnostic log now records which search method is active.',
  ],
  '1.31.2': [
    'Internal robustness pass (from a code review): debug log now actually rotates at its 20 MB cap during a long session instead of only when toggled; the backup-import dialog wording now matches what it does (adds/updates sources, keeps existing ones); a database migration registration-order issue that could crash debug builds was corrected (release builds were never affected); and two minor resource-handling tidies (a slider focus-node leak and a stray empty DVR cache folder on low disk).',
  ],
  '1.31.1': [
    'TV fix: the channel picker (used to assign a channel to a multi-view cell) now clearly highlights the row you are on with the D-pad — previously the source color tint hid the focus indicator.',
    'QR/LAN source import now also carries each source’s own settings (connection limit, tag color, sort mode) along with the EPG URL, favorites, category state and resume positions — not just the bare source.',
  ],
  '1.31.0': [
    'New Live DVR buffer (off by default): full-screen live TV can record up to 90 minutes to a temporary disk buffer, so you can pause live TV and let brief drops play through the cushion. The stream is stored as-is (no re-encoding) and the buffer auto-caps to leave 5 minutes of free disk, freezing growth if space runs low. Settings → Live DVR buffer.',
    'The log now always identifies its app version: a version line is written every time the log is cleared and every time it is exported.',
  ],
  '1.30.0': [
    'Favorites view is now grouped by source (A–Z) with channels A–Z within each source — no more mixed-up ordering when multiple sources are enabled.',
    'Categories are now sorted alphabetically: favorited categories A–Z on top, then the rest A–Z. Disabled categories stay hidden.',
    'Settings remembers which groups you opened or closed for the rest of the session.',
  ],
  '1.29.3': [
    'Multi-view audio fix: cells no longer finish opening at full volume when focus moved on during a slow start — only the focused cell plays sound.',
    'Movies section fixed: series episodes no longer leak into Movies, search results, or favorites; they appear only inside their series.',
    'Backups are now complete: favorite and hidden categories, VOD resume positions, and the multi-view stability buffer setting are all exported and restored (applied after the first refresh, like favorites). Older backups still import fine.',
  ],
  '1.29.2': [
    'New "VOD/Movie pre-buffer" setting (default 15 s): movies and episodes now buffer ahead before starting — and refill properly after running dry — instead of stuttering continuously on servers that send files slowly. Set it to 0 for the old start-immediately behaviour. Live TV is unaffected.',
  ],
  '1.29.1': [
    'Series fixed: opening a series now lists every episode. A database uniqueness rule meant for series tiles was accidentally matching episodes too, collapsing all of a series’ episodes onto a single entry — only the last one survived. Already-affected series heal themselves the next time you open them.',
  ],
  '1.29.0': [
    'Multi-view now warns you when more cells are assigned to one source than the provider allows (e.g. "Dino allows 1 connection — 4 cells will fight over it"). Oversubscribed sources round-robin their connections, which is why an over-packed grid endlessly cycles; the limit is read from each provider during refresh.',
    'Smoother starts on Samsung devices: when the video surface registers late (the screen stays black a few seconds while audio runs), the player now waits up to 8 seconds for it to attach on its own instead of interrupting a healthy stream with an unnecessary reconnect at 4. Attach timing is also now logged for diagnostics.',
  ],
  '1.28.1': [
    'Multi-view fix: on sources that cycle connections (e.g. 1-connection providers in a 2×2 grid), the silent quick-reconnect budget never replenished, so every cell hit its limit after a few minutes and did a visible full restart — spinner plus a fresh "Building buffer…" pause — over and over. A clean provider drop now counts as a disturbance for the 15-second stability clock, so the budget refills between drops and cells recover with a brief freeze-frame indefinitely. The stability buffer is built once per cell and full restarts stop.',
  ],
  '1.28.0': [
    'libmpv is now the one and only playback engine. ExoPlayer has been removed entirely — along with the engine picker, the Player engine setting, per-source default engine, and the runtime engine-fallback machinery. libmpv already handled every format (MPEG-TS, HLS, DASH, MP4, RTMP) and carries all the device-specific decode fixes, so this removes a whole class of dual-engine bugs. Existing engine settings and backups are ignored harmlessly.',
  ],
  '1.27.1': [
    'Background processing now covers more long tasks: EPG refresh, channel re-match, and the stream scanner keep running if you switch away from the app (previously only source refresh did). Enable it in Settings — "Keep long tasks running in background".',
  ],
  '1.27.0': [
    'Live TV controls cleaned up: the previous/next skip buttons (which do nothing on a live stream) are gone. Play/pause stays — pausing live TV works and resumes where you left off. Movies and series keep the full controls, including the seek bar.',
  ],
  '1.26.62': [
    'Secured the TV export portal: the page and its source-import upload now require the link from the QR code (other devices on your network can no longer access it), oversized uploads are rejected, and an imported source list asks for confirmation on the TV before any refresh runs.',
  ],
  '1.26.61': [
    'Multi-view: when a provider drops a stream, the reconnect strategy is now fully deterministic — previously two internal end-of-stream signals could race and randomly choose between the smooth same-player reconnect and a full restart with a spinner.',
  ],
  '1.26.60': [
    'Search results now sort identically to channel browsing (an older sort order was still used on one search path) and benefit from the same speed fix as 1.26.59.',
    'Multi-view: a cell that reconnects after a provider drop but never resumes playing is now detected within seconds and automatically restarted, instead of freezing on the last frame.',
    'Player engine reliability: fixed a case where a healthy stream could be misjudged as failed shortly after starting, and stopped a single ExoPlayer error from being counted repeatedly against the reconnect limit.',
  ],
  '1.26.59': [
    'Browsing large catalogues is dramatically faster: the channel list sort now uses the database index added in 1.26.46, which was not actually being used until now — opening the All view on a very large source (hundreds of thousands of channels) drops from ~11 seconds to near-instant on devices like the Shield.',
  ],
  '1.26.58': [
    'Fixed the multi-view stability buffer on the ExoPlayer engine: cells were being restarted by a startup timeout right after the buffer finished building. The buffer now works on both engines.',
  ],
  '1.26.57': [
    'Smoother multi-view on providers that cycle connections: a dropped cell now reconnects on the same player keeping the last frame on screen (no more spinner on every drop), and a new optional "stability buffer" setting (Settings > Multi-view) lets cells play 15-30s behind live so brief drops play through invisibly.',
  ],
  '1.26.56': [
    'Fixed stretched video in multi-view cells on the ExoPlayer engine: video now keeps its correct aspect ratio with letterboxing instead of filling the cell, most visible in portrait 2x2.',
  ],
  '1.26.55': [
    'Fixed live channels on the ExoPlayer engine constantly restarting (especially visible as flickering/reloading cells in multi-view): live streams misreported a tiny duration, making the player think the stream had ended about once per second. Live streams no longer emit end-of-stream at all.',
  ],
  '1.26.54': [
    'Improved multi-view reliability: a cell whose video texture fails to attach now recovers on the normal retry schedule instead of restarting aggressively, and no longer double-restarts when the provider also drops the connection.',
    'The debug log is now guaranteed to be cleared for the new version whenever the What\'s New screen appears after an update.',
  ],
  '1.26.53': [
    'Fixed black cells in 2x2 multi-view on NVIDIA Shield: video textures could fail to attach when all four cells started at once, leaving some cells black with audio. Cells now initialise one at a time and automatically restart if a texture fails to attach.',
  ],
  '1.26.52': [
    'Added playback controls for movies and other on-demand video on the ExoPlayer engine: play/pause, skip back/forward 10 seconds, a seek bar, and elapsed/total time. Live TV is unaffected (it is not seekable).',
  ],
  '1.26.51': [
    'Fixed live TV on the ExoPlayer engine dropping to the backup engine after ~15 seconds even when it was playing fine — the app now recognises ExoPlayer is playing and no longer falls back unnecessarily.',
  ],
  '1.26.50': [
    'Further fix for ExoPlayer black-screen-with-audio on some TV boxes: the video now paints its first frame automatically instead of staying black until an unrelated action (like opening the cast menu) forced it to appear.',
  ],
  '1.26.49': [
    'On TV, you can now navigate to and toggle the enable checkbox on category tiles with the remote — previously the checkbox could not be reached with the D-pad.',
  ],
  '1.26.48': [
    'Fixed a black screen with working audio when playing some movies/streams on the ExoPlayer engine: the video now appears as soon as it is ready instead of staying black.',
  ],
  '1.26.47': [
    'Fixed the selection dialogs (e.g. Player engine, Multi-view) on TV: every option now highlights and can be selected with the remote, and the dialog opens focused on the current choice — previously the top option could not be highlighted or chosen.',
    'Added diagnostics to help track down a black-screen-with-audio playback issue on some TV boxes.',
  ],
  '1.26.46': [
    'Much faster browsing of very large catalogues: opening the All view no longer freezes for several seconds while the full channel list is sorted — it now uses a dedicated index and appears almost instantly.',
  ],
  '1.26.45': [
    'The TV export download page and QR screen now show which device the export came from, matching the device name already included in export filenames.',
  ],
  '1.26.44': [
    'Fixed out-of-memory crashes when exporting on TV with large channel catalogues: export files are now written to disk and streamed to your phone/PC instead of being held in memory all at once.',
  ],
  '1.26.43': [
    'TV export now shows a step-by-step progress indicator (gathering data, building backup, compressing, starting the server) instead of appearing to hang, and any failure is shown in a clear dialog instead of a brief message you might miss.',
  ],
  '1.26.42': [
    'Fixed the Edit Source screen on TV (again): the form content now actually scrolls inside the dialog, with Save/Cancel always visible — previously the bottom options could still spill off the screen.',
    'The source password is now masked in the Edit Source screen, with a tap-to-reveal toggle.',
  ],
  '1.26.41': [
    'Internal: added an automated test suite (refresh retry/preserve logic, database wipe behaviour, player-engine preferences, export device tags) that now runs in CI and gates every release.',
  ],
  '1.26.40': [
    'Fixed the Edit Source screen on TV: the form is now scrollable, so the channel-order options, the hide-headers switch, the source info, and the Save/Cancel buttons are all reachable instead of being cut off at the bottom.',
  ],
  '1.26.39': [
    'Background refresh can now actually run on Android 14+ devices — the foreground service was failing to start due to a missing system declaration. Turning on Background processing and switching away from the app will now keep a refresh running.',
  ],
  '1.26.38': [
    'More reliable refreshes: a temporary empty fetch is no longer reported as a hard error when existing channels were kept, and a content type recovered on retry is no longer discarded.',
    'Background refresh now logs why the foreground service could not start (e.g. notification permission), to aid troubleshooting.',
    'Performance: faster in-memory search cache build on large catalogues.',
    'Exports now include a device name in the filename so backups/logs from different devices are easy to tell apart.',
  ],
  '1.26.37': [
    'More reliable refreshes: if a provider returns an empty list for one content type (live, movies, or series) that it previously had — often a temporary hiccup, especially in the background — that type is retried once and, if still empty, its existing channels are kept instead of being wiped. The other content types still update normally.',
  ],
  '1.26.36': [
    'Fixed: a source refresh could fail partway (leaving series/VOD empty) when a provider returned a channel with no category. Such channels are now grouped under “Uncategorized” instead of erroring out.',
  ],
  '1.26.35': [
    'Performance: large channel catalogues (hundreds of thousands of channels) no longer freeze or crash on low-memory TV boxes — the in-memory search cache is skipped there and searches run directly, with new indexes to keep browsing fast.',
  ],
  '1.26.34': [
    'New (Android): optional "Keep refreshes running in background" setting. When on, a source refresh continues via a foreground notification if you leave the app. Off by default.',
  ],
  '1.26.33': [
    'New: the TV export web page (QR portal) can now also import a settings file to add its sources to this device. Only sources are imported (other settings are skipped), and sources refresh automatically afterward.',
  ],
  '1.26.32': [
    'Playback: if the chosen engine opens a stream but fails to show video (black screen / no frames) or fails to open, the app now automatically tries your fallback engine once (when your Player engine setting has one, e.g. libmpv → ExoPlayer).',
  ],
  '1.26.31': [
    'Settings: Backup & Restore, Reset, and Diagnostics are now collapsible groups like the others; Diagnostics moved to the bottom.',
    'Settings: the player engine option now offers libmpv → ExoPlayer (default), ExoPlayer → libmpv, libmpv only, or ExoPlayer only instead of Auto.',
  ],
  '1.26.30': [
    'New: Multi-view decode setting (Auto / Hardware / Software). On NVIDIA Shield / Tegra, Auto now uses software decode to fix the colour corruption seen in the 2×2 grid.',
  ],
  '1.26.29': [
    'Documentation: refreshed and condensed the README with the latest features.',
  ],
  '1.26.28': [
    'Release reliability: the update feed now publishes only after the new version\'s install file is confirmed available, preventing a brief window where the updater could fail to download.',
  ],
  '1.26.27': [
    'On TV, the LAN export now always offers all three files — source dump, debug log, and settings — each individually plus a combined zip, all sharing one timestamp.',
  ],
  '1.26.26': [
    'New: when an update is available, the app can now download and install it for you in one tap, instead of opening the download page in a browser.',
  ],
  '1.26.25': [
    'Long-pressing a movie or series (e.g. in the All view) now opens the same menu as live channels, with favorite and category options, instead of silently toggling favorite.',
  ],
  '1.26.24': [
    'New: long-press a category to favorite it, sorting it to the top of the Categories list (the channels inside are not affected).',
    'New: in a channel\'s long-press menu, tap the category name to jump to that category in the Categories list.',
  ],
  '1.26.23': [
    'When a source is disabled, its refresh, edit, delete, and color actions are now disabled too. The enable/disable switch stays active.',
  ],
  '1.26.22': [
    'After a stream scan, validation outlines now stay correct on all scanned channels without changing your scroll position.',
  ],
  '1.26.21': [
    'Fix: the stream scanner now correctly starts at the first tile actually visible on screen.',
    'Long-pressing a channel now shows which category it came from at the top of the menu.',
  ],
  '1.26.20': [
    'The search bar and the radar/multi-view buttons now stay pinned at the top while you scroll.',
    'The stream scanner now starts at the first visible channel and scans downward from there.',
  ],
  '1.26.19': [
    'Fix: the multi-view channel picker now loads more channels as you scroll, so the full list is reachable instead of just the first page.',
  ],
  '1.26.18': [
    'Fix: opening a category now shows all of its channels, even if that category is unchecked. The checkbox still controls Live and search.',
  ],
  '1.26.17': [
    'Fix: providers that limit the all-movies response now load their full movie catalog by fetching each movie category.',
  ],
  '1.26.16': [
    'Safe mode now also hides channels your provider marks as adult, in addition to the built-in keyword list.',
  ],
  '1.26.15': [
    'Fix: categories that your provider references but does not name now appear on the Categories screen, so you can enable them. They are named from the channel name prefix.',
  ],
  '1.26.14': [
    'Fix: searching now finds channels in your enabled categories. Previously, divider labels and disabled categories could fill the results and hide real channels.',
    'Fix: enabling or disabling categories now persists across source refreshes instead of resetting.',
  ],
  '1.26.13': [
    'Fix: the Select all / Unselect all buttons on the Categories screen no longer fail when no media-type filter is active.',
    'Maintenance: added temporary diagnostics to investigate a search issue. No change to app behavior.',
  ],
  '1.26.12': [
    'Fix: searching no longer shows channels from categories you have hidden, '
        'or the provider\'s "#### … ####" section-header rows.',
    'Fix: the channel picker no longer shows duplicate "Favourites" and '
        '"History" sections — each appears once, with all its channels grouped together.',
  ],
  '1.26.11': [
    'Maintenance: internal release-process validation. No changes to app behavior.',
  ],
  '1.26.10': [
    'CI fix: fixed a git mechanics issue in the 1.26.9 self-heal that prevented '
        'version.json regeneration when switching branches. The fix adds a stash '
        'before the branch switch so the regenerated file does not block the '
        'operation. version.json staleness is now guaranteed to never fail a '
        'release.',
  ],
  '1.26.9': [
    'CI improvement: the release workflow now self-heals stale version.json '
        'instead of failing. This eliminates the recurring "version.json on the '
        'tagged commit is stale" error that has plagued prior releases. Users '
        'will never see a failed release again due to version.json staleness.',
  ],
  '1.26.8': [
    'Build fix: fixed the release build process to guarantee version.json is '
        'committed on the tagged commit, preventing CI stale-version errors that '
        'affected previous releases.',
  ],
  '1.26.7': [
    'New: the Categories screen now has a checkbox on each category and '
        'Select all / Unselect all buttons. Unchecked categories are hidden '
        'from Live and All, so you can hide ones you do not watch. All '
        'categories are shown by default.',
    'Improvement: the "By category" channel order now sorts channels A–Z '
        'within each category instead of by provider number.',
  ],
  '1.26.6': [
    'Fix: corrected the channel picker sort comparator to handle the new '
        '"By category" sort mode alongside provider and alphabetical modes.',
  ],
  '1.26.5': [
    'New: each source now has a "By category" channel order option that groups '
        'channels under their provider category, plus a switch to hide the '
        'provider\'s "#### … ####" section-header rows (which are labels and '
        'do not play). Set both when editing a source.',
  ],
  '1.26.4': [
    'Improvement: the source edit screen now shows the provider connection '
        'limit and the number of live channels, movies, and series found at '
        'the last refresh.',
  ],
  '1.26.3': [
    'Improvement: "Clear log" now also deletes the large diagnostic source '
        'files saved during refresh, so debug data no longer builds up on your '
        'device.',
  ],
  '1.26.2': [
    'Fix: channel lists could fail to load with a database error after the '
        'provider-order update. Browsing now works correctly again.',
  ],
  '1.26.1': [
    'Fix: in the multi-view channel picker, favorites now appear first under '
        'provider channel order, matching the main channel list.',
  ],
  '1.26.0': [
    'Improvement: the channel picker and browse view now correctly sort by the '
        'per-source channel order setting. In "Use provider channel order" mode, '
        'favorites are listed first, then provider order. In alphabetical mode, '
        'the full 6-tier sort (favorites / history / validated) is used.',
    'Fix: multi-source browse views with a mix of provider and alphabetical '
        'sources now sort each source correctly according to its own setting, '
        'and the channel picker respects this per-source sort mode.',
  ],
  '1.25.7': [
    'Improvement: added per-source channel sort mode toggle. Go to source settings '
        'and enable "Use provider channel order" to list channels in the provider\'s '
        'intended order (e.g., section headers next to their channels in Xtream sources). '
        'Disable it to sort alphabetically (A–Z). Each source can use a different mode, '
        'and the setting applies to Live, Movies, Series, and All views.',
    'Note: channel picker now shows per-source colors to match the main channel list.',
  ],
  '1.25.6': [
    'Fix: multi-view now self-heals focused/reconnecting cells. While a tile is '
        'waiting to reconnect, you can now open the cell menu with D-pad select or '
        'touch long-press to replace the stream without waiting for recovery. The menu '
        'is fully interactive during reconnection.',
  ],
  '1.25.5': [
    'Fix: added missing detailed changelog entries for releases 1.25.3 and '
        '1.25.4, so the in-app changelog history is now complete.',
    'Improvement (TV): D-pad select/center and dedicated menu keys now open the '
        'cell options menu (Replace channel / Full screen / Close) on filled '
        'cells, making it no longer exclusive to touch long-press.',
    'Improvement (TV): the empty-cell "+" button is now clearly highlighted with '
        'a focus ring and autofocuses on cell 0, making it easier to land on and '
        'activate with the D-pad.',
    'Improvement (TV): the channel picker now lands focus on the first tile so you '
        'can scroll immediately with the D-pad; pressing UP from the top row moves '
        'to the search bar as intended.',
  ],
  '1.25.4': [
    'Improvement: multi-view now self-heals dropped streams. When a tile loses '
        'its stream mid-session (common on long viewing sessions when a provider '
        'cycles a channel), it first does the usual quick retries, then keeps '
        'trying every 60 seconds for up to 5 more attempts before giving up — so '
        'tiles that used to go dark for the rest of the session now recover on '
        'their own.',
    'Improvement: while a tile is waiting to reconnect it shows a '
        '"Reconnecting" message instead of a generic error, and a tile that '
        'comes back and plays steadily resets its retry budget so it can recover '
        'again later.',
  ],
  '1.25.3': [
    'Performance: the EPG auto-match step during a source refresh is now much '
        'faster on large catalogs (a targeted database index replaces a full '
        'scan that took over a second on memory-limited TV boxes).',
    'Fix: "Analyze playback & suggest settings" no longer recommends values '
        'outside the slider range. Suggestions are now clamped to the same '
        'minimum and maximum as the settings sliders, so every recommendation '
        'can actually be applied.',
    'Improvement: the in-app default search method is now the fastest '
        '(in-memory) option for new installs. Existing devices keep whatever '
        'they had set.',
    'Improvement: the "What\'s new" summary is now generated automatically from '
        'the changes in each release, so update notes no longer fall back to a '
        'generic placeholder.',
  ],
  '1.25.2': [
    'Diagnostics: added app-wide slow-query logging. When debug logging is enabled, any database statement taking 1000ms or longer is logged so you can identify performance issues.',
  ],
  '1.25.1': [
    'Fix: source refresh failed with a database error on this build. The refresh now completes correctly, and the channel-restore step is fast (an internal index was missing and is now created).',
  ],
  '1.25.0': [
    'Performance: fixed the remaining source-refresh slowdown. The database was using a less-efficient index for the channel-restore step on some devices; it is now pinned to the correct index, cutting the restore phase from over two minutes to under a second on large catalogs.',
    'Multi-view: the channel picker now shows the same per-source pastel background colors as the main channel list.',
  ],
  '1.24.1': [
    'Performance (major): source refresh now 150x faster for large catalogs. The refresh bottleneck was per-row isolate round-trips in restorePreserve; now batched with a set-based UPDATE...FROM. 21,794-row preserve phase dropped from ~150s to <1s. Measured on Aniel3000 (Samsung S25).',
  ],
  '1.24.0': [
    'Diagnostics: added refresh timing and raw-source export to help investigate slow source refreshes. No user-facing behavior change.',
  ],
  '1.23.28': [
    'CI: Release workflow now gates the APK build on analyze passing. If analyze fails, no build is scheduled.',
  ],
  '1.23.27': [
    'Re-release: fix for unescaped apostrophe in 1.23.23 changelog entry. Build now succeeds.',
  ],
  '1.23.26': [
    'Build fix: unescaped apostrophe in 1.23.23 changelog broke the build. Escaped for Dart string safety.',
  ],
  '1.23.25': [
    'Default search method is now In-Memory (fastest). FTS triggers are created on-demand only when '
        'an FTS search method is active; otherwise they are absent, making refresh inserts naturally fast. '
        'Switch back to FTS from Settings any time.',
  ],
  '1.23.24': [
    'Revert: multi-source refresh regression in 1.23.22 (fix206) is reverted. '
        'Single-source refresh on large catalogs was 6x slower due to whole-table index rebuild; '
        'now back to ~145s for Aniel3000.',
  ],
  '1.23.23': [
    'Fix: "What\'s New" showed stale changelog entries from old patch versions. '
        '1.23.22 displayed a 1.23.2-era note due to a string-prefix match bug. Now fixed to compare version components.',
  ],
  '1.23.22': [
    'Performance: source refresh is now ~2.6x faster. Non-unique indexes and FTS trigger '
        'are dropped during bulk insert, recreated once when complete. 271k-row refresh '
        'now takes ~3 minutes instead of ~8.5.',
  ],
  '1.23.21': [
    'Improvement: added timing instrumentation to source refresh DB-write phase. '
        'No behavior change; debug logs now show where time is spent.',
  ],
  '1.23.20': [
    'Fix: removed overly-restrictive connection limit gate on multi-view layouts. '
        'Provider limits are now advisory; layouts are always offered.',
  ],
  '1.23.19': [
    'Fix: source tag colors now persist when switching between Live, Favorites, '
        'and History tabs.',
  ],
  '1.23.18': [
    'Fix: multi-view audio no longer lingers 5 seconds after exit.',
    'Fix: editing a source now preserves its auto-detected connection limit.',
    'Improvement: the source list now shows each provider connection limit '
        'next to the source type, so you can see the multi-view gating at a glance.',
    'Improvement: large Xtream source refreshes are 16x faster.',
    'Improvement: assign a pastel color to each source for quick visual '
        'identification in the channel list.',
    'Fix: multi-view layout ceiling now correctly sums connection limits '
        'across all enabled sources instead of using the minimum.',
  ],
  '1.23.16': [
    'Fix: source refresh now correctly detects your provider connection '
        'limit for multi-view. A missing function prevented the detection '
        'from running in the previous build.',
  ],
  '1.23.15': [
    'Improvement: the multi-view layout picker now checks your provider '
        'connection limit and only offers layouts it can support. Providers '
        'that allow only one connection show a message instead of a silent '
        'failed cell. The limit is auto-detected for Xtream providers on '
        'add or refresh.',
  ],
  '1.23.14': [
    'Improvement (TV): D-pad focus now lands on a sensible control when '
        'every screen and dialog opens. The first channel tile is focused '
        'on the home screen, the first settings row is focused in Settings, '
        'and every dialog opens with focus on the primary action (or the '
        'safe Cancel option on destructive dialogs).',
  ],
  '1.23.13': [
    'Improvement: when you update to a new version, the playback history '
        'used by the Analyze playback feature is automatically cleared so '
        'that suggestions reflect only your experience on the current '
        'version rather than being skewed by data from older builds.',
  ],
  '1.23.12': [
    'Fix (critical): upgrading from 1.23.9 or earlier to 1.23.11 froze '
        'the app on the logo and required an uninstall. A database migration '
        'tried to create a unique index over data that already violated it, '
        'causing the migration to fail and preventing the app from starting. '
        'Upgrading to 1.23.12 recovers without any data loss or uninstall.',
  ],
  '1.23.11': [
    'Fix: corrected six escaped string interpolations from the previous '
        'build that caused the channel import bulk insert to write literal '
        'text instead of row values, and left the progress percentage helper '
        'unreachable. Import and progress display now work as intended.',
  ],
  '1.23.10': [
    'Fix (critical): a large Xtream source (270k channels) no longer '
        'collapses to a tiny number of rows on import. The channel database '
        'was keyed on the display name, so channels sharing a name overwrote '
        'each other. It is now keyed on the provider stable ID so every '
        'distinct stream is stored correctly.',
    'Improvement: source import is significantly faster. Channel rows are '
        'now written in batches instead of one at a time, reducing the '
        'database write phase from several minutes to well under a minute.',
    'Improvement: the import progress bar now shows real percentage, '
        'channel count, and a time estimate during the database write phase.',
    'Fix: the settings backup filename now shows the correct timestamp '
        'on the phone save dialog.',
  ],
  '1.23.9': [
    'Fix (TV): multi-view D-pad audio focus now works correctly. The previous '
        'build had a syntax error in the cell widget that prevented compilation. '
        'This build fixes that, seeds initial focus on the first cell so the '
        'remote has a starting point, and keeps D-pad traversal contained '
        'within the cells.',
  ],
  '1.23.8': [
    'Fix: the playback analyzer now runs correctly on upgraded devices. '
        'The database migration for its history table was out of order and '
        'silently skipped, so the analyzer threw on every launch without '
        'showing any dialog. A new migration guarantees the table exists.',
    'Fix (TV): in multi-view, D-pad focus now moves audio between cells. '
        'Moving the remote to a cell assigns it audio, matching touch behaviour.',
  ],
  '1.23.7': [
    'Fix (TV): focus highlight now works correctly throughout the app. '
        'The previous build had an invalid theme parameter that blocked CI '
        'and prevented the fix164/166 features from shipping. This build is '
        'the first that compiles and includes all TV improvements from '
        'v1.23.5 and v1.23.6.',
  ],
  '1.23.6': [
    'Improvement: export filenames now include a readable date and time stamp '
        '(e.g. free4me-backup-20260530-154223.json) so files are self-describing '
        'and each export is unique. The backup and log from one export share '
        'the same stamp so they are obviously a matched pair. The TV export '
        'page shows the snapshot time under the title.',
  ],
  '1.23.5': [
    'Fix (TV): A/V sync restored on low-RAM TV boxes. The previous hardware '
        'decoder path caused video to lag behind audio; software decode keeps '
        'them in sync and avoids the black-screen failure it was replacing.',
    'Fix (TV): D-pad can now leave the multi-view channel picker search bar '
        'and reach the channel list. The setup wizard text fields also yield '
        'focus so the wizard is completable with a remote.',
    'Improvement (TV): focused rows and buttons now show a visible highlight '
        'throughout the app so you can always see where the remote is.',
  ],
  '1.23.4': [
    'Fix: the playback analyzer now accumulates history correctly across '
        'sessions. Each session is tracked by its actual start time so '
        're-captures of the same session update the existing record instead '
        'of adding duplicates. The data threshold has been lowered to 10 '
        'minutes across 2 streams, and the progress dialog shows how close '
        'you are to the threshold.',
  ],
  '1.23.3': [
    'New (TV): settings backups and debug logs can now be downloaded from '
        'any phone or PC on the same Wi-Fi. Tap Export in Settings to get a '
        'QR code and local address. No cloud, no account required.',
  ],
  '1.23.2': [
    'Fix (TV): the multi-view layout picker cards (1x2, 2x2) are now '
        'reachable with the D-pad. Settings rows no longer trap focus on the '
        'help icon, so the row actions are reachable directly.',
  ],
  '1.23.1': [
    'New: Settings includes an Analyze playback option that reads your local '
        'playback history and suggests specific buffer, cache, and timing '
        'tweaks based on your actual rebuffering and startup times. '
        'Changes are shown for review before applying.',
  ],
  '1.23.0': [
    'Fix: the "All" content filter now shows in white, making it visually '
        'distinct from the "Live" filter which remains blue.',
  ],
  '1.22.13': [
    'Fix: the local build script now correctly reads the GitHub release token '
        'from the new account after the repository transfer. The release step '
        'would have failed to create or upload the APK when running locally.',
  ],
  '1.22.12': [
    'Improvement: channel list and picker now sort in a consistent 6-tier '
        'order across all views — Favourites, then recently watched, then '
        'all channels, with validated streams at the top of each group and '
        'alphabetical ordering within. Headers show Favourites, History, and '
        'All channels; the green circle badge indicates validated streams.',
    'Fix: validated green highlight now persists across app restarts. '
        'The highlight was reading only the in-memory scan map (cleared on '
        'start), ignoring the persisted database flag. Both sources are now '
        'checked so validated channels stay highlighted after a restart.',
    'Fix: multi-view no longer restores non-live-TV channels into cells if '
        'a saved channel ID was reassigned to a movie or series by a source '
        'refresh. The cell opens empty instead.',
    'Diagnostic: rotation is now logged to help confirm that rotating the '
        'device does not affect playback or reconnect the stream.',
  ],
  '1.22.11': [
    'Fix (critical): identified and eliminated the true root cause of the '
        'post-swap black screen. media_kit fullscreen pushes a hidden second '
        'route onto the root navigator with its own Video widget on the same '
        'controller. The swap pop+push only accounted for one route per player, '
        'leaving an orphaned fullscreen route whose Video kept rendering a black '
        'frame above the channel list. The fix stops delegating fullscreen to '
        'media_kit and lets the app drive it directly, as it already does for '
        'the ExoPlayer path — one route per player, swap math stays correct. '
        'Single back press now exits the player (the hidden double-back-exit '
        'bug is also gone as a bonus).',
  ],
  '1.22.10': [
    'Fix (critical): eliminated the black screen after closing the '
        'mini-player and pressing back on the full-screen player after a swap. '
        'The adopted engine video texture was not released on dispose, leaving '
        'a dead black frame composited above the channel list. The fix now '
        'releases the video surface before tearing down the player, and gives '
        'each adopted engine a fresh video surface so texture lifecycles '
        'stay clean across swaps.',
    'Improvement: on a version upgrade, the release notes dialog now appears '
        'as soon as the channel list loads, instead of waiting for the '
        'in-memory search cache to finish building. The cache continues '
        'building in the background while the dialog is visible.',
  ],
  '1.22.9': [
    'Fix (critical): corrected the cause of the black screen after closing '
        'the mini-player and then pressing back on the full-screen player. '
        'Flutter RouteObserver cannot fire for the channel list because it '
        'is the root route — the repaint added in 1.22.8 could never trigger. '
        'The fix now forces a repaint directly from the player exit path and '
        'adds a second trigger from the overlay controller, both of which are '
        'proven to run on every exit.',
  ],
  '1.22.8': [
    'Fix (critical): after closing the mini-player and then pressing back '
        'on the full-screen player, the app no longer shows a black screen '
        'requiring a force-close. The route exit was working correctly '
        '(fix118), but the channel list behind it was not repainting. '
        'The channel list now repaints the moment the player exits.',
    'Fix: swapping the mini-player no longer corrupts the reveal of the '
        'channel list on a subsequent back press. The swap operation now '
        'uses pop+push instead of pushReplacement, which keeps the '
        'navigation stack in the same shape the rest of the app uses.',
  ],
  '1.22.6': [
    'Fix (critical): pressing back after a swap no longer leaves a black '
        'screen with a dead back button requiring a force-close. The root '
        'cause was the exit handler waiting on engine teardown before '
        'navigating — if the widget unmounted during that wait (which '
        'happened when the mini-player was closed moments earlier), the '
        'route never popped. The player now pops the route immediately and '
        'tears down the engine in the background.',
    'Improvement: exit is no longer blocked by engine state at all — '
        'pressing back during buffering or reconnecting also exits instantly.',
    'Improvement: movie resume position save is now time-bounded (1s max) '
        'so a busy engine can no longer delay exit.',
  ],
  '1.22.5': [
    'Fix: swapping the mini-player with the full-screen player no longer '
        'causes a 10–25 second black screen / buffering stall on channels '
        'whose stream URL stalls when re-opened immediately after close. '
        'Swap now hands the live engine objects between players instead of '
        'closing and reopening the stream — the promoted channel appears '
        'full-screen instantly because it was already decoding in the mini-player.',
    'Technical: each engine instance is now tagged with a unique identity '
        'in the log, making swap handoffs end-to-end traceable: the same id '
        'flows from overlay → full-screen (adopt) and full-screen → overlay '
        '(demote), and confirms each engine is disposed exactly once.',
  ],
  '1.22.4': [
    'Build fix: removed an unused field that caused the CI build to fail '
        'with an unused_field warning. No behaviour change.',
  ],
  '1.22.3': [
    'Fix: when a channel fails instantly with "Failed to open" on every '
        'attempt, the app now shows a specific message: "this provider may '
        'allow only one stream at a time." Previously the generic '
        '"stream may be unavailable" message gave no hint that a concurrent '
        'connection on another device was the likely cause.',
    'Fix: after an instant connection refusal, the app waits 3 seconds '
        'before retrying (up from 1 second), giving the provider time to '
        'release the previous connection slot.',
    'Fix: when switching channels, the previous channel\'s connection is '
        'now closed before the new one opens. On single-connection accounts '
        'this prevents the new channel racing the old connection\'s release '
        'and getting an instant "Failed to open".',
  ],
  '1.22.2': [
    'Fix (critical): audio no longer keeps playing after pressing back. '
        'A guard introduced in v1.22.0 to prevent double-dispose accidentally '
        'skipped engine disposal on the normal exit path — the engine stayed '
        'alive and audio continued until force-close. The engine is now '
        'explicitly stopped when the player exits.',
    'Fix: mini-player now renders correctly. The hardware-decode option '
        '(mediacodec-copy) added in v1.22.1 was never actually applied to '
        'the overlay engine because mpv options must be set before open() '
        'is called, and that call was missing. The overlay now calls '
        'reapplyOptions before open, so the hwdec setting takes effect.',
  ],
  '1.22.1': [
    'Fix: mini-player (and multi-view cells) no longer show a permanent '
        'black screen with a spinner. The overlay was forced into pure CPU '
        'decode, which stalls silently on MPEG-TS/H.264 streams even though '
        'the same channel plays fine in full-screen. The overlay now uses '
        'hardware decode in copy mode (mediacodec-copy on Android), which '
        'avoids decoder-pool contention while reliably rendering frames.',
    'The Hardware Decode toggle in Settings still applies to the mini-player '
        '— turning it off falls back to CPU decode as before.',
  ],
  '1.22.0': [
    'Fix: after swapping the mini-player with the full-screen player, the '
        'demoted channel no longer reconnects in the background. Previously '
        'each swap left a phantom full-screen engine alive that could '
        'spontaneously steal audio or change the visible feed. The outgoing '
        'player is now fully stopped before the new one takes over.',
    'Fix: pressing back after multiple swaps now reliably disposes a single '
        'engine instead of 3+ phantom instances, eliminating the force-close '
        'that was required in some cases.',
  ],
  '1.21.7': [
    'Fix: swapping the mini-player with the full-screen player no longer '
        'stacks routes. Each swap replaces the current full-screen route '
        'atomically, so pressing back always exits in a single tap instead '
        'of requiring 5–6 back presses.',
    'Fix: rapid double-tapping the swap button is now ignored — a debounce '
        'guard prevents a second swap from firing before the first completes.',
    'Removed the maximize (⤢) button from the mini-player. The video body '
        'tap and the ⇄ swap button both promote the mini-player to full-screen; '
        'a separate maximize button is redundant.',
  ],
  '1.21.6': [
    'Fix: full-screen player no longer opens muted. The route-based muting '
        'added in v1.21.5 misfired on the newly created player itself. '
        'Audio handoff is now tied to the player registration handoff instead '
        'of route push/pop timing.',
    'New: mini-player now plays with audio when it is the only active player. '
        'It mutes when a full-screen player opens and unmutes when the '
        'full-screen player closes.',
  ],
  '1.21.5': [
    'Fix: tapping the mini-player to go full-screen while another full-screen '
        'channel was already playing caused double audio. The old player is now '
        'muted and closed before the new one opens.',
    'Defense in depth: the full-screen player now mutes automatically '
        'whenever any other screen is pushed on top of it, and unmutes '
        'when that screen is dismissed.',
  ],
  '1.21.4': [
    'Fix: streams that open successfully but never produce a frame now give '
        'up in ~watchdog seconds instead of waiting ~30 s for mpv\'s internal '
        'timeout. A startup watchdog now covers the open→first-frame gap in '
        'both full-screen and multi-view.',
    'Fix: open-failure retries now respect the Max Reconnect Attempts setting '
        'instead of a separate hardcoded limit of 6. All failure modes — '
        'open() throwing, stream dropping, and startup stall — now share one '
        'counter and one setting.',
    'Default Max Reconnect Attempts changed from 6 to 3 (existing stored '
        'values are kept; only fresh installs and Settings Reset get 3).',
    'Buffering settings help text rewritten: each entry now explains '
        'what the setting controls, how changing it affects behaviour, '
        'and which other settings it interacts with.',
  ],
  '1.21.3': [
    'Fix: each reconnect attempt now times out in ~12 s instead of ~31 s. '
        'The buffering watchdog was being silenced during the startup grace '
        'window, so the player waited for mpv\'s own TCP timeout on every '
        'cycle. The watchdog now arms during grace using a 2× timeout, '
        'keeping slow-start protection while catching genuine stalls promptly.',
  ],
  '1.21.2': [
    'Fix: the back button now works on the stuck buffering screen. After '
        'exhausting all reconnect attempts, pressing back was silently ignored '
        '— the only way out was force-closing the app. Root cause: the '
        '“stop retrying” flag also blocked the back-button handler. '
        'The two concerns are now separate.',
    'Fix: multi-view cells now correctly count retries and give up after '
        'the configured maximum. Previously the retry counter reset to 0 on '
        'every attempt, so cells retried forever at “1/6”.',
  ],
  '1.21.1': [
    'Fix: when a stream exhausts all reconnect attempts, the player now '
        'correctly returns to the channel list. The previous fix (v1.20.2) '
        'was blocked by the back-gesture guard and never fired.',
    'Full-screen reconnect overlay now shows "Retrying 1/6…" '
        'instead of a static "Reconnecting…" message.',
    'Multi-view cells now show a retry counter ("Retrying 1/6…") '
        'below the spinner during transient reconnects.',
  ],
  '1.21.0': [
    'New setting: Max Reconnect Attempts (Settings → Buffering). '
        'Controls how many times the app retries a failed stream before '
        'giving up — applies to both full-screen playback and multi-view '
        'cells. Default: 6. Range: 1–10. Previously hardcoded to 6 '
        '(full-screen) and 5 (multi-view).',
    'Code cleanup: removed internal fix-number labels from source '
        'comments. No behaviour change.',
  ],
  '1.20.2': [
    'Fix: when a stream fails after the maximum number of reconnect attempts, '
        'the player now automatically returns to the channel list and shows a '
        'brief message explaining the stream is unavailable. Previously the '
        'screen froze with no visible controls — the only way out was '
        'force-closing the app.',
  ],
  '1.20.1': [
    'Fix: multi-view channel picker now opens instantly. '
        'The initial browse previously fetched the entire Live TV catalogue '
        '(∼8 400 SQL round-trips for 302 k channels) before '
        'showing anything. It now loads a single page in under 60 ms. '
        'Favourites and validated channels still appear at the top because '
        'the database already returns them first.',
  ],
  '1.20.0': [
    'In-Memory search now sorts results correctly across all pages — '
        'favourites and validated channels were previously skipped when they '
        'fell beyond the first page in cache order.',
    'Favouriting a channel, watching a channel, or running a stream scan '
        'now updates the in-memory search cache immediately without a full '
        'rebuild.',
    'Multi-view channel picker: the search box now uses a 200 ms debounce '
        'matching the main Live TV search. Clearing the search box restores the '
        'browse list instantly without any SQL. The fallback search method is '
        'now FTS AND, matching the app default.',
    'SQLite FTS index now only updates on channel name changes. Previously '
        'every favourite toggle, history write, or stream scan caused '
        'unnecessary FTS index churn.',
    'New composite index on the channels table speeds up the no-query '
        'Live TV browse and picker browse flows.',
    'Settings help text updated throughout: clearer defaults, ON/OFF '
        'trade-offs, and corrected descriptions. Safe Mode no longer '
        'incorrectly claims the search cache is rebuilt on toggle.',
  ],
  '1.19.0': [
    'Fix: multi-view channel picker no longer floods SQLite with thousands of '
        'redundant browse queries while streams are running. '
        'A stale-load guard drops superseded in-flight searches, and the '
        'no-query result is cached so rebuild-triggered reloads are O(1) '
        'memory lookups instead of SQL round-trips.',
    'Favorite toggle events (add/remove) are now written to the app log, '
        'making it easier to correlate user actions with playback activity '
        'when diagnosing issues.',
  ],
  '1.18.9': [
    'Fix: long-pressing a channel to favorite it no longer jumps the scroll '
        'position back to the top of the list.',
    'Fix: tapping the All tab from Favorites or History now navigates to All '
        'without also cycling the content filter. The filter only cycles when '
        'you are already on the All tab.',
    'Multi-view channel picker now uses your chosen search method and safe mode '
        'setting — faster searches and adult channels are filtered when safe '
        'mode is on. Results are sorted favorites+validated → favorites '
        '→ validated → alphabetical.',
  ],
  '1.18.8': [
    'Fix: tapping History or Favorites with Safe mode enabled no longer crashes '
        'with a SQL syntax error — the ORDER BY clause was incorrectly placed '
        'before the Safe mode AND conditions.',
    'Search results are now sorted — favorites first, then recently watched, '
        'then alphabetical. This order is consistent across FTS, LIKE Scan, '
        'and In-Memory search.',
    'Stream Scanner results now persist across app restarts. A previously '
        'validated channel (green indicator) will still show as validated after '
        'relaunching the app, and survives source refresh.',
    'Settings → Reset: new "Clear stream validation" option resets all scan '
        'results so channels appear unvalidated until rescanned.',
    'Settings → Content: "Default view" setting moved into the Content '
        'section where it logically belongs.',
  ],
  '1.18.7': [
    'Fix: selecting "FTS AND (recommended)" in Settings now correctly activates '
        'FTS AND mode — the dialog labels were swapped with FTS Phrase. Any user '
        'who previously selected FTS AND was actually running FTS Phrase and vice versa.',
    'Fix: the selected Search method now actually takes effect — searches were '
        'always using the FTS AND default regardless of what was chosen. '
        'In-Memory search is now fully functional.',
    'Fix: In-Memory search with Favorites, History, or Category views no longer '
        'returns sparse pages — all filters are applied before pagination.',
    'Fix: In-Memory search result order is now deterministic across pages.',
    'Fix: Safe mode now applies to LIKE Scan searches (previously adult channels '
        'could appear when LIKE Scan was selected).',
    'Fix: Safe mode toggle is instant — no cache rebuild required. The '
        'adult-blocked flag is pre-computed at cache build time.',
    'Fix: In-Memory cache no longer builds twice on cold start when the background '
        'warmup and home screen initialization overlap.',
  ],
  '1.18.6': [
    'Settings → Content: new "Safe mode" toggle — hides channels and '
        'categories whose name or group contains adult-content keywords '
        '(xxx, 18+, porn, erotic, x-rated). Filtering happens at the SQL '
        'and in-memory-cache level so no adult channel ever reaches the grid. '
        'Default: OFF.',
  ],
  '1.18.5': [
    'Search: keyword toggle removed — search now always splits on spaces '
        '(AND mode) by default, matching all terms independently. '
        'Measurably faster than phrase mode for multi-word queries.',
    'Search: empty results now show a contextual message — "No results '
        'found" with a search-off icon when a query is active, '
        '"No channels available" otherwise.',
    'Settings → Content: new "Search method" picker with four options: '
        'FTS AND (default, fast), FTS Phrase (original exact-phrase mode), '
        'LIKE Scan (any query length, slower), and In-Memory (pre-loads '
        'all channel names into RAM — fastest for repeated searches, '
        '~2.5 MB for 54k channels).',
    'Search: selecting In-Memory mode warms up the channel name cache in '
        'the background at startup. The search box shows "Preparing '
        'search…" and is briefly disabled until the cache is ready.',
  ],
  '1.18.4': [
    'Fix: tapping the content-type filter tab (All → Live → Movies → Series) '
        'now correctly reloads the channel list immediately — the grid no '
        'longer stays frozen on all types after a tap.',
    'Fix: filter change is reflected in the channel grid before the database '
        'write completes, so every tap feels instant.',
  ],
  '1.18.3': [
    'New: tap the All tab to cycle content types — All → Live → Movies → '
        'Series → All. Search runs against only the selected type, making '
        'large multi-type sources (250k+ channels) instantly snappy.',
    'Fix: selecting a content-type filter persists across app restarts and '
        'is preserved in backup/restore.',
    'Fix: disabling a content type in Settings while its filter is active '
        'automatically resets the filter to All.',
    'Fix: turning off all three content types in Settings is now blocked '
        'with a snackbar — at least one must remain enabled.',
    'Fix: debug log is now activated immediately when a backup with '
        'debugLogging=true is imported on a fresh install.',
  ],
  '1.18.2': [
    'Fix: typing 1–2 characters in the search box no longer triggers '
        'a full-table scan — the query is skipped until at least 3 characters '
        'are entered, keeping the UI responsive on large sources.',
    'Fix: a stale search result page loading after you started a new search '
        'could no longer append its rows to the new result list.',
    'Fix: search state is now snapshotted at query time so a concurrent '
        'search cannot corrupt the page number of an in-flight request.',
  ],
  '1.18.1': [
    'Fix: importing a credential-safe backup (exported without '
        'username/password) no longer wipes existing Xtream source '
        'credentials — they are now preserved via COALESCE.',
    'Fix: restoring a manual EPG channel override from backup now correctly '
        'updates the EPG lookup ID so the guide immediately reflects the '
        'pinned assignment.',
    'Fix: EPG refresh on an empty or timed-out server response no longer '
        'hangs the progress dialog indefinitely.',
    'Fix: stale EPG row cleanup now runs before the WAL checkpoint so '
        'both writes are flushed in a single pass, reducing the chance of '
        'a post-refresh search stall.',
    'Fix: upgrading from an old schema with a large EPG table no longer '
        'performs an expensive dedupe at startup before discarding the table.',
  ],
  '1.18.0': [
    'Settings: collapsible groups (Playback, Buffering, Multi-view, '
        'Content, EPG) reduce scrolling — all sections start collapsed '
        'and expand on tap.',
    'Settings: refreshing an Xtream source now shows a live progress '
        'dialog instead of a plain spinner.',
    'Fix: backup export now includes matched EPG channel IDs, so a '
        'restore-from-backup followed by a source refresh preserves all '
        'EPG assignments without a full re-match.',
    'Diagnostics: improved logging for backup import/restore and M3U '
        'processing to make post-restore EPG flow traceable in the log.',
  ],
  '1.17.9': [
    'Fix: on very large sources (600k+ EPG programmes), channel '
        'searches could still stall for 30+ seconds while SQLite '
        'checkpointed a 1GB write-ahead log — even after the fix in '
        '1.17.8. EPG programme data is now stored in a separate database '
        'file (epg.sqlite), so its write-ahead log never blocks the '
        'channel-search database. Searches stay fast throughout any EPG '
        'refresh.',
  ],
  '1.17.8': [
    'Fix: after a large EPG refresh (100k+ programs), searches could '
        'stall for 90–150 seconds while SQLite flushed its write-ahead '
        'log. The flush now runs while the "Optimising database…" '
        'progress message is visible — searches are fast immediately '
        'after.',
    'Improvement: the "Refresh on start" flow and the Settings '
        '"Refresh all sources" button now show the same per-source '
        'progress dialog as the backup import — instead of a plain '
        'spinner with no text.',
    'Visual: each bottom navigation tab now has its own colour — '
        'blue, purple, amber, green, and red-orange for All, '
        'Categories, Favorites, History, and Settings respectively.',
  ],
  '1.17.7': [
    'Fix: EPG channel assignments (the "which EPG feed entry matches '
        'this channel" link) are now preserved when you refresh a source. '
        'Previously every source refresh erased all EPG matches, requiring '
        'a full re-match afterwards.',
    'Fix: "Refresh EPG now" incorrectly showed a "0 programs loaded" '
        'warning even when hundreds of thousands of programs were loaded '
        'successfully.',
    'Fix: "Re-match all channels" could stall at "Starting…" immediately '
        'after running "Refresh EPG now" in the same session.',
  ],
  '1.17.6': [
    'Maintenance: flutter analyze now blocks the release build if it '
        'finds errors. Previously the check was advisory-only. No '
        'app-visible changes.',
  ],
  '1.17.5': [
    'Fix: "Re-match all channels" could hang forever at '
        '"Downloading & parsing…" if the EPG server stalled mid-stream. '
        'A 60-second per-chunk watchdog now closes the stalled stream '
        'and completes the match on whatever data arrived — the dialog '
        'always finishes instead of requiring a force-close.',
    'Fix: after a fresh install + backup import, sources that were '
        'disabled in the backup were incorrectly created as enabled. '
        'Disabled sources now stay disabled after import.',
    'Improvement: the sources-refresh dialog no longer risks getting '
        'stuck at "Preparing…" on fast devices due to a startup race '
        'condition. EPG refresh and re-match operations now write '
        'detailed progress to the debug log.',
  ],
  '1.17.4': [
    'Maintenance: audited KGP (Kotlin Gradle Plugin) deprecation warnings. '
        'Upgrade of device_info_plus, file_picker, and package_info_plus is '
        'blocked by a win32 ^5/^6 ecosystem split; pin comments added to '
        'pubspec.yaml. No app-visible changes.',
  ],
  '1.17.3': [
    'Maintenance: corrects stale session-guide references left over from '
        'the debug-signing era (fix31/v1.17.0 migrated to the release '
        'keystore). No app-visible changes.',
  ],
  '1.17.2': [
    'Maintenance: declares NDK 28.2 explicitly in build.gradle to silence '
        'the jni version-mismatch build warning. No app-visible changes.',
  ],
  '1.17.1': [
    'Important: this update bundles the keystore migration that was '
        'meant to ship as v1.17.0 (the v1.17.0 build failed on the '
        'server). The one-time uninstall described in v1.17.0 still '
        'applies — back up first via Settings → Backup & Restore → '
        'Export, then uninstall and install v1.17.1, then tap "Import '
        'settings backup" on the Setup welcome screen.',
    'UX: After importing a backup, the app now waits with a clear '
        '"Loading channels…" progress dialog until every enabled '
        'source has finished refreshing. You land on Home with '
        'channels already populated instead of an empty screen with '
        'a silent background refresh.',
    'Fix: EPG refresh ("Refresh EPG now" in Settings) could fail '
        'with "syntax error near \'(\'" on devices whose loaded '
        'SQLite was older than 3.39. The bulk EPG-channel write-back '
        'now uses a CTE-based UPDATE that works on every SQLite '
        'version from 3.8.3 onward.',
    'Fix: When you trigger "Refresh all sources" (or refresh-on-start '
        'or post-import refresh), disabled sources are now correctly '
        'skipped. Previously disabled sources got refreshed anyway, '
        'wasting time and bandwidth.',
    'Debug: A one-shot "Sqlite: runtime version=…" log line is now '
        'emitted at app start so future SQLite-related issues can be '
        'diagnosed without guessing at which library is loaded.',
  ],
  '1.17.0': [
    'Important: this update requires a one-time uninstall. The app '
        'now ships with a dedicated release signing identity (replacing '
        'the brittle debug-keystore approach used through v1.16.x) so '
        'every future update installs cleanly without uninstalling. '
        'Android requires that signing identity to match across updates, '
        'which is why the v1.16.x → v1.17.0 transition needs a fresh '
        'install — but it\'s the last one you\'ll have to do.',
    'Before uninstalling: open Settings → Backup & Restore → Export, '
        'and save the JSON somewhere safe (Drive, Files, etc.). After '
        'installing v1.17.0, the Setup welcome screen has an "Import '
        'settings backup" button that brings your sources, favorites, '
        'last-watched, multi-view layout, and the rest back in one tap.',
    'Maintenance: No other functional changes. v1.17.x picks up from '
        'where v1.16.3 left off.',
  ],
  '1.16.3': [
    'Speed: Search-as-you-type now feels responsive on long queries. '
        'The debounce dropped from 500 ms to 200 ms, so results update '
        'mid-word as a fast typist keeps going. A generation-counter '
        'guard drops stale results from superseded queries so a slow '
        'page won\'t clobber a faster newer one.',
    'New: "Restore last channels on open" toggle in Settings, under '
        'the multi-view layout picker. When OFF, multi-view opens with '
        'all cells empty (ready to assign). When ON (default), the last '
        'channels per layout come back as before. Your picks are still '
        'persisted either way — flipping the toggle back on restores '
        'them on the next open.',
    'Debug: Added end-to-end diagnostic logging across the search '
        'pipeline (keystroke → debounce → SQL → render) and around '
        'settings persistence (load / save / export / import). All '
        'gated on debug-logging — zero overhead when off. The import '
        'log line says which fields the backup carried, which makes '
        'old-backup diagnoses immediate (e.g. v2 backups predate '
        'multi-view export support).',
  ],
  '1.16.2': [
    'Speed: EPG refresh is substantially faster. Five separate changes '
        'work together — a larger channel-match batch (cuts isolate '
        'overhead 6×), batched UPDATE of matched EPG IDs (one statement '
        'per 200 channels instead of one per channel), concurrent refresh '
        'across multiple EPG sources, an inverted token index in the '
        'channel matcher (skips EPG entries with no token overlap up '
        'front), and idempotent program inserts so a successful refresh '
        'no longer wipes the existing guide before re-inserting it.',
    'Reliability: If an EPG download fails mid-stream, the previously '
        'imported guide is now preserved instead of leaving an empty '
        'guide until the next successful refresh. Old entries outside '
        'the configured EPG window are garbage-collected after each '
        'successful refresh instead.',
    'Schema: New unique index on programmes(source_id, epg_channel_id, '
        'start_utc) added in a one-time migration. Existing duplicate '
        'rows are deduped before the index is created.',
  ],
  '1.16.1': [
    'New: First-run Setup now has an "Import settings backup" button on '
        'the welcome screen. Restoring a backup on a clean install no '
        'longer requires adding a throwaway source first.',
    'Fix: Backup export/import now round-trips your favorites and last-'
        'watched timestamps. Backup files also carry 9 settings fields '
        'that previously reverted to defaults on every restore '
        '(startup grace, mini demuxer cap, buffer size, stream completed '
        'delay, stream scanner thresholds, multi-view layout, and saved '
        'multi-view cell assignments). Backup schema bumped v2 → v3; '
        'v2 backups still import successfully.',
    'Fix: Channels you watch from multi-view (by picking a cell channel '
        'or by promoting a cell to full-screen) now appear in the Recent '
        'view. Previously only Home tile taps were recorded.',
    'Fix: Promoting a multi-view cell to full-screen (long-press → Full '
        'screen, or double-tap) used to leave the cell\'s player engine '
        'attached to the same .ts URL the full-screen Player was '
        'opening. The provider rejected the duplicate read and the '
        'promotion failed permanently. The cell engine is now disposed '
        'before the Player opens, and restored on return.',
  ],
  '1.16.0': [
    'Maintenance: No functional changes. Starts a fresh 1.16.x minor '
        'version line now that the automated release pipeline is '
        'documented end-to-end in CLAUDE-WORKFLOW.md.',
  ],
  '1.15.9': [
    'Build: First release shipped from the new automated GitHub Actions '
        'pipeline driven by Claude. No functional changes in the app. The '
        'debug signing key carries over from the previous local-Mac '
        'builds, so updates from v1.15.8 install cleanly with no need to '
        'uninstall.',
  ],
  '1.15.8': [
    'Fix: End-of-stream is signalled by mpv on two channels at once '
        '(an "End of file" error and a "completed" event). Multi-view '
        'used to schedule a retry from both, burning a transient-retry '
        'slot on every legitimate stream cycle. Both paths now share '
        'one retry; the budget is preserved for real network issues.',
    'Polish: "Reset to defaults" and "Optimise for this device" only '
        'tell you to restart the app when the buffer size actually '
        'changed. Other buffer-related fields (demuxer caps, cache '
        'seconds) take effect on the next stream open and never needed '
        'a restart message in the first place.',
    'Cleanup: Pre-existing camelCase lint in the multi-source channel '
        'picker fixed (no behavior change).',
  ],
  '1.15.7': [
    'Fix: "Optimise for this device" no longer resets your library view, '
        'show/hide preferences, force-TV-mode, or EPG settings — those '
        'are personal preferences with no relationship to device tuning. '
        'Only buffer, cache, timing, and decoder fields change now. '
        '"Reset to defaults" still resets everything (except sources, '
        'debug-logging, and multi-view session state).',
    'Cleanup: Optimise dialog now uses the canonical multi-view layout '
        'labels ("Disabled" / "1×2 Side by side" / "2×2 Quad grid") '
        'instead of the abbreviated forms.',
  ],
  '1.15.6': [
    'Fix: Multi-view cells now apply the same mpv runtime options the '
        'full-screen player does (cache-secs, network-timeout, demuxer '
        'caps). Cells were silently running on libmpv stock defaults, '
        'which provoked premature server disconnects and the cascading '
        '"stream completed → retry → permanent error" pattern.',
    'Fix: Multi-view cells now send the per-channel HTTP headers (User-'
        'Agent, Referer, Origin) the M3U source declared. Some provider '
        'edges and WAFs treat unfamiliar UAs aggressively, which was a '
        'major contributor to multi-view connection cycling.',
    'Fix: Permanent multi-view errors now dispose the engine immediately. '
        'Previously a failed cell could orphan its TCP connection for 10+ '
        'minutes, silently consuming a slot in the provider\'s '
        'connection budget and breaking subsequent retries.',
    'Fix: Duplicate transient errors emitted by mpv in the same event '
        'tick (e.g. ECONNRESET + read failure) are now debounced so a '
        'single TCP reset burns one retry slot instead of two.',
    'Fix: Duplicate permanent errors no longer double-fire setState or '
        'double-dispose the engine.',
    'Improvement: Multi-view transient retry budget raised from 3 to 5; '
        'channels surviving provider edge-cycling get more headroom. The '
        '15-second stable-playback counter still resets the budget, so '
        'truly-dead channels still hit the error UI in ~15 seconds.',
    'Improvement: Multi-view transient classifier now matches more '
        '"recoverable" mpv errors — Failed to open, Error decoding '
        'audio/video, Could not open codec, End of file, HTTP 5xx — that '
        'were previously sent straight to the permanent branch despite '
        'mpv itself treating them as recoverable.',
    'Improvement: Cells now honour the user\'s "stream completed delay" '
        'setting; previously the value was hardcoded at 2 seconds.',
    'New: Settings → Reset section. "Reset settings to defaults" '
        'restores hardcoded defaults; "Optimise for this device" computes '
        'recommended values based on detected RAM, TV-vs-phone form '
        'factor, and current multi-view layout. Both preserve sources, '
        'credentials, debug-logging toggle, and multi-view channel '
        'assignments.',
  ],
  '1.15.5': [
    'Fix: Multi-view overlay now uses preview-mode buffers and software '
        'decode, eliminating the bandwidth and hardware-decoder contention '
        'that produced most ETIMEDOUT errors during multi-view sessions.',
    'Fix: Multi-view cells now suppress the benign "Cannot seek" probe that '
        'mpv emits on non-seekable livestreams. Cells no longer fall into a '
        'spurious error state on first open.',
    'Fix: Transient network errors in multi-view (timeouts, resets, format '
        'recognition glitches) now auto-retry up to three times with a 3-second '
        'delay; the retry counter resets after 15 seconds of stable playback. '
        'Permanently broken streams no longer retry forever.',
    'Fix: MpvEngine.dispose() is now idempotent, preventing crashes when '
        'Flutter\'s deferred widget disposal fires multiple times for the '
        'same engine instance during long multi-view sessions.',
    'Fix: Multi-view cells now honour the EnginePicker (per-channel, '
        'per-source, and global engine overrides) instead of always forcing '
        'libmpv. HLS, DASH, and MP4 streams now use ExoPlayer in cells.',
    'Fix: Multi-view cell stream subscriptions are now explicitly cancelled '
        'on engine disposal, preventing listener leaks if dispose() ever '
        'throws or is skipped.',
    'Fix: Cold-start order reordered so debug logging is enabled before '
        'DeviceMemory and SettingsService log their initialisation. Fresh '
        'installs now produce the full startup diagnostic banner.',
    'Improvement: Buffering log lines now print only on actual state '
        'transitions, eliminating the "buffering=false buffering=false" '
        'duplicates media_kit can emit immediately after open().',
    'Improvement: Five subsystems (xtream, stream-scanner, catchup-url, '
        'cast, PIP) no longer swallow errors silently; failures appear in '
        'the debug log so remote diagnosis is possible.',
    'Improvement: Mounted checks added after long awaits in the player and '
        'EPG channel-mapping screens, preventing "setState after dispose" '
        'warnings during rapid navigation.',
    'Improvement: Player open() log no longer prints "startPosition=nulls" '
        'for live streams; uses "<live>" to make logs readable.',
  ],
  '1.15.4': [
    'Improvement: Comprehensive diagnostic logging added across all playback '
        'subsystems (multi-view cells, ExoPlayer, MpvEngine, OverlayPlayer, '
        'EnginePicker, M3U/Xtream sources, settings service). Every state '
        'transition — engine open/close, buffering, errors, focus changes, '
        'PIP mode — now appears in the debug log for instant remote diagnosis. '
        'No behaviour changes; logging is gated by the debug-logging setting.',
  ],
  '1.15.3': [
    'Improvement: Multi-view channel picker now sorts and groups channels '
        'into three labelled sections — Favourites (⭐ amber, top), '
        'Validated (✅ green, scan-confirmed streams), then All Channels. '
        'Each section is alphabetical. All pages are loaded so favourites '
        'beyond the first 36 channels are never hidden.',
  ],
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

/// Returns the changelog entries that apply to [version].
/// fix208: match on dot-delimited version COMPONENTS, not a raw string prefix.
/// The old `version.startsWith(key)` wrongly matched e.g. key "1.23.2" against
/// running "1.23.22" (string prefix), leaking an old release's notes into a
/// newer version's "What's New". A key matches only if it equals the version
/// exactly, OR it is a minor-only key (major.minor) and the version is a patch
/// within that minor (starts with key + ".").
List<MapEntry<String, List<String>>> _entriesForVersion(String version) {
  // Defensive: drop any build suffix (e.g. "1.23.22+208" -> "1.23.22").
  final v = version.split('+').first;
  return _changelog.entries.where((e) {
    final key = e.key;
    if (key == v) return true;
    final parts = key.split('.');
    if (parts.length == 2 && v.startsWith('$key.')) return true;
    return false;
  }).toList();
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
        ? ['This update includes general improvements and fixes.']
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
            await SettingsService.updateLastSeenVersion();
            if (context.mounted) Navigator.pop(context, true);
          },
          autofocus: true,
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
