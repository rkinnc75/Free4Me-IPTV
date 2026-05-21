# Free4Me-IPTV

A feature-rich IPTV player for Android and Android TV, forked from the excellent open-source
[open-tv](https://github.com/Fredolx/open-tv) project by [@Fredolx](https://github.com/Fredolx).

---

## Features

### Sources
- **Xtream Codes**, **M3U URL**, and **M3U file** source types
- Add multiple sources; each can be individually **enabled or disabled**
- Per-source **EPG URL** — configure at add time or later in Settings
- Live progress dialog during source import (channel/movie/series counts)
- URL auto-correction (missing `http://` prefix is added automatically)
- Xtream: automatic correction of player_api.php path

### Channels, Movies & Series
- Unified channel grid with **search** (keyword and FTS5 full-text modes)
- Categories, Favorites, History, and All views
- History sorted most-recent-first; long-press to remove an entry
- **Stream scanner** — tap the radar icon to probe up to 20 visible streams
  for validity (10 s timeout, no video); valid streams get a green outline
- Infinite scroll with lazy loading

### Player
- Dual-engine: **libmpv** (media_kit) and **ExoPlayer** (video_player)
- Engine auto-selection per stream type, or force a global engine in Settings
- Hardware decoding via `mediacodec` (phones) / `mediacodec-copy` (Android TV)
  and VideoToolbox (iOS)
- Chromecast / Google Cast support for compatible streams
- **Dual-stream Picture-in-Picture** — watch two channels simultaneously:
  one full-screen with audio, one muted in a draggable corner window; swap
  with one tap
- Native Android PiP (background playback)
- Reconnect logic with configurable retry limits and cooldown
- Buffering watchdog, stable-playback threshold, and startup grace window —
  all tunable in Settings

### EPG (Electronic Programme Guide)
- XMLTV download and fuzzy channel matching (tiered: exact → normalised →
  stripped → token → token-subset)
- **Incremental matching** — only unmatched channels are re-processed on each
  refresh, making background refreshes dramatically faster on large sources
- Manual channel-to-EPG mapping with persistent override
- Now/Next strip on channel tiles; full schedule in channel detail view
- Configurable refresh interval (1 – 168 hours), refresh hour, past/forecast
  day windows
- **Re-match all channels** button to force a full re-match after feed changes
- Background refresh via WorkManager (configurable)

### Settings
- Buffer tuning: live cache, VOD cache, demuxer cache, open timeout,
  buffering watchdog, stable threshold, startup grace window
- Hardware decoding toggle; pre-warm on focus toggle
- Force TV mode; refresh sources on start
- Debug logging (writes timestamped log file to device storage)
- Backup and restore settings + sources as JSON
- Version history — tap the version number to see full changelog

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

This fork adds Android TV support, ExoPlayer integration, Chromecast,
dual-stream PiP, advanced EPG matching, stream scanner, and numerous
stability improvements. All additions are released under the same license
as the original project.
