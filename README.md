# Free4Me-IPTV

A feature-rich IPTV player for Android and Android TV, forked from the excellent open-source
[open-tv](https://github.com/Fredolx/open-tv) project by [@Fredolx](https://github.com/Fredolx).

---

## Features

### Sources
- **Xtream Codes**, **M3U URL**, and **M3U file** source types
- Add multiple sources; each can be individually **enabled or disabled**
- Per-source **EPG URL** — configure at add time or later in Settings
- Per-source **engine override** — force libmpv or ExoPlayer for a specific provider
- Live progress dialog during source refresh (channel/movie/series counts with status text)
- Per-source refresh button in Settings shows a live progress dialog (not a plain spinner)
- URL auto-correction (missing `http://` prefix is added automatically)
- Xtream: automatic correction of `player_api.php` path
- **Credential-safe backup import** — restoring a backup without username/password fields
  leaves existing credentials intact (no accidental wipe)

### Channels, Movies & Series
- Unified channel grid with **search** — FTS5 trigram index for fast partial matching;
  short queries (1–2 chars) are skipped to avoid full-table scans on large sources
- **Content-type filter on the All tab** — tap to cycle All → Live → Movies → Series → All;
  limits search to the selected type, making 250k+ channel sources instantly snappy
- Categories, Favorites, History, and All views
- History sorted most-recent-first; long-press to remove an entry
- **Stream scanner** — tap the radar icon to probe visible streams for validity
  (configurable count 1–100, timeout 3–30 s); valid streams get a green outline
- Infinite scroll with lazy loading; stale pagination results are dropped when a
  newer search starts

### Player
- Dual-engine: **libmpv** (media_kit) and **ExoPlayer** (video_player)
- Engine auto-selection per stream type, or force a global engine in Settings
- Per-channel engine override stored in the database
- Hardware decoding via `mediacodec` (phones) / `mediacodec-copy` (Android TV)
- Chromecast / Google Cast support for compatible streams
- **Dual-stream Picture-in-Picture** — watch two channels simultaneously:
  one full-screen with audio, one muted in a draggable corner window; swap with one tap
- Native Android PiP (background playback)
- Reconnect logic with configurable watchdog, stable-playback threshold, startup
  grace window, and stream-completed reconnect delay — all tunable in Settings
- Pre-warm on focus (HEAD request) to reduce channel-switch latency on D-pad navigation

### EPG (Electronic Programme Guide)
- Streaming XMLTV parser — handles plain and gzip-compressed feeds; sniffs compression
  from magic bytes rather than trusting `Content-Encoding` headers
- Fuzzy channel matching (tiered: exact → normalised → stripped → token → token-subset)
- **Incremental matching** — only unmatched channels re-processed on each refresh;
  manual overrides are always preserved
- Manual channel-to-EPG mapping with persistent override; override survives backup/restore
- Now/Next strip on channel tiles; full schedule in channel detail view
- Configurable refresh interval (1–168 h), refresh hour, past-day and forecast-day windows
- **Re-match all channels** button to force a full re-match after a feed change
- Background refresh via WorkManager (runs at the configured hour, requires network)
- EPG data stored in a **separate `epg.sqlite` database** so large WAL writes
  (600k+ programme inserts) never block channel-search reads in the main DB
- WAL checkpointed explicitly after each EPG write phase — searches are fast
  immediately after a refresh completes

### Backup & Restore
- Export settings + sources as a JSON backup file
- Backup includes EPG channel assignments and manual overrides so EPG is preserved
  across a restore without requiring a full re-match
- Selective restore: favorites, watch history, EPG IDs, and manual overrides are
  applied per-channel after the source refresh populates the channel list
- Debug log activated immediately when a backup with `debugLogging: true` is imported

### Settings — collapsible groups
Settings are organised into expandable groups to reduce scrolling.
Tap a group header to expand/collapse it.

- **Default view** (flat) — choose which tab opens on launch
- **Playback** — force TV mode, low-latency mode, hardware decode, pre-warm on focus,
  player engine picker
- **Buffering** — live cache, VOD cache, demuxer cache sizes; open timeout, buffering
  watchdog, stable threshold, startup grace window, stream-completed reconnect delay
- **Multi-view** — layout picker, restore-last-channels toggle
- **Content** — show/hide livestreams, movies, and series; refresh on start; stream scanner
- **EPG / Program Guide** — auto-refresh toggle, refresh interval, refresh hour,
  past/forecast day windows, Refresh EPG Now button, Re-match All Channels button
- **Diagnostics** (flat) — debug logging toggle, save/clear log
- **Backup & Restore** (flat) — export and import JSON backup
- **Reset** (flat) — restore all settings to optimised defaults
- **App** (flat) — version, changelog, open-source credits
- **Sources** (flat) — add, edit, enable/disable, and per-source refresh

### Android TV
- D-pad navigation throughout
- Focus-aware channel grid, settings menus, and dialogs
- Separate TV home layout with side menu

---

## Installation

Download the latest APK from the
[GitHub Releases](https://github.com/rkinnc75/Free4Me-IPTV/releases) page
and sideload it onto your Android device or Android TV.

---

## Building from source

```bash
# Prerequisites: Flutter 3.27+, Android SDK
git clone https://github.com/rkinnc75/Free4Me-IPTV.git
cd Free4Me-IPTV
flutter pub get
flutter build apk --release
```

---

## Credits & License

Free4Me-IPTV is a fork of **[open-tv](https://github.com/Fredolx/open-tv)**,
created and maintained by [@Fredolx](https://github.com/Fredolx).

The original project is an excellent open-source IPTV client for Android and
iOS. If you find open-tv useful, please consider supporting the original author:

- ⭐ Star the [open-tv repository](https://github.com/Fredolx/open-tv)
- 💖 Sponsor on [GitHub](https://github.com/sponsors/Fredolx)
- ❤️ Support on [Patreon](https://www.patreon.com/fredol)
- 💸 Donate via [PayPal](https://paypal.me/fredolx)

This fork adds Android TV support, ExoPlayer integration, Chromecast, dual-stream PiP,
content-type filter cycling, advanced EPG matching, separate EPG database, stream scanner,
collapsible settings groups, and numerous reliability and performance improvements.
All additions are released under the same license as the original project.
