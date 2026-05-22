# updated-help-messages.md — All Settings Help Messages (Revised)

All messages follow a consistent structure:
- What the setting does
- **↑ Raising** the value does X
- **↓ Lowering** the value does Y
- When to change it
- Default and range

Replace all existing help message bodies with the versions below.

---

## Static const help messages (top of settings_view.dart)

```dart
const _helpDefaultView = (
  title: 'Default View',
  body:
      'Which content type the app opens to when you launch it. '
      '"All" shows livestreams, movies, and series together. '
      '"Livestreams" jumps straight to live TV. '
      '"Movies" or "Series" opens that section directly.\n\n'
      'Choose whichever you use most — saves a navigation tap every launch. '
      'Default: All.',
);

const _helpForceTvMode = (
  title: 'Force TV Mode',
  body:
      'Overrides automatic device detection and always uses the '
      'TV-optimised layout — larger tiles, D-pad navigation, no touch '
      'shortcuts.\n\n'
      '↑ ON — forces TV layout on any device. Use this if the app '
      'incorrectly starts in phone mode on your Android TV box or Onn 4K.\n\n'
      '↓ OFF — uses the touch-friendly phone/tablet layout. '
      'Default: OFF.',
);

const _helpLowLatency = (
  title: 'Low Latency (Live TV)',
  body:
      'Tells libmpv to request the lowest-bitrate HLS variant stream '
      'and reduces internal buffering targets.\n\n'
      '↑ ON — minimises the delay between broadcast and playback. '
      'Useful for live sports where score spoilers matter. '
      'May reduce picture quality on HLS streams.\n\n'
      '↓ OFF — requests the highest-quality variant and uses larger '
      'buffers for smoother playback on stable connections.\n\n'
      'Has no effect on non-HLS streams (MPEG-TS, RTMP). Default: OFF.',
);

const _helpRefreshOnStart = (
  title: 'Refresh Sources on Start',
  body:
      'Re-downloads all M3U playlists and Xtream channel lists every '
      'time the app launches.\n\n'
      '↑ ON — always starts with the freshest channel list. Useful if '
      'your provider changes URLs often. Adds a few seconds to startup '
      'and uses data on every launch.\n\n'
      '↓ OFF — uses the cached list for instant startup. '
      'You can still refresh manually from the Sources section. '
      'Default: OFF.',
);

const _helpShowLivestreams = (
  title: 'Show Livestreams',
  body:
      'Controls whether live TV channels appear in the channel grid, '
      'search results, and "All" view.\n\n'
      '↑ ON — live TV is visible everywhere in the app.\n\n'
      '↓ OFF — hides all live TV channels. Does not delete them — '
      'they reappear when turned back on. '
      'Useful if your source only has movies and series. Default: ON.',
);

const _helpShowMovies = (
  title: 'Show Movies',
  body:
      'Controls whether on-demand movies appear in the channel grid, '
      'search results, and "All" view.\n\n'
      '↑ ON — movies are visible.\n\n'
      '↓ OFF — hides the movie library. Does not delete content. '
      'Default: ON.',
);

const _helpShowSeries = (
  title: 'Show Series',
  body:
      'Controls whether TV series and episodes appear in the channel '
      'grid, search results, and "All" view.\n\n'
      '↑ ON — series are visible.\n\n'
      '↓ OFF — hides series content. Does not delete content. '
      'Default: ON.',
);

const _helpHwDecode = (
  title: 'Hardware Decoding',
  body:
      'Uses your device\'s dedicated video-decoder chip instead of the CPU.\n\n'
      '↑ ON — MediaCodec (Android) or VideoToolbox (iOS/Apple TV) '
      'handles decoding. Dramatically reduces CPU heat and load. '
      'Required for smooth 4K/HEVC playback on TV boxes. '
      'Recommended for all devices. '
      'Android TV / Nvidia Shield automatically uses a copy mode '
      '(mediacodec-copy) that is compatible with all TV chipsets.\n\n'
      '↓ OFF — software (CPU) decoding. Use only if you see video '
      'corruption, a green screen, or black video with audio — '
      'which indicates a buggy hardware decoder on your device. '
      'Default: ON.',
);

const _helpPreWarm = (
  title: 'Pre-warm Streams on Focus',
  body:
      'Resolves redirect URLs in the background as soon as you highlight '
      'a channel tile with the D-pad or hover over it.\n\n'
      '↑ ON — playback starts noticeably faster when you select a channel '
      'because the redirect is already resolved. Best for D-pad navigation '
      'on TV boxes.\n\n'
      '↓ OFF — URL resolution happens at tap time. Slightly slower channel '
      'start but no background network activity while browsing. '
      'Recommended on metered mobile connections. Default: ON.',
);

const _helpLiveCacheSecs = (
  title: 'Livestream Cache (seconds)',
  body:
      'How many seconds of live TV libmpv reads ahead into memory.\n\n'
      '↑ Raising — reduces rebuffering on unstable or congested connections. '
      'Also adds a small rewind window. Uses more RAM. '
      'Values above 45 s can cause audio/video sync drift on slow streams.\n\n'
      '↓ Lowering — reduces RAM use. Recommended on 1–2 GB Android TV boxes '
      '(Onn 4K, Fire TV Stick). May increase rebuffering on weak signals.\n\n'
      'Has no effect in Low Latency mode (which disables caching entirely). '
      'Default: 20 s. Range: 5–60 s.',
);

const _helpLiveDemuxerMB = (
  title: 'Livestream Demuxer Buffer (MB)',
  body:
      'Maximum RAM the stream-splitter (demuxer) may use while playing '
      'live TV. This is separate from and in addition to the cache.\n\n'
      '↑ Raising — gives the decoder a larger in-memory cushion, reducing '
      'dropped frames on high-bitrate 4K or HEVC streams. '
      'Also helps when two streams play simultaneously (mini-player + '
      'full-screen).\n\n'
      '↓ Lowering — frees RAM. Reduce this first if the app is killed by '
      'the system on a low-memory box. 32–64 MB is sufficient for '
      'standard 1080p IPTV streams.\n\n'
      'Max is capped at 75 % of your device RAM. '
      'Default: auto-detected from RAM. Range: 32–512 MB.',
);

const _helpVodCacheSecs = (
  title: 'VOD/Movie Cache (seconds)',
  body:
      'How many seconds ahead libmpv reads from a movie or on-demand '
      'stream into memory.\n\n'
      '↑ Raising — reduces pauses during seek (fast-forward/rewind) and '
      'smooths playback on slow connections. Large values also improve '
      'chapter-skip responsiveness.\n\n'
      '↓ Lowering — reduces RAM use. Has no effect on live TV streams. '
      'Default: 60 s. Range: 10–180 s.',
);

const _helpVodDemuxerMB = (
  title: 'VOD/Movie Demuxer Buffer (MB)',
  body:
      'Maximum RAM the demuxer may use while playing a movie or series '
      'episode.\n\n'
      '↑ Raising — improves seek performance and reduces pauses on '
      'high-bitrate VOD (Blu-ray remuxes, 4K HDR). '
      'Essential for smooth chapter navigation on large files.\n\n'
      '↓ Lowering — frees RAM. Has no effect on live TV streams. '
      '64–128 MB is sufficient for most 1080p VOD. '
      'Default: 256 MB. Range: 64–1024 MB.',
);

const _helpOpenTimeout = (
  title: 'Stream Open Timeout (seconds)',
  body:
      'How long the player waits for a stream to begin playing before '
      'giving up and showing an error.\n\n'
      '↑ Raising — gives slow or geographically distant servers more time '
      'to respond. Helpful on congested networks or with international '
      'streams. Also useful for streams that take longer to negotiate '
      'a session.\n\n'
      '↓ Lowering — surfaces failures faster so the app can retry sooner. '
      'Reduce if you find yourself waiting a long time for obviously '
      'dead streams.\n\n'
      'Default: 15 s. Range: 5–60 s.',
);

const _helpWatchdog = (
  title: 'Buffering Watchdog (seconds)',
  body:
      'If a live stream stalls in a buffering/loading state for longer '
      'than this value, the player automatically reconnects.\n\n'
      '↑ Raising — gives the server more time to recover on its own. '
      'Better on intermittent connections where a brief stall '
      'self-resolves within a few seconds. Reduces unnecessary reconnects '
      'during temporary network hiccups.\n\n'
      '↓ Lowering — forces a reconnect sooner. Useful for streams that '
      'silently freeze without ever recovering — you get picture back '
      'faster at the cost of more reconnects on shaky connections.\n\n'
      'Note: when two streams are playing simultaneously (mini-player + '
      'full-screen), both watchdogs run independently. If both fire at '
      'the same time, the reconnects compete for bandwidth — '
      'raising this value reduces that risk. '
      'Default: 12 s. Range: 5–60 s.',
);
```

---

## Inline help messages (inside build method)

### Stable Playback Threshold

```dart
help: (
  title: 'Stable Playback Threshold (seconds)',
  body:
      'How long a stream must play without any buffering event before '
      'the reconnect retry counter resets to zero.\n\n'
      '↑ Raising — requires more sustained stability before considering '
      'the stream "healthy". Keeps the retry counter active longer '
      'after a shaky period, so the app gives up sooner on '
      'persistently unstable streams.\n\n'
      '↓ Lowering — resets the counter sooner after a brief blip, '
      'allowing more retries on streams that recover quickly. '
      'Reduce if good streams are hitting max-reconnect and giving up '
      'prematurely.\n\n'
      'Default: 30 s. Range: 5–60 s.',
),
```

### Startup Grace Window

```dart
help: (
  title: 'Startup Grace Window (ms)',
  body:
      'How long after buffering begins to suppress the mpv seek-probe '
      'error ("Cannot seek in this stream") which would otherwise cause '
      'an immediate false reconnect on every channel open.\n\n'
      'Note: as of the current version, seek errors are suppressed '
      'unconditionally (not just during the grace window), so this '
      'setting primarily affects other false-positive errors that may '
      'fire during stream initialisation.\n\n'
      '↑ Raising — catches errors that arrive later during startup. '
      'Increase to 1000–1500 ms on slower TV hardware (Onn 4K, '
      'older Fire TV Stick) if streams still double-start.\n\n'
      '↓ Lowering — allows genuine errors to surface and trigger a '
      'reconnect sooner after stream open. '
      'Default: 500 ms. Range: 100–3000 ms.',
),
```

### Stream-Ended Reconnect Delay

```dart
help: (
  title: 'Stream-Ended Reconnect Delay (ms)',
  body:
      'How long to wait before reconnecting when the stream signals it '
      'has ended (TCP connection closed by provider).\n\n'
      'IPTV providers sometimes briefly close the TCP connection at '
      'segment boundaries or during load-balancer rotation — the stream '
      'is not actually dead, just rotating. A short wait lets the '
      'provider re-establish without triggering a full reconnect.\n\n'
      '↑ Raising — gives the provider more time to re-establish. '
      'Reduces unnecessary reconnects on providers that frequently '
      'rotate connections. Values above 5000 ms may cause a visible '
      'freeze before the stream resumes.\n\n'
      '↓ Lowering — reconnects faster when the stream genuinely ends. '
      'Set to 0 to reconnect immediately (original behaviour).\n\n'
      'Default: 2000 ms (2 seconds). Range: 0–10 000 ms.',
),
```

### Mini-Player Demuxer Cache

```dart
help: (
  title: 'Mini-Player Demuxer Buffer (MB)',
  body:
      'Maximum RAM the demuxer may use for the mini-player / overlay '
      'stream running alongside the full-screen player.\n\n'
      '↑ Raising — smoother mini-player playback on high-bitrate streams. '
      'Reduces buffering oscillation when both streams compete for '
      'bandwidth. Uses more RAM — ensure full-screen + mini-player '
      'total stays below ~60 % of device RAM.\n\n'
      '↓ Lowering — frees RAM for the full-screen stream and the OS. '
      'The mini-player is a preview window; 16–32 MB is usually '
      'sufficient for 1080p IPTV. Reduce first if the app is '
      'killed by the system.\n\n'
      'Max is capped at 75 % of your device RAM ÷ 2 streams. '
      'Default: auto-detected (${DeviceMemory.defaultMiniDemuxerMb} MB '
      'on this ${DeviceMemory.totalMb} MB device). '
      'Range: 8–${DeviceMemory.maxMiniDemuxerMb} MB.',
),
```

### Player Buffer Size

```dart
help: (
  title: 'Player Buffer Size (MB)',
  body:
      'Internal libmpv read-ahead buffer allocated per player instance '
      'at startup. The mini-player automatically uses half this value.\n\n'
      '↑ Raising — larger in-memory read buffer. Helps on very high '
      'bitrate streams (4K HEVC above 25 Mbps) where the default buffer '
      'empties faster than the network can refill it. Takes effect on '
      'the next app restart.\n\n'
      '↓ Lowering — reduces per-instance RAM use. Essential on devices '
      'with 2 GB or less RAM, especially when the mini-player is active '
      '(two instances = 2× this value). '
      'Values below 32 MB may cause frequent stalls on 4K streams.\n\n'
      'Max is capped at 75 % of your device RAM ÷ 2 streams. '
      'Requires app restart to take effect. '
      'Default: auto-detected (${DeviceMemory.defaultBufferSizeMb} MB '
      'on this ${DeviceMemory.totalMb} MB device). '
      'Range: 16–${DeviceMemory.maxBufferSizeMb} MB.',
),
```

### Streams Per Scan

```dart
help: (
  title: 'Streams Per Scan',
  body:
      'Maximum number of visible channels the radar button probes in '
      'a single scan run.\n\n'
      '↑ Raising — tests more channels per run, giving a more complete '
      'picture of which streams are working. Scan time increases '
      'proportionally (count × timeout per stream). '
      '100 streams at 8 s timeout = up to ~13 minutes worst-case.\n\n'
      '↓ Lowering — faster scan. Useful for a quick sanity check on '
      'your most-watched channels. The scanner always tests channels '
      'in the order they appear on screen, so put your favourites first.\n\n'
      'Green border = valid MPEG-TS sync bytes or HLS playlist confirmed. '
      'No border = failed or not yet scanned. '
      'Default: 20. Range: 1–100.',
),
```

### Scan Timeout

```dart
help: (
  title: 'Scan Timeout (seconds)',
  body:
      'How long the scanner waits per stream to receive and validate '
      'the first media bytes (MPEG-TS sync bytes at 0, 188, 376 bytes; '
      'or "#EXTM3U" for HLS playlists).\n\n'
      '↑ Raising — gives slow CDNs and geographically distant servers '
      'more time to respond. Reduces false negatives (streams marked '
      'as failed when they are actually just slow). Increases total '
      'scan time proportionally.\n\n'
      '↓ Lowering — faster scans. May produce false negatives on slow '
      'or international streams that take longer than the timeout to '
      'send the first packet.\n\n'
      '8 s covers most IPTV providers. Only increase if you see '
      'streams your player can open but the scanner marks as failed. '
      'Default: 8 s. Range: 3–30 s.',
),
```

### Player Engine

```dart
// Inside _showEnginePickerDialog or the help icon onPressed:
body:
    'Controls which media engine decodes and renders your streams.\n\n'
    '"Auto (recommended)" selects automatically based on the stream URL: '
    'HLS (.m3u8), DASH (.mpd), and MP4 use ExoPlayer for better adaptive '
    'bitrate switching and battery efficiency; everything else (MPEG-TS '
    '.ts, RTMP, and most IPTV URLs) uses libmpv.\n\n'
    '"libmpv" forces libmpv for all streams. Best for MPEG-TS and RTMP '
    'sources that ExoPlayer cannot handle. Supports full track selection '
    '(audio language, subtitles).\n\n'
    '"ExoPlayer" forces ExoPlayer. Use only if Auto picks the wrong '
    'engine for a specific source. Note: audio/subtitle track selection '
    'is not available in ExoPlayer mode, and some MPEG-TS streams will '
    'fail with a Source Error — the app will attempt to fall back to '
    'libmpv automatically when this occurs.',
```

### Multi-View

```dart
body:
    'Play multiple live streams simultaneously in a split-screen grid.\n\n'
    '1×2 — two streams side by side in landscape. '
    'Best for watching two events at once (e.g. two sports games). '
    'Recommended starting point on all devices.\n\n'
    '2×2 — four streams in a quad grid. '
    'Requires a device with at least 3 GB RAM and a capable chipset. '
    'On the Nvidia Shield, Onn 4K, and similar Android TV boxes, '
    'use Hardware Decoding ON with mediacodec-copy mode (automatic).\n\n'
    'Tap a cell to give it audio focus (coloured border = active audio). '
    'Tap + in an empty cell to assign a channel. '
    'Double-tap a cell to promote it to full-screen.\n\n'
    'Each stream uses its own decoder instance and buffer. '
    'The mini-player buffer setting controls RAM per cell. '
    'On lower-end devices (< 3 GB RAM), 2×2 may cause thermal '
    'throttling or the OS killing the app — start with 1×2.',
```

### Auto-refresh EPG

```dart
help: (
  title: 'Auto-refresh EPG',
  body:
      'Automatically downloads updated program guide data in the '
      'background at the scheduled hour.\n\n'
      '↑ ON — program guide stays current without manual action. '
      'Uses data and battery during the refresh window.\n\n'
      '↓ OFF — EPG only updates when you tap "Refresh EPG" manually. '
      'Useful on metered connections or if your EPG source rarely changes. '
      'Default: ON.',
),
```

### EPG Refresh Interval

```dart
help: (
  title: 'EPG Refresh Interval (hours)',
  body:
      'How often the background EPG refresh runs.\n\n'
      '↑ Raising — less frequent downloads. Reduces data and battery '
      'use. EPG data may become stale (programs showing wrong times '
      'or missing). Values above 48 h are only suitable if your '
      'provider rarely updates the guide.\n\n'
      '↓ Lowering — more frequent downloads. Guide stays current. '
      'Each refresh downloads and re-parses the full XMLTV file '
      '(up to 500 k programs) — avoid values below 12 h on metered '
      'or slow connections.\n\n'
      'Note: only unmatched channels are re-matched on each refresh. '
      'Already-matched channels are skipped, keeping refresh fast. '
      'Default: 24 h. Range: 6–168 h (7 days).',
),
```

### EPG Refresh Hour

```dart
help: (
  title: 'EPG Refresh Hour',
  body:
      'The hour of the day (local time, 24-hour clock) when the '
      'background EPG refresh runs.\n\n'
      '↑ Raising — schedules the refresh later in the day.\n\n'
      '↓ Lowering — schedules it earlier.\n\n'
      'Choose a time when the device is plugged in and on Wi-Fi — '
      'EPG parsing is CPU-intensive (up to 2 min on slower boxes). '
      '3:00 AM is the default as most devices are idle then. '
      'Default: 3 (03:00). Range: 0–23.',
),
```

### EPG Past Days

```dart
help: (
  title: 'EPG Past Days',
  body:
      'How many days of already-aired program data to retain.\n\n'
      '↑ Raising — lets you see what aired recently in the guide. '
      'Uses more storage and slightly increases EPG parse time.\n\n'
      '↓ Lowering / 0 — keeps only current and future programs. '
      'Reduces storage and speeds up parsing. '
      'Set to 0 on low-storage devices. '
      'Default: 1. Range: 0–3.',
),
```

### EPG Forecast Days

```dart
help: (
  title: 'EPG Forecast Days',
  body:
      'How many days ahead of program guide data to download.\n\n'
      '↑ Raising — more advance schedule visibility. Allows planning '
      'recordings or viewing further in advance. '
      'Increases download size and parse time proportionally '
      '(each extra day ≈ +70 k programs for large guides).\n\n'
      '↓ Lowering — faster EPG refresh, less storage. '
      '3 days is sufficient if you only use the guide for '
      '"what\'s on now/next". '
      'Default: 7. Range: 3–14.',
),
```

---

## Notes on defaults shown in help text

For the three RAM-aware settings (Mini-Player Demuxer, Player Buffer Size,
Livestream Demuxer), the help body references `DeviceMemory.totalMb` and
`DeviceMemory.defaultXxxMb` dynamically. This means the text shown to the
user will reflect their actual device — e.g. "Default: 32 MB on this 3936 MB
device" — making it immediately clear why their slider max differs from
what documentation might say.

These fields cannot be `const` — they must be computed at runtime in the
`_bufferSlider` call inside the `build` method.

---

## Summary of changes from existing messages

| Setting | Key additions |
|---|---|
| Force TV Mode | Mentions Onn 4K specifically |
| Low Latency | Clarifies HLS-only, mentions quality trade-off |
| Hardware Decoding | Explains mediacodec-copy for TV, green screen diagnosis |
| Pre-warm | Adds metered connection advice |
| Livestream Cache | Adds sync-drift warning, Low Latency interaction |
| Livestream Demuxer | Adds mini-player bandwidth contention context, RAM cap note |
| VOD Cache | Adds chapter-skip note |
| VOD Demuxer | Adds 4K HDR context |
| Open Timeout | Adds session negotiation note |
| Buffering Watchdog | Adds dual-stream bandwidth contention warning |
| Stable Threshold | Adds give-up-prematurely diagnosis tip |
| Startup Grace Window | Notes seek suppression is now unconditional |
| Stream-Ended Delay | New setting — full explanation |
| Mini-Player Demuxer | New setting — full explanation with RAM cap |
| Player Buffer Size | New setting — restart requirement, mini-player halving |
| Streams Per Scan | Adds scan order tip (favourites first) |
| Scan Timeout | Explains TS sync byte validation |
| Player Engine | Adds ExoPlayer→libmpv fallback note |
| Multi-View | Adds RAM guidance, Shield/Onn 4K notes, buffer setting cross-reference |
| Auto-refresh EPG | Adds battery/data note |
| EPG Refresh Interval | Adds incremental matching note |
| EPG Refresh Hour | Adds CPU-intensity warning for slow boxes |
| EPG Past Days | Adds storage guidance |
| EPG Forecast Days | Adds per-day program count estimate |
