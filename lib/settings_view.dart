import 'dart:async';
import 'dart:convert';
import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/background_task_service.dart';
import 'package:open_tv/backend/export_server.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:open_tv/backend/playback_analyzer.dart';
import 'package:open_tv/backend/device_memory.dart';
import 'package:open_tv/models/device_detector.dart';
import 'package:open_tv/models/dev_mpv_options.dart' show
    VideoSyncMode, TscaleMode, FrameDropMode,
    HwdecImageFormat, AudioSpdifMode;
import 'package:open_tv/models/multi_view_layout.dart';
import 'package:open_tv/models/multi_view_decode.dart';
import 'package:open_tv/multi_view_picker_dialog.dart';
import 'package:open_tv/backend/epg_service.dart';
import 'package:open_tv/backend/issue_reporter.dart';
import 'package:open_tv/backend/settings_io.dart';
import 'package:open_tv/views/epg_channel_mapping.dart';
import 'package:open_tv/backend/render_cap.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/widgets/search_perf_dialog.dart';
import 'package:open_tv/source_color_picker.dart';
import 'package:open_tv/backend/stream_scanner.dart';
import 'package:open_tv/backend/update_checker.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/bottom_nav.dart';
import 'package:open_tv/confirm_delete.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/select_dialog.dart';
import 'package:open_tv/edit_dialog.dart';
import 'package:open_tv/widgets/dpad_text_field.dart';
import 'package:open_tv/home.dart';
import 'package:open_tv/loading.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/id_data.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/confirm_exit_scope.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/setup.dart';
import 'package:open_tv/whats_new_modal.dart';
import 'package:open_tv/widgets/setting_help_dialog.dart';
import 'package:open_tv/widgets/sources_refresh_dialog.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _helpDefaultView = (
  title: 'Default View',
  body:
      'Chooses the content view the app opens to at launch.\n\n'
      'Default: All.\n\n'
      'All shows every enabled content type together. Livestreams opens '
      'directly to live TV. Movies and Series open directly to those '
      'libraries.\n\n'
      'Use the view you open most often to save a navigation step every '
      'time the app starts. This does not hide or delete content; it only '
      'changes the first screen you see.',
);

const _helpForceTvMode = (
  title: 'Force TV Mode',
  body:
      'Forces the TV-style interface even if the device is detected as a '
      'phone or tablet.\n\n'
      'Default: OFF.\n\n'
      'ON: Uses larger TV-focused controls and D-pad navigation. Turn this '
      'on if an Android TV box, Onn 4K, Fire TV, or similar device is '
      'detected as a touch device.\n\n'
      'OFF: Lets the app choose the layout automatically. Best for phones '
      'and tablets where touch controls are easier to use.',
);

const _helpLowLatency = (
  title: 'Low Latency (Live TV)',
  body:
      'Reduces the delay between the live broadcast and what you see on '
      'screen.\n\n'
      'Default: OFF.\n\n'
      'ON: Requests the lowest-latency HLS behavior and reduces buffering. '
      'Useful for live sports or events where being several seconds behind '
      'matters. May reduce picture quality and can make unstable streams '
      'buffer more often.\n\n'
      'OFF: Uses normal buffering for smoother playback and better quality '
      'selection on stable connections. Recommended for most users.\n\n'
      'This mainly affects HLS streams. Non-HLS streams (MPEG-TS, RTMP) '
      'may not benefit.',
);

const _helpRefreshOnStart = (
  title: 'Refresh Sources on Start',
  body:
      'Refreshes your channel lists automatically every time the app '
      'opens.\n\n'
      'Default: OFF.\n\n'
      'ON: Downloads the latest M3U and Xtream data at startup. Use this '
      'if your provider changes channels or stream URLs often. Startup '
      'takes longer and uses network data every launch.\n\n'
      'OFF: Starts faster using the saved channel list. You can still '
      'refresh manually from the Sources section whenever you want fresh '
      'data.',
);

const _helpShowLivestreams = (
  title: 'Show Livestreams',
  body:
      'Controls whether live TV channels appear in browsing and search.\n\n'
      'Default: ON.\n\n'
      'ON: Live TV appears in All, Livestreams, search results, and the '
      'multi-view channel picker.\n\n'
      'OFF: Hides live TV from normal browsing and search. Nothing is '
      'deleted; turn it back on to show live channels again.\n\n'
      'At least one content type must stay enabled.',
);

const _helpShowMovies = (
  title: 'Show Movies',
  body:
      'Controls whether on-demand movies appear in browsing and search.\n\n'
      'Default: ON.\n\n'
      'ON: Movies appear in All, Movies, and search results.\n\n'
      'OFF: Hides the movie library from normal browsing and search. '
      'Nothing is deleted; turn it back on to show movies again.\n\n'
      'At least one content type must stay enabled.',
);

const _helpShowSeries = (
  title: 'Show Series',
  body:
      'Controls whether series and episodes appear in browsing and '
      'search.\n\n'
      'Default: ON.\n\n'
      'ON: Series appear in All, Series, and search results.\n\n'
      'OFF: Hides series content from normal browsing and search. Nothing '
      'is deleted; turn it back on to show series again.\n\n'
      'At least one content type must stay enabled.',
);

const _helpSafeMode = (
  title: 'Safe Mode',
  body:
      'Hides channels and categories whose name or group contains '
      'adult-content keywords.\n\n'
      'Default: OFF.\n\n'
      'ON: Adult-labeled channels are hidden from browsing, categories, '
      'search results, and picker screens. The filter is applied '
      'immediately.\n\n'
      'OFF: Shows all channels from your enabled sources.\n\n'
      'Safe Mode uses a keyword blocklist (e.g. xxx, 18+, erotic, porn, '
      'x-rated). It is a practical filter, not a parental-control '
      'guarantee.',
);

const _helpHwDecode = (
  title: 'Hardware Decoding',
  body:
      'Uses the device video decoder instead of relying only on the CPU.\n\n'
      'Default: ON.\n\n'
      'ON: Usually gives smoother playback, lower CPU use, less heat, and '
      'better battery life. Recommended for most devices, especially 4K or '
      'HEVC streams. Android TV and Nvidia Shield automatically use a safer '
      'copy mode where needed.\n\n'
      'OFF: Uses software decoding. Turn this off only if hardware decoding '
      'causes black video, green video, corruption, or device-specific '
      'playback problems.',
);

const _helpPreWarm = (
  title: 'Pre-warm Streams on Focus',
  body:
      'Starts resolving a stream URL when a channel tile receives focus, '
      'before you press play.\n\n'
      'Default: ON.\n\n'
      'ON: Channels often start faster because redirects and basic network '
      'setup have already happened. Best for TV remotes where focus moves '
      'deliberately.\n\n'
      'OFF: Does no background stream checks while browsing. Uses less '
      'network activity and can be better on metered or slow connections. '
      'Playback may take slightly longer to begin.',
);

const _helpDevControlsHideSecs = (
  title: 'Controls auto-hide (seconds)',
  body:
      'How long the on-screen controls (top bar + bottom control row) stay '
      'visible after you tap, before they fade away.\n\n'
      'Default: 3 s. Range: 0–30 s.\n\n'
      'Set to 0 to keep the controls up until you tap to dismiss them.',
);

const _helpDevSkipBackOnResumeSecs = (
  title: 'Skip back on resume (seconds)',
  body:
      'When you resume a paused movie or series episode, jump back this many '
      'seconds first so you can pick the scene back up.\n\n'
      'Live TV is never skipped — pausing live already leaves you behind the '
      'live edge.\n\n'
      'Default: 0 (off). Range: 0–30 s.',
);

const _helpLiveCacheSecs = (
  title: 'Livestream Cache (seconds)',
  body:
      'Controls how many seconds of live TV playback are buffered ahead.\n\n'
      'Default: 20 s. Range: 5–60 s.\n\n'
      'Increasing: Gives the player more cushion on unstable connections '
      'and can reduce buffering. Uses more RAM and increases live delay. '
      'Very high values can make slow streams feel less live.\n\n'
      'Decreasing: Uses less RAM and reduces live delay. May buffer more '
      'often on weak Wi-Fi or unreliable providers.\n\n'
      'Interacts with:\n'
      '• Low Latency mode — reduces or bypasses this buffer for a more '
      'live feed at the cost of stability.\n'
      '• Livestream Demuxer Buffer — the cache lives inside the demuxer '
      'buffer; a large cache needs enough demuxer MB to hold it.',
);

const _helpLiveDemuxerMB = (
  title: 'Livestream Demuxer Buffer (MB)',
  body:
      'Sets the maximum RAM the stream demuxer can use while playing live '
      'TV.\n\n'
      'Default: calculated from device RAM. Range: 32–512 MB.\n\n'
      'Increasing: Helps high-bitrate, 4K, HEVC, or unstable live streams '
      'keep enough data ready for decoding. May reduce stutter, but uses '
      'more RAM.\n\n'
      'Decreasing: Frees RAM for the system and other players. Lower this '
      'first on 1–2 GB TV boxes if the app closes in the background or '
      'during multi-player use.\n\n'
      'Interacts with:\n'
      '• Livestream Cache — the cache must fit inside this buffer; raise '
      'this if you raise the cache.\n'
      '• Multi-view — each cell allocates its own (smaller) demuxer '
      'buffer, so total RAM use scales with the number of cells.\n\n'
      'The maximum is capped from detected RAM to avoid unsafe values.',
);

const _helpVodCacheSecs = (
  title: 'VOD/Movie Cache (seconds)',
  body:
      'Controls how many seconds of movies or series are buffered ahead.\n\n'
      'Default: 60 s. Range: 10–180 s.\n\n'
      'Increasing: Helps long movies, large files, and slow servers play '
      'more smoothly. Can also make seeking feel better. Uses more RAM and '
      'may take longer to fill after a seek.\n\n'
      'Decreasing: Uses less RAM and may respond faster after jumps, but '
      'can buffer more often on slow VOD servers.\n\n'
      'Interacts with:\n'
      '• VOD/Movie Demuxer Buffer — the cache lives inside that buffer; '
      'a large cache needs enough demuxer MB.\n\n'
      'Does not affect live TV streams.',
);

const _helpVodPrebufferSecs = (
  title: 'VOD/Movie Pre-buffer (seconds)',
  body:
      'How many seconds must be buffered before a movie or episode starts '
      'playing — and before it resumes after running dry.\n\n'
      'Default: 15 s. Range: 0–60 s. 0 turns it off.\n\n'
      'Increasing: Much smoother playback on servers that send files '
      'slowly (constant stutter becomes one short wait at the start plus '
      'rare pauses). Startup and seeks take a little longer.\n\n'
      'Decreasing/0: Fastest possible start, but slow servers will '
      'stutter continuously.\n\n'
      'Does not affect live TV streams.\n\n'
      'Restart required: applied when player instances are created.',
);

const _helpAudioDownmix = (
  title: 'Downmix audio to stereo',
  body:
      'Mixes surround-sound (5.1) audio down to stereo before playback.\n\n'
      'Default: ON. Keep this on for TV boxes and TVs without an AV '
      'receiver — some channels send Dolby Digital Plus (E-AC3) 5.1 '
      'audio that those devices cannot decode, causing repeated audio '
      'errors or silence. Stereo downmix plays everywhere.\n\n'
      'Turn OFF only if you have a receiver/soundbar that handles '
      'multichannel audio and want the original surround mix.\n\n'
      'Restart required: applied when player instances are created.',
);

const _helpDvr = (
  title: 'Live DVR Buffer',
  body:
      'Full-screen live TV only (single view). Records the incoming stream '
      'to a temporary disk buffer so you can pause live TV — pausing builds '
      'a cushion that brief network drops can play through.\n\n'
      'The stream is stored as-is (no re-encoding — a bit-identical copy is '
      'the most space-efficient option these devices can do in real time; '
      'expect roughly 30–60 MB per minute depending on the channel).\n\n'
      'Disk safety: the window is automatically capped so recording stops '
      'about 5 minutes short of filling free space, and growth freezes if '
      'space runs low mid-session. The buffer is deleted when playback '
      'ends.\n\n'
      'Default: OFF. Length: 5–90 minutes in 5-minute steps.\n\n'
      'Restart required: applied when player instances are created.',
);

const _helpVodDemuxerMB = (
  title: 'VOD/Movie Demuxer Buffer (MB)',
  body:
      'Sets the maximum RAM the demuxer can use for movies and series '
      'episodes.\n\n'
      'Default: 256 MB. Range: 64–1024 MB.\n\n'
      'Increasing: Helps high-bitrate VOD, 4K movies, and large files play '
      'and seek more smoothly. Uses more RAM.\n\n'
      'Decreasing: Frees RAM for the system and other streams. Most 1080p '
      'VOD works well around 64–128 MB, while large 4K files may need '
      'more.\n\n'
      'Interacts with:\n'
      '• VOD/Movie Cache — the cache must fit inside this buffer; raise '
      'this if you raise the cache.\n\n'
      'Does not affect live TV streams.',
);

const _helpOpenTimeout = (
  title: 'Stream Open Timeout (seconds)',
  body:
      'How long the app waits for the open() call to start a stream '
      'before counting that attempt as a failure.\n\n'
      'Default: 5 s. Range: 5–60 s.\n\n'
      '↑ Increasing — gives slow or distant servers more time to '
      'respond before failing. Fewer false failures, but you wait '
      'longer before a retry or give-up.\n\n'
      '↓ Decreasing — fails faster on dead servers.\n\n'
      'Interacts with:\n'
      '• Max Reconnect Attempts — each open failure counts toward that '
      'limit. With a low timeout and a low attempt limit, a dead stream '
      'gives up very quickly.\n'
      '• Buffering Watchdog — the open timeout only covers the open() '
      'call. Once a stream opens but then stalls without a picture, the '
      'Buffering Watchdog (not this setting) catches it.',
);

const _helpMaxReconnectAttempts = (
  title: 'Max Reconnect Attempts',
  body:
      'How many times the app tries a stream before giving up. This is '
      'the single limit for ALL failure types: a stream that won\'t '
      'open, one that opens then drops, and one that opens but never '
      'shows a picture.\n\n'
      'Default: 3. Range: 1–10.\n\n'
      'Applies to both full-screen playback and multi-view cells.\n\n'
      'Full-screen: when the limit is reached the player returns to the '
      'channel list and shows a message.\n'
      'Multi-view: when the limit is reached the cell shows "Stream '
      'unavailable" with a manual Retry button.\n\n'
      '↑ Increasing — gives flaky streams more chances to recover. '
      'Useful for providers that drop briefly then come back.\n\n'
      '↓ Decreasing — fails faster on dead streams. Set to 1 for '
      'immediate give-up with no retry; 2–3 for a couple of chances.\n\n'
      'Interacts with:\n'
      '• Stream Open Timeout — each attempt can wait up to this long for '
      'open() to respond.\n'
      '• Buffering Watchdog — each attempt can wait up to this long for '
      'a stalled stream to recover before counting as a failed attempt.\n'
      '• Total wait before give-up ≈ attempts × (open timeout or '
      'watchdog, whichever applies). Example: 3 attempts × 10 s '
      'watchdog ≈ 30 s worst case on a dead stream.',
);

const _helpWatchdog = (
  title: 'Buffering Watchdog (seconds)',
  body:
      'How long a live stream may stay frozen — buffering, or opened but '
      'showing no picture — before the app counts it as a failed attempt '
      'and reconnects or gives up.\n\n'
      'Default: 12 s. Range: 5–60 s.\n\n'
      '↑ Increasing — gives a stuck stream more time to recover on its '
      'own. Fewer needless reconnects on brief pauses, but longer waits '
      'when a stream is truly stuck.\n\n'
      '↓ Decreasing — reacts faster when playback freezes. Quicker '
      'recovery, but may reconnect during short network dips.\n\n'
      'Interacts with:\n'
      '• Max Reconnect Attempts — every time this watchdog fires it uses '
      'one attempt. Total give-up time ≈ attempts × this value on a '
      'stuck stream.\n'
      '• Startup Grace — during the brief grace window right after open, '
      'the watchdog uses a longer timeout so a slow but real start is '
      'not killed early.\n'
      '• It also covers the "opened but never produced a frame" case '
      '(a dead stream that returns success then sends nothing).\n\n'
      'In mini-player or multi-view, each active stream has its own '
    'watchdog running independently.',
);

// fix394: Developer / libmpv advanced tunables. Defaults match libmpv
// upstream exactly; the Developer section is a no-op until the user opts
// in. Help bodies follow the _helpWatchdog convention (Default / Range /
// ↑ / ↓ / Interacts with).

const _helpDevDemuxerReadaheadSecs = (
  title: 'Demuxer Read-Ahead (seconds)',
  body:
      'How far ahead of the current playback point the demuxer pre-fetches '
      'data. Larger values give the player more cushion against network '
      'jitter; smaller values reduce RAM and disk usage.\n\n'
      'Default: 1.5 s. Range: 0.5–10 s.\n\n'
      '↑ Increasing — smoother playback on shaky networks; more RAM/disk.\n\n'
      '↓ Decreasing — less RAM; more visible rebuffering on slow links.',
);

const _helpDevNetworkTimeoutSecs = (
  title: 'Network Timeout (seconds)',
  body:
      'libmpv aborts an open() or read if no bytes arrive within this many '
      'seconds. Surfaces as a network error and triggers the reconnect '
      'logic.\n\n'
      'Default: 30 s. Range: 5–120 s.\n\n'
      '↑ Increasing — more tolerant of slow providers; can mask a dead '
      'stream for longer.\n\n'
      '↓ Decreasing — faster failure on dead streams; may falsely fail '
      'on very slow first-segment delivery.',
);

const _helpDevImportFetchTimeoutSecs = (
  title: 'Import Fetch Timeout (seconds)',
  body:
      'How long each Xtream import request (live / VOD / series) waits for the '
      'provider before giving up. SEPARATE from Network Timeout, which is for '
      'playback. A slow provider can take ~1 minute to respond, especially '
      'when several sources refresh at once.\n\n'
      'Default: 60 s. Range: 0–120 s (0 = use the built-in default).\n\n'
      '↑ Increasing — survives slow providers during a multi-source refresh.\n\n'
      '↓ Decreasing — fails a dead provider faster, but may falsely fail a '
      'slow one.',
);

const _helpDevTlsVerify = (
  title: 'TLS Verify',
  body:
      'Whether libmpv verifies TLS certificates when fetching HTTPS '
      'playlist/segment URLs. Defaults to OFF in this app, as many IPTV '
      'providers serve HTTPS with self-signed certificates.\n\n'
      'Turn OFF only for sources that use self-signed certificates you '
      'trust. Sources added with `ignore SSL` already force this OFF '
      'unconditionally per-source and override this toggle.\n\n'
      'Range: ON / OFF.\n\n'
      '↑ ON — more secure; rejects invalid certs.\n\n'
      '↓ OFF — accepts any cert; vulnerable to MITM on hostile networks.',
);

const _helpDevVideoSync = (
  title: 'A/V Sync Mode (video-sync)',
  body:
      'How libmpv keeps video and audio in sync.\n\n'
      'Default: audio (resample audio to match video).\n\n'
      'audio — resample audio. Best for live TV; audio quality may dip '
      'on extreme resamples.\n\n'
      'display — resample video to display refresh. Crisp video; needs '
      'the device to be at the right refresh rate.\n\n'
      'display-resample — resample video AND drop/duplicate frames. '
      'Smoothest on displays that don\'t match the source rate.\n\n'
      'display-vdrop — like display, but drops frames instead of '
      'duplicating. Avoids the soap-opera effect on film sources.\n\n'
      'audio-desync — try to fix A/V desync by resampling audio. Use '
      'only if you see drift on a specific provider.\n\n'
      'Restart required for some devices.',
);

const _helpDevVideoSyncMaxVideoChange = (
  title: 'Max Video-Rate Change',
  body:
      'Upper bound on the per-frame video-rate change libmpv will apply '
      'for sync (with `video-sync=display*` modes). Higher = more '
      'aggressive resampling.\n\n'
      'Default: 1.0. Range: 0–5.\n\n'
      '↑ Increasing — faster sync convergence; visible judder on motion.\n\n'
      '↓ Decreasing — smoother motion; slower to converge on big drift.',
);

const _helpDevTscale = (
  title: 'Temporal Scaler (tscale)',
  body:
      'Algorithm used to upscale video frames to display resolution on '
      'slow hardware. Affects sharpness vs. performance.\n\n'
      'Default: nearest (fastest, sharpest, may show aliasing on diagonals).\n\n'
      'bilinear — smoother diagonals; softens detail slightly.\n\n'
      'oversample — three-tap filter; good sharpness/perf trade-off.\n\n'
      'spline36 — high quality; noticeably slower on low-end CPUs.\n\n'
      'lanczos — highest quality; slowest; only useful on fast hardware.\n\n'
      'Use bilinear or oversample if you see aliasing artifacts with '
      'nearest on a 4K display.',
);

const _helpDevFramedrop = (
  title: 'Frame Drop Mode',
  body:
      'When and how libmpv is allowed to skip frames to maintain sync.\n\n'
      'Default: vo (libmpv upstream). On low-RAM Android boxes a `vo` setting '
      'is auto-applied as `decoder` to stop texture-upload judder.\n\n'
      'no — never drop; full quality, may stutter on slow hardware.\n\n'
      'vo — drop late frames at the video output (libmpv upstream default).\n\n'
      'decoder — drop frames at the decoder before the upload stage; on weak '
      'GPUs this eliminates the texture-upload judder `vo` causes on high-fps '
      'streams (verified on the onn 4K Plus).\n\n'
      'Range: no / vo / decoder.',
);

const _helpDevInterpolation = (
  title: 'Frame Interpolation',
  body:
      'Motion-compensated frame interpolation (the "soap opera" effect). '
      'Smooths 24/30 fps content to higher rates by synthesising '
      'in-between frames. Requires decent CPU.\n\n'
      'Default: OFF.\n\n'
      'Range: ON / OFF.\n\n'
      '↑ ON — smoother motion; can introduce artifacts on fast pans.\n\n'
      '↓ OFF — natural cadence; less CPU.',
);

const _helpDevDeband = (
  title: 'Debanding Filter',
  body:
      'Removes colour banding (visible steps in gradients) from low-bitrate '
      'content. Adds a small amount of dithering noise. Most useful for '
      'animated content.\n\n'
      'Default: OFF.\n\n'
      'Range: ON / OFF.\n\n'
      '↑ ON — fewer visible bands; may soften edges slightly.\n\n'
      '↓ OFF — no processing; cleanest for high-bitrate sources.',
);

const _helpDevCapFps = (
  title: 'Cap 60→30 fps',
  body:
      'Cap 60 fps video output to 30 fps. Intended for low-RAM Android boxes '
      '(e.g. onn 4K Plus) where a 60 fps stream still judders, but when enabled '
      'it now applies on ANY device. Most low-RAM judder is already handled '
      'automatically by the decoder frame-drop mode, which keeps the full frame '
      'rate with no dropped frames — so leave this OFF unless a 60 fps stream '
      'still judders. When on, capping to 30 fps halves the display-upload load '
      'while keeping audio and video in sync.\n\n'
      'Default: OFF (opt-in). Applies to any device and 60 fps '
      'content.\n\n'
      'Range: ON / OFF.\n\n'
      '↑ ON — 30 fps output; smoothest on weak boxes that still judder.\n\n'
      '↓ OFF — full frame rate (recommended; the decoder frame-drop mode '
      'already prevents judder on most low-RAM boxes).',
);

const _helpDevHwdecImageFormat = (
  title: 'HW Decoder Image Format',
  body:
      'Image format libmpv requests from the hardware decoder. `default` '
      '(default) lets libmpv pick the optimal format for the active hwdec '
      'mode. Override only if you see chroma/colour issues on a specific '
      'SoC.\n\n'
      'Default: default (do not force).\n\n'
      'nv12 — most hardware decoders; lowest overhead.\n\n'
      'rgba — universal; higher overhead, no chroma subsampling.\n\n'
      'i420 — chroma-subsampled; older devices.\n\n'
      'Range: default / nv12 / rgba / i420.\n\n'
      'Interacts with hwdec mode (Settings → Playback → Hardware '
      'decoding).',
);

const _helpDevAudioBufferSecs = (
  title: 'Audio Buffer (seconds)',
  body:
      'Extra audio buffer in seconds. The default is 0.20 s — a small cushion '
      'against A/V desync. Set 0 to use the codec\'s natural buffer '
      '(libmpv\'s upstream default).\n\n'
      'Default: 0.20 s. Range: 0–2 s.\n\n'
      '↑ Increasing — smoother A/V on weak networks; higher audio latency.\n\n'
      '↓ Decreasing — lower audio latency; more audio dropouts on slow '
      'links.\n\n'
      'Interacts with audio-spdif (below) and demuxer-readahead-secs.',
);

const _helpDevAudioSpdif = (
  title: 'Audio S/PDIF Passthrough',
  body:
      'Sends compressed audio bitstreams over HDMI/Optical S/PDIF to a '
      'downstream receiver. Default OFF (audio is decoded in software and '
      'routed as PCM).\n\n'
      'Default: no (passthrough disabled).\n\n'
      'ac3 — Dolby Digital 5.1.\n\n'
      'eac3 — Dolby Digital Plus (Atmos metadata passthrough).\n\n'
      'dts — DTS.\n\n'
      'all — accept all three formats; receiver picks what it can decode.\n\n'
      'WARNING: enabling passthrough on a plain box→TV HDMI path will '
      'SILENCE audio unless the downstream device is an AV receiver or '
      'soundbar that can decode the passthrough codec. Keep OFF unless '
      'your output chain ends in a real receiver.',
);


class SettingsView extends StatefulWidget {
  final bool showNavBar;
  final bool tvRailPane;

  const SettingsView({super.key, this.showNavBar = true, this.tvRailPane = false});

  @override
  State<SettingsView> createState() => _SettingsState();
}

class _SettingsState extends State<SettingsView> {
  /// fix356: per-group expand/collapse, remembered for the app session only
  /// (static — survives the settings route closing, dies with the process).
  static final Map<String, bool> _groupOpen = {};

  Settings settings = Settings();
  List<Source> sources = [];
  bool loading = true;
  String _appVersion = '';

  /// fix512: TV rail+pane — index of the selected rail group. Switching it
  /// re-keys the pane ListView (ValueKey(_railIndex)), which mounts a fresh
  /// scroll view starting at the top — so no ScrollController is needed.
  int _railIndex = 0;

  @override
  void initState() {
    super.initState();
    initAsync();
    // fix182: land D-pad focus on the first settings row when the
    // screen opens (ExpansionTile has no autofocus; nextFocus() on a
    // scope with no focused child moves to the first focusable).
    // fix512: skip on the TV rail+pane path — it autofocuses the first rail
    // row itself, and nextFocus() assumes the old single ListView.
    if (!widget.tvRailPane) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) FocusScope.of(context).nextFocus();
      });
    }
  }

  Future<void> initAsync() async {
    final results = await Future.wait([
      SettingsService.getSettings(),
      Sql.getSources(),
      PackageInfo.fromPlatform(),
      Sql.getLatestEpgRefresh(), // finding 12: load once, not per-build
    ]);
    if (!mounted) return;
    setState(() {
      settings = results[0] as Settings;
      sources = results[1] as List<Source>;
      final info = results[2] as PackageInfo;
      _appVersion = 'v${info.version}';
      _latestEpgRefreshTs = results[3] as int?;
      loading = false;
    });
  }

  void updateView(ViewType view) {
    if (view != ViewType.settings) {
      Navigator.pushAndRemoveUntil(
        context,
        PageRouteBuilder(
          pageBuilder: (_, _, _) => Home(
            home: HomeManager(filters: Filters(viewType: view)),
          ),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          transitionsBuilder: (context, animation, secondaryAnimation, child) =>
              child,
        ),
        (route) => false,
      );
    }
  }

  Future<void> showEditDialog(BuildContext context, final Source source) async {
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (builder) =>
          EditDialog(source: source, afterSave: reloadSources),
    );
  }

  Future<void> _showDefaultViewDialog(BuildContext context) async {
    showDialog(
      barrierDismissible: true,
      context: context,
      builder: (BuildContext context) {
        return SelectDialog(
          title: "Default view",
          data: ViewType.values
              .take(4)
              .map((x) => IdData(id: x.index, data: viewTypeToString(x)))
              .toList(),
          action: (view) {
            setState(() {
              settings.defaultView = ViewType.values[view];
              updateSettings();
            });
            Navigator.of(context).pop();
          },
        );
      },
    );
  }

  Future<void> toggleSource(Source source) async {
    await Error.tryAsyncNoLoading(
      () async => await Sql.setSourceEnabled(!source.enabled, source.id!),
      context,
    );
    await reloadSources();
    if (!mounted) return;
    // After reloadSources(), source.enabled has been flipped in the new list,
    // so we read the updated state from the refreshed sources list.
    final updated = sources.where((s) => s.id == source.id).firstOrNull;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          "${source.name} ${updated?.enabled == true ? "enabled" : "disabled"}",
        ),
        duration: const Duration(milliseconds: 800),
      ),
    );
  }

  Widget getSource(Source source) {
    return Opacity(
      opacity: source.enabled ? 1.0 : 0.5,
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        elevation: 5,
        child: ListTile(
          // fix196: tap the monitor icon to pick a per-source tag color.
          // fix307: only when the source is enabled.
          leading: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: !source.enabled
                ? null
                : () async {
              final result =
                  await showSourceColorPicker(context, current: source.color);
              if (result == null) return;
              source.color = result.color;
              await Sql.updateSource(source);
              await reloadSources();
            },
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (source.color != null)
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: Color(source.color!),
                      shape: BoxShape.circle,
                    ),
                  ),
                Icon(source.enabled ? Icons.tv : Icons.tv_off),
              ],
            ),
          ),
          horizontalTitleGap: 25,
          contentPadding: const EdgeInsets.only(left: 20),
          title: Text(source.name),
          // fix268: connection count moved to the source edit dialog; the list
          // subtitle shows just the source type again.
          subtitle: Text(source.sourceType.label),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Enable/disable toggle — always active (fix307).
              Switch(
                value: source.enabled,
                onChanged: (_) => toggleSource(source),
              ),
              // fix307: when a source is disabled, its other actions
              // (refresh / edit / delete / color) are disabled too — only the
              // enable/disable switch above stays usable.
              Offstage(
                offstage: source.sourceType == SourceType.m3u,
                child: IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: !source.enabled
                      ? null
                      : () async {
                    await _refreshSingleSource(source);
                    if (mounted) await reloadSources();
                  },
                ),
              ),
              Offstage(
                offstage: source.sourceType == SourceType.m3u,
                child: IconButton(
                  icon: const Icon(Icons.edit),
                  // fix384: Edit is always available, even when the
                  // source is disabled. The user may want to fix a
                  // typo in the URL of a source they disabled because
                  // it was broken. The Edit dialog is a thin
                  // showDialog wrapper around `Sql.updateSource` (no
                  // network) so it's safe to expose for disabled
                  // sources.
                  onPressed: () async => await showEditDialog(context, source),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete),
                // fix384: Delete is always available too, regardless
                // of the enable/disable toggle. The user disabled the
                // source for a reason; allowing direct deletion is a
                // cleaner UX than forcing a re-enable → delete cycle.
                // `showConfirmDeleteDialog` shows a confirm dialog
                // before the actual delete, so a stray tap is
                // protected.
                onPressed: () async => await showConfirmDeleteDialog(source),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> showConfirmDeleteDialog(Source source) async {
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (builder) => ConfirmDelete(
        type: "source",
        name: source.name,
        confirm: () async {
          await Error.tryAsync(
            () async => await Sql.deleteSource(source.id!),
            context,
            "Successfully deleted source",
          );
          await reloadSources();
          if (sources.isEmpty && mounted) {
            // ignore: use_build_context_synchronously
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => const Setup()),
              (route) => false,
            );
          }
        },
      ),
    );
  }

  Future<void> reloadSources() async {
    await Error.tryAsyncNoLoading(
      () async => sources = await Sql.getSources(),
      context,
    );
    if (mounted) setState(() {});
  }

  /// Refresh a single Xtream source with a live progress dialog.
  /// Uses the Completer pattern so the async callback can drive the
  /// StatefulBuilder dialog — same approach as showSourcesRefreshDialog.
  Future<void> _refreshSingleSource(Source source) async {
    AppLog.info('Settings: refresh single source "${source.name}"');

    String status = 'Connecting…';
    bool done = false;
    String? errorMsg;

    final dialogReady = Completer<void>();
    late void Function(void Function()) setSt;

    final dialogClosed = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (sCtx, s) {
          setSt = s;
          if (!dialogReady.isCompleted) dialogReady.complete();
          return PopScope(
            canPop: done,
            child: AlertDialog(
              title: Text('Refreshing "${source.name}"…'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!done) const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                    status,
                    style: Theme.of(sCtx).textTheme.bodySmall,
                  ),
                ],
              ),
              actions: done
                  ? [
                      FilledButton(
                          autofocus: true,
                        onPressed: () => Navigator.pop(sCtx),
                        child: const Text('OK'),
                      ),
                    ]
                  : null,
            ),
          );
        },
      ),
    );

    unawaited(() async {
      await dialogReady.future;
      try {
        await Utils.refreshSource(
          source,
          onProgress: (msg) => setSt(() {
            status = msg.length > 60 ? '${msg.substring(0, 60)}…' : msg;
          }),
        );
        // fix600: also refresh this source's EPG so the guide/On-now have a
        // current forecast — the channel refresh alone left the EPG stale
        // (the onn's background EPG task is unreliable).
        final epgUrl = EpgService.resolveEpgUrl(source);
        if (epgUrl != null) {
          await EpgService.refreshSource(
            source,
            epgUrl: epgUrl,
            onProgress: (p) {
              final msg = p.statusMessage ??
                  'EPG: ${p.programsInserted} programmes…';
              setSt(() {
                status = msg.length > 60 ? '${msg.substring(0, 60)}…' : msg;
              });
            },
          );
        }
        AppLog.info('Settings: refresh "${source.name}" — done');
        setSt(() {
          done = true;
          status = 'Refresh complete.';
        });
      } catch (e, st) {
        errorMsg = e.toString();
        AppLog.warn('Settings: refresh "${source.name}" — ERROR: $e\n$st');
        setSt(() {
          done = true;
          status = 'Error: $errorMsg';
        });
      }
    }());

    await dialogClosed;
  }

  // fix541: format an EPG refresh timestamp as a friendly relative/absolute
  // string for the "Last loaded …" subtitle.
  String _formatEpgWhen(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) {
      final h = diff.inHours;
      return '$h hour${h == 1 ? '' : 's'} ago';
    }
    if (diff.inDays < 7) {
      final d = diff.inDays;
      return '$d day${d == 1 ? '' : 's'} ago';
    }
    String two(int v) => v.toString().padLeft(2, '0');
    return '${when.year}-${two(when.month)}-${two(when.day)}';
  }

  // fix541: format a sub-24h age (in hours) for the recent-EPG confirm prompt.
  String _formatEpgAge(double ageHours) {
    if (ageHours < 1) {
      final mins = (ageHours * 60).round();
      return '$mins minute${mins == 1 ? '' : 's'}';
    }
    final h = ageHours.floor();
    return '$h hour${h == 1 ? '' : 's'}';
  }

  /// Shows a live progress dialog while refreshing all EPG sources, then
  /// displays a summary of results.
  Future<void> _runEpgRefresh(BuildContext ctx) async {
    final enabledWithEpg = sources.where((s) {
      if (!s.enabled) return false;
      final hasManualUrl = s.epgUrl?.isNotEmpty == true;
      final isXtream = s.sourceType == SourceType.xtream;
      return hasManualUrl || isXtream;
    }).toList();

    AppLog.info(
      'EpgRefresh: starting — ${enabledWithEpg.length} eligible source(s):'
      ' ${enabledWithEpg.map((s) => '"${s.name}"').join(", ")}',
    );

    String status = 'Starting…';
    int programs = 0;
    int matchDone = 0;
    int matchTotal = 0;
    final results = <String>[];

    bool dialogOpen = true;
    // a new one. After a dialog closes, _refreshSetState still holds its
    // disposed widget's setSt. Calling it throws "Null check operator used
    // on a null value" inside Flutter's State.setState (_element! is null
    // after dispose), crashing the for-loop and leaving the next dialog
    // frozen at "Starting…" forever.
    _refreshSetState = null;
    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (sCtx, setSt) {
          _refreshSetState = setSt;
          _refreshStatus = status;

          final isMatching = matchTotal > 0;
          final matchFraction =
              isMatching ? matchDone / matchTotal : null;

          return AlertDialog(
            title: const Text('Refreshing EPG…'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Indeterminate during download; determinate during matching
                matchFraction != null
                    ? LinearProgressIndicator(value: matchFraction)
                    : const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(
                  _refreshStatus,
                  style: Theme.of(sCtx).textTheme.bodySmall,
                ),
                // Download phase: show loaded program count
                if (programs > 0 && !isMatching)
                  Text(
                    '$programs programs loaded',
                    style: Theme.of(sCtx).textTheme.bodySmall,
                  ),
                // Matching phase: bold X / Y channel counter
                if (isMatching)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Channels matched: $matchDone / $matchTotal',
                      style: Theme.of(sCtx).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ).then((_) {
      dialogOpen = false;
      _refreshSetState = null; // finding 2: dialog gone -> progress callbacks
      // become no-ops (_updateRefreshDialog null-guards), so a mid-run Back no
      // longer throws setState-on-disposed and aborts the refresh.
    });

    // fix349: keep this task alive via a foreground service if the user
    // switches away from the app (same pattern as the fix318 source
    // refresh). Work stays on the main isolate; the service only promotes
    // the process and mirrors progress to its notification.
    await BackgroundTaskService.run<void>(
      enabled: SettingsService.cached?.backgroundProcessing ?? false,
      title: 'Refreshing EPG',
      work: (update) async {
        for (final source in sources) {
          if (!source.enabled) continue;
          final hasManualUrl = source.epgUrl?.isNotEmpty == true;
          final isXtream = source.sourceType == SourceType.xtream;
          if (!hasManualUrl && !isXtream) continue;

          final url = hasManualUrl ? source.epgUrl : null;
          matchDone = 0;
          matchTotal = 0;
          programs = 0;
          status = 'Preparing "${source.name}"…';
          _updateRefreshDialog(status);
          update(status);

          AppLog.info('EpgRefresh: source "${source.name}" — starting');

          int sourceInserted = 0;
          int sourceMatchedChannels = 0;
          int sourceTotalChannels = 0;
          String? sourceError;
          try {
            await EpgService.refreshSource(
              source,
              epgUrl: url,
              onProgress: (p) {
                // matchChannels fires onProgress with programsInserted: 0
                // (it doesn't insert programs). Without this guard the
                // match-phase callbacks overwrite sourceInserted with 0,
                // producing a false "0 programs loaded" warning.
                if (!p.isMatching) {
                  sourceInserted = p.programsInserted;
                  programs = p.programsInserted;
                }

                if (p.isMatching) {
                  matchDone = p.matchingChannelsDone;
                  matchTotal = p.matchingChannelsTotal;
                  // Capture running totals for the summary line
                  sourceMatchedChannels = p.matchingChannelsDone;
                  sourceTotalChannels = p.matchingChannelsTotal;
                  status = '${source.name}: matching channels…';
                  _updateRefreshDialog(status);
                  update(status);
                } else {
                  status = p.statusMessage != null
                      ? '${source.name}: ${p.statusMessage}'
                      : '${source.name}: $programs programs…';
                  _updateRefreshDialog(status);
                  update(status);
                }
              },
            );
            if (sourceInserted == 0) {
              AppLog.warn(
                'EpgRefresh: source "${source.name}" — 0 programs loaded'
                ' (check EPG URL / server / date window)',
              );
              results.add(
                '⚠ ${source.name}: refresh completed but 0 programs loaded '
                '(check EPG URL, server response, or date window)',
              );
            } else {
              AppLog.info(
                'EpgRefresh: source "${source.name}" — done'
                ' programs=$sourceInserted'
                ' matched=$sourceMatchedChannels/$sourceTotalChannels',
              );
              final matchSuffix = sourceTotalChannels > 0
                  ? ' · $sourceMatchedChannels/$sourceTotalChannels channels matched'
                  : '';
              results.add(
                '✓ ${source.name}: $sourceInserted programs$matchSuffix',
              );
            }
          } catch (e, st) {
            sourceError = e.toString();
            AppLog.warn('EpgRefresh: source "${source.name}" — ERROR: $e\n$st');
            results.add('✗ ${source.name}: $sourceError');
          }
        }
      },
    );

    AppLog.info(
      'EpgRefresh: complete — ${results.length} source(s) processed\n'
      '${results.join("\n")}',
    );
  
    if (dialogOpen && ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();

    if (!ctx.mounted) return;
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('EPG Refresh Complete'),
        content: SingleChildScrollView(
          child: Text(results.isEmpty
              ? 'No sources had an EPG URL configured.'
              : results.join('\n')),
        ),
        actions: [
          FilledButton(
              autofocus: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    // finding 12: refresh the memoized "last loaded" subtitle after a run.
    if (mounted) {
      _latestEpgRefreshTs = await Sql.getLatestEpgRefresh();
      setState(() {});
    }
  }

  /// Force a full EPG re-match for all sources (forceRematch=true).
  /// Re-downloads each source's XMLTV to get the current channel map, then
  /// force-matches EVERY channel (not just unmatched ones). The epg.sqlite
  /// writes are guarded against cross-isolate SQLITE_BUSY (fix625).
  Future<void> _runEpgRematch(BuildContext ctx) async {
    final eligibleSources = sources.where((s) {
      if (!s.enabled) return false;
      return EpgService.resolveEpgUrl(s) != null;
    }).toList();

    AppLog.info(
      'EpgRematch: starting — ${eligibleSources.length} eligible source(s):'
      ' ${eligibleSources.map((s) => '"${s.name}"').join(", ")}',
    );

    String status = 'Starting…';
    int matchDone = 0;
    int matchTotal = 0;
    bool dialogOpen = true;
    _refreshSetState = null;

    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (sCtx, setSt) {
          _refreshSetState = setSt;
          final fraction = matchTotal > 0 ? matchDone / matchTotal : null;
          return AlertDialog(
            title: const Text('Re-matching channels…'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                fraction != null
                    ? LinearProgressIndicator(value: fraction)
                    : const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(status,
                    style: Theme.of(sCtx).textTheme.bodySmall),
                if (matchTotal > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Channels matched: $matchDone / $matchTotal',
                      style: Theme.of(sCtx).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ).then((_) {
      dialogOpen = false;
      _refreshSetState = null; // finding 2/3: dialog gone -> progress callbacks
      // become no-ops, so a mid-run Back no longer aborts the re-match.
    });

    final results = <String>[];
    // fix349: keep this task alive via a foreground service if the user
    // switches away from the app (same pattern as the fix318 source
    // refresh). Work stays on the main isolate; the service only promotes
    // the process and mirrors progress to its notification.
    await BackgroundTaskService.run<void>(
      enabled: SettingsService.cached?.backgroundProcessing ?? false,
      title: 'Re-matching channels',
      work: (update) async {
        for (final source in sources) {
          if (!source.enabled) continue;
          final epgUrl = EpgService.resolveEpgUrl(source);
          if (epgUrl == null) continue;

          status = 'Re-matching "${source.name}"…';
          _updateRefreshDialog(status);
          update(status);
          matchDone = 0;
          matchTotal = 0;

          AppLog.info('EpgRematch: source "${source.name}" — downloading EPG');

          try {
            // Download fresh XMLTV to get the latest channelMap, then force-match.
            final channelMap = await EpgService.downloadAndParseEpg(
              source,
              epgUrl: epgUrl,
              onProgress: (p) {
                status = '${source.name}: ${p.statusMessage ?? "downloading…"}';
                _updateRefreshDialog(status);
                update(status);
              },
            );
            if (channelMap == null) {
              AppLog.warn('EpgRematch: source "${source.name}" — download returned null');
              results.add('⚠ ${source.name}: failed to download EPG');
              continue;
            }
            AppLog.info(
              'EpgRematch: source "${source.name}" — EPG downloaded'
              ' (${channelMap.length} channel entries),'
              ' starting force-match',
            );
            await EpgService.matchChannels(
              source,
              channelMap,
              forceAll: true,
              onProgress: (p) {
                matchDone = p.matchingChannelsDone;
                matchTotal = p.matchingChannelsTotal;
                status = '${source.name}: matching…';
                _updateRefreshDialog(status);
                update(status);
              },
            );
            AppLog.info(
              'EpgRematch: source "${source.name}" — force-match done'
              ' $matchDone/$matchTotal',
            );
            results.add('✓ ${source.name}: re-match complete'
                '${matchTotal > 0 ? " ($matchDone/$matchTotal)" : ""}');
          } catch (e, st) {
            AppLog.warn('EpgRematch: source "${source.name}" — ERROR: $e\n$st');
            results.add('✗ ${source.name}: $e');
          }
        }
      },
    );

    AppLog.info(
      'EpgRematch: complete — ${results.length} source(s) processed\n'
      '${results.join("\n")}',
    );

    if (dialogOpen && ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
    if (!ctx.mounted) return;
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('Re-match Complete'),
        content: SingleChildScrollView(
          child: Text(results.isEmpty
              ? 'No sources with EPG configured.'
              : results.join('\n')),
        ),
        actions: [
          FilledButton(
              autofocus: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // Mutable state for the refresh progress dialog
  void Function(void Function())? _refreshSetState;
  String _refreshStatus = '';

  // finding 12: cache the last-EPG-refresh timestamp so the "Refresh EPG now"
  // subtitle no longer fires a fresh Sql.getLatestEpgRefresh() DB query on
  // every Settings rebuild (which competed with an in-flight refresh on the
  // shared sqlite pool and flickered the subtitle). Loaded in initAsync and
  // re-read after a refresh run.
  int? _latestEpgRefreshTs;

  void _updateRefreshDialog(String status) {
    _refreshStatus = status;
    _refreshSetState?.call(() {});
  }

  /// fix612: run the on-device search benchmark and, if the user picks a
  /// method, persist it via the same path as the manual method picker.
  Future<void> _runSearchPerfTest() async {
    final enabledIds = sources
        .where((s) => s.enabled)
        .map((s) => s.id!)
        .toList();
    if (enabledIds.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enable at least one source first.'),
        ),
      );
      return;
    }
    final chosen = await showSearchPerfDialog(
      context,
      enabledSourceIds: enabledIds,
      safeMode: settings.safeMode,
    );
    if (chosen == null || !mounted) return;
    if (chosen != settings.searchMethod) {
      setState(() {
        settings.searchMethod = chosen;
        updateSettings();
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Search method set to ${_searchMethodShortLabel(chosen)}.')),
      );
    }
  }

  Future<void> updateSettings() async {
    await Error.tryAsyncNoLoading(
      () async => await SettingsService.updateSettings(settings),
      context,
    );
  }

  /// Shared confirmation + apply flow for both reset actions.
  ///
  /// [builder] produces the fresh [Settings] instance.
  ///
  /// The following session-state fields are ALWAYS preserved across both
  /// actions because the user wouldn't expect a "reset" to clobber them:
  ///   - `debugLogging`
  ///   - `multiViewLayout`, `multiViewCells1x2`, `multiViewCells2x2`
  ///
  /// When [preserveLibraryPreferences] is true (used by the Optimise
  /// action), these additional fields are preserved because they are
  /// personal library preferences with no relationship to device tuning:
  ///   - `defaultView`, `refreshOnStart`, `forceTVMode`
  ///   - `showLivestreams`, `showMovies`, `showSeries`
  ///   - All EPG settings
  // fix327: TV export used to build the bundle (gather dumps, read log, zip)
  // and start the LAN server with NO UI — on a large catalogue that silent gap
  // made it look frozen/broken, and a failure only flashed a SnackBar that is
  // easy to miss on a TV (the reported "QR site never opens"). This wraps the
  // whole flow in a step-by-step progress dialog and surfaces any failure as a
  // persistent, dismissible dialog. Everything is logged so the cause is in
  // the debug log even when the user can't easily retrieve one.
  Future<void> _runTvServerExport({
    required String stamp,
    String? sourceDump,
    bool includeCredentials = false,
  }) async {
    final stepNotifier = ValueNotifier<String>('Preparing export…');
    var dialogOpen = true;
    // fix357: unawaited — an await here would put an async gap before the
    // showDialog(context:) below (analyzer INFO). Line order in the log may
    // shift by a few entries; the stamp still lands at export start.
    unawaited(AppLog.stampVersion('log export'));
    AppLog.info('TV export: starting (stamp=$stamp)');
    // Progress dialog (not dismissible — closed programmatically).
    // ignore: unawaited_futures
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
                width: 28, height: 28, child: CircularProgressIndicator()),
            const SizedBox(width: 20),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: stepNotifier,
                builder: (context, step, child) => Text(step),
              ),
            ),
          ],
        ),
      ),
    ).then((_) => dialogOpen = false); // finding 4: track Back-dismissal so
    // closeProgress() below can't later pop the wrong (Settings) route.

    void closeProgress() {
      if (dialogOpen && mounted) {
        dialogOpen = false;
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    List<ExportItem> items;
    try {
      items = await _buildExportBundle(
        stamp: stamp,
        sourceDump: sourceDump,
        includeCredentials: includeCredentials,
        onStep: (step) {
          AppLog.info('TV export: $step');
          stepNotifier.value = step;
        },
      );
      stepNotifier.value = 'Starting download server…';
      AppLog.info('TV export: starting download server…');
    } catch (e) {
      AppLog.error('TV export: failed building bundle — $e');
      closeProgress();
      stepNotifier.dispose();
      if (mounted) {
        await _showExportErrorDialog('Could not prepare the export', '$e');
      }
      return;
    }

    if (!mounted) {
      stepNotifier.dispose();
      return;
    }
    closeProgress();
    stepNotifier.dispose();
    // fix329: pass the readable device name so the portal + QR dialog
    // identify the source device (aligns with device-tagged filenames).
    final deviceName = await DeviceDetector.deviceLabel();
    if (!mounted) return;
    await _showExportServerDialog(items,
        capturedAt: stamp, deviceName: deviceName);
  }

  // fix327: persistent (not SnackBar) failure dialog for TV export, so the
  // user actually sees why nothing opened.
  Future<void> _showExportErrorDialog(String title, String detail) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(detail)),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // fix158: start server, show URL + QR dialog (TV export).
  Future<void> _showExportServerDialog(
    List<ExportItem> items, {
    String? capturedAt,
    String? deviceName, // fix329
  }) async {
    final server = ExportServer(
      items,
      capturedAt: capturedAt,
      deviceName: deviceName,
      // fix317: portal sources-only import. Runs on the app isolate, so it can
      // touch the DB and trigger a refresh directly. After a successful import
      // we schedule a source refresh on the device (next frame, so the HTTP
      // response returns first).
      onImportSources: (bytes) async {
        final n = await SettingsIo.importSourcesOnly(bytes);
        if (n > 0 && mounted) {
          await reloadSources();
          // fix347 (review HIGH-4): the refresh no longer auto-fires. A
          // portal import previously triggered network fetches against the
          // imported URLs with no on-device interaction — combined with the
          // (formerly) unauthenticated endpoint, an SSRF-flavoured vector.
          // The user now confirms on the device before any fetch runs.
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            if (!mounted) return;
            final go = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Sources imported'),
                content: Text(
                    'Imported $n source${n == 1 ? '' : 's'} from the export '
                    'portal. Refresh ${n == 1 ? 'it' : 'them'} now to load '
                    'channels?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Later'),
                  ),
                  TextButton(
                    autofocus: true,
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Refresh now'),
                  ),
                ],
              ),
            );
            if (go == true && mounted) {
              // ignore: use_build_context_synchronously
              showSourcesRefreshDialog(context);
            }
          });
        }
        return n;
      },
    );
    List<String> urls;
    try {
      urls = await server.start();
    } catch (e) {
      AppLog.error('ExportServer: start failed — $e');
      if (mounted) {
        // ignore: use_build_context_synchronously
        await _showExportErrorDialog('Could not start the download server',
            'The local server on port ${ExportServer.port} could not start.\n\n$e');
      }
      return;
    }
    if (urls.isEmpty) {
      await server.stop();
      AppLog.warn('ExportServer: no network interface / no URL to show');
      if (mounted) {
        // ignore: use_build_context_synchronously
        await _showExportErrorDialog('No network found',
            'Connect this device to Wi-Fi or Ethernet on the same network as '
            'your phone or PC, then try the export again.');
      }
      return;
    }
    if (!mounted) { await server.stop(); return; }
    final primary = urls.first;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      // ignore: use_build_context_synchronously
      builder: (ctx) => AlertDialog(
        title: Text(deviceName != null && deviceName.isNotEmpty
            ? 'Download from $deviceName'
            : 'Download on your phone or PC'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'On a device on the same Wi-Fi, scan this code or '
                'type the address, then tap a file to download:'),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                color: Colors.white,
                child: QrImageView(
                  data: primary,
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              for (final u in urls)
                SelectableText(
                  u,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
              const SizedBox(height: 8),
              const Text(
                'Server stops after 10 minutes.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () async {
              await server.stop();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
    await server.stop();
  }

  // fix222: long-press on "Export log file" exports the raw Xtream source
  // dumps (xtream_dump_*.json written during refresh when debug logging is on),
  // concatenated into one text file with delimiters so a single SAF save
  // captures all of them. Diagnostic aid for refresh-perf investigation.
  Future<void> _exportSourceDumps() async {
    final dir = await Utils.appDir;
    final d = Directory(dir);
    final dumps = <File>[];
    if (await d.exists()) {
      await for (final e in d.list()) {
        if (e is File &&
            e.path.contains('xtream_dump_') &&
            e.path.endsWith('.json')) {
          dumps.add(e);
        }
      }
    }
    if (!mounted) return;
    if (dumps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'No source dumps found. Enable debug logging, refresh a source, '
              'then try again.'),
        ),
      );
      return;
    }
    final isTV = await DeviceDetector.isTV();
    if (!mounted) return;
    final stamp = await SettingsIo.stampWithDevice(); // fix322
    if (isTV) {
      // fix536: offer to include the DB snapshot from the diagnostic export too
      // (previously only the "Export settings to file" path could). Gated the
      // same way — the DB carries credentials — and defaults to No.
      if (!mounted) return;
      final includeDb = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Include database snapshot?'),
          content: const Text(
            'Also include a full database snapshot (channels + EPG) for '
            'diagnostics? This makes the export much larger and contains your '
            'Xtream usernames and passwords.\n\n'
            'Only choose YES if you are sending this somewhere secure.',
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('No (safer)'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Yes'),
            ),
          ],
        ),
      );
      if (includeDb == null || !mounted) return;
      // fix311: the LAN server exports all files (source dump, debug log,
      // settings) plus a combined zip.
      // fix327: build + serve behind a progress dialog.
      // fix328: pass sourceDump:null so the builder STREAMS the dumps to a
      // file instead of this method concatenating them in memory (OOM on TV).
      await _runTvServerExport(stamp: stamp, includeCredentials: includeDb);
    } else {
      // Phone/tablet: concatenate for the single-file save (SAF available,
      // catalogues smaller — acceptable in memory here).
      final buf = StringBuffer();
      for (final f in dumps) {
        final name = f.path.split(Platform.pathSeparator).last;
        buf.writeln('===== FILE: $name =====');
        buf.writeln(await f.readAsString());
        buf.writeln();
      }
      if (!mounted) return;
      await SettingsIo.exportStringToFile(
        // ignore: use_build_context_synchronously
        context,
        content: buf.toString(),
        suggestedName: 'free4me-source-dump-$stamp.txt',
      );
    }
  }

  // fix311: build the full export bundle — source dump, debug log, settings
  // backup — all sharing one timestamp, plus a zip containing all three. Each
  // file is offered individually AND in the combined zip (4 download options).
  // Any file that can't be produced (e.g. no source dump yet) is simply
  // omitted, and the zip contains whatever was produced.
  Future<List<ExportItem>> _buildExportBundle({
    required String stamp,
    String? sourceDump,
    bool includeCredentials = false,
    void Function(String step)? onStep, // fix327: progress reporting
  }) async {
    final items = <ExportItem>[];
    // fix328: write each export file to a temp dir and stream from disk
    // (ExportServer is now file-backed). Nothing holds the whole catalogue in
    // memory — fixes the OOM on the 2GB TV box while gathering source data.
    final tmp = await getTemporaryDirectory();
    // fix572: purge prior sessions' export artifacts before building this one.
    // These bundle dirs can hold multi-hundred-MB DB snapshots and were never
    // cleaned up when the download server stopped, so the temp dir grew without
    // bound. Keep the dir we're about to (re)create; also sweep orphaned backup
    // jsons left by a crash mid-save.
    await SettingsIo.purgeStaleExportArtifacts(
        keepExportDir: 'free4me-export-$stamp');
    final outDir = Directory('${tmp.path}/free4me-export-$stamp');
    if (await outDir.exists()) await outDir.delete(recursive: true);
    await outDir.create(recursive: true);

    // Files to include in the zip, by on-disk path + archive name.
    final toZip = <String, String>{};
    // fix594: DB snapshot paths (credential-gated), for the "Everything" zip.
    final dbPaths = <String, String>{};

    // fix654: gzip every text item at level 9 (dart:io native zlib — see
    // SettingsIo.gzipBytes) instead of writing plain text. The zip below then
    // STOREs these already-compressed files instead of re-deflating them.
    Future<void> addTextFile(String key, String filename, String label,
        String content, String contentType) async {
      final gzName = '$filename.gz';
      final f = File('${outDir.path}/$gzName');
      await f.writeAsBytes(SettingsIo.gzipBytes(utf8.encode(content)));
      final len = await f.length();
      items.add(ExportItem(
        key: key,
        filename: gzName,
        label: label,
        filePath: f.path,
        sizeBytes: len,
        contentType: 'application/gzip',
      ));
      toZip[f.path] = gzName;
    }

    // 1. Source dump — written file-to-file (no giant in-memory string), then
    // stream-gzipped (fix654) and the plaintext discarded. Streaming gzip is
    // what actually fixes the OOM that hit a 532MB dump on the 2GB TV box —
    // archive's pure-Dart Deflate buffered enough of it to exhaust the heap;
    // dart:io's native zlib does not.
    onStep?.call('Gathering source data…');
    final dumpName = 'free4me-source-dump-$stamp.txt';
    final dumpPath = '${outDir.path}/$dumpName';
    // finding P0-1: the raw source dumps echo the Xtream user_info block
    // (username + password in cleartext) and have no scrubber, so gate them on
    // includeCredentials exactly as the DB snapshot below is gated. When creds
    // are excluded, wroteDump is false so the dump never enters items/toZip/zip.
    final wroteDump = !includeCredentials
        ? false
        : (sourceDump != null
            ? await _writeStringToFile(dumpPath, sourceDump)
            : await _streamSourceDumpToFile(dumpPath));
    if (wroteDump) {
      final gzName = '$dumpName.gz';
      final gzPath = '${outDir.path}/$gzName';
      await SettingsIo.gzipFileStream(File(dumpPath), gzPath);
      await File(dumpPath).delete();
      final len = await File(gzPath).length();
      items.add(ExportItem(
        key: 'sourcedump',
        filename: gzName,
        label: 'Raw source dumps',
        filePath: gzPath,
        sizeBytes: len,
        contentType: 'application/gzip',
      ));
      toZip[gzPath] = gzName;
    }
    // 2. Debug log.
    onStep?.call('Collecting debug log…');
    final log = await AppLog.readLog();
    if (log.isNotEmpty) {
      await addTextFile('log', 'free4me_log-$stamp.txt', 'Debug log', log,
          'text/plain; charset=utf-8');
    }
    // 3. Settings backup.
    onStep?.call('Building settings backup…');
    final backup = await SettingsIo.buildBackupPayload(
        includeCredentials: includeCredentials);
    await addTextFile('settings', 'free4me-settings-$stamp.json',
        'Settings backup', backup, 'application/json');

    // fix535: SQLite database snapshot(s). The QR/LAN diagnostic export
    // previously shipped only the raw source dumps + settings + log, which lets
    // us mirror schema and row SHAPE but not the real cat_enabled / favorite /
    // stream_validated / EPG distribution — exactly what a faithful
    // performance-benchmark seed needs.
    //
    // GATED on includeCredentials: db.sqlite stores Xtream usernames/passwords
    // in the `sources` table AND embeds them in every channel `url`, so the DB
    // ships ONLY when the user explicitly opted into credentials (same gate as
    // the settings backup). When creds are excluded, the DB is omitted rather
    // than shipped with secrets.
    //
    // Checkpoint+truncate the WAL first so the .sqlite files are self-consistent
    // (recent writes otherwise live only in the -wal sidecar), then
    // stream-gzip each DB straight to the export dir as a STANDALONE download
    // — no plaintext copy ever touches disk. fix654: replaces the old
    // stream-COPY (fix536); dart:io's native zlib streams a multi-hundred-MB
    // file without holding it in memory (unlike archive's Deflate, which
    // OOM'd on a 532MB text file this same session), and a SQLite file
    // compresses better than the old "barely compresses" assumption gave it
    // credit for — the page structure repeats a lot (URLs, channel names).
    if (includeCredentials) {
      onStep?.call('Snapshotting database…');
      try {
        await Sql.checkpointAndTruncateWal();
      } catch (e) {
        AppLog.warn('export: WAL checkpoint before DB snapshot failed — $e');
      }
      final appDir = await Utils.appDir;
      for (final dbName in const ['db.sqlite', 'epg.sqlite']) {
        final src = File('$appDir/$dbName');
        if (!await src.exists()) continue;
        final destName = 'free4me-$dbName-$stamp.sqlite.gz';
        final destPath = '${outDir.path}/$destName';
        try {
          await SettingsIo.gzipFileStream(src, destPath);
          final len = await File(destPath).length();
          dbPaths[destPath] = destName; // fix594: for the "Everything" zip
          items.add(ExportItem(
            key: 'db-$dbName',
            filename: destName,
            label:
                dbName == 'db.sqlite' ? 'Channel database' : 'EPG database',
            filePath: destPath,
            sizeBytes: len,
            contentType: 'application/gzip',
          ));
        } catch (e) {
          AppLog.warn('export: failed to gzip $dbName — $e');
        }
      }
    }

    // 4. Combined zip — encoded directly to a file on disk. fix654: every
    // entry is already gzipped at level 9 (dart:io native zlib, streamed —
    // see addTextFile / gzipFileStream above), so STORE it as-is; re-deflating
    // already-compressed bytes just burns CPU for no size gain.
    onStep?.call('Compressing files…');
    if (toZip.isNotEmpty) {
      final zipName = 'free4me-export-$stamp.zip';
      final zipPath = '${outDir.path}/$zipName';
      final encoder = ZipFileEncoder();
      encoder.create(zipPath);
      for (final entry in toZip.entries) {
        await encoder.addFile(File(entry.key), entry.value, ZipFileEncoder.STORE);
      }
      await encoder.close();
      final len = await File(zipPath).length();
      items.add(ExportItem(
        key: 'bundle',
        filename: zipName,
        label: 'All files (zip)',
        filePath: zipPath,
        sizeBytes: len,
        contentType: 'application/zip',
      ));
    }

    // fix594/fix654: an optional "Everything (incl. databases)" zip — the
    // small zip's contents PLUS the SQLite DBs in ONE download. Every entry
    // (text and DB) is already gzipped, so both loops STORE. addFile streams
    // the input (archive 4.x) so neither path holds the file in heap.
    // Credential-gated (the DB embeds Xtream user/pass), same as the
    // standalone DB downloads. The small zip above is left exactly as-is.
    if (includeCredentials && dbPaths.isNotEmpty && toZip.isNotEmpty) {
      onStep?.call('Building full archive (incl. databases)…');
      final allName = 'free4me-export-all-$stamp.zip';
      final allPath = '${outDir.path}/$allName';
      final allEnc = ZipFileEncoder();
      allEnc.create(allPath);
      for (final entry in toZip.entries) {
        await allEnc.addFile(File(entry.key), entry.value, ZipFileEncoder.STORE);
      }
      for (final entry in dbPaths.entries) {
        await allEnc.addFile(File(entry.key), entry.value, ZipFileEncoder.STORE);
      }
      await allEnc.close();
      final len = await File(allPath).length();
      items.add(ExportItem(
        key: 'bundle-all',
        filename: allName,
        label: 'Everything incl. databases (zip)',
        filePath: allPath,
        sizeBytes: len,
        contentType: 'application/zip',
      ));
    }
    return items;
  }

  // fix328: write a string to a file, returning false (and no file) when the
  // content is empty.
  Future<bool> _writeStringToFile(String path, String content) async {
    if (content.isEmpty) return false;
    await File(path).writeAsString(content);
    return true;
  }

  // fix311/fix328: stream the raw Xtream source dumps to a single file,
  // copying each dump file-to-file (never concatenating into one big string).
  // Returns false when there are no dumps to write.
  Future<bool> _streamSourceDumpToFile(String outPath) async {
    final dir = await Utils.appDir;
    final d = Directory(dir);
    if (!await d.exists()) return false;
    final dumps = <File>[];
    await for (final e in d.list()) {
      if (e is File &&
          e.path.contains('xtream_dump_') &&
          e.path.endsWith('.json')) {
        dumps.add(e);
      }
    }
    if (dumps.isEmpty) return false;
    final sink = File(outPath).openWrite();
    try {
      for (final f in dumps) {
        final name = f.path.split(Platform.pathSeparator).last;
        sink.writeln('===== FILE: $name =====');
        await sink.addStream(f.openRead());
        sink.writeln();
        sink.writeln();
      }
    } finally {
      await sink.close();
    }
    return true;
  }

  // fix158: build backup + log payloads and serve via LAN (TV only).
  // fix311: now exports the full bundle (source dump + log + settings + zip).
  // fix416: in-app issue reporter. Reports go through a Cloudflare Worker
  // (the "middleman") that holds the GitHub token server-side and files an
  // issue + commits the log to the PRIVATE repo. The app only knows the Worker
  // URL and a low-stakes shared key (worst case if extracted: rate-limited
  // spam issues to the private repo — no GitHub access, no token exposure).
  // fix607: the Worker URL + payload logic moved to IssueReporter (shared with
  // the Live-TV diagnostic easter egg in tv_shell).

  /// fix416: collect a subject + details, then submit. Gated by the caller on
  /// debugLogging && !logUserPass (so a log with raw credentials is never sent).
  Future<void> _showReportIssueDialog() async {
    final subjectCtl = TextEditingController();
    final detailsCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Report an issue'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // fix550: on Android TV a raw multi-line TextField traps D-pad
              // up/down for caret movement, so focus could never leave the
              // 5-line Details field to reach Cancel/Submit — the report dialog
              // was unusable by remote. DpadFocusEscape intercepts arrow up/down
              // and yields focus (previousFocus/nextFocus) before the field sees
              // them, while preserving maxLength/textInputAction/maxLines exactly
              // (so the touch soft-keyboard and char counter are unchanged).
              DpadFocusEscape(
                child: TextField(
                  controller: subjectCtl,
                  autofocus: true,
                  maxLength: 100,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Subject',
                    hintText: 'Short summary',
                  ),
                ),
              ),
              DpadFocusEscape(
                child: TextField(
                  controller: detailsCtl,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Details',
                    hintText: 'What happened? Steps to reproduce?',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Your current debug log will be attached, with the provider '
                'host, username and password removed.',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    final subject = subjectCtl.text.trim();
    final details = detailsCtl.text.trim();
    subjectCtl.dispose();
    detailsCtl.dispose();
    if (ok != true) return;
    if (subject.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a subject.')),
      );
      return;
    }
    await _submitIssueReport(subject, details);
  }

  Future<void> _submitIssueReport(String subject, String details) async {
    // finding 7: track the progress dialog so a Back press during submit can't
    // desync — an unconditional pop would eject the user off the Settings route.
    var progressOpen = false;
    if (mounted) {
      progressOpen = true;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Expanded(child: Text('Submitting report…')),
            ],
          ),
        ),
      ).then((_) => progressOpen = false);
    }
    // fix607: shared submitter (also used by the Live-TV diagnostic easter egg).
    final r = await IssueReporter.submit(subject: subject, details: details);
    final bool success = r.success;
    final String? errorMsg = r.errorMsg;
    if (!mounted) return;
    // finding 7: only dismiss if the dialog is still up (Back may have popped it).
    if (progressOpen) {
      Navigator.of(context, rootNavigator: true).pop(); // dismiss progress
    }
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(success ? 'Report submitted' : 'Report not sent'),
        content: Text(
          success
              ? 'Thanks — your report and log were submitted to the developer.'
              : (errorMsg ?? 'Unknown error.'),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// fix417: confirmation gate for enabling raw-credential logging. The Enable
  /// button stays disabled until the user types "INSECURE" exactly; Cancel or
  /// any other text returns false (the toggle stays OFF).
  Future<bool> _confirmInsecureLogging() async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final match = ctl.text == 'INSECURE';
          return AlertDialog(
            title: const Text('Log raw credentials?'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'This writes your provider usernames and passwords into the '
                    'debug log in plain text. Anyone you share the log with will '
                    'see them, and the in-app issue reporter is disabled while '
                    'this is on.\n\n'
                    'Enable only for your own local testing. To confirm, type '
                    'INSECURE below.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: ctl,
                    autofocus: true,
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (_) => setLocal(() {}),
                    decoration: const InputDecoration(hintText: 'INSECURE'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: match ? () => Navigator.pop(ctx, true) : null,
                child: const Text('Enable'),
              ),
            ],
          );
        },
      ),
    );
    ctl.dispose();
    return ok ?? false;
  }

  Future<void> _exportEverythingViaServer(
      {required bool includeCredentials}) async {
    // fix327: build + serve behind a progress dialog (device-tagged stamp).
    final stamp = await SettingsIo.stampWithDevice();
    await _runTvServerExport(
      stamp: stamp,
      includeCredentials: includeCredentials,
    );
  }

  // fix154: analyze playback log and suggest settings changes.
  Future<void> _runPlaybackAnalysis() async {
    if (!AppLog.enabled) {
      final enable = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Enable debug logging first'),
          content: const Text(
            'Playback analysis needs the debug log. Enable it, '
            'watch a few channels for at least 20 minutes, '
            'then run this again.',
          ),
          actions: [
            // finding 10: only ONE autofocus per scope — let it land on the
            // emphasized 'Enable logging' button, not the destructive Cancel.
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
                autofocus: true,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Enable logging'),
            ),
          ],
        ),
      );
      if (enable == true) {
        await AppLog.setEnabled(true);
        if (mounted) setState(() => settings.debugLogging = true);
        updateSettings(); // fix160: persist via standard helper
      }
      return;
    }

    // Snapshot current session, then aggregate history.
    try {
      final text = await AppLog.readLog();
      final m = PlaybackAnalyzer.parseLatestSession(text);
      if (m.streamsOpened > 0) await Sql.insertPlaybackMetrics(m);
    } catch (_) {}

    if (!mounted) return;
    final agg = await Sql.getAggregatedMetrics();
    AppLog.info('PlaybackAnalysis: aggregate '
        'minutes=${agg.totalMinutes.round()} streams=${agg.totalStreams} '
        'sessions=${agg.sessionCount} sufficient=${agg.hasSufficientData}');
    if (!mounted) return;

    if (!agg.hasSufficientData) {
      await showDialog<void>(
        context: context,
        // ignore: use_build_context_synchronously
        builder: (_) => AlertDialog(
          title: const Text('Not enough data yet'),
          content: Text(
            'Need at least 20 minutes of logged playback across 3+ '
            'streams. Current: '
            '${agg.totalMinutes.round()} min, ${agg.totalStreams} streams.'
            '\n\nWatch a few more channels and try again.',
          ),
          actions: [TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          )],
        ),
      );
      return;
    }

    final recs = Recommender.recommend(agg, settings);

    AppLog.info('PlaybackAnalysis: ${recs.length} recommendation(s)');
    if (!mounted) return;
    if (recs.isEmpty) {
      await showDialog<void>(
        context: context,
        // ignore: use_build_context_synchronously
        builder: (_) => AlertDialog(
          title: const Text('Playback looks healthy'),
          content: Text(
            'No setting changes recommended based on '
            '${agg.totalMinutes.round()} min across '
            '${agg.totalStreams} streams.',
          ),
          actions: [TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          )],
        ),
      );
      return;
    }

    if (!mounted) return;
    final apply = await showDialog<bool>(
      context: context,
      // ignore: use_build_context_synchronously
      builder: (_) => AlertDialog(
        title: const Text('Suggested settings'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Based on ${agg.totalMinutes.round()} min across '
                '${agg.totalStreams} streams:',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              for (final r in recs) ...
                [
                  Text(r.label,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold)),
                  Text(
                    '${r.currentValue} → ${r.suggestedValue}'
                    '${r.requiresRestart ? ' (next launch)' : ''}',
                    style: const TextStyle(fontSize: 13),
                  ),
                  Text(r.rationale,
                      style: const TextStyle(
                          fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 12),
                ],
            ],
          ),
        ),
        actions: [
          TextButton(
              autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
              autofocus: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply all'),
          ),
        ],
      ),
    );

    if (apply != true || !mounted) return;

    final updated = settings;
    for (final r in recs) {
      switch (r.settingKey) {
        case 'liveCacheSecs':
          updated.liveCacheSecs = r.suggestedValue as int; break;
        case 'bufferSizeMB':
          updated.bufferSizeMB = r.suggestedValue as int; break;
        case 'startupGraceMs':
          updated.startupGraceMs = r.suggestedValue as int; break;
        case 'bufferingWatchdogSecs':
          updated.bufferingWatchdogSecs = r.suggestedValue as int; break;
        case 'openTimeoutSecs':
          updated.openTimeoutSecs = r.suggestedValue as int; break;
      }
    }
    await SettingsService.updateSettings(updated);
    if (mounted) setState(() => settings = updated);

    final hasRestart = recs.any((r) => r.requiresRestart);
    if (mounted) {
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Applied ${recs.length} change(s).'
          '${hasRestart ? ' Buffer size takes effect on next launch.' : ''}',
        ),
      ));
    }
  }

  Future<void> _confirmAndResetSettings({
    required String title,
    required String body,
    required Settings Function() builder,
    bool preserveLibraryPreferences = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
              autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final fresh = builder()
      ..debugLogging = settings.debugLogging
      ..logUserPass = settings.logUserPass
      // finding 103: searchMethod must survive BOTH reset and optimise —
      // settings.searchMethod already holds the RAM-aware resolver's decision,
      // so preserving it stops reset/optimise re-persisting the ctor `inMemory`
      // on a low-RAM box (which would drop the channels_fts triggers).
      ..searchMethod = settings.searchMethod
      ..multiViewLayout = settings.multiViewLayout
      ..multiViewCells1x2 = settings.multiViewCells1x2
      ..multiViewCells2x2 = settings.multiViewCells2x2;

    if (preserveLibraryPreferences) {
      fresh
        ..defaultView = settings.defaultView
        ..refreshOnStart = settings.refreshOnStart
        ..forceTVMode = settings.forceTVMode
        ..use24HourTime = settings.use24HourTime // fix604 (#5)
        ..showLivestreams = settings.showLivestreams
        ..showMovies = settings.showMovies
        ..showSeries = settings.showSeries
        ..epgAutoRefresh = settings.epgAutoRefresh
        ..epgRefreshHours = settings.epgRefreshHours
        ..epgRefreshHour = settings.epgRefreshHour
        ..epgPastDays = settings.epgPastDays
        ..epgForecastDays = settings.epgForecastDays
        ..epgSearchHours = settings.epgSearchHours
        // findings 5/105: Optimise promises to preserve library/UX prefs but
        // its factory reset them to ctor defaults — safeMode flipping off
        // (un-hiding adult content) is the worst. Preserve them explicitly.
        ..safeMode = settings.safeMode
        ..confirmToExit = settings.confirmToExit
        ..contentTypeFilter = settings.contentTypeFilter
        ..playerZoomMode = settings.playerZoomMode;
    } else {
      // finding 104: plain Reset must use RAM-aware memory defaults (what a
      // fresh install would pick on THIS box), not the hardcoded ctor
      // 128/150/32. Reset-only so it never clobbers the device-tuned values
      // Settings.optimisedFor bakes in on the Optimise path.
      fresh
        ..bufferSizeMB = DeviceMemory.defaultBufferSizeMb
        ..miniDemuxerMaxMB = DeviceMemory.defaultMiniDemuxerMb
        ..liveDemuxerMaxMB = DeviceMemory.defaultLiveDemuxerMb
        ..vodDemuxerMaxMB = DeviceMemory.defaultLiveDemuxerMb + 64;
    }

    // Only `bufferSizeMB` is baked into `PlayerConfiguration` at MpvEngine
    // construction (lib/player/mpv_engine.dart), so it is the one field
    // that genuinely requires an app restart to take effect. The demuxer-MB
    // and cache-secs fields are re-applied via `reapplyOptions()` on the
    // next stream open. Choose the snackbar copy accordingly so users
    // aren't told to restart when nothing restart-bound changed.
    final restartNeeded = fresh.bufferSizeMB != settings.bufferSizeMB;

    setState(() => settings = fresh);
    await updateSettings();

    if (!mounted) return;
    AppLog.info(
      'Settings: reset applied — $title'
      ' bufferSizeChanged=$restartNeeded',
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          restartNeeded
              ? 'Settings updated. Restart the app for buffer-size changes '
                  'to take full effect.'
              : 'Settings updated.',
        ),
      ),
    );
  }


  /// A section header with the standard style.
  Widget _sectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(label, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  /// Small info icon button that opens [title] / [body] help dialog.
  Widget _helpIcon({
    required String title,
    required String body,
  }) {
    return IconButton(
      icon: Icon(
        Icons.info_outline,
        size: 18,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
      ),
      tooltip: 'About this setting',
      onPressed: () => SettingHelpDialog.show(context, title: title, body: body),
    );
  }

  /// A switch row where tapping the label also opens the help dialog.
  Widget _switchTile({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    required ({String title, String body}) help,
  }) {
    // fix156: SwitchListTile makes the whole row D-pad focusable;
    // select toggles the switch. Help is a separate focus stop.
    return SwitchListTile(
      title: Text(label),
      value: value,
      onChanged: onChanged,
      secondary: _helpIcon(title: help.title, body: help.body),
    );
  }

  /// A slider row where tapping the label also opens the help dialog.
  Widget _bufferSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    required ({String title, String body}) help,
    int decimals = 0, // fix394: 0 = integer display (legacy); 1 or 2
        // for fractional libmpv tunables (e.g. demuxer-readahead-secs 1.5,
        // audio-buffer 0.20).
  }) {
    final String valueText = switch (decimals) {
      1 => value.toStringAsFixed(1),
      2 => value.toStringAsFixed(2),
      _ => value.round().toString(),
    };
    return ListTile(
      // fix156/160: plain text title so the row body is the D-pad target.
      title: Text(label),
      subtitle: _DpadFriendlySlider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        label: valueText,
        onChanged: onChanged,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              valueText,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          _helpIcon(title: help.title, body: help.body),
        ],
      ),
    );
  }


  Widget _multiViewTile(Settings settings) {
    return ListTile(
      title: Row(
        children: [
          const Text('Multi-view layout'),
          const SizedBox(width: 4),
          _helpIcon(
            title: 'Multi-view',
            body: 'Plays multiple Live TV channels at the same time in a '
                'split-screen grid.\n\n'
                'Default: Off.\n\n'
                'Off: Multi-view is hidden and no extra streams are '
                'started.\n\n'
                '1×2: Plays up to two Live TV channels side by side. This '
                'is the safest multi-view option for most TV boxes.\n\n'
                '2×2: Plays up to four Live TV channels. Needs more CPU, '
                'decoder capacity, network bandwidth, and RAM. Use it on '
                'stronger devices or with lower-bitrate streams.\n\n'
                'Tap an empty cell to choose a Live TV channel. Tap a '
                'playing cell to give it audio focus.',
          ),
        ],
      ),
      trailing: TextButton(
        onPressed: () => _showMultiViewPickerDialog(settings),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _multiViewShortLabel(settings.multiViewLayout),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  String _multiViewShortLabel(MultiViewLayout layout) => switch (layout) {
        MultiViewLayout.none => 'Off',
        MultiViewLayout.oneByTwo => '1×2',
        MultiViewLayout.twoByTwo => '2×2',
      };

  // fix314: decode-mode picker for multi-view cells (Tegra/Shield colour fix).
  Widget _multiViewDecodeTile(Settings s) {
    return ListTile(
      title: Row(
        children: [
          const Text('Multi-view decode'),
          const SizedBox(width: 4),
          _helpIcon(
            title: 'Multi-view decode',
            body: 'Controls how multi-view cells decode video.\n\n'
                'Default: Auto.\n\n'
                'Auto: Uses hardware decode on most devices, but switches to '
                'software decode on NVIDIA Shield / Tegra boxes, where running '
                'several hardware decoders at once can corrupt the colours '
                '(rainbow / wrong tint) in the 2×2 grid.\n\n'
                'Hardware (copy): Forces hardware decode for all cells. Lowest '
                'CPU use, but may show colour corruption on Shield/Tegra.\n\n'
                'Software: Forces CPU decode for all cells. Fixes colour '
                'problems at the cost of higher CPU use; best on strong '
                'devices or with lower-bitrate streams.',
          ),
        ],
      ),
      trailing: TextButton(
        onPressed: () => _showMultiViewDecodeDialog(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              s.multiViewDecode.label,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  // fix341: multi-view stability buffer (seconds behind live).
  static const _stabilityBufferOptions = [0, 15, 30];

  Widget _stabilityBufferTile(Settings s) {
    final v = s.multiViewStabilityBufferSecs;
    final label = v == 0 ? 'Off' : '${v}s';
    return ListTile(
      title: Row(
        children: [
          const Text('Multi-view stability buffer'),
          const SizedBox(width: 4),
          _helpIcon(
            title: 'Multi-view stability buffer',
            body: 'Builds a cushion of video before each cell starts playing, '
                'so brief provider connection drops play through smoothly '
                'instead of stuttering.\n\n'
                'Default: Off (cells play at the live edge).\n\n'
                'With a 15s or 30s buffer, each cell waits that long after '
                'opening (showing "Building buffer…"), then plays that far '
                'BEHIND live. Useful when a provider limits simultaneous '
                'connections and cycles them (cells dropping every ~30s). '
                'Not recommended for time-sensitive viewing such as live '
                'sports, since the picture is delayed by the buffer length.',
          ),
        ],
      ),
      trailing: TextButton(
        onPressed: () => _showStabilityBufferDialog(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  Future<void> _showStabilityBufferDialog(BuildContext context) async {
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (_) => SelectDialog(
        title: 'Multi-view stability buffer',
        selectedId: _stabilityBufferOptions
            .indexOf(settings.multiViewStabilityBufferSecs),
        data: _stabilityBufferOptions
            .asMap()
            .entries
            .map((e) =>
                IdData(id: e.key, data: e.value == 0 ? 'Off' : '${e.value}s'))
            .toList(),
        action: (idx) {
          setState(() {
            settings.multiViewStabilityBufferSecs =
                _stabilityBufferOptions[idx];
            updateSettings();
          });
          Navigator.of(context).pop();
        },
      ),
    );
  }

  static const _multiViewDecodeOptions = [
    MultiViewDecode.auto,
    MultiViewDecode.hardwareCopy,
    MultiViewDecode.software,
  ];

  Future<void> _showMultiViewDecodeDialog(BuildContext context) async {
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (_) => SelectDialog(
        title: 'Multi-view decode',
        data: _multiViewDecodeOptions
            .asMap()
            .entries
            .map((e) => IdData(id: e.key, data: e.value.label))
            .toList(),
        action: (idx) {
          setState(() {
            settings.multiViewDecode = _multiViewDecodeOptions[idx];
            updateSettings();
          });
          Navigator.of(context).pop();
        },
      ),
    );
  }


  String _searchMethodShortLabel(SearchMethod m) => switch (m) {
        SearchMethod.ftsAnd => 'FTS AND',
        SearchMethod.ftsPhrase => 'FTS Phrase',
        SearchMethod.likeSubstring => 'LIKE Scan',
        SearchMethod.inMemory => 'In-Memory',
      };

  Widget _searchMethodTile(Settings s) {
    return ListTile(
      title: Row(
        children: [
          const Text('Search method'),
          const SizedBox(width: 4),
          _helpIcon(
            title: 'Search Method',
            body:
                'Controls how channel-name searches are performed in the '
                'Live TV grid and channel picker screens.\n\n'
                'Default: FTS AND.\n\n'
                'FTS AND: Recommended. Splits your search into words and '
                'requires every word to match. Fast on large channel lists '
                'and usually best for names like "sky sports" or '
                '"espn hd".\n\n'
                'FTS Phrase: Uses the full query as one phrase. Can be '
                'useful when word order matters, but may be slower or less '
                'forgiving for multi-word searches.\n\n'
                'LIKE Scan: Checks channel names directly without the '
                'full-text index. Can match very short searches such as '
                '1–2 characters, but may be slow on large sources.\n\n'
                'In-Memory: Loads lightweight channel search data into RAM '
                'and searches it without disk reads. Fast for repeated '
                'searches after warmup, but uses more memory and may take '
                'a moment to prepare after startup or source refresh.',
          ),
        ],
      ),
      trailing: TextButton(
        onPressed: () => _showSearchMethodDialog(context),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _searchMethodShortLabel(s.searchMethod),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  static const _searchMethodOptions = [
    (method: SearchMethod.ftsAnd,        label: 'FTS AND (recommended)'),
    (method: SearchMethod.ftsPhrase,     label: 'FTS Phrase (word order)'),
    (method: SearchMethod.likeSubstring, label: 'LIKE Scan (any length)'),
    (method: SearchMethod.inMemory,      label: 'In-Memory (fastest)'),
  ];

  Future<void> _showSearchMethodDialog(BuildContext context) async {
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (_) => SelectDialog(
        title: 'Search method',
        data: _searchMethodOptions
            .asMap()
            .entries
            .map((e) => IdData(id: e.key, data: e.value.label))
            .toList(),
        action: (idx) {
          setState(() {
            settings.searchMethod = _searchMethodOptions[idx].method;
            updateSettings();
          });
          Navigator.of(context).pop();
        },
      ),
    );
  }

  /// fix394: generic enum-tile for the Developer / libmpv section. Mirrors
  /// the `_searchMethodTile` / `SelectDialog` pattern but is parameterised
  /// over any enum T (positional record options, as the handoff flagged —
  /// named records would fail to type-check here).
  ///
  /// options is a List of (T, String label) positional records. The dialog
  /// returns the chosen T via [onChanged].
  Widget _devEnumTile<T>({
    required String label,
    required T value,
    required List<(T, String)> options,
    required ValueChanged<T> onChanged,
    required ({String title, String body}) help,
  }) {
    return ListTile(
      title: Row(
        children: [
          Text(label),
          const SizedBox(width: 4),
          _helpIcon(title: help.title, body: help.body),
        ],
      ),
      trailing: TextButton(
        onPressed: () => _showDevEnumDialog<T>(
          context: context,
          title: help.title,
          value: value,
          options: options,
          onChanged: onChanged,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              options.firstWhere((o) => o.$1 == value, orElse: () => options.first).$2,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  Future<void> _showDevEnumDialog<T>({
    required BuildContext context,
    required String title,
    required T value,
    required List<(T, String)> options,
    required ValueChanged<T> onChanged,
  }) async {
    await showDialog(
      barrierDismissible: true,
      context: context,
      builder: (_) => SelectDialog(
        title: title,
        data: options
            .asMap()
            .entries
            .map((e) => IdData(id: e.key, data: e.value.$2))
            .toList(),
        action: (idx) {
          onChanged(options[idx].$1);
          setState(() {});
          updateSettings();
          Navigator.of(context).pop();
        },
      ),
    );
  }

  void _showMultiViewPickerDialog(Settings settings) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => MultiViewPickerDialog(
        current: settings.multiViewLayout,
        onSelected: (layout) {
          setState(() => settings.multiViewLayout = layout);
          updateSettings();
        },
      ),
    );
  }


  // fix512: settings rows lifted into getters so the phone build()
  // (ExpansionTiles) and the TV rail+pane both render the SAME widgets.
  List<Widget> get _playbackChildren => [
                      _switchTile(
                        label: "Force TV Mode",
                        value: settings.forceTVMode,
                        help: _helpForceTvMode,
                        onChanged: (v) {
                          setState(() => settings.forceTVMode = v);
                          updateSettings();
                        },
                      ),
                      _switchTile(
                        label: "Low latency livestreams",
                        value: settings.lowLatency,
                        help: _helpLowLatency,
                        onChanged: (v) {
                          setState(() => settings.lowLatency = v);
                          updateSettings();
                        },
                      ),
                      _switchTile(
                        label: "Hardware decoding",
                        value: settings.hwDecode,
                        help: _helpHwDecode,
                        onChanged: (v) {
                          setState(() => settings.hwDecode = v);
                          updateSettings();
                        },
                      ),
                      // fix505: advanced override — force hardware decode on
                      // low-RAM boxes (normally routed to software for A/V sync).
                      _switchTile(
                        label: "Force hardware decode (advanced)",
                        value: settings.forceHwDecode,
                        help: (
                          title: 'Force hardware decode',
                          body:
                              'On weak / low-RAM boxes (e.g. onn 4K / Amlogic) the '
                              'app defaults to SOFTWARE decode, because hardware '
                              'decode there can drift audio and video out of sync. '
                              'Turn this on to force hardware decode anyway — it '
                              'may be smoother for high-bitrate / 4K streams, but '
                              'if audio and video desync, turn it back off. '
                              'Requires Hardware decoding to be on. Default: off.',
                        ),
                        onChanged: (v) {
                          setState(() => settings.forceHwDecode = v);
                          updateSettings();
                        },
                      ),
                      // fix506: 1080p render cap on low-RAM 4K boxes.
                      _switchTile(
                        label: "Render at 1080p on 4K (low-memory boxes)",
                        value: settings.cap1080pOnLowRam,
                        help: (
                          title: 'Render at 1080p on 4K',
                          body:
                              'On low-memory 4K boxes (e.g. onn 4K / Amlogic) the '
                              'interface renders much more smoothly at 1080p, '
                              'upscaled to your 4K screen — the UI looks slightly '
                              'softer but is far less laggy. Only applies to '
                              'low-memory 4K TV boxes; no effect elsewhere. '
                              'Takes effect after an app restart. Default: on.',
                        ),
                        onChanged: (v) {
                          setState(() => settings.cap1080pOnLowRam = v);
                          updateSettings();
                          RenderCap.setEnabled(v);
                        },
                      ),
                      // fix582 (#3): force-30 cap co-located with the render cap
                      // (both low-RAM performance toggles), moved out of the
                      // Developer section for discoverability. Now functional —
                      // the custom libmpv has the `fps` filter (fix582 / #2).
                      _switchTile(
                        label: "Cap 60→30 fps (low-RAM)",
                        value: settings.devCapFpsLowRam,
                        help: _helpDevCapFps,
                        onChanged: (v) {
                          setState(() => settings.devCapFpsLowRam = v);
                          updateSettings();
                        },
                      ),
                      // fix510: live video preview in the TV guide hero.
                      _switchTile(
                        label: "Live preview in TV guide",
                        value: settings.tvHeroLivePreview,
                        help: (
                          title: 'Live preview in TV guide',
                          body:
                              'Plays a muted live preview of the focused channel '
                              'in the TV guide\'s hero area. On capable boxes this '
                              'is on automatically; on low-memory boxes (e.g. onn '
                              '4K / Amlogic) it stays off by default to protect '
                              'smoothness — turn it on here to enable it there. '
                              'The preview opens only after you pause on a channel '
                              'and is always muted. Default: off on low-memory '
                              'boxes.',
                        ),
                        onChanged: (v) {
                          setState(() => settings.tvHeroLivePreview = v);
                          updateSettings();
                        },
                      ),
                      // fix604 (#5): EPG guide clock format. Default off = 12-hour.
                      _switchTile(
                        label: "24-hour clock in guide",
                        value: settings.use24HourTime,
                        help: (
                          title: '24-hour clock in guide',
                          body:
                              'Show the TV guide times in 24-hour format (e.g. '
                              '21:38) instead of 12-hour (9:38 PM). Default: off '
                              '(12-hour).',
                        ),
                        onChanged: (v) {
                          setState(() => settings.use24HourTime = v);
                          updateSettings();
                        },
                      ),
                      _switchTile(
                        label: "Pre-warm streams on focus",
                        value: settings.preWarmOnFocus,
                        help: _helpPreWarm,
                        onChanged: (v) {
                          setState(() => settings.preWarmOnFocus = v);
                          updateSettings();
                        },
                      ),
                      // fix318: keep source refreshes running in the background.
                      // fix349: extended to EPG refresh, re-match, and scans.
                      _switchTile(
                        label: "Keep long tasks running in background",
                        value: settings.backgroundProcessing,
                        help: (
                          title: 'Background processing',
                          body:
                              'Android only. When ON, long tasks — source '
                              'refresh, EPG refresh, channel re-match, and '
                              'the stream scanner — keep running via a '
                              'foreground service (with a notification) if '
                              'you switch away from the app, instead of '
                              'pausing.\n\n'
                              'Default: OFF.\n\n'
                              'You may be asked to allow notifications the '
                              'first time. If you decline, tasks still run '
                              'while the app is open.',
                        ),
                        onChanged: (v) {
                          setState(() => settings.backgroundProcessing = v);
                          updateSettings();
                        },
                      ),
  ];

  List<Widget> get _bufferingChildren => [

                  _bufferSlider(
                    label: "Livestream cache (seconds)",
                    value: settings.liveCacheSecs.toDouble(),
                    min: 5,
                    max: 60,
                    divisions: 55,
                    help: _helpLiveCacheSecs,
                    onChanged: (v) {
                      setState(() => settings.liveCacheSecs = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Livestream demuxer max (MB)",
                    value: settings.liveDemuxerMaxMB.toDouble(),
                    min: 32,
                    max: DeviceMemory.maxLiveDemuxerMb.toDouble(),
                    divisions:
                        ((DeviceMemory.maxLiveDemuxerMb - 32) / 8).round(),
                    help: _helpLiveDemuxerMB,
                    onChanged: (v) {
                      setState(() => settings.liveDemuxerMaxMB = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Mini-player demuxer cache (MB)",
                    value: settings.miniDemuxerMaxMB.toDouble(),
                    min: 8,
                    max: DeviceMemory.maxMiniDemuxerMb.toDouble(),
                    divisions:
                        ((DeviceMemory.maxMiniDemuxerMb - 8) / 8).round(),
                    help: (
                      title: 'Mini-Player Demuxer Buffer (MB)',
                      body:
                          'Sets the maximum RAM the demuxer can use for the '
                          'mini-player or overlay stream while another player '
                          'may also be active.\n\n'
                          'Default: calculated from device RAM '
                          '(${DeviceMemory.defaultMiniDemuxerMb} MB on this '
                          '${DeviceMemory.totalMb} MB device). '
                          'Range: 8–${DeviceMemory.maxMiniDemuxerMb} MB.\n\n'
                          'Increasing: Can smooth the mini-player on '
                          'higher-bitrate streams and reduce buffer swings '
                          'when two streams are active. Uses more RAM.\n\n'
                          'Decreasing: Frees RAM for the main player, '
                          'multi-view cells, and the OS. Use lower values on '
                          'low-memory TV boxes or if the app is closed by the '
                          'system.\n\n'
                          'For many 1080p streams, 16–32 MB is enough.',
                    ),
                    onChanged: (v) {
                      setState(() => settings.miniDemuxerMaxMB = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Player buffer size (MB)",
                    value: settings.bufferSizeMB.toDouble(),
                    min: 16,
                    max: DeviceMemory.maxBufferSizeMb.toDouble(),
                    divisions:
                        ((DeviceMemory.maxBufferSizeMb - 16) / 16).round(),
                    help: (
                      title: 'Player Buffer Size (MB)',
                      body:
                          'Sets the internal libmpv read buffer allocated '
                          'when a player instance is created.\n\n'
                          'Default: calculated from device RAM '
                          '(${DeviceMemory.defaultBufferSizeMb} MB on this '
                          '${DeviceMemory.totalMb} MB device). '
                          'Range: 16–${DeviceMemory.maxBufferSizeMb} MB.\n\n'
                          'Increasing: Can help very high-bitrate streams, '
                          'especially 4K or HEVC, keep enough data ready. '
                          'Uses more RAM per player. Multi-view and '
                          'mini-player sessions multiply that cost.\n\n'
                          'Decreasing: Reduces per-player RAM use and is '
                          'safer on 1–2 GB devices. Very low values can '
                          'cause more stalls on high-bitrate streams.\n\n'
                          'Restart required: this value is applied when '
                          'player instances are created.',
                    ),
                    onChanged: (v) {
                      setState(() => settings.bufferSizeMB = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "VOD/Movie cache (seconds)",
                    value: settings.vodCacheSecs.toDouble(),
                    min: 10,
                    max: 180,
                    divisions: 34,
                    help: _helpVodCacheSecs,
                    onChanged: (v) {
                      setState(() => settings.vodCacheSecs = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "VOD/Movie pre-buffer (seconds)",
                    value: settings.vodPrebufferSecs.toDouble(),
                    min: 0,
                    max: 60,
                    divisions: 12,
                    help: _helpVodPrebufferSecs,
                    onChanged: (v) {
                      setState(() => settings.vodPrebufferSecs = v.round());
                      updateSettings();
                    },
                  ),
                  _switchTile(
                    label: "Downmix audio to stereo",
                    value: settings.audioDownmixStereo,
                    help: _helpAudioDownmix,
                    onChanged: (v) {
                      setState(() => settings.audioDownmixStereo = v);
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Stream open timeout (seconds)",
                    value: settings.openTimeoutSecs.toDouble(),
                    min: 5,
                    max: 60,
                    divisions: 55,
                    help: _helpOpenTimeout,
                    onChanged: (v) {
                      setState(() => settings.openTimeoutSecs = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Buffering watchdog (seconds)",
                    value: settings.bufferingWatchdogSecs.toDouble(),
                    min: 5,
                    max: 60,
                    divisions: 55,
                    help: _helpWatchdog,
                    onChanged: (v) {
                      setState(
                        () => settings.bufferingWatchdogSecs = v.round(),
                      );
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Max reconnect attempts",
                    value: settings.maxReconnectAttempts.toDouble(),
                    min: 1,
                    max: 10,
                    divisions: 9,
                    help: _helpMaxReconnectAttempts,
                    onChanged: (v) {
                      setState(
                        () => settings.maxReconnectAttempts = v.round(),
                      );
                      updateSettings();
                    },
                  ),
  ];

  List<Widget> get _dvrChildren => [
                      _switchTile(
                        label: "Enable Live DVR",
                        value: settings.dvrEnabled,
                        help: _helpDvr,
                        onChanged: (v) {
                          setState(() => settings.dvrEnabled = v);
                          updateSettings();
                        },
                      ),
                      _bufferSlider(
                        label: "DVR length (minutes)",
                        value: settings.dvrMinutes.toDouble(),
                        min: 5,
                        max: 90,
                        divisions: 17,
                        help: _helpDvr,
                        onChanged: (v) {
                          setState(() => settings.dvrMinutes = v.round());
                          updateSettings();
                        },
                      ),
  ];

  List<Widget> get _multiviewChildren => [
                      _multiViewTile(settings),
                      _multiViewDecodeTile(settings),
          _stabilityBufferTile(settings),
                      SwitchListTile(
                        title: Row(
                          children: [
                            const Expanded(
                              child: Text('Restore last channels on open'),
                            ),
                            const SizedBox(width: 4),
                            _helpIcon(
                              title: 'Auto-restore channels',
                              body:
                                  'Controls whether multi-view reopens with '
                                  'the Live TV channels you used last time.\n\n'
                                  'Default: ON.\n\n'
                                  'ON: Opening multi-view restores the saved '
                                  'channels for the selected layout. Fastest '
                                  'if you usually watch the same channel '
                                  'group.\n\n'
                                  'OFF: Multi-view opens with empty cells. '
                                  'Use this if you prefer to choose fresh '
                                  'channels each session.\n\n'
                                  'Your previous picks are still remembered. '
                                  'Turning this back on restores them the '
                                  'next time multi-view opens.',
                            ),
                          ],
                        ),
                        value: settings.multiViewAutoRestoreChannels,
                        onChanged: settings.multiViewLayout == MultiViewLayout.none
                            ? null // greyed when multi-view itself is off
                            : (v) {
                                setState(
                                  () => settings.multiViewAutoRestoreChannels = v,
                                );
                                updateSettings();
                              },
                      ),
  ];

  List<Widget> get _contentChildren => [
                      ListTile(
                        // fix156: plain text title so ListTile is the
                        // focusable D-pad target (select opens picker).
                        // Help icon moved to trailing as a separate stop.
                        title: const Text("Default view"),
                        subtitle: Text(viewTypeToString(settings.defaultView)),
                        trailing: _helpIcon(
                          title: _helpDefaultView.title,
                          body: _helpDefaultView.body,
                        ),
                        onTap: () async => await _showDefaultViewDialog(context),
                      ),
                      _switchTile(
                        label: "Refresh sources on start",
                        value: settings.refreshOnStart,
                        help: _helpRefreshOnStart,
                        onChanged: (v) {
                          setState(() => settings.refreshOnStart = v);
                          updateSettings();
                        },
                      ),
                      _switchTile(
                        label: "Show livestreams",
                        value: settings.showLivestreams,
                        help: _helpShowLivestreams,
                        onChanged: (v) {
                          if (!v &&
                              !settings.showMovies &&
                              !settings.showSeries) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'At least one content type must be enabled.'),
                              ),
                            );
                            return;
                          }
                          setState(() {
                            settings.showLivestreams = v;
                            if (!settings
                                .availableContentFilters()
                                .contains(settings.contentTypeFilter)) {
                              settings.contentTypeFilter =
                                  ContentTypeFilter.all;
                            }
                          });
                          updateSettings();
                        },
                      ),
                      _switchTile(
                        label: "Show movies",
                        value: settings.showMovies,
                        help: _helpShowMovies,
                        onChanged: (v) {
                          if (!v &&
                              !settings.showLivestreams &&
                              !settings.showSeries) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'At least one content type must be enabled.'),
                              ),
                            );
                            return;
                          }
                          setState(() {
                            settings.showMovies = v;
                            if (!settings
                                .availableContentFilters()
                                .contains(settings.contentTypeFilter)) {
                              settings.contentTypeFilter =
                                  ContentTypeFilter.all;
                            }
                          });
                          updateSettings();
                        },
                      ),
                      _switchTile(
                        label: "Show series",
                        value: settings.showSeries,
                        help: _helpShowSeries,
                        onChanged: (v) {
                          if (!v &&
                              !settings.showLivestreams &&
                              !settings.showMovies) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                    'At least one content type must be enabled.'),
                              ),
                            );
                            return;
                          }
                          setState(() {
                            settings.showSeries = v;
                            if (!settings
                                .availableContentFilters()
                                .contains(settings.contentTypeFilter)) {
                              settings.contentTypeFilter =
                                  ContentTypeFilter.all;
                            }
                          });
                          updateSettings();
                        },
                      ),
                      _searchMethodTile(settings),
                      _switchTile(
                        label: 'Safe mode',
                        value: settings.safeMode,
                        help: _helpSafeMode,
                        onChanged: (v) async {
                          setState(() => settings.safeMode = v);
                          await updateSettings();
                          // fix369: guard the build context's OWN mounted across
                          // the async gap before using it — the State's `mounted`
                          // is an "unrelated" check for a local BuildContext
                          // (use_build_context_synchronously).
                          if (!context.mounted) return;
                          // ignore: use_build_context_synchronously
                          final messenger = ScaffoldMessenger.of(context);
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                v
                                    ? 'Safe mode enabled — adult channels hidden.'
                                    : 'Safe mode disabled — all channels visible.',
                              ),
                            ),
                          );
                        },
                      ),
                      // fix587 (#23): require a second Back to leave the app.
                      _switchTile(
                        label: 'Confirm to exit',
                        value: settings.confirmToExit,
                        help: (
                          title: 'Confirm to Exit',
                          body:
                              'When on, pressing Back on the main screen shows '
                              '"Press Back again to exit" and only a second Back '
                              'within two seconds closes the app. Helps avoid '
                              'exiting by accident with a TV remote.\n\nOff by '
                              'default — Back exits immediately.',
                        ),
                        onChanged: (v) async {
                          setState(() => settings.confirmToExit = v);
                          await updateSettings();
                        },
                      ),
                      // Stream scanner
                      _bufferSlider(
                        label: "Streams per scan",
                        value: settings.streamScanMaxCount.toDouble(),
                        min: 1,
                        max: 100,
                        divisions: 99,
                        help: (
                          title: 'Streams Per Scan',
                          body:
                              'Maximum number of visible channels the radar button '
                              'probes in a single scan run.\n\n'
                              '↑ Raising — tests more channels per run. Scan time '
                              'increases proportionally '
                              '(count × timeout per stream). '
                              '100 streams at 8 s timeout = up to ~13 minutes '
                              'worst-case.\n\n'
                              '↓ Lowering — faster scan. The scanner always tests '
                              'channels in the order they appear on screen, so '
                              'put your favourites first.\n\n'
                              'Green border = valid MPEG-TS or HLS confirmed. '
                              'Default: 20. Range: 1–100.',
                        ),
                        onChanged: (v) {
                          setState(
                            () => settings.streamScanMaxCount = v.round(),
                          );
                          updateSettings();
                        },
                      ),
                      _bufferSlider(
                        label: "Scan timeout (sec)",
                        value: settings.streamScanTimeoutSecs.toDouble(),
                        min: 3,
                        max: 30,
                        divisions: 27,
                        help: (
                          title: 'Scan Timeout (seconds)',
                          body:
                              'How long the scanner waits per stream to receive '
                              'and validate the first media bytes (MPEG-TS sync '
                              'bytes at 0, 188, 376; or "#EXTM3U" for HLS).\n\n'
                              '↑ Raising — gives slow CDNs and geographically '
                              'distant servers more time to respond. Reduces false '
                              'negatives. Increases total scan time '
                              'proportionally.\n\n'
                              '↓ Lowering — faster scans. May produce false '
                              'negatives on slow or international streams.\n\n'
                              '8 s covers most IPTV providers. Only increase if '
                              'you see streams your player can open but the scanner '
                              'marks as failed. Default: 8 s. Range: 3–30 s.',
                        ),
                        onChanged: (v) {
                          setState(
                            () => settings.streamScanTimeoutSecs = v.round(),
                          );
                          updateSettings();
                        },
                      ),
  ];

  List<Widget> get _epgChildren => [
                  ...sources.map(
                    (source) => ListTile(
                      leading: Icon(
                        source.epgUrl?.isNotEmpty == true
                            ? Icons.check_circle_outline
                            : Icons.tv_outlined,
                        color: source.epgUrl?.isNotEmpty == true
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text('EPG for "${source.name}"'),
                      subtitle: Text(
                        source.epgUrl?.isNotEmpty == true
                            ? source.epgUrl!
                            : 'Tap to set — default US guide pre-filled',
                      ),
                      onTap: () async {
                        // Pre-fill with current URL or the benchmark default
                        // so the user can accept it with one tap.
                        final initialText = source.epgUrl?.isNotEmpty == true
                            ? source.epgUrl!
                            : 'https://iptv-epg.org/files/epg-us.xml';
                        final controller = TextEditingController(
                          text: initialText,
                        );
                        // Select all text so the user can immediately replace
                        controller.selection = TextSelection(
                          baseOffset: 0,
                          extentOffset: controller.text.length,
                        );
                        final result = await showDialog<String?>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text('EPG URL for "${source.name}"'),
                            content: DpadTextField(
                              controller: controller,
                              decoration: const InputDecoration(
                                labelText: 'XMLTV feed URL',
                              ),
                              keyboardType: TextInputType.url,
                              autofocus: true,
                              // Enter/OK on D-pad saves immediately
                              onSubmitted: (text) =>
                                  Navigator.pop(ctx, text.trim()),
                            ),
                            // Save first so one D-pad-down from the field
                            // lands on Save, not Cancel.
                            actions: [
                              FilledButton(
                              autofocus: true,
                                onPressed: () => Navigator.pop(
                                  ctx,
                                  controller.text.trim(),
                                ),
                                child: const Text('Save'),
                              ),
                              TextButton(
                                onPressed: () =>
                                    Navigator.pop(ctx, ''),
                                child: const Text('Clear'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, null),
                                child: const Text('Cancel'),
                              ),
                            ],
                          ),
                        );
                        controller.dispose(); // finding 11: was leaked per open
                        if (result != null && source.id != null) {
                          await Sql.setSourceEpgUrl(
                            source.id!,
                            result.isEmpty ? null : result,
                          );
                          // fix386: mark the EPG state as 'manual' so the
                          // source-list pill shows "EPG: manual" and the
                          // auto-discovery won't try to re-probe this
                          // source on next add (it's already set, and
                          // stickiness is per-source).
                          await Sql.setSourceEpgDiscovery(
                            source.id!,
                            url: result.isEmpty ? null : result,
                            state: 'manual',
                          );
                          await initAsync();
                        }
                      },
                    ),
                  ),
                  _switchTile(
                    label: "Auto-refresh EPG",
                    value: settings.epgAutoRefresh,
                    help: (
                      title: 'Auto-refresh EPG',
                      body:
                          'Automatically downloads updated program guide data '
                          'in the background at the scheduled hour.\n\n'
                          '↑ ON — program guide stays current without manual '
                          'action. Uses data and battery during the refresh '
                          'window.\n\n'
                          '↓ OFF — EPG only updates when you tap "Refresh EPG" '
                          'manually. Useful on metered connections or if your '
                          'EPG source rarely changes. Default: ON.',
                    ),
                    onChanged: (v) {
                      setState(() => settings.epgAutoRefresh = v);
                      updateSettings();
                      EpgService.scheduleBackgroundRefresh();
                    },
                  ),
                  _bufferSlider(
                    label: "Refresh every (hours)",
                    value: settings.epgRefreshHours.toDouble(),
                    min: 6,
                    max: 168,
                    divisions: 162,
                    help: (
                      title: 'EPG Refresh Interval (hours)',
                      body:
                          'How often the background EPG refresh runs.\n\n'
                          '↑ Raising — less frequent downloads. Reduces data '
                          'and battery use. EPG data may become stale.\n\n'
                          '↓ Lowering — more frequent downloads. Guide stays '
                          'current. Each refresh downloads and re-parses the '
                          'full XMLTV file — avoid values below 12 h on '
                          'metered or slow connections.\n\n'
                          'Note: only unmatched channels are re-matched on '
                          'each refresh — already-matched channels are skipped '
                          'keeping refresh fast. '
                          'Default: 24 h. Range: 6–168 h (7 days).',
                    ),
                    onChanged: (v) {
                      setState(() => settings.epgRefreshHours = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Refresh hour (local, 24h)",
                    value: settings.epgRefreshHour.toDouble(),
                    min: 0,
                    max: 23,
                    divisions: 23,
                    help: (
                      title: 'EPG Refresh Hour',
                      body:
                          'The hour of the day (local time, 24-hour clock) '
                          'when the background EPG refresh runs.\n\n'
                          'Choose a time when the device is plugged in and on '
                          'Wi-Fi — EPG parsing is CPU-intensive (up to 2 min '
                          'on slower boxes). 3:00 AM is the default as most '
                          'devices are idle then. '
                          'Default: 3 (03:00). Range: 0–23.',
                    ),
                    onChanged: (v) {
                      setState(() => settings.epgRefreshHour = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Past days to keep",
                    value: settings.epgPastDays.toDouble(),
                    min: 0,
                    max: 3,
                    divisions: 3,
                    help: (
                      title: 'EPG Past Days',
                      body:
                          'How many days of already-aired program data to '
                          'retain.\n\n'
                          '↑ Raising — lets you see what aired recently in '
                          'the guide. Uses more storage.\n\n'
                          '↓ Lowering / 0 — keeps only current and future '
                          'programs. Reduces storage and speeds up parsing. '
                          'Set to 0 on low-storage devices. '
                          'Default: 1. Range: 0–3.',
                    ),
                    onChanged: (v) {
                      setState(() => settings.epgPastDays = v.round());
                      updateSettings();
                    },
                  ),
                  _bufferSlider(
                    label: "Forecast days",
                    value: settings.epgForecastDays.toDouble(),
                    min: 3,
                    max: 14,
                    divisions: 11,
                    help: (
                      title: 'EPG Forecast Days',
                      body:
                          'How many days ahead of program guide data to '
                          'download.\n\n'
                          '↑ Raising — more advance schedule visibility. '
                          'Increases download size and parse time '
                          'proportionally (each extra day ≈ +70 k programs '
                          'for large guides).\n\n'
                          '↓ Lowering — faster EPG refresh, less storage. '
                          '3 days is sufficient if you only use the guide for '
                          '"what\'s on now/next". '
                          'Default: 7. Range: 3–14.',
                    ),
                    onChanged: (v) {
                      setState(() => settings.epgForecastDays = v.round());
                      updateSettings();
                    },
                  ),
                  // fix502: forward-only look-ahead for "what's on" search.
                  // Max tracks the forecast window (you can't search past the
                  // guide data you have).
                  _bufferSlider(
                    label: "Search window (hours)",
                    value: settings.epgSearchHours.toDouble(),
                    min: 1,
                    max: (settings.epgForecastDays * 24).toDouble(),
                    divisions: settings.epgForecastDays * 24 - 1,
                    help: (
                      title: 'EPG Search Window (hours)',
                      body:
                          'How far ahead the "what\'s on" search looks for '
                          'matching programs.\n\n'
                          'Search is forward-only (now → +window) and can '
                          'never exceed the Forecast days above (the guide data '
                          'you have downloaded). '
                          'Default: 3 h.',
                    ),
                    onChanged: (v) {
                      setState(() => settings.epgSearchHours = v.round());
                      updateSettings();
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text("Refresh EPG now"),
                    // fix541 (item 7): show when the EPG was last loaded.
                    // finding 12: read the memoized _latestEpgRefreshTs (loaded
                    // in initAsync, refreshed after a run) instead of firing a
                    // Sql.getLatestEpgRefresh() DB query on every rebuild.
                    subtitle: Text(
                      _latestEpgRefreshTs == null
                          ? 'Download latest program guide'
                          : 'Last loaded ${_formatEpgWhen(DateTime.fromMillisecondsSinceEpoch(_latestEpgRefreshTs! * 1000))}',
                    ),
                    onTap: () async {
                      final noUrls = sources.every(
                        (s) =>
                            (s.epgUrl?.isEmpty ?? true) &&
                            s.sourceType != SourceType.xtream,
                      );
                      if (noUrls) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'No EPG URL configured. Tap the EPG row for '
                              'your source and save a URL first.',
                            ),
                            duration: Duration(seconds: 5),
                          ),
                        );
                        return;
                      }
                      // fix541 (item 8): if the EPG was refreshed less than 24h
                      // ago, confirm before re-downloading (it rarely changes
                      // intra-day and the download is heavy).
                      final last = await Sql.getLatestEpgRefresh();
                      if (!mounted) return;
                      if (last != null) {
                        final ageH = (DateTime.now()
                                    .millisecondsSinceEpoch ~/
                                1000 -
                                last) /
                            3600.0;
                        if (ageH < 24) {
                          final proceed = await showDialog<bool>(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('EPG is recent'),
                              content: Text(
                                'The guide was loaded '
                                '${_formatEpgAge(ageH)} ago. It usually does '
                                'not change within a day. Download it again '
                                'anyway?',
                              ),
                              actions: [
                                TextButton(
                                  autofocus: true,
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  onPressed: () =>
                                      Navigator.pop(context, true),
                                  child: const Text('Refresh anyway'),
                                ),
                              ],
                            ),
                          );
                          if (proceed != true || !mounted) return;
                        }
                      }
                      await _runEpgRefresh(context);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.manage_search),
                    title: const Text("Re-match all channels"),
                    subtitle: const Text(
                      "Force full EPG re-match — use after feed or "
                      "matcher changes",
                    ),
                    onTap: () async {
                      await _runEpgRematch(context);
                    },
                  ),
                  ...sources
                      .where((s) => s.id != null)
                      .map(
                        (source) => ListTile(
                          leading: const Icon(Icons.tune),
                          title: Text(
                            'Channel mappings — ${source.name}',
                          ),
                          subtitle: const Text(
                            'Manually assign EPG IDs to unmatched channels',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => EpgChannelMappingView(
                                source: source,
                              ),
                            ),
                          ),
                        ),
                      ),
  ];

  List<Widget> get _backupRestoreChildren => [
                  ListTile(
                    leading: const Icon(Icons.upload_file),
                    title: const Text("Export settings to file"),
                    subtitle: const Text(
                      "Save sources and settings as a JSON backup",
                    ),
                    onTap: () async {
                      final includeCredentials = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('Include credentials?'),
                          content: const Text(
                            'Include Xtream usernames and passwords in the backup?\n\n'
                            'Choosing YES also includes a full database snapshot '
                            '(channels + EPG) for diagnostics, which contains '
                            'those credentials.\n\n'
                            'Only choose YES if you are saving the file somewhere secure.',
                          ),
                          actions: [
                            TextButton(
                                autofocus: true,
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('No (safer)'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Yes'),
                            ),
                          ],
                        ),
                      );
                      if (includeCredentials == null || !mounted) return;
                      // fix158: TV has no SAF — use local server
                      final isTV = await DeviceDetector.isTV();
                      if (!mounted) return;
                      if (isTV) {
                        await _exportEverythingViaServer(
                            includeCredentials: includeCredentials);
                      } else {
                        await SettingsIo.exportToFile(
                          // ignore: use_build_context_synchronously
                          context,
                          includeCredentials: includeCredentials,
                        );
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.download_for_offline),
                    title: const Text("Import settings from file"),
                    subtitle: const Text(
                      "Restore sources and settings from a backup",
                    ),
                    onTap: () async {
                      final imported =
                          await SettingsIo.importFromFile(context);
                      if (!context.mounted) return;
                      if (imported) {
                        // ignore: use_build_context_synchronously
                        await showSourcesRefreshDialog(context);
                      }
                      if (!context.mounted) return;
                      await initAsync(); // Reload UI after import
                    },
                  ),

  ];

  List<Widget> get _resetChildren => [
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text("Reset settings to defaults"),
                    subtitle: const Text(
                      "Restore the hardcoded defaults. Preserves sources, "
                      "debug-logging toggle, and any active multi-view "
                      "channel layout.",
                    ),
                    onTap: () => _confirmAndResetSettings(
                      title: 'Reset to defaults?',
                      body: 'This restores every tunable setting to its '
                          'hardcoded default. Your sources, credentials, '
                          'debug-logging toggle, and multi-view channel '
                          'assignments are preserved.\n\n'
                          'Some changes (buffer size) take effect on the '
                          'next app launch.',
                      builder: () => Settings.defaults(),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.auto_fix_high),
                    title: const Text("Optimise for this device"),
                    subtitle: const Text(
                      "Calculate the best values for your device's RAM, "
                      "form factor, and current multi-view layout.",
                    ),
                    onTap: () async {
                      final isTV = await DeviceDetector.isTV();
                      if (!mounted) return;
                      _confirmAndResetSettings(
                        title: 'Optimise for this device?',
                        body: 'This computes recommended values for your '
                            'device based on:\n\n'
                            '  • Detected RAM: ${DeviceMemory.totalMb} MB\n'
                            '  • Form factor: ${isTV ? "TV" : "phone/tablet"}\n'
                            '  • Multi-view layout: '
                            '${settings.multiViewLayout.label}\n\n'
                            'Only buffer / cache / timing / decoder '
                            'settings change. Your library view, EPG, '
                            'show/hide preferences, sources, credentials, '
                            'debug-logging toggle, and multi-view channel '
                            'assignments are all preserved.\n\n'
                            'Some changes (buffer size) take effect on '
                            'the next app launch.',
                        builder: () => Settings.optimisedFor(
                          isTV: isTV,
                          layout: settings.multiViewLayout,
                        ),
                        preserveLibraryPreferences: true,
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.insights),
                    title: const Text('Analyze playback & suggest settings'),
                    subtitle: const Text(
                      'Reviews your recent playback history (buffering, '
                      'startup, reconnects) and suggests buffer/cache/timing '
                      'tweaks for your device and connection.',
                    ),
                    onTap: _runPlaybackAnalysis,
                  ),
                  ListTile(
                    leading: const Icon(Icons.wifi_tethering_off),
                    title: const Text("Clear stream validation"),
                    subtitle: const Text(
                      "Reset all stream scan results. Channels will "
                      "show as unvalidated until rescanned.",
                    ),
                    onTap: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text("Clear stream validation?"),
                          content: const Text(
                            "This resets the scan result for every channel. "
                            "Channels will appear unvalidated until you run "
                            "the stream scanner again.\n\n"
                            "Your favorites, watch history, and EPG data "
                            "are not affected.",
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text("Cancel"),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text("Clear"),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true && mounted) {
                        await Sql.clearAllStreamValidated();
                        StreamScanner.clearResults();
                        // fix369: guard the build context's OWN mounted (not the
                        // State's) before using it after the async gap
                        // (use_build_context_synchronously).
                        if (context.mounted) {
                          // ignore: use_build_context_synchronously
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text("Stream validation cleared."),
                            ),
                          );
                        }
                      }
                    },
                  ),

  ];

  List<Widget> get _appChildren => [
                  _sectionHeader("App"),
                  ListTile(
                    leading: const Icon(Icons.system_update_outlined),
                    title: const Text("Check for updates"),
                    subtitle: const Text("Check for a newer version of the app"),
                    onTap: () async {
                      // checkNow bypasses the throttle and shows
                      // "up to date" feedback, unlike checkOnLaunch.
                      await UpdateChecker.checkNow(context);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.article_outlined),
                    title: const Text('Version and changelog'),
                    subtitle: Text(_appVersion.isEmpty ? '…' : _appVersion),
                    onTap: _appVersion.isEmpty
                        ? null
                        : () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const FullChangelogPage(),
                              ),
                            ),
                    trailing: _appVersion.isEmpty
                        ? null
                        : const Icon(Icons.chevron_right),
                  ),
  ];

  List<Widget> get _sourcesChildren => [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(left: 10),
                        child: Text(
                          'Sources',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          IconButton(
                            onPressed: () async {
                              await showSourcesRefreshDialog(context);
                              // Reload the sources list in case names or
                              // counts changed.
                              if (mounted) await reloadSources();
                            },
                            icon: const Icon(Icons.refresh),
                          ),
                          IconButton(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) =>
                                    const Setup(showAppBar: true),
                              ),
                            ),
                            icon: const Icon(Icons.add),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ...sources.map(getSource),
  ];

  List<Widget> get _diagnosticsChildren => [
                  _switchTile(
                    label: "Enable debug logging",
                    value: settings.debugLogging,
                    help: (
                      title: 'Debug Logging',
                      body:
                          'Writes a timestamped log of every significant action '
                          '(EPG refresh, source reload, errors, settings changes) '
                          'to a file in app storage. Turn ON only when '
                          'troubleshooting — leaves a file you can export and '
                          'share. Auto-rotates at 2 MB. Default: OFF.',
                    ),
                    onChanged: (v) async {
                      setState(() => settings.debugLogging = v);
                      await AppLog.setEnabled(v);
                      AppLog.info('Debug logging ${v ? "enabled" : "disabled"}');
                      updateSettings();
                    },
                  ),
                  _switchTile(
                    label: "Log User/Pass",
                    value: settings.logUserPass,
                    help: (
                      title: 'Log User/Pass',
                      body:
                          'When OFF (default), source usernames and passwords '
                          'are removed from the debug log and replaced with '
                          'labelled tokens like <A3000_USER> / <A3000_PASS>, so '
                          'you can safely share a log for troubleshooting. Turn '
                          'ON only for your own testing — it writes credentials '
                          'verbatim. Default: OFF.',
                    ),
                    onChanged: (v) async {
                      // fix417: turning raw-credential logging ON requires the
                      // user to type "INSECURE" to confirm. Turning OFF is
                      // one-tap. On cancel the toggle stays OFF.
                      if (v) {
                        final confirmed = await _confirmInsecureLogging();
                        if (!mounted) return;
                        if (!confirmed) {
                          setState(() {}); // snap the switch back to OFF
                          return;
                        }
                      }
                      setState(() => settings.logUserPass = v);
                      AppLog.logUserPass = v;
                      AppLog.info(
                          'Log User/Pass ${v ? "ON (raw credentials)" : "OFF (redacted)"}');
                      updateSettings();
                    },
                  ),
                  ListTile(
                    enabled: settings.debugLogging,
                    leading: const Icon(Icons.download_outlined),
                    title: const Text("Export log file"),
                    subtitle: const Text(
                      "Tap to save the debug log. Long-press to export raw "
                      "source dumps (diagnostic).",
                    ),
                    onTap: settings.debugLogging
                        ? () async {
                            final log = await AppLog.readLog();
                            if (!mounted) return;
                            if (log.isEmpty) {
                              // ignore: use_build_context_synchronously
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Log file is empty.'),
                                ),
                              );
                              return;
                            }
                            // fix158: TV has no SAF — use local server
                            final isTV = await DeviceDetector.isTV();
                            if (!mounted) return;
                            if (isTV) {
                              await _exportEverythingViaServer(
                                  includeCredentials: false);
                            } else {
                              await SettingsIo.exportStringToFile(
                                // ignore: use_build_context_synchronously
                                context,
                                content: log,
                                suggestedName:
                                    'free4me_log-${await SettingsIo.stampWithDevice()}.txt',
                              );
                            }
                          }
                        : null,
                    // fix222: long-press exports the raw source dumps (diagnostic).
                    onLongPress: settings.debugLogging
                        ? () async {
                            await _exportSourceDumps();
                          }
                        : null,
                  ),
                  ListTile(
                    enabled:
                        settings.debugLogging && !settings.logUserPass,
                    leading: const Icon(Icons.bug_report_outlined),
                    title: const Text("Report an issue"),
                    subtitle: Text(
                      settings.logUserPass
                          ? "Turn off \"Log User/Pass\" first — reports can't be "
                              "sent while raw credentials are being logged."
                          : "Send a description and your debug log to the "
                              "developer (host, username and password removed).",
                    ),
                    onTap: (settings.debugLogging && !settings.logUserPass)
                        ? () async {
                            await _showReportIssueDialog();
                          }
                        : null,
                  ),
                  ListTile(
                    enabled: settings.debugLogging,
                    leading: const Icon(Icons.delete_outline),
                    title: const Text("Clear log"),
                    onTap: settings.debugLogging
                        ? () async {
                            await AppLog.clearLog();
                            if (!mounted) return;
                            // ignore: use_build_context_synchronously
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Log and source dumps cleared.'),
                              ),
                            );
                          }
                        : null,
                  ),

  ];

  List<Widget> get _developerChildren => [
                      // fix612: on-device search-method benchmark. Runs every
                      // method against the user's real catalog and offers to
                      // switch to the fastest.
                      ListTile(
                        leading: const Icon(Icons.speed),
                        title: const Text('Run Search Perf Test'),
                        subtitle: const Text(
                          'Benchmark each search method on this device and '
                          'switch to the fastest.',
                        ),
                        onTap: _runSearchPerfTest,
                      ),
                      const Divider(height: 1),
                      // ── Refined buffering (moved from Buffering) ──
                      _bufferSlider(
                        label: "VOD/Movie demuxer max (MB)",
                        value: settings.vodDemuxerMaxMB.toDouble(),
                        min: 64,
                        max: 1024,
                        divisions: 60,
                        help: _helpVodDemuxerMB,
                        onChanged: (v) {
                          setState(() => settings.vodDemuxerMaxMB = v.round());
                          updateSettings();
                        },
                      ),
                      _bufferSlider(
                        label: "Stable playback threshold (seconds)",
                        value: settings.stableThresholdSecs.toDouble(),
                        min: 5,
                        max: 60,
                        divisions: 55,
                        help: (
                          title: 'Stable Playback Threshold (seconds)',
                          body:
                              'Controls how long playback must stay healthy '
                              'before the reconnect retry counter resets.\n\n'
                              'Default: 30 s. Range: 5–60 s.\n\n'
                              'Increasing: Requires a longer stable period '
                              'before the app trusts the stream again. This '
                              'is stricter for unreliable streams and can '
                              'make the app give up sooner after repeated '
                              'problems.\n\n'
                              'Decreasing: Resets the retry counter sooner '
                              'after a brief recovery. More forgiving for '
                              'streams that have small hiccups but usually '
                              'recover.\n\n'
                              'If good streams are reaching the maximum '
                              'retry limit too easily, lower this value.',
                        ),
                        onChanged: (v) {
                          setState(
                            () => settings.stableThresholdSecs = v.round(),
                          );
                          updateSettings();
                        },
                      ),
                      _bufferSlider(
                        label: "Startup grace window (ms)",
                        value: settings.startupGraceMs.toDouble(),
                        min: 100,
                        max: 3000,
                        divisions: 29,
                        help: (
                          title: 'Startup Grace Window (ms)',
                          body:
                              'Gives a newly opened stream a short grace '
                              'period before certain startup errors are '
                              'allowed to trigger reconnect behavior.\n\n'
                              'Default: 500 ms. Range: 100–3000 ms.\n\n'
                              'Increasing: Helps slower TV hardware and '
                              'slow providers that emit harmless startup '
                              'errors shortly after playback begins. Try '
                              '1000–1500 ms if streams double-start or '
                              'reconnect immediately after opening.\n\n'
                              'Decreasing: Lets real startup failures '
                              'surface sooner. Use lower values if bad '
                              'streams take too long to fail.',
                        ),
                        onChanged: (v) {
                          setState(
                            () => settings.startupGraceMs = v.round(),
                          );
                          updateSettings();
                        },
                      ),
                      _bufferSlider(
                        label: "Stream-ended reconnect delay (ms)",
                        value: settings.streamCompletedDelayMs.toDouble(),
                        min: 0,
                        max: 10000,
                        divisions: 20,
                        help: (
                          title: 'Stream-Ended Reconnect Delay (ms)',
                          body:
                              'Controls how long the app waits before '
                              'reconnecting after a live stream reports '
                              'that it ended or the provider closes the '
                              'connection.\n\n'
                              'Default: 2000 ms. Range: 0–10 000 ms.\n\n'
                              'Increasing: Gives providers more time to '
                              'rotate servers or reconnect at a segment '
                              'boundary without an immediate full '
                              'reconnect.\n\n'
                              'Decreasing: Reconnects faster when the '
                              'stream really ended. Set to 0 for '
                              'immediate reconnect behavior.',
                        ),
                        onChanged: (v) {
                          setState(
                            () => settings.streamCompletedDelayMs = v.round(),
                          );
                          updateSettings();
                        },
                      ),
                      // ── Demuxer / cache ──
                      _bufferSlider(
                        label: "Demuxer read-ahead (seconds)",
                        value: settings.devDemuxerReadaheadSecs,
                        min: 0.5,
                        max: 10,
                        divisions: 95, // 0.1 s steps
                        decimals: 1,
                        help: _helpDevDemuxerReadaheadSecs,
                        onChanged: (v) {
                          setState(
                            () => settings.devDemuxerReadaheadSecs = v,
                          );
                          updateSettings();
                        },
                      ),
                      _bufferSlider(
                        label: "Network timeout (seconds)",
                        value: settings.devNetworkTimeoutSecs.toDouble(),
                        min: 5,
                        max: 120,
                        divisions: 115,
                        help: _helpDevNetworkTimeoutSecs,
                        onChanged: (v) {
                          setState(
                            () => settings.devNetworkTimeoutSecs = v.round(),
                          );
                          updateSettings();
                        },
                      ),
                      _bufferSlider(
                        label: "Import fetch timeout (seconds, 0 = default)",
                        value: settings.devImportFetchTimeoutSecs.toDouble(),
                        min: 0,
                        max: 120,
                        divisions: 120,
                        help: _helpDevImportFetchTimeoutSecs,
                        onChanged: (v) {
                          setState(
                            () => settings.devImportFetchTimeoutSecs = v.round(),
                          );
                          updateSettings();
                        },
                      ),
                      _bufferSlider(
                        label: "Controls auto-hide (seconds, 0 = stay)",
                        value: settings.devControlsHideSecs.toDouble(),
                        min: 0,
                        max: 30,
                        divisions: 30,
                        help: _helpDevControlsHideSecs,
                        onChanged: (v) {
                          setState(
                            () => settings.devControlsHideSecs = v.round(),
                          );
                          updateSettings();
                        },
                      ),
                      _bufferSlider(
                        label: "Skip back on resume (seconds, 0 = off)",
                        value:
                            settings.devSkipBackOnResumeSecs.toDouble(),
                        min: 0,
                        max: 30,
                        divisions: 30,
                        help: _helpDevSkipBackOnResumeSecs,
                        onChanged: (v) {
                          setState(
                            () => settings.devSkipBackOnResumeSecs =
                                v.round(),
                          );
                          updateSettings();
                        },
                      ),
                      _switchTile(
                        label: "TLS verify",
                        value: settings.devTlsVerify,
                        help: _helpDevTlsVerify,
                        onChanged: (v) {
                          setState(() => settings.devTlsVerify = v);
                          updateSettings();
                        },
                      ),
                      // ── Sync / image quality ──
                      _devEnumTile<VideoSyncMode>(
                        label: "A/V sync mode",
                        value: settings.devVideoSync,
                        options: const [
                          (VideoSyncMode.audio, "Audio (default)"),
                          (VideoSyncMode.displayResample,
                              "Display (resample)"),
                          (VideoSyncMode.displayResampleVdrop,
                              "Display (resample + drop)"),
                          (VideoSyncMode.displayVdrop, "Display (drop)"),
                          (VideoSyncMode.desync, "Display (desync)"),
                        ],
                        onChanged: (v) {
                          setState(() => settings.devVideoSync = v);
                        },
                        help: _helpDevVideoSync,
                      ),
                      _bufferSlider(
                        label: "Max video-rate change",
                        value: settings.devVideoSyncMaxVideoChange,
                        min: 0,
                        max: 5,
                        divisions: 50, // 0.1 steps
                        decimals: 1,
                        help: _helpDevVideoSyncMaxVideoChange,
                        onChanged: (v) {
                          setState(
                            () => settings.devVideoSyncMaxVideoChange = v,
                          );
                          updateSettings();
                        },
                      ),
                      _devEnumTile<TscaleMode>(
                        label: "Temporal scaler",
                        value: settings.devTscale,
                        options: const [
                          (TscaleMode.nearest, "Nearest (default)"),
                          (TscaleMode.bilinear, "Bilinear"),
                          (TscaleMode.oversample, "Oversample"),
                          (TscaleMode.spline36, "Spline36"),
                          (TscaleMode.lanczos, "Lanczos"),
                        ],
                        onChanged: (v) {
                          setState(() => settings.devTscale = v);
                        },
                        help: _helpDevTscale,
                      ),
                      _devEnumTile<FrameDropMode>(
                        label: "Frame drop mode",
                        value: settings.devFramedrop,
                        options: const [
                          (FrameDropMode.no, "No (never drop)"),
                          (FrameDropMode.vo, "Video output (default)"),
                          (FrameDropMode.decoder, "Decoder"),
                        ],
                        onChanged: (v) {
                          setState(() => settings.devFramedrop = v);
                        },
                        help: _helpDevFramedrop,
                      ),
                      _switchTile(
                        label: "Frame interpolation",
                        value: settings.devInterpolation,
                        help: _helpDevInterpolation,
                        onChanged: (v) {
                          setState(() => settings.devInterpolation = v);
                          updateSettings();
                        },
                      ),
                      _switchTile(
                        label: "Debanding filter",
                        value: settings.devDeband,
                        help: _helpDevDeband,
                        onChanged: (v) {
                          setState(() => settings.devDeband = v);
                          updateSettings();
                        },
                      ),
                      // fix582 (#3): "Cap 60→30 fps" moved to Settings → Playback
                      // (Performance / low-RAM), next to the render cap.
                      _devEnumTile<HwdecImageFormat>(
                        label: "HW decoder image format",
                        value: settings.devHwdecImageFormat,
                        options: const [
                          (HwdecImageFormat.defaultFmt, "Auto (default)"),
                          (HwdecImageFormat.nv12, "NV12"),
                          (HwdecImageFormat.rgba, "RGBA"),
                          (HwdecImageFormat.i420, "I420"),
                        ],
                        onChanged: (v) {
                          setState(() => settings.devHwdecImageFormat = v);
                        },
                        help: _helpDevHwdecImageFormat,
                      ),
                      // ── Audio / network ──
                      _bufferSlider(
                        label: "Audio buffer (seconds)",
                        value: settings.devAudioBufferSecs,
                        min: 0,
                        max: 2,
                        divisions: 200, // 0.01 s steps
                        decimals: 2,
                        help: _helpDevAudioBufferSecs,
                        onChanged: (v) {
                          setState(
                            () => settings.devAudioBufferSecs = v,
                          );
                          updateSettings();
                        },
                      ),
                      _devEnumTile<AudioSpdifMode>(
                        label: "Audio S/PDIF passthrough",
                        value: settings.devAudioSpdif,
                        options: const [
                          (AudioSpdifMode.no, "Off (default)"),
                          (AudioSpdifMode.ac3, "AC3"),
                          (AudioSpdifMode.eac3, "E-AC3"),
                          (AudioSpdifMode.dts, "DTS"),
                          (AudioSpdifMode.all, "All (AC3+E-AC3+DTS)"),
                        ],
                        onChanged: (v) {
                          setState(() => settings.devAudioSpdif = v);
                        },
                        help: _helpDevAudioSpdif,
                      ),
  ];

  // fix512: single ordered source of truth for the TV rail. Each entry maps a
  // group title + icon to the SAME children getter the phone ExpansionTiles use.
  List<({String title, IconData icon, List<Widget> Function() children})>
      get _railEntries => [
            (
              title: 'Playback',
              icon: Icons.play_circle_outline,
              children: () => _playbackChildren,
            ),
            (
              title: 'Buffering',
              icon: Icons.tune,
              children: () => _bufferingChildren,
            ),
            (
              title: 'Live DVR',
              icon: Icons.fiber_manual_record,
              children: () => _dvrChildren,
            ),
            (
              title: 'Multi-view',
              icon: Icons.grid_view,
              children: () => _multiviewChildren,
            ),
            (
              title: 'Content',
              icon: Icons.filter_list,
              children: () => _contentChildren,
            ),
            (
              title: 'EPG / Program Guide',
              icon: Icons.calendar_month,
              children: () => _epgChildren,
            ),
            (
              title: 'Backup & Restore',
              icon: Icons.settings_backup_restore,
              children: () => _backupRestoreChildren,
            ),
            (
              title: 'Reset',
              icon: Icons.restart_alt,
              children: () => _resetChildren,
            ),
            (
              title: 'App',
              icon: Icons.system_update_outlined,
              children: () => _appChildren,
            ),
            (
              title: 'Sources',
              icon: Icons.source,
              children: () => _sourcesChildren,
            ),
            (
              title: 'Diagnostics',
              icon: Icons.bug_report_outlined,
              children: () => _diagnosticsChildren,
            ),
            (
              title: 'Developer',
              icon: Icons.developer_mode,
              children: () => _developerChildren,
            ),
          ];

  /// fix512: TV rail+pane layout. Left = focusable group rail; right = the
  /// selected group's settings (the exact same widgets the phone build uses).
  /// D-pad: up/down moves the rail selection; right/select moves focus into the
  /// pane; left from the pane returns to the rail — all via the default
  /// directional traversal (no custom FocusScope that would trap focus).
  Widget _buildTvRailPane() {
    final entries = _railEntries;
    return Scaffold(
      body: Visibility(
        visible: !loading,
        child: Loading(
          child: SafeArea(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 300,
                  child: ListView.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final selected = i == _railIndex;
                      return InkWell(
                        autofocus: i == 0,
                        onFocusChange: (hasFocus) {
                          if (hasFocus && _railIndex != i) {
                            setState(() => _railIndex = i);
                          }
                        },
                        onTap: () => setState(() => _railIndex = i),
                        child: Container(
                          color: selected
                              ? Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.15)
                              : null,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                entries[i].icon,
                                color: selected
                                    ? Theme.of(context).colorScheme.primary
                                    : null,
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  entries[i].title,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        fontWeight: selected
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: FocusTraversalGroup(
                    policy: OrderedTraversalPolicy(),
                    child: ListView(
                      key: ValueKey(_railIndex),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      children: entries[_railIndex].children(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // fix587 (#23): confirm-to-exit guard. No-op unless the setting is on AND
    // Back would exit the app (ConfirmExitScope's !Navigator.canPop() guard),
    // so on TV — where Settings is a sub-route — Back still returns normally.
    return ConfirmExitScope(
      enabled: settings.confirmToExit,
      child: _buildSettingsBody(context),
    );
  }

  Widget _buildSettingsBody(BuildContext context) {
    // fix512: Android-TV rail (groups) + pane (settings) layout. Reuses the
    // exact same settings widgets as the phone ExpansionTiles via the getters.
    if (widget.tvRailPane) return _buildTvRailPane();
    return Scaffold(
      body: Visibility(
        visible: !loading,
        child: Loading(
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(vertical: 10),
              child: FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: ListView(
                children: [
                  const SizedBox(height: 10),
                  const Padding(
                    padding: EdgeInsets.only(left: 10),
                    child: Text(
                      'Settings',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  ExpansionTile(
                    key: const PageStorageKey('playback'),
                    leading: const Icon(Icons.play_circle_outline),
                    title: Text(
                      'Playback',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: _groupOpen['playback'] ?? false,
                    // fix356: remember open/close for this app session only.
                    onExpansionChanged: (v) => _groupOpen['playback'] = v,
                    children: _playbackChildren,
                  ),

                  const Divider(),

                  ExpansionTile(
                    key: const PageStorageKey('buffering'),
                    leading: const Icon(Icons.tune),
                    title: Text(
                      'Buffering',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: _groupOpen['buffering'] ?? false,
                    // fix356: remember open/close for this app session only.
                    onExpansionChanged: (v) => _groupOpen['buffering'] = v,
                    children: _bufferingChildren,
                  ),

                  // fix394: Live DVR — its own section. Moved out of
                  // Buffering per user decision #1.
                  ExpansionTile(
                    key: const PageStorageKey('dvr'),
                    leading: const Icon(Icons.fiber_manual_record),
                    title: Text(
                      'Live DVR',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: _groupOpen['dvr'] ?? false,
                    onExpansionChanged: (v) => _groupOpen['dvr'] = v,
                    children: _dvrChildren,
                  ),

                  ExpansionTile(
                    key: const PageStorageKey('multiview'),
                    leading: const Icon(Icons.grid_view),
                    title: Text(
                      'Multi-view',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: _groupOpen['multiview'] ?? false,
                    // fix356: remember open/close for this app session only.
                    onExpansionChanged: (v) => _groupOpen['multiview'] = v,
                    children: _multiviewChildren,
                  ),

                  const Divider(),

                  ExpansionTile(
                    key: const PageStorageKey('content'),
                    leading: const Icon(Icons.filter_list),
                    title: Text(
                      'Content',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: _groupOpen['content'] ?? false,
                    // fix356: remember open/close for this app session only.
                    onExpansionChanged: (v) => _groupOpen['content'] = v,
                    children: _contentChildren,
                  ),

                  const Divider(),

                  ExpansionTile(
                    key: const PageStorageKey('epg'),
                    leading: const Icon(Icons.calendar_month),
                    title: Text(
                      'EPG / Program Guide',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: _groupOpen['epg'] ?? false,
                    // fix356: remember open/close for this app session only.
                    onExpansionChanged: (v) => _groupOpen['epg'] = v,
                    children: _epgChildren,
                  ),

                  const Divider(),

                  ExpansionTile(
                    key: const PageStorageKey('backuprestore'),
                    leading: const Icon(Icons.settings_backup_restore),
                    title: Text(
                      'Backup & Restore',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: _groupOpen['backuprestore'] ?? false,
                    // fix356: remember open/close for this app session only.
                    onExpansionChanged: (v) => _groupOpen['backuprestore'] = v,
                    children: _backupRestoreChildren,
                  ),

                  const Divider(),

                  ExpansionTile(
                    key: const PageStorageKey('reset'),
                    leading: const Icon(Icons.restart_alt),
                    title: Text(
                      'Reset',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: _groupOpen['reset'] ?? false,
                    // fix356: remember open/close for this app session only.
                    onExpansionChanged: (v) => _groupOpen['reset'] = v,
                    children: _resetChildren,
                  ),

                  const Divider(),

                  ..._appChildren,


                  const Divider(),


                  ..._sourcesChildren,

                  const Divider(),

                  ExpansionTile(
                    key: const PageStorageKey('diagnostics'),
                    leading: const Icon(Icons.bug_report_outlined),
                    title: Text(
                      'Diagnostics',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: _groupOpen['diagnostics'] ?? false,
                    // fix356: remember open/close for this app session only.
                    onExpansionChanged: (v) => _groupOpen['diagnostics'] = v,
                    children: _diagnosticsChildren,
                  ),

                  // fix394: Developer / libmpv advanced tunables. Hidden
                  // behind a folded ExpansionTile at the very bottom of the
                  // menu — advanced users opt in; the defaults match
                  // libmpv upstream so the section is a no-op until then.
                  // (Exception: on low-RAM Android the engine auto-applies
                  // framedrop=decoder — see mpv_engine _applyMpvOptions.)
                  ExpansionTile(
                    key: const PageStorageKey('developer'),
                    leading: const Icon(Icons.developer_mode),
                    title: Text(
                      'Developer',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: const Text(
                      'Advanced libmpv options. Defaults match libmpv '
                      'upstream; adjust only if a specific provider or '
                      'device needs it.',
                    ),
                    tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                    childrenPadding: EdgeInsets.zero,
                    initiallyExpanded: _groupOpen['developer'] ?? false,
                    onExpansionChanged: (v) => _groupOpen['developer'] = v,
                    children: _developerChildren,
                  ),

                ],
              ),
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: widget.showNavBar
          ? BottomNav(
              updateViewMode: updateView,
              startingView: ViewType.settings,
              settings: settings,
              contentTypeFilter: settings.contentTypeFilter,
              onContentTypeChanged: (_) {}, // no-op in Settings view
            )
          : null,
    );
  }
}

/// A [Slider] that does not consume D-pad up/down key events.
///
/// Flutter's stock [Slider] treats up/down arrow keys the same as right/left
/// (nudging the value), which on Android TV traps focus on the first slider
/// in a list — the user cannot move past it. This wrapper handles
/// left/right itself (so the value can still be adjusted) but returns
/// [KeyEventResult.ignored] for up/down, allowing the parent
/// [FocusTraversalGroup] / [ListView] to move focus to the next row.
class _DpadFriendlySlider extends StatefulWidget {
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final ValueChanged<double> onChanged;

  const _DpadFriendlySlider({
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
  });

  @override
  State<_DpadFriendlySlider> createState() => _DpadFriendlySliderState();
}

class _DpadFriendlySliderState extends State<_DpadFriendlySlider> {
  late final FocusNode _focusNode = FocusNode(debugLabel: 'DpadSlider');

  // finding 14: paint a visible highlight when this slider row holds D-pad
  // focus (cheap — one setState per focus enter/leave, not per drag tick).
  bool _focused = false;

  /// fix359: the stock Slider's inert focus node, hoisted out of build() so it
  /// is allocated once and disposed (was leaking one node per rebuild).
  late final FocusNode _innerInertNode =
      FocusNode(skipTraversal: true, canRequestFocus: false);

  @override
  void dispose() {
    _focusNode.dispose();
    _innerInertNode.dispose();
    super.dispose();
  }

  double get _step =>
      (widget.max - widget.min) / widget.divisions;

  void _nudge(double delta) {
    final next = (widget.value + delta).clamp(widget.min, widget.max);
    if (next != widget.value) widget.onChanged(next);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    // Let up/down propagate so the ListView can move focus.
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _nudge(-_step);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _nudge(_step);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKey,
      // finding 14: reflect D-pad focus with a tint + active-color so the
      // focused slider is obvious among the ten in the Buffering section.
      onFocusChange: (f) => setState(() => _focused = f),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: _focused
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
              : Colors.transparent,
        ),
        child: Slider(
          value: widget.value.clamp(widget.min, widget.max),
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          label: widget.label,
          activeColor:
              _focused ? Theme.of(context).colorScheme.primary : null,
          // Do not let the stock Slider grab keyboard focus — our outer
          // Focus node receives keys and forwards left/right manually.
          // fix359: hoisted out of build() (was allocating a leaked FocusNode
          // per rebuild during drag); disposed with the state.
          focusNode: _innerInertNode,
          onChanged: widget.onChanged,
        ),
      ),
    );
  }
}
