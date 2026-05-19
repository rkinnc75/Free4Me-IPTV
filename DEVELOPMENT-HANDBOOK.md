# Free4Me-IPTV — Post-v1 Development Handbook

**Intended audience:** A coding AI (Cursor / Claude Code / similar) working on the project on macOS, with the user.

**Prerequisite:** v1 of Free4Me-IPTV must be built and verified working on a real Android device. Do not start v1.1+ work until v1 builds and installs cleanly.

---

## Model selection — IMPORTANT, read first

This project mixes Flutter/Dart, native Android Kotlin, SQLite migrations, streaming XML parsing, and media engine integration. No single model is best at all of these. **The runbook explicitly specifies which model to use per task.** Switch the active model in Cursor (or your IDE) before starting each task.

### Default model
**Claude Sonnet 4.6** — use this as the baseline unless a task below says otherwise. Best cost/quality ratio for the bulk of the work.

### Escalation models
- **Claude Opus 4.7** — architectural design, hard debugging, anything memory-sensitive or with subtle correctness traps
- **GPT-5 / GPT-5 Codex** — native Android Kotlin work, Cast SDK, Gradle/AGP build errors Claude can't resolve in two tries
- **Composer 2.5** — mechanical pattern-following (UI tiles mirroring existing ones, applying clean patches)

### Why this matters
The cost difference between Opus and Composer is roughly 50× per token. Using Opus on settings sliders wastes budget; using Composer on the XMLTV parser ships broken code. Match the model to the task complexity.

### Quick decision tree
- **Is this architectural design or hard debugging?** → Opus 4.7
- **Is this Kotlin/native Android/Cast SDK/Gradle?** → GPT-5
- **Is this pure pattern-matching against existing code in the same file?** → Composer 2.5
- **Anything else?** → Sonnet 4.6

---

## Project context (recap)

- **Original:** [Fredolx/fred-tv-mobile](https://github.com/Fredolx/fred-tv-mobile) — Flutter IPTV app using `media_kit` (libmpv)
- **Fork:** Free4Me-IPTV
- **Package ID:** `me.free4me.iptv`
- **Internal Dart package name:** still `open_tv` (intentional — avoids rewriting hundreds of imports)
- **Signing:** debug key (upstream behavior)
- **Distribution:** sideload only via GitHub releases
- **User profile:** personal use, optimized for US English content, primary device is Android TV
- **All upstream credits preserved:** Fredolx donation links, issue tracker references, original copyright

### What v1 already includes
- Rebrand (app ID, package, launcher, manifest)
- Player reliability: timeout-bounded `open()`, buffer config, reconnect on error/buffering, HW decode, connectivity awareness, awaited position save
- HTTP layer: shared `AppHttp` client with retry, streaming M3U download
- Settings cache: in-memory `_cached` Settings, no repeated disk reads
- DB fix: `Sql.updateGroups()` SQL bug fixed
- FTS5 search with trigram tokenizer
- Pre-warm URL resolution on D-pad focus for livestreams
- New Settings UI section "Buffering (Android TV)" with sliders/toggles
- Version 1.4.2+12

---

## v1.1 — Quality of Life (~2 hours session work)

### Model Plan
| Step | Model | Why |
|---|---|---|
| Update checker (HTTP fetch, semver compare, dialog) | **Sonnet 4.6** | Standard Flutter work, no traps |
| Settings backup/restore (JSON serialization) | **Sonnet 4.6** | Standard pattern, but watch for credentials handling |
| Error message humanization (string mapping) | **Composer 2.5** | Pure pattern work |
| Settings UI tiles for new features | **Composer 2.5** | Mirror existing `_bufferSlider` pattern |
| Setting help tooltips | **Composer 2.5** | Pure pattern work; copy is pre-written below |

### Files touched
- `lib/main.dart` (update check on launch)
- `lib/backend/update_checker.dart` (**NEW**)
- `lib/backend/settings_io.dart` (**NEW** — backup/restore)
- `lib/settings_view.dart` (add "Backup & Restore" section, "Check for updates" button, help icons on every setting row)
- `lib/error.dart` (humanize error messages)
- `lib/player.dart` (use friendlier error labels in overlay)
- `lib/widgets/setting_help_dialog.dart` (**NEW** — reusable help dialog widget)

### Feature: in-app update check

**Behavior:** On app launch, fetch a `version.json` from GitHub Pages. Compare semver. If remote > local, show a non-blocking dialog: "Update available: vX.Y.Z. [Download] [Skip]".

**JSON shape** (host this yourself):
```json
{
  "latest": "1.2.0",
  "releaseUrl": "https://github.com/<user>/free4me-iptv/releases/tag/v1.2.0",
  "minSupportedAndroidApi": 21,
  "criticalUpdate": false,
  "releaseNotes": "Added EPG support."
}
```

**Implementation notes:**
- URL is a constant in `update_checker.dart` — replace placeholder with actual GitHub raw URL after first release
- Cache last-checked timestamp; don't check more than once per 12 hours
- Use existing `AppHttp.getWithRetry` with 5-second timeout — never block app startup more than 5 seconds
- If check fails (offline, 404, malformed JSON): fail silent, just log

### Feature: settings backup/restore

**Behavior:**
- Settings → Backup & Restore section
- "Export to file" button → writes JSON to user-selectable location via `file_picker`
- "Import from file" button → reads JSON, confirms with dialog showing what will be replaced, applies

**JSON shape:**
```json
{
  "schemaVersion": 1,
  "exportedAt": "2026-05-19T01:24:00Z",
  "appVersion": "1.1.0",
  "sources": [ /* full Source rows */ ],
  "settings": { /* full Settings object */ },
  "favorites": [ /* channel names */ ],
  "history": [ /* recent channel names */ ]
}
```

**Implementation notes:**
- `file_picker` is already in pubspec
- On import, run inside a transaction; rollback on any error
- Validate `schemaVersion` — refuse import if newer than app supports
- Omit Xtream passwords from export by default; warn user with an opt-in "Include credentials"

### Feature: humanized error messages

**Replace common patterns:**
| Current | Replace with |
|---|---|
| `SocketException` / `TimeoutException` | "Cannot reach server — check your internet connection" |
| `HttpException 401/403` | "Authentication failed — check your username and password" |
| `HttpException 404` | "Stream or playlist not found — provider may have changed URLs" |
| `HttpException 5xx` | "Provider's server is down — try again in a few minutes" |
| `FormatException` on M3U parse | "Playlist file is malformed — verify the URL is correct" |
| mpv open failure | "Stream codec or format not supported by this player" |
| mpv buffering watchdog | "Stream is not responding — reconnecting..." |

**Implementation:** Add a `friendlyMessage` static method to `lib/error.dart` that takes an exception and returns a user-readable string.

### Feature: setting help tooltips

**Behavior:** Every setting row in `settings_view.dart` gets a small `?` icon (Info outlined icon, 18 px) placed at the trailing edge of the row title. Tapping the icon — **or tapping the title/label text itself** — opens a modal dialog with the setting's name and a detailed explanation. This must work on both touch screens and D-pad (TV remote); the `?` icon must be D-pad focusable.

**Widget to create — `lib/widgets/setting_help_dialog.dart`:**
```dart
/// Call from any GestureDetector or InkWell wrapping a setting label.
static void show(BuildContext context, {required String title, required String body}) {
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(body)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Got it')),
      ],
    ),
  );
}
```

**How to add to each setting row in `settings_view.dart`:**
- Wrap the existing `ListTile` title `Text` in a `Row` that appends an `IconButton(icon: Icon(Icons.info_outline, size: 18), onPressed: () => SettingHelpDialog.show(...))`.
- Also wrap the full `ListTile` (or `InkWell` parent if one exists) with `onTap` calling the same dialog so tapping the label text works too.
- On Android TV the `IconButton` must have its own `FocusNode` so the D-pad can reach it independently from the switch/slider control.

**DO NOT invent copy.** Use exactly the strings in the table below. If a setting is added in a future version and is not yet in this table, leave a `// TODO: add help copy` comment and open a Jira task.

The table covers every setting row in `settings_view.dart` in display order. Defaults and slider ranges are sourced directly from `lib/models/settings.dart` and the slider widget parameters — do not guess them.

---

#### Help copy for every setting (complete — 14 settings)

| Setting key | Dialog title | Dialog body |
|---|---|---|
| `defaultView` | Default View | Which content type the app opens to when you launch it. **All** shows everything — livestreams, movies, and series together. **Livestreams** jumps straight to live TV. **Movies** or **Series** opens that section directly. Choose whichever you use most so you never have to navigate after launch. |
| `forceTVMode` | Force TV Mode | Overrides automatic device detection and always shows the TV-optimized layout — larger tiles, D-pad navigation, no on-screen keyboard shortcuts. Turn ON if the app incorrectly starts in phone/tablet mode on your Android TV box. Turn OFF to use the touch-friendly layout on any device. Default: OFF. |
| `lowLatency` | Low Latency (Live TV) | Tells the player to prefer the lowest-quality HLS variant instead of the highest. Turn ON to reduce the delay between broadcast and playback — useful for live sports where score spoilers matter. Turn OFF for the best picture quality. Has no effect on non-HLS streams (MPEG-TS, RTMP, etc.). Default: OFF. |
| `refreshOnStart` | Refresh Sources on Start | Automatically re-downloads all your M3U playlists and Xtream channel lists every time the app launches. Turn ON if your provider changes channel URLs frequently and you want the freshest list without tapping Refresh manually. Turn OFF to start faster — you can still refresh at any time from the Sources section. Default: OFF. |
| `showLivestreams` | Show Livestreams | Controls whether live TV channels appear anywhere in the app — in the channel grid, search results, and the "All" view. Turn OFF to hide live TV entirely if your source only contains movies and series. Hiding a type does not delete channels; they reappear if you turn the setting back on. Default: ON. |
| `showMovies` | Show Movies | Controls whether on-demand movies appear in the channel grid, search results, and "All" view. Turn OFF to hide the movie library if you only use the app for live TV. Default: ON. |
| `showSeries` | Show Series | Controls whether TV series and episodes appear in the channel grid, search results, and "All" view. Turn OFF to hide series content if you do not use that section. Default: ON. |
| `hwDecode` | Hardware Decoding | Uses your device's dedicated video-decoder chip (MediaCodec) instead of the CPU. Turn ON (recommended for Android TV) — reduces heat and CPU load and allows 4K/HEVC streams to play smoothly on most boxes. Turn OFF only if you see video corruption, a green screen, or playback failures; some older or budget chipsets have buggy hardware decoders. Default: ON. |
| `preWarmOnFocus` | Pre-warm Streams on Focus | Resolves redirect URLs in the background the moment you highlight a channel tile with the D-pad, so playback starts noticeably faster when you press OK/Enter. Turn ON for snappier channel switching. Turn OFF if you are on a metered connection or notice unwanted network activity while browsing. Default: ON. |
| `liveCacheSecs` | Livestream Cache (seconds) | How many seconds of live TV the player keeps in its read-ahead memory buffer. **Increasing** reduces rebuffering on unstable connections and adds a small rewind window. **Decreasing** lowers RAM use — useful on 1–2 GB Android TV boxes. Too high a value on a slow stream can cause audio/video sync drift. Default: 20 s. Slider range: 5–60 s. |
| `liveDemuxerMaxMB` | Livestream Demuxer Buffer (MB) | Maximum RAM the stream-splitter (demuxer) may use while playing live TV. **Increasing** prevents dropped frames on high-bitrate 4K or HEVC streams by giving the decoder a larger in-memory cushion. **Decreasing** frees RAM — reduce this first if the app is killed by the system on a low-memory box. Default: 150 MB. Slider range: 32–512 MB. |
| `vodCacheSecs` | VOD/Movie Cache (seconds) | How many seconds ahead the player reads from a movie or on-demand stream into memory. **Increasing** reduces pauses during seek (fast-forward/rewind) and smooths playback on slow connections. **Decreasing** lowers RAM use. Has no effect on live TV streams. Default: 60 s. Slider range: 10–180 s. |
| `vodDemuxerMaxMB` | VOD/Movie Demuxer Buffer (MB) | Maximum RAM the demuxer may use while playing a movie or series episode. **Increasing** improves seek performance and reduces pauses on high-bitrate VOD (Blu-ray remuxes, 4K). **Decreasing** frees memory. Has no effect on live TV streams. Default: 256 MB. Slider range: 64–1024 MB. |
| `openTimeoutSecs` | Stream Open Timeout (seconds) | How long the player waits for a stream to begin playing before giving up and showing an error. **Increasing** gives slow or geographically distant servers more time to respond — helpful on congested networks or with international streams. **Decreasing** makes failures surface faster so the app can retry or show an error sooner. Default: 15 s. Slider range: 5–60 s. |
| `bufferingWatchdogSecs` | Buffering Watchdog (seconds) | If a live stream stalls in a buffering/loading state for longer than this value, the player automatically disconnects and reconnects. **Increasing** gives the server more time to recover on its own — better on intermittent connections where a brief stall self-resolves. **Decreasing** forces a reconnect sooner, which helps with streams that silently freeze without ever recovering. Default: 12 s. Slider range: 5–60 s. |

---

**Implementation notes:**
- The dialog is informational only — it must never modify state.
- On Android TV the dialog must be dismissible with the Back button (default `AlertDialog` behavior satisfies this).
- Keep the `?` icon subtle — use `Theme.of(context).colorScheme.onSurface.withOpacity(0.4)` so it does not compete visually with the setting control.
- All copy in the table above is final. Do not paraphrase, shorten, or reword without asking the user.
- The "Donate" row and the "Sources" section header are **not** settings — they do not get a `?` icon.
- Note: the table has 14 rows but `defaultView` opens its own selection dialog rather than a switch/slider, so its `?` icon sits beside the subtitle text (the current view name), not a trailing control.

### Acceptance criteria
- [ ] App launch checks for updates once, fails silently if offline
- [ ] Settings → Backup & Restore exports a valid JSON file
- [ ] Importing a previously-exported file restores the exact same state
- [ ] At least 5 common error scenarios show friendly messages instead of stack traces
- [ ] Tapping any setting label **or** its `?` icon opens the correct help dialog
- [ ] All 14 help dialogs contain exactly the copy from the table above
- [ ] Dialogs are dismissible with Back button on Android TV remote
- [ ] `?` icon is D-pad focusable independently of the setting's switch/slider
- [ ] Donate row and Sources section header have no `?` icon
- [ ] No regression in v1 functionality

---

## v1.2 — EPG / Electronic Program Guide (~5–6 hours session work)

### Model Plan
| Step | Model | Why |
|---|---|---|
| Streaming XMLTV parser (`xmltv_parser.dart`) | **Opus 4.7** | Hardest task in the roadmap. Memory-sensitive. |
| DB schema + migration #5 + indexes | **Opus 4.7** | Hard to reverse once data exists |
| Channel matcher heuristics (`epg_matcher.dart`) | **Opus 4.7** | Lots of edge cases |
| Xtream EPG fetcher (`xtream_epg.dart`) | **Sonnet 4.6** | Mostly wiring |
| Refresh service + workmanager setup | **GPT-5** | Native Android background work |
| Sql.dart CRUD for programs | **Sonnet 4.6** | Standard SQL work |
| Now/Next strip widget | **Sonnet 4.6** | Query-driven UI |
| Channel schedule view | **Sonnet 4.6** | ListView builder + date formatting |
| Settings UI for EPG section | **Composer 2.5** | Mirror existing slider/switch tiles |
| Manual channel mapping UI | **Sonnet 4.6** | Custom UI flow |

**Critical:** Do NOT use Composer 2.5 or Sonnet for the XMLTV parser. The 466 MB file size requires careful streaming.

### User-locked defaults & ranges (DO NOT CHANGE WITHOUT ASKING)

| Setting | Default | User-adjustable range |
|---|---|---|
| `epgPastDays` | **1** | 0–3 |
| `epgForecastDays` | **7** | 3–14 |
| `epgRefreshHours` | **24** | 6–48 |
| `epgRefreshHour` | **3** (03:00 local) | 0–23 |
| `epgAutoRefresh` | **true** | toggle |

### Critical implementation requirements

#### Streaming XMLTV parser
Reference feed (iptv-epg.org/files/epg-us.xml) is **466 MB uncompressed, 56 MB gzipped, 1.03M programs**. Cannot DOM-parse on a 1–2 GB RAM Android TV box.

**Required approach:**
- Use `package:xml`'s `XmlEventDecoder` for event-stream parsing
- Stream from `AppHttp.sendStreaming()` → through gzip decoder → through event decoder
- **Filter by date window during parse**, not after insert
- Batch inserts in 1000-row transactions
- Throw away `<icon>` URLs to save DB space
- Emit `RefreshProgress` stream for UI progress display

**Expected outcome for the US feed:** 1.03M programs → ~50–70k after window filter → ~15–20 MB DB growth → 30–60 second refresh.

#### Channel matching (tiered)
1. Exact `tvg-id` match
2. Normalized name match (strip HD/4K/FHD/+1/dots/case)
3. `tvg-id` with stripped regional suffix (`.us`, `.sxm`, etc.)
4. Unmatched → user can manually map in settings

Expected match rate: 60–80% automatic.

#### Database schema (migration #5)

```sql
ALTER TABLE sources ADD COLUMN epg_url TEXT;
ALTER TABLE channels ADD COLUMN epg_channel_id TEXT;
ALTER TABLE channels ADD COLUMN epg_manual_override TEXT;

CREATE TABLE programmes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  epg_channel_id TEXT NOT NULL,
  source_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  category TEXT,
  start_utc INTEGER NOT NULL,
  stop_utc INTEGER NOT NULL,
  episode_num TEXT,
  FOREIGN KEY(source_id) REFERENCES sources(id) ON DELETE CASCADE
);
CREATE INDEX idx_programmes_channel_time ON programmes(epg_channel_id, source_id, start_utc);
CREATE INDEX idx_programmes_time_range ON programmes(source_id, start_utc, stop_utc);

CREATE TABLE epg_refresh_log (
  source_id INTEGER PRIMARY KEY,
  last_refreshed_utc INTEGER NOT NULL,
  programs_loaded INTEGER NOT NULL,
  last_error TEXT,
  FOREIGN KEY(source_id) REFERENCES sources(id) ON DELETE CASCADE
);
```

### Acceptance criteria
- [ ] Refresh completes in under 90 seconds with default 7-day window
- [ ] DB size after refresh is under 25 MB
- [ ] Channel tiles show "Now: X · Next: Y" for matched channels
- [ ] Channels without EPG show no strip
- [ ] Manual override persists and shows EPG on next view
- [ ] Refresh failure logs error to `epg_refresh_log` without crashing

---

## v1.3 — Catchup / Timeshift (~2–3 hours session work)

### Model Plan
| Step | Model | Why |
|---|---|---|
| M3U `catchup-*` attribute parser additions | **Sonnet 4.6** | Extend existing M3U parser |
| Xtream `tv_archive` flag wiring | **Sonnet 4.6** | Add field to existing model |
| Catchup URL template substitution | **Opus 4.7** | Many provider variants; subtle date-format bugs |
| Channel schedule view button logic | **Sonnet 4.6** | Conditional UI work |

### Files touched
- `lib/models/channel.dart` (add `catchupType`, `catchupSource`, `catchupDays`)
- `lib/backend/m3u.dart` (parse `catchup` / `catchup-source` / `catchup-days` M3U attributes)
- `lib/backend/xtream.dart` (use `tv_archive` flag from Xtream live streams)
- `lib/backend/catchup_url.dart` (**NEW** — URL template substitution)
- `lib/views/channel_schedule.dart` (add "Watch from beginning" button on past programs)
- `lib/widgets/now_next_strip.dart` (add tap → schedule view)

### Catchup URL formats

**Xtream:**
```
http://{host}:{port}/streaming/timeshift.php?username={u}&password={p}&stream={id}&start={Y}-{m}-{d}:{H}-{M}&duration={duration_minutes}
```

**M3U `catchup-source` variables:**
`{Y}` `{m}` `{d}` `{H}` `{M}` `{S}` `{utc}` `{duration}` `${start}` `${end}` `${timestamp}`

### Acceptance criteria
- [x] Xtream `tv_archive=1` channels show catchup buttons on past programs
- [x] M3U `catchup-source` channels show catchup buttons (within `catchup-days`)
- [x] Channels without catchup support show no button on past programs
- [x] Catchup playback works through existing `Player` widget (`overrideUrl` param) without engine changes

### Shipped in 1.7.0+20

- DB migration #6: `channels.catchup_type` / `catchup_source` / `catchup_days`
- `Channel.supportsCatchup` helper, populated by both M3U and Xtream loaders
- Xtream loader maps `tv_archive` → `catchup_type='xc'`, `tv_archive_duration` → `catchup_days`
- `lib/backend/catchup_url.dart` builds URLs for `xc` / `append` / `shift` / `default` / `flussonic` engines and respects the `catchup-days` window
- `lib/views/channel_schedule.dart` shows a "Watch from beginning" trailing button on past/now programs when catchup is available, and adds it to the details dialog
- `lib/widgets/now_next_strip.dart` accepts an `onTap` callback; `channel_tile.dart` wires it to push `ChannelScheduleView` (eats the gesture so tap-to-play still works elsewhere on the tile)
- `Player` gained an optional `overrideUrl` so catchup URLs play without touching the live URL or the prewarm cache

### Fuzzy matcher refinement (also shipped in 1.7.0+20)

- `lib/backend/epg_matcher.dart`: tiers 5–7 (token-superset, callsign, Jaccard) now **skip the match entirely** when two or more candidates tie for the best score / length. Better unmatched than wrong. Added a new `MatchTier.ambiguous` so telemetry distinguishes "no candidate" from "too many candidates".

---

## v1.4 — ExoPlayer + Chromecast (~3 hours session work)

### Model Plan
| Step | Model | Why |
|---|---|---|
| `PlayerEngine` abstract interface | **Opus 4.7** | Architectural — affects every other v1.4 file |
| Refactor `player.dart` into `mpv_engine.dart` | **Opus 4.7** | Extract-without-breaking-v1 |
| New `exo_engine.dart` implementation | **Sonnet 4.6** | Mirror the mpv_engine shape |
| Engine picker / routing logic | **Sonnet 4.6** | Conditional logic; well-defined |
| `CastOptionsProvider.kt` (native Kotlin) | **GPT-5** | Native Android; Cast SDK |
| AndroidManifest Cast meta-data + Gradle deps | **GPT-5** | Build-system work |
| Cast session UI (button, mini-player, disconnect) | **Sonnet 4.6** | Flutter UI work |
| Settings UI for engine selection | **Composer 2.5** | Mirror existing patterns |
| Per-channel engine override in DB | **Sonnet 4.6** | Migration + model field |

### Engine selection logic
```dart
EngineType pick(Channel channel, Source source, Settings settings) {
  if (channel.engineOverride != null) return channel.engineOverride!;
  if (settings.forcedEngine != null) return settings.forcedEngine!;
  if (source.defaultEngine != null) return source.defaultEngine!;

  final url = (channel.url ?? '').toLowerCase();
  if (url.contains('.m3u8')) return EngineType.exoplayer;
  if (url.contains('.mpd')) return EngineType.exoplayer;
  if (url.endsWith('.mp4')) return EngineType.exoplayer;

  return EngineType.libmpv;
}
```

### Chromecast specifics
- Requires Google Play Services — detect and hide Cast button if unavailable
- Default Media Receiver (ID `CC1AD845`) — supports HLS, DASH, MP4 only
- Show snackbar if user tries to cast a libmpv channel: "This stream format isn't supported on Chromecast"
- On disconnect, resume local playback at Cast-reported position

### Acceptance criteria
- [ ] HLS livestream plays via ExoPlayer by default
- [ ] MPEG-TS livestream plays via libmpv by default
- [ ] Manual engine override (per-channel) works and persists
- [ ] Cast button appears on devices with Play Services, hidden otherwise
- [ ] Casting an HLS stream to a Chromecast plays on the TV
- [ ] Casting an MPEG-TS stream shows the "not supported" snackbar

---

## v1.5 — EPG Grid View (~3–4 hours, OPTIONAL)

### Model Plan
| Step | Model | Why |
|---|---|---|
| Grid layout architecture (virtual scrolling) | **Opus 4.7** | Complex stateful UI; performance-sensitive |
| Programme block rendering | **Sonnet 4.6** | Widget work |
| Timeline header / time axis | **Sonnet 4.6** | Custom paint or row of containers |
| D-pad navigation handling | **Opus 4.7** | Focus management on Android TV is fiddly |
| Category filter UI | **Sonnet 4.6** | Existing pattern |
| Tap-to-action routing | **Sonnet 4.6** | Reuses v1.2 + v1.3 logic |

### Files touched
- `lib/views/epg_grid.dart` (**NEW**)
- `lib/widgets/programme_block.dart` (**NEW**)
- `lib/widgets/timeline_header.dart` (**NEW**)
- `lib/tv_home.dart` (add "Guide" button)
- `lib/bottom_nav.dart` (add Guide entry)

### Critical UX requirements
- D-pad: left/right scrubs timeline, up/down moves channels
- 30-minute slots, 6-hour window visible at once
- Auto-scroll to "now" line on open
- Long-press a programme → details dialog with full description
- Only render visible programs (virtual scrolling)
- Skip unless you've lived with v1.2's now/next strip for a few weeks and genuinely miss the grid

### Acceptance criteria
- [ ] Grid opens in under 2 seconds with 200+ channels loaded
- [ ] D-pad navigation is smooth (no dropped frames on Android TV)
- [ ] Tapping a programme launches the correct action (live/catchup/info)
- [ ] Scrolling 24 hours forward and back works without crash
- [ ] Filter by category works

---

## Cross-cutting guidance

### Build & deploy workflow
After every version:
```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export PATH="/Users/rich.kalsky/tools/flutter/bin:$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$HOME/Library/Android/sdk"
cd /Users/rich.kalsky/git/free4me-iptv
flutter pub get
flutter analyze --no-fatal-warnings
flutter build apk --release --split-per-abi
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

### What NOT to change without asking the user
- The Dart package name `open_tv`
- The Android package ID `me.free4me.iptv`
- Upstream Fredolx credit/donation links
- The 1-day-past + 7-day-forward EPG defaults
- Debug signing
- The buffer-config slider ranges in Settings

### When something doesn't compile
1. `flutter analyze` first
2. Check for missing imports (most common AI code issue)
3. `flutter clean && flutter pub get` if build cache is stale
4. For native (Kotlin) errors: check that package declaration matches file path
5. For Cast issues: check Play Services version on test device first

### Model escalation when stuck
- **Dart/Flutter errors** → Opus 4.7
- **Kotlin/Gradle/AGP errors** → GPT-5
- **Logic errors or "it compiles but runs wrong"** → Opus 4.7

### v1 regression policy
v1 is the foundation. If v1 regresses while adding v1.1+, **stop and fix the regression first**.

---

## Credits

Fork of **[Fredolx/fred-tv-mobile](https://github.com/Fredolx/fred-tv-mobile)**. All upstream donation links, issue trackers, and copyright notices preserved in source.
