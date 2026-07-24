# Free4Me-IPTV

A feature-rich IPTV player for Android and Android TV, forked from
[open-tv](https://github.com/Fredolx/open-tv) by [@Fredolx](https://github.com/Fredolx).

---

## Features

### Sources
- **Xtream Codes**, **M3U URL**, and **M3U file** sources; add multiple, each individually enable/disable-able
- Per-source **EPG URL** and **engine override** (force libmpv or ExoPlayer)
- Live refresh progress (channel/movie/series counts); URL auto-correction incl. Xtream `player_api.php`
- **Partial-refresh protection** — a failed fetch is distinguished from a genuinely empty one; content types that fail are never wiped, so a provider hiccup can't erase your channels
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
- Hardware decoding (`mediacodec` phones / `mediacodec-copy` TV) with a **codec-open fallback** — if hardware decode fails to open, the player falls back to software automatically; a per-URL **hwdec blocklist** (30-day TTL, app-version aware) skips re-probing known-bad combinations, and hardware decoding can be re-tested on demand from Settings
- **Silent-stall watchdog** — detects a wedged stream (frozen position with no intent to pause) and auto-reconnects; deliberately ignores user pauses and backgrounded/phone-call states so it never fires falsely
- **Fast channel start** — tap-down prewarm begins connecting the moment your finger touches a channel, cached package info, and a concurrent pre-open path shave channel-zap latency
- **Catchup / time-shift** — play back past programs on channels whose provider advertises catchup support
- **Dual-stream Picture-in-Picture** — two channels at once (one full-screen with audio, one muted/draggable; one-tap swap)
- App-managed fullscreen + native Android PiP; pre-warm on focus to cut switch latency; PiP is automatically suppressed during an in-app update install
- **Zoom modes** (fit / fill / zoom) and hold-to-seek acceleration on the ◀/▶ transport keys
- Chromecast / Google Cast
- Tunable reconnect (watchdog, stable threshold, startup grace, completed-reconnect delay); graceful give-up restores prior audio
- **Debug stats overlay** (with debug logging on): decode path, fps, dropped frames, A/V sync, cache — also written to the log for offline review

### Multi-view
- 1×2 and 2×2 layouts, **live-TV only**; independent engine + reconnect per cell
- Channel picker scroll-loads the full catalog; optional restore-last-channels on entry

### Scheduled Recording (SR)
- Record live channels on a schedule or on-demand; exact wall-clock start via a background alarm that survives Doze and reboot
- Foreground-service capture to `Movies/Free4Me`; status (scheduled → recording → done/failed) tracked in-app with a blinking REC indicator and live list updates
- Optional **MP4 conversion** (lossless stream-copy remux; MKV fallback for streams MP4 can't hold) powered by the custom muxer-enabled libmpv engine
- 1 GB low-space floor; deleting a scheduled recording cancels its timer

### EPG (Electronic Programme Guide)
- Streaming XMLTV parser (plain + gzip, sniffed from magic bytes); tiered fuzzy channel matching
- **Auto-discovery** of the EPG feed for Xtream/Stalker-style portals (tries the common endpoint variants automatically)
- **Incremental matching** — only unmatched channels reprocessed; manual overrides always preserved (survive backup/restore)
- Now/Next on tiles, full schedule in detail; configurable interval/hour/past/forecast windows; Re-match-all button
- Background refresh via WorkManager; stored in a **separate `epg.sqlite`** (WAL-checkpointed) so large writes never block search

### Networking & Diagnostics
- **DNS-over-HTTPS resolver** (experimental, off by default) — resolves portal/API hosts through a DoH provider so a DNS-blocked portal still works
- Connection-setup timing diagnostic (DNS / TCP / TLS phase breakdown) to pinpoint slow channel starts
- **Report an issue** — in-app diagnostic reporter that submits a scrubbed, redacted log (no credentials, no stream URLs) straight from Settings
- Search-performance self-test tooling for very large sources

### Safe mode
- Unified adult filter: a single indexed flag set at import from the provider's `is_adult` **or** the built-in keyword list

### Backup & Restore
- JSON export of settings + sources, including EPG assignments/overrides
- Selective per-channel restore (favorites, history, EPG IDs, overrides) applied after refresh
- Hardened import: old or hand-edited backups are validated/clamped so they can't crash settings screens, and sensitive values are redacted from exported logs

### Settings — collapsible groups
Expandable groups to reduce scrolling: **Default view**, **Playback**, **Buffering**, **Multi-view**,
**Content**, **EPG**, **Diagnostics**, **Backup & Restore**, **Reset**, **App**, **Sources**.

### Android TV
- Full D-pad navigation; focus-aware grid/menus/dialogs; dedicated TV home with side menu
- **Live guide hero preview** — dwell on a channel in the TV guide and a muted live preview starts inline (single engine, never more than one provider connection)
- **Voice search** via the remote's speech recognizer, plus a hardware search-key shortcut from any screen
- Guide genre color stripes, channel logos with initials fallback, and branded poster fallbacks
- Optional **1080p render cap** for low-RAM 4K boxes (applied at launch)
- **LAN export** (QR + port 9479) serves source dump, debug log, and settings — each individually plus a combined zip

### Updates
- Built-in update check against `version.json` with a "what's new" summary
- **In-app auto-update**: one-tap download of the new APK and launch the installer
- **Per-ABI releases** — separate arm64, arm, x86_64, and universal APKs; the updater automatically picks the right one for your device

---

## Installation

Download the latest APK from [GitHub Releases](https://github.com/rkinnc75/Free4Me-IPTV/releases)
and sideload it onto your Android device or Android TV. Each release ships four builds —
**arm64** (most modern phones), **arm** (older 32-bit devices and many TV boxes),
**x86_64** (emulators and x86 devices), and **universal** (works everywhere, larger download).
When in doubt, pick **universal** — or just use the in-app updater, which chooses for you.

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

This fork adds Android TV support, ExoPlayer, Chromecast, dual-stream PiP, catchup/time-shift,
scheduled recording with MP4 remux, content-type cycling, consistent multi-key sort,
persistent stream validation, favorite categories, live-TV-only multi-view,
advanced/incremental EPG with a separate database, unified safe mode, in-app auto-update
with per-ABI builds, LAN export bundles, and many reliability and performance improvements.
Released under the original project's license.
