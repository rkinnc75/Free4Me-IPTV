# Free4Me-IPTV

A feature-rich IPTV player for Android and Android TV, forked from
[open-tv](https://github.com/Fredolx/open-tv) by [@Fredolx](https://github.com/Fredolx).

---

## Features

### Sources
- **Xtream Codes**, **M3U URL**, and **M3U file** sources; add multiple, each individually enable/disable-able
- Per-source **EPG URL** and **engine override** (force libmpv or ExoPlayer)
- Live refresh progress (channel/movie/series counts); URL auto-correction incl. Xtream `player_api.php`
- Categories the provider references but doesn't name are auto-named from channel prefixes so they stay usable
- Providers that cap the all-movies response are back-filled per category to load the full catalog
- Credential-safe backup import (restoring without credentials never wipes existing ones)
- Disabling a source disables its other actions (refresh/edit/delete); enable/disable stays available

### Channels, Movies & Series
- Unified grid with fast **FTS5 trigram search** (1–2 char queries skipped); divider/disabled-category rows are filtered before pagination so real channels are never hidden
- **Content-type cycle** on the All tab (All → Live → Movies → Series) for snappy 250k+ sources
- Consistent multi-key sort everywhere: Favourites → History → All, validated-first then alphabetical
- **Favorite a category** (long-press) to pin it to the top of the Categories list — channels inside are untouched
- Opening a category shows all its channels regardless of the enable checkbox
- Long-press any tile (live, movie, or series) for the same menu: favorite, plus a tappable link to its category
- **Stream scanner** (radar): probes from the first visible tile downward, configurable count/timeout; valid streams get a green outline that **persists across restarts** and is reapplied after each scan
- Categories, Favorites, History, All views; infinite scroll with stale-result guarding

### Player
- Dual-engine **libmpv** (media_kit, **custom LGPL-max build** with all non-GPL filters/codecs + MP4/MKV muxers) + **ExoPlayer** (video_player); auto-select per stream or force globally / per-channel
- Hardware decoding (`mediacodec` phones / `mediacodec-copy` TV); Chromecast / Google Cast
- **Dual-stream Picture-in-Picture** — two channels at once (one full-screen with audio, one muted/draggable; one-tap swap)
- App-managed fullscreen + native Android PiP; pre-warm on focus to cut switch latency
- Tunable reconnect (watchdog, stable threshold, startup grace, completed-reconnect delay); graceful give-up restores prior audio

### Multi-view
- 1×2 and 2×2 layouts, **live-TV only**; independent engine + reconnect per cell
- Channel picker scroll-loads the full catalog; optional restore-last-channels on entry

### Scheduled Recording (SR)
- Record live channels on a schedule or on-demand; exact wall-clock start via a background alarm that survives Doze and reboot
- Foreground-service capture to `Movies/Free4Me`; status (scheduled → recording → done/failed) tracked in-app
- Optional **MP4 conversion** (lossless stream-copy remux; MKV fallback for streams MP4 can't hold) powered by the custom muxer-enabled libmpv engine
- 1 GB low-space floor; deleting a scheduled recording cancels its timer

### EPG (Electronic Programme Guide)
- Streaming XMLTV parser (plain + gzip, sniffed from magic bytes); tiered fuzzy channel matching
- **Incremental matching** — only unmatched channels reprocessed; manual overrides always preserved (survive backup/restore)
- Now/Next on tiles, full schedule in detail; configurable interval/hour/past/forecast windows; Re-match-all button
- Background refresh via WorkManager; stored in a **separate `epg.sqlite`** (WAL-checkpointed) so large writes never block search

### Safe mode
- Unified adult filter: a single indexed flag set at import from the provider's `is_adult` **or** the built-in keyword list

### Backup & Restore
- JSON export of settings + sources, including EPG assignments/overrides
- Selective per-channel restore (favorites, history, EPG IDs, overrides) applied after refresh

### Settings — collapsible groups
Expandable groups to reduce scrolling: **Default view**, **Playback**, **Buffering**, **Multi-view**,
**Content**, **EPG**, **Diagnostics**, **Backup & Restore**, **Reset**, **App**, **Sources**.

### Android TV
- Full D-pad navigation; focus-aware grid/menus/dialogs; dedicated TV home with side menu
- **LAN export** (QR + port 9479) serves source dump, debug log, and settings — each individually plus a combined zip

### Updates
- Built-in update check against `version.json` with a "what's new" summary
- **In-app auto-update**: one-tap download of the new APK and launch the installer

---

## Installation

Download the latest APK from [GitHub Releases](https://github.com/rkinnc75/Free4Me-IPTV/releases)
and sideload it onto your Android device or Android TV.

## Building from source

```bash
# Prerequisites: Flutter 3.44+, Android SDK
git clone https://github.com/rkinnc75/Free4Me-IPTV.git
cd Free4Me-IPTV
flutter pub get
flutter build apk --release
```

---

## Credits & License

Free4Me-IPTV is a fork of **[open-tv](https://github.com/Fredolx/open-tv)** by
[@Fredolx](https://github.com/Fredolx). If you find open-tv useful, please support the original author:
⭐ [Star](https://github.com/Fredolx/open-tv) · 💖 [Sponsor](https://github.com/sponsors/Fredolx) ·
❤️ [Patreon](https://www.patreon.com/fredol) · 💸 [PayPal](https://paypal.me/fredolx)

This fork adds Android TV support, ExoPlayer, Chromecast, dual-stream PiP, content-type cycling,
consistent multi-key sort, persistent stream validation, favorite categories, live-TV-only multi-view,
advanced/incremental EPG with a separate database, unified safe mode, in-app auto-update, LAN export
bundles, and many reliability and performance improvements. Released under the original project's license.
