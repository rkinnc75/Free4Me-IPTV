# AGENTS.md — Free4Me-IPTV AI Session Guide

**Read this first.** Every new agent session should start here.

Related docs:
- [`CLAUDE-WORKFLOW.md`](CLAUDE-WORKFLOW.md) — how Claude ships releases (mobile vs Cowork vs Cursor; CI pipeline; bootstrap state; failure recovery).
- [`BUILD-ENV.md`](BUILD-ENV.md) — host-Mac build environment that CI mirrors.
- [`AGENT-HANDOFF-v1.15.7.md`](AGENT-HANDOFF-v1.15.7.md) — codebase patterns + invariants captured at the v1.15.7 boundary.
- [`DEVELOPMENT-HANDBOOK.md`](DEVELOPMENT-HANDBOOK.md) — original feature plan and copy strings.

---

## Current state at a glance

| Item | Value |
|---|---|
| Latest release | **v1.18.3+86** (refer to git tags for absolute current state — this line is not auto-updated by the release script) |
| GitHub releases | https://github.com/rkinnc75/Free4Me-IPTV/releases |
| `flutter analyze` | **0 issues** |
| Release pipelines | Automated: tag push → `.github/workflows/release.yml`. Manual: `bash scripts/build_and_release.sh` from a Mac. See `CLAUDE-WORKFLOW.md`. |
| Flutter SDK (host Mac) | `/Users/builder/tools/flutter/bin` |
| Dart package name | `open_tv` (intentional — do not rename) |
| Android package ID | `me.free4me.iptv` |
| Signing | release keystore — alias `free4me-iptv` (fix31, v1.17.0+). See `BUILD-ENV.md §4`. |

---

## What has shipped (v1.0 → v1.14.0)

### Core infrastructure (v1.0–v1.1)
- Rebrand from `fred-tv-mobile` → Free4Me-IPTV
- Player reliability: `open()` timeout, buffer config, reconnect, HW decode, connectivity listener
- FTS5 trigram search, pre-warm on D-pad focus
- Settings cache (`SettingsService._cached`), DB key-value store (`INSERT … ON CONFLICT`)
- Update checker (`lib/backend/update_checker.dart`)
- Settings backup/restore (`lib/backend/settings_io.dart`)
- Humanized error messages (`Error.friendlyMessage`)
- Setting help dialogs (`SettingHelpDialog` + `_helpIcon` in every settings row)
- `AppLogger` / `AppLog` — structured file logging, log view in Settings

### EPG (v1.2)
- Streaming XMLTV parser (`lib/backend/xmltv_parser.dart`) — handles 466 MB feeds
- EPG DB tables: `programmes`, `epg_refresh_log`; indexes on channel/time
- Channel matcher — 7 tiers, ambiguous-tie suppression (`MatchTier.ambiguous`)
- Xtream EPG fetcher (`lib/backend/xtream_epg.dart`)
- Workmanager background refresh
- Now/Next strip (`lib/widgets/now_next_strip.dart`)
- Channel schedule view (`lib/views/channel_schedule.dart`)
- `EpgService.downloadAndParseEpg` / `matchChannels` / `refreshSource`
- Re-match all channels button in Settings
- `XmltvProgress` with matched/total channel counts shown after refresh

### Catchup / Timeshift (v1.3 — v1.7.0+20)
- `Channel.catchupType/catchupSource/catchupDays`; M3U + Xtream loaders populate them
- `lib/backend/catchup_url.dart` — URL templates for xc/append/shift/default/flussonic
- "Watch from beginning" button on past programs
- `Player.overrideUrl` for catchup playback without touching live URL

### ExoPlayer + Chromecast (v1.4)
- `PlayerEngine` abstract interface
- `MpvEngine` + `ExoEngine` implementations
- `EnginePicker` — auto-selects by URL extension; per-channel override in DB
- `CastController` — Chromecast session management; hidden when Play Services absent
- Settings tile for global engine override
- **fix16 (v1.13.4):** `Player.clearCooldown()` static method; `_swapEngine()` helper;
  engine subscriptions refactored into re-callable `_subscribeEngineStreams()`

### PIP / Mini-player (v1.x)
- `OverlayPlayerController` — singleton managing the floating mini-player
- `OverlayPlayerWidget` — draggable overlay with maximize / swap / close
- `Player.clearCooldown()` called on `_maximize()` and `_swap()` to clear stale give-up records

### Player quality (v1.5–v1.13)
- Stability threshold / give-up cooldown / `_recentGiveUps` static map
- Buffering watchdog, startup grace window (`startupGraceMs`)
- `_buildBufferingOverlay` — terminal states show "Go back" button, no spinner
- ExoPlayer → libmpv one-shot fallback on Source error
- `mediacodec-copy` for Android TV; `videotoolbox` for iOS; `no` otherwise
- `fix13.md` (Shield audio-black-screen fix) — shipped in `mpv_engine.dart`

### Source management (v1.12)
- Auto-correct URL format on source entry
- Progress indicator during source submission
- Optional EPG URL field on source entry
- Enable/Disable per source (Switch in settings, Opacity dim when disabled)

### History
- Long-press → "Remove from history" menu option
- `Sql.deleteHistoryEntry(channelId)` sets `last_watched = NULL`

### Stream scanner (v1.12.2 → v1.13.4)
- `StreamScanner` — HTTP probe with media-byte validation
  (MPEG-TS sync bytes, HLS `#EXTM3U`, MP4 `ftyp`, DASH `<MPD`)
- HTML/JSON/plain-text content-type fast-fail (fix15)
- HLS detection via URL substring `m3u8` + Content-Type (fix15)
- `ValueNotifier` progress dialog (reliable counter updates)
- Configurable max count (1–100) and timeout (3–30 s) in Settings
- Green border on passing channel tiles

### Multi-view (v1.14.0)
- `MultiViewLayout` enum (`none / oneByTwo / twoByTwo`)
- Visual picker dialog (`MultiViewPickerDialog`) from Settings
- `MultiViewScreen` — 1×2 `Row` or 2×2 `GridView`
- `MultiViewCell` — independent `MpvEngine`, generation token, retry button
- `ChannelPickerScreen` — standalone slim channel search, returns `Channel` via pop
- Cell assignments persist across exits (comma-separated IDs in Settings)
- `MpvEngine.previewMode` — 32 MB buffer, forced software decode
- `Sql.getChannelById(int id)` — fetch single channel by primary key
- Grid icon in Home toolbar (visible only when layout ≠ none)

### Logging (v1.13.3)
- `SettingsService.maybeRotateLogOnVersionChange()` — clears log on first boot of new version
- Log view and log-export in Settings

---

## Pending / next phases

### ✅ Multi-view P6 — EPG strip per cell (v1.15.2)
Implemented: `_buildInfoBar()` in `MultiViewCell` renders a gradient bottom bar with
channel name + `NowNextStrip` (existing widget, reused). Shows "▶ Now: title  •  Next HH:MM: title"
for livestreams that have EPG data. Silent for cells without EPG or non-livestream channels.

---

### ✅ Multi-view P5 — Audio focus coexistence (v1.15.1)
Implemented: `audio_session` package, `AudioSession.instance` configured for video
playback in `MultiViewScreen`. Interruption events (calls, Siri) mute all cells by
flipping `_interrupted` flag; volume is restored when interruption ends.

### ✅ Multi-view P7 — PIP/overlay coexistence (v1.14.1)
Implemented: `OverlayPlayerController.instance.stopOverlay()` called in `_openMultiView()`
before pushing `MultiViewScreen`. Mini-player buttons gated on
`multiViewLayout == MultiViewLayout.none`.

---

## Key files map

| Area | File(s) |
|---|---|
| Player | `lib/player.dart`, `lib/player/mpv_engine.dart`, `lib/player/exo_engine.dart` |
| Player engine contract | `lib/player/player_engine.dart` |
| Engine selection | `lib/player/engine_picker.dart` |
| PIP / overlay | `lib/player/overlay_player_controller.dart`, `lib/player/overlay_player_widget.dart` |
| Multi-view | `lib/multi_view_screen.dart`, `lib/multi_view_cell.dart`, `lib/channel_picker_screen.dart` |
| Stream scanner | `lib/backend/stream_scanner.dart` |
| EPG | `lib/backend/epg_service.dart`, `lib/backend/xmltv_parser.dart`, `lib/backend/xtream_epg.dart`, `lib/backend/epg_matcher.dart` |
| Source setup wizard | `lib/setup.dart` |
| Settings | `lib/settings_view.dart`, `lib/models/settings.dart`, `lib/backend/settings_service.dart` |
| Database | `lib/backend/sql.dart` |
| Logging | `lib/backend/app_logger.dart` |
| Home / search | `lib/home.dart`, `lib/channel_tile.dart` |
| Navigation | `lib/bottom_nav.dart`, `lib/models/app_navigator.dart` |
| Channel model | `lib/models/channel.dart` |
| Source model | `lib/models/source.dart` |

---

## Build runbook

```bash
# Environment (run once per terminal session)
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export PATH="/Users/builder/tools/flutter/bin:$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$HOME/Library/Android/sdk"

# Daily checks
cd /Users/builder/git/free4me-iptv
flutter pub get
flutter analyze            # must be 0 issues before shipping

# Build only
flutter build apk --release --split-per-abi
# → build/app/outputs/flutter-apk/app-arm64-v8a-release.apk

# Build + tag + GitHub release (automated)
bash scripts/build_and_release.sh
# Script bumps pubspec version, builds, tags, and creates GH release
```

**Before every release:**
1. `flutter analyze` → 0 issues
2. Bump `version: X.Y.Z+N` in `pubspec.yaml`
3. Add changelog entry to `lib/whats_new_modal.dart` (`_changelog` map, newest key first)
4. `bash scripts/build_and_release.sh`

**Commit message convention (rule: git_commits.mdc):**  
`PO-XXXXX Verb Subject` — imperative, ≤72 chars, Jira key required (except docs/tests).  
Example: `PO-11412 Add multi-view grid layout`

---

## Rules that always apply (workspace rules)

| Rule | Effect |
|---|---|
| `db-read-only-by-default.mdc` | Never write to DB without explicit user consent per operation |
| `fail-fast-no-fallbacks.mdc` | No silent fallbacks; throw / fail loud on missing required data |
| `feature-documentation.mdc` | Update docs when adding features — update AGENTS.md if new docs added |
| `git_commits.mdc` | Jira key required on commit subjects |
| `sql-switch-client-context.mdc` | Use unqualified names after `set_client`; add filters only when cross-tenant |

---

## Model selection

| Task type | Model |
|---|---|
| Architectural design, hard debugging, memory-sensitive code | **Opus 4.7** |
| Standard Flutter / Dart feature work (default) | **Sonnet 4.6** |
| Native Android Kotlin, Gradle/AGP, Cast SDK | **GPT-5** |
| Mechanical pattern-following (mirror existing tile/slider) | **Composer 2.5** |

---

## Do not change without asking the user

- Dart package name `open_tv`
- Android package ID `me.free4me.iptv`
- Upstream Fredolx credit/donation links
- Default EPG window (1 day past, 7 days forward)
- Release signing identity (alias `free4me-iptv`, fingerprint in `BUILD-ENV.md §4`) — any change forces every existing user to uninstall before updating
- Buffer slider ranges in Settings
