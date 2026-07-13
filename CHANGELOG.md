# Changelog

All notable changes to Free4Me-IPTV are documented here.
## [v4.1.40+737] - 2026-07-13

### Changed
- **fix737 — Recordings rows → glass cards (mock §4.9)** — TV Recordings rows now render as token glass cards (fill + stroke + inter-card gap) instead of bare Material list tiles, matching the redesigned surfaces. Phone unchanged.

### Technical
- **fix737**: `recordings_view.dart` `_RecordingTile` TV branch adds `glassFill`/`glassStroke` + margin to the existing fix718 accent-ring `AnimatedContainer`; focus node + held-OK untouched. `test/fix737_recordings_glass_test.dart` (2). Version → 4.1.40+737.

## [v4.1.39+736] - 2026-07-13

**Guide → schedule & record.** TV Live guide.

### Added
- **fix736 — Program guide & record from the guide (mock §4.3)** — the Live guide's channel menu (held-OK) now offers **Program guide & record**, opening the channel's full programme schedule where you can browse upcoming shows, read details, and schedule a recording. (In-grid cell navigation is a separate follow-up; this delivers the capability safely by reusing the proven schedule view + real Scheduled Recording arc.)

### Technical
- **fix736**: `tv_guide_view.dart` held-OK menu adds a live-only `ChannelScheduleView(channel: ch)` push (`RecordingActions.recordProgramme` → `RecordingScheduler.scheduleForProgramme`), avoiding focus-model surgery on the passive (ExcludeFocus, finding 75) dense grid. `test/fix736_guide_schedule_test.dart` (2). Version → 4.1.39+736.

## [v4.1.38+735] - 2026-07-13

**Stability/performance (Peer2-guided).** A/V-desync watchdog → silent resync. Live full-screen only; phone/Shield/VOD/preview unaffected.

### Fixed
- **fix735 — A/V-desync watchdog (Peer2 watchdog→resync, inverted for mpv)** — on a long uninterrupted single-channel session the audio/video could slowly drift out of sync (observed ~36s after ~3.5h on the onn under software decode). Root-caused: a fresh tune opens perfectly synced (avsync≈0) and drifts over hours; a reopen resets it. The player now monitors `avsync` and, on sustained desync of a live, advancing, non-buffering stream, silently reopens to re-sync — with a hold-based backoff so a broken-PTS feed can't reopen-loop.

### Technical
- **fix735**: `MpvEngine` gains an always-on (not debug-gated), live-only `_startAvsyncWatchdog()` — every 6s on a playing/advancing/non-buffering/not-paused-for-cache stream, if `|avsync| > 3s` for 3 consecutive ticks (~18s) it emits `desyncStream`. `player.dart` `_onAvsyncDesync` reopens via the proven `onDisconnect('avsync watchdog')` → fresh live `open()`; 30s debounce; a resync that holds >3min resets the strike count (legit drift correction), else strikes → **terminal** give-up after 3 (`_avsyncGaveUp`; a fresh tune resets). Guarded on `_isReconnecting`/`_isCasting`; also armed in `promoteToFullScreen()` (adopt path). This is the ONLY recovery for a desynced-but-advancing stream (invisible to the buffering/startup watchdogs); ExoPlayer exposes no avsync, so monitoring it is an mpv advantage. Adversarial-reviewed (false-trip + reopen-loop focus → SHIP-WITH-FIXES, all applied). `test/fix735_avsync_watchdog_test.dart` (6). Version → 4.1.38+735.

## [v4.1.37+734] - 2026-07-12

**Gap-audit polish.** TV only. Search field glass + accent ring.

### Changed
- **fix734 — TV search field glass + accent ring (mock §4.5)** — the Search field was a borderless default-filled box; it now uses the token glass fill with a glass-stroke border and an accent focus ring (follows the accent picker).

### Technical
- **fix734**: `tv_search_view.dart` `InputDecoration` → `fillColor` = `F4.of(context).colors.glassFill`, enabled border = `glassStroke`, `focusedBorder` = `AccentScope.of(context)` width 2 (live-recolors via fix719). TV-only view, no `hasTouchScreen` gate. `test/fix734_search_glass_test.dart` (3). Version → 4.1.37+734.

## [v4.1.36+733] - 2026-07-12

**Gap-audit item #4** (largest unbuilt surface). TV only. History is now TV-native.

### Changed
- **fix733 — History tab → TV poster grid (mock §4.5)** — the History tab was still the reused phone `Home` body; it is now a tokenized poster grid of recently-watched channels, matching Movies/Series (source-tint tiles, D-pad focus, play + series drill-in).

### Technical
- **fix733**: new `lib/tv/tv_history_view.dart` — `Sql.search(viewType: history, all media types)` (bounded, cap 200) → `GridView` of `ChannelTile` on the shared spec (maxExtent 130, AR 0.838), reused verbatim (source edge bar, play/drill-in, `isHistory` remove). Empty/error+Retry/loading states; `onRemoveHistory` reloads. `tv_shell.dart` routes `ViewType.history` → `TvHistoryView` in both the initial build and the Clear-history rebuild. `test/fix733_history_grid_test.dart` (4). Version → 4.1.36+733.

## [v4.1.35+732] - 2026-07-12

**Gap-audit item #3.** TV only. Channel-zap shutter.

### Added
- **fix732 — Channel-zap black shutter (mock §4.7)** — a black cover fades out (150ms, easeOut) the instant the first frame renders on a fresh play, masking the black-load so a channel change reads clean instead of flashing.

### Technical
- **fix732**: `MpvEngine` gains a broadcast `firstFrameStream` fired from the existing `dwidth` 0→WxH first-frame observe (`PlayerEngine` default = empty stream). `player.dart` `_buildZapShutter()` is a full-bleed black `AnimatedOpacity(F4Motion.shutter)` above the video / below the buffering spinner; `_showShutter` starts true on a fresh play, cleared on the first-frame event with a 4s fallback timer, and skipped for adopted (already-rendering) swap engines. `test/fix732_zap_shutter_test.dart` (4). Version → 4.1.35+732.

## [v4.1.34+731] - 2026-07-12

**Gap-audit item #2.** TV only. Player OSD now animates instead of snapping.

### Changed
- **fix731 — Player OSD animated fade + token scrim (mock §4.6/§5)** — the TV control overlay fades in/out (crossIn 250ms / crossOut 200ms, easeOut) instead of snapping mount↔unmount, and its scrim is the token `panelSlate` at the `playerMenu` (0.6) alpha instead of a static `black54` gradient.

### Technical
- **fix731**: the overlay is always mounted and wrapped `IgnorePointer(!_navMode) → ExcludeFocus(!_navMode) → AnimatedOpacity → FocusTraversalGroup`; `ExcludeFocus(excluding:true)` keeps the whole subtree (incl. `_overlayFirstFocus`) unreachable while hidden and `Opacity(0)` skips paint, so the hard-won D-pad model + fps are unchanged (verified against the pinned SDK by an adversarial review — verdict SHIP). Follow-up from that review: `active: _navMode` threaded through `PlayerInfoBar` → `PlayerEpgNowLabel` so its 30s `getNowNext` poll pauses while the OSD is hidden. `test/fix731_osd_fade_test.dart` (4). Version → 4.1.34+731.

## [v4.1.33+730] - 2026-07-12

**Mock-vs-code gap audit → first fix.** TV only. An 11-agent audit of `docs/TV_GUI_REDESIGN.md` vs the code found ~28 remaining items; this is the highest-payoff trivial one.

### Fixed
- **fix730 — Settings rail selection accent (mock §4.8)** — the selected row in the Settings two-pane rail followed the seed-blue `colorScheme.primary` instead of the chosen accent, so picking a non-white accent recolored every focus ring but left the Settings selection blue. The selected row background + icon now read `AccentScope`.

### Technical
- **fix730**: `settings_view.dart` `_buildTvRailPane` itemBuilder selected-branch → `AccentScope.of(context)` (bg `withValues(alpha:0.15)` + icon), rebuilding via the fix719 accent notifier. `test/fix730_settings_accent_test.dart` (4). Version → 4.1.33+730.

## [v4.1.32+728] - 2026-07-12

**TV GUI redesign → mock §2: Inter type face (10-foot type).** TV only; phone/touch UI keeps the platform default. The last of the owner-approved "top visual payoff" items.

### Added
- **fix728 — Inter font on TV** — bundles Inter (OFL 1.1 variable font) as the app-wide TV type face. The redesign's micro-ramp sizes, accent rings, and glass were all built on the default face; Inter is the final layer that makes the TV UI read as designed.

### Technical
- **fix728**: `assets/fonts/Inter.ttf` — the OFL variable font from github.com/google/fonts (`Inter[opsz,wght].ttf`, ~856 KB); its `wght` axis maps to `TextStyle.fontWeight`, so all weights come from one file. `pubspec.yaml` declares `family: Inter`; `main.dart` sets `ThemeData(fontFamily: hasTouchScreen ? null : 'Inter')` — the same TV gate the fix707 accent chrome uses, so phone stays byte-identical. License ships at `assets/fonts/Inter-OFL.txt`. `test/fix728_inter_font_test.dart` (4). Version → 4.1.32+728.

## [v4.1.31+727] - 2026-07-12

**TV GUI redesign → mock: Player Actions Bar completion (§4.6).** TV OSD only; phone/touch bar unchanged. Chrome-only — the playback engine, channel-surf, and reconnect logic are untouched.

### Added
- **fix727 — Sleep timer** — Player OSD ▸ Sleep timer: {Off, 15, 30, 45, 60, 90} min. Arms a one-shot timer that pauses playback then exits the player; the bedtime icon fills while armed. **Survives channel surf** (the deadline is threaded across the fresh Player so "sleep to live TV" actually works).
- **fix727 — Playback speed** — Player OSD ▸ Playback speed on VOD/catch-up: {0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0}×. Gated to non-live surfaces (2× would burn a DVR buffer to the live edge); the button label shows the active rate.

### Technical
- **fix727**: `PlayerEngine` gains `double get playbackRate` + `Future<void> setRate(double)` (default 1.0 / no-op), overridden in `MpvEngine` via media_kit `setRate`. `player.dart` adds `_openSpeedFromOverlay` / `_openSleepTimerFromOverlay` (reusing the glass `SelectDialog` + auto-hide-cancel wrapper the track pickers use), `_armSleepTimer` / `_scheduleSleep` (wall-clock deadline), and a `sleepDeadline` ctor param threaded through `_commitSurf`'s `pushReplacement`. Went through an adversarial (rr) review before ship — fixed a sleep-fire-pops-an-open-dialog wedge (`popUntil` the player route), the surf-cancels-the-timer gap (deadline carry), and gated speed to VOD. `test/fix727_actions_bar_test.dart` (7). Version → 4.1.31+727.

## [v4.1.30+726] - 2026-07-12

**TV GUI redesign → mock: OLED-black background toggle.** TV mode only; phone/touch UI unchanged.

### Added
- **fix726 — OLED-black background** — Settings ▸ Playback ▸ **OLED-black background** replaces the neon `tv_background.webp` with pure `#000000` (mock §4.1). Persists across restarts; swaps live.

### Technical
- **fix726**: `appOledNotifier` (in `accent_scope.dart`) + persisted `Settings.oledBlack` (`oledBlackProp`), restored at startup in `main.dart`. `tv_shell.dart` wraps its background (image + scrim) in a `ValueListenableBuilder(appOledNotifier)` → `ColoredBox(0xFF000000)` when on, else the webp + scrim (the keep-alive `IndexedStack` body is untouched). Settings toggle is a TV-gated `_switchTile`. (Crossfade route transitions — the other half of §4.1 — deferred to a separate fix to avoid an IndexedStack keep-alive rewrite.) `test/fix726_oled_toggle_test.dart` (6). Version → 4.1.30+726.

## [v4.1.29+725] - 2026-07-12

**TV GUI redesign → mock: source color everywhere + guide micro-ramp.** TV mode only; phone/touch UI unchanged. (Renumbered from a working fix724/v4.1.28 that collided with a parallel commit — see note.)

### Changed
- **fix725 — guide source-tinted rails + micro-ramp + art-less tile tint** — matching the visual mock: (1) EPG guide rail cells now carry a source-tinted background (`SourcePalette.tintOver`, the same tint as the bright source edge), not just the 5px edge; (2) the typographic micro-ramp (channel name 12→11, programme title 11→10); (3) channel tiles with no artwork use the source-tinted card background on TV instead of a flat grey rectangle.

### Technical
- **fix725**: `tv_guide_view.dart` `_FocusTile` gains an optional `Color? background` (source-tinted rail always shows its tint; focus via the accent ring; category rows unchanged); `_channelItem` passes the already-computed `tint`; fonts per mock §4.3. `channel_tile.dart` `_buildPoster` computes `posterBg = showSourceEdgeBar && tintColor != null ? SourcePalette.tintOver(tintColor, black26) : black26` for the fallback + loading placeholders (phone / non-edge tiles unchanged). Rebased onto the parallel v4.1.28. `test/fix725_source_tint_test.dart` (4). Version → 4.1.29+725.

## [v4.1.28+724] - 2026-07-12

**Signing — APK Signature Scheme v3 (key-rotation insurance).** No user-visible change. *(Shipped by a parallel commit; documented here for a complete changelog.)*

### Changed
- **fix724** — `android/app/build.gradle` now also enables APK Signature Scheme v3 alongside v1/v2, so the release key can be rotated in future without breaking in-place updates.

## [v4.1.27+723] - 2026-07-12

**Bug fix — Re-match / source-refresh no longer aborts when you leave Settings.** TV + phone.

### Fixed
- **fix723** — a long-standing bug where navigating away from the Settings screen during "Re-match all channels" or a source refresh **silently aborted** the operation partway (often after only the first source). The background work now runs to completion regardless of navigation.

### Technical
- **fix723**: the refresh/re-match work runs on `BackgroundTaskService` (fix349), which outlives the Settings screen. `_updateRefreshDialog` did `_refreshSetState?.call(() {})` — `?.` guards a null reference but not a **disposed** dialog State, so after navigate-away the captured `setState` hit `markNeedsBuild()` on an unmounted State and threw `Null check operator used on a null value` unhandled inside the loop → abort. Added an `if (!mounted) return;` guard (the work continues headless; its foreground-service notification is managed by `BackgroundTaskService`) plus a belt-and-suspenders `try/catch` around the call for the narrow window where the dialog State is torn down before `_refreshSetState` is nulled. `_refreshStatus` is latched before the guard so a re-opened dialog repaints. **Adversarial review also caught a second, pre-existing setState-after-dispose in the same flow** (`_runEpgRefresh`: `mounted` was checked *before* `await Sql.getLatestEpgRefresh()` but `setState` ran after it without re-checking) — folded in a post-await `if (mounted) setState(...)` re-check. `test/fix723_refresh_dialog_disposed_guard_test.dart` (4). Version → 4.1.27+723.

## [v4.1.26+722] - 2026-07-12

**TV GUI redesign — Phase 5, unit 5: multi-view accent ring.** TV mode only; phone/touch UI unchanged. Completes the accent focus-ring language across every TV surface.

### Changed
- **fix722 — multi-view accent focus ring** — the focused-cell ring in multi-view (and the empty-cell "+" button focus border) now use the shared accent color on TV, matching the tabs / tiles / rails / buttons / recordings. This was the last surface still on the old `colorScheme.primary` ring. Phone keeps its original color.

### Technical
- **fix722**: `multi_view_cell.dart` gains `_isTvLike` (mirrors channel_tile's finding-107 signal: `settings.forceTVMode || DeviceDetector.isTvCached || !hasTouchScreenCached`) and `_ringColor(context, fallback) => _isTvLike ? AccentScope.of(context) : fallback`. The two cell focus-ring `Border.all` colors route through it (fallback = `colorScheme.primary`), as does the "+" button focused border (fallback = white). Ambient-gated → no constructor/call-site plumbing and phone renders the original colors (byte-identical). The `_CellMenuIntent` single-press menu, audio-focus-on-focus (fix170), and cell-0 autofocus (fix172) are untouched — only color expressions changed. Adversarial review. `test/fix722_multiview_accent_ring_test.dart` (5). Version → 4.1.26+722.

## [v4.1.25+721] - 2026-07-12

**TV GUI redesign — Phase 5, unit 4: dialog glass** + **CI: pub-cache speedup** (folded in). TV mode only for the UI; phone/touch UI unchanged.

### Changed
- **fix721 — TV dialog glass** — `AlertDialog`/`SelectDialog` surfaces (confirmations, pickers, the "Re-match complete" notice, etc.) now use the same dark glass card + rounded corners as the fix720 bottom sheets, so every pop-up reads as migrated. TV only; phone keeps the Material default.

### CI
- Added an `actions/cache@v4` pub-cache step (`~/.pub-cache`, keyed on `pubspec.lock`) after the Flutter setup step in `analyze.yml` and in **both** `release.yml` jobs (the analyze gate and the build), so `flutter pub get` reuses resolved dependencies across runs. Purely a dependency-download speedup — the analyze gate, `needs: analyze`, triggers, concurrency groups, and `APK_BEFORE_VERSIONJSON` logic are untouched. Both YAML files validated with `ruby -ryaml`. Folded into this release rather than shipped standalone.

### Technical
- **fix721**: `main.dart` `ThemeData` gains `dialogTheme: hasTouchScreen ? null : DialogThemeData(backgroundColor 0xF00B0F19, surfaceTintColor transparent, all-corners radius 20)` — mirrors the fix720 `bottomSheetTheme`, same TV gate + F4 glass literals. `test/fix721_dialog_glass_and_pubcache_test.dart` (5) covers the dialog gate/glass and the pub-cache step in all three job locations. Version → 4.1.25+721.

## [v4.1.24+720] - 2026-07-12

**TV GUI redesign — Phase 5, unit 3: bottom-sheet menu restyle.** TV mode only; phone/touch UI unchanged.

### Changed
- **fix720 — TV context-menu glass restyle** — the pop-up menus that appear on TV (the held-OK channel context menu from fix586, and any other modal bottom sheet) now use the redesign's dark glass card with rounded top corners, matching the migrated dialogs/OSD instead of the flat Material sheet.

### Technical
- **fix720**: added a `bottomSheetTheme` to `main.dart`'s `ThemeData`, gated `hasTouchScreen ? null : BottomSheetThemeData(...)` — TV gets `backgroundColor`/`modalBackgroundColor` `0xF00B0F19` (opaque F4 glass), `surfaceTintColor: transparent` (no M3 elevation tint), and a `RoundedRectangleBorder` top radius 20 (`F4Radius.modal`); phone gets `null` → the Material default, so the touch sheets are byte-identical. Theme-level, so it covers every `showModalBottomSheet` uniformly (no per-call-site edits). `test/fix720_bottomsheet_theme_test.dart` (2). Version → 4.1.24+720.

## [v4.1.23+719] - 2026-07-12

**TV GUI redesign — Phase 5, unit 2: accent-color picker.** TV mode only; phone/touch UI unchanged.

### Added
- **fix719 — TV accent picker** — Settings ▸ Playback ▸ **Accent color** now lets you choose the focus-ring accent from a curated palette (White · Sky Blue · Amber · Magenta · Green). The choice recolors every focus outline across the TV UI instantly and persists across restarts. Default: White (unchanged look for anyone who doesn't touch it).

### Technical
- **fix719**: `accent_scope.dart` gains `AccentPreset` + `kAccentPresets` (the 5 curated colors) + `accentColorFromId` (unknown/null → White). New persisted `Settings.accentName` (default `'white'`) round-tripped via `accentNameProp` in `SettingsService`. `main.dart` restores it into `appAccentNotifier` before the first frame, and now wraps `MaterialApp` in a `ValueListenableBuilder<Color>(appAccentNotifier)` so the button-theme focus rings (which read the notifier in their `resolveWith`) re-resolve live on change — `AccentScope`-based widgets already update via the InheritedNotifier. Picker UI (`_accentColorTile` + `_AccentSwatch` D-pad-focusable swatches) is added to `_playbackChildren` gated `if (widget.tvRailPane)`, so the phone settings list is byte-identical. Adversarial review. `test/fix719_accent_picker_test.dart` (6). Version → 4.1.23+719.

## [v4.1.22+718] - 2026-07-12

**TV GUI redesign — Phase 5 (settings/menus), unit 1: Recordings restyle.** TV mode only; phone/touch UI unchanged.

### Added / Changed
- **fix718 — Recordings accent focus ring** — on TV, the focused row in the Recordings list now shows the shared accent focus outline (matching the tabs / tiles / rails / buttons from fix704/707), instead of only the faint Material highlight. Phone keeps the bare Material list.

### Technical
- **fix718**: `RecordingsView` gains `final bool tv` (default false); the TV shell builds `RecordingsView(tv: true)`, phone `bottom_nav` unchanged. `_RecordingTile` gains `tv` + a `_focused` flag driven by a `_node` focus listener (added initState / removed dispose). build() returns the bare `ListTile` when `!tv` (phone byte-identical); on TV wraps it in an `AnimatedContainer` (`F4Motion.fast`) with `Border.all(width: 2, color: _focused ? AccentScope.of(context) : transparent)` + `t.radius.card`. The 2px border is always allocated (color-only change) so focus causes no layout reflow; the ListTile keeps `focusNode`/`onTap`/`onLongPress` and the fix693 held-OK key model is untouched. Adversarial review. `test/fix718_recordings_accent_test.dart` (5). Version → 4.1.22+718.

## [v4.1.21+717] - 2026-07-12

**EPG reliability — route "Re-match all" through the shared match gate.** No UI change; TV + phone.

### Fixed
- **fix717 — Re-match all match-gate** — the Settings "Re-match all channels" action no longer collides with an automatic guide refresh running on the same isolate. Two channel-matches writing to the guide database at once could exhaust the busy-retries and leave a source's channels silently without listings (the "guide empty on every channel" failure); Re-match now serializes against the refresh path.

### Technical
- **fix717**: new public `EpgService.matchChannelsSerialized(...)` = `_serializeMatch(() => matchChannels(...))` — the single entry point external callers use; `refreshSource` routes through it too (one gate source of truth; `matchChannels(` now has exactly two occurrences: its definition + the wrapper's call). `settings_view.dart` "Re-match all" loop calls the wrapper instead of `matchChannels` directly. **Scope (per adversarial review):** the gate (`_matchGate`) is a per-isolate static, so this closes the realistic same-isolate window (Re-match vs a foreground launch/stale refresh — `BackgroundTaskService.run` spawns no isolate); a Workmanager BACKGROUND refresh (separate isolate) is out of scope and still relies on the SQLITE_BUSY retries (follow-up: have Re-match honor `epg_refresh_in_progress`). `test/fix717_rematch_gated_test.dart` (4). Version → 4.1.21+717.

## [v4.1.20+716] - 2026-07-12

**TV GUI redesign — Phase 4 (player OSD), unit 3: Channel Bar.** TV mode only; phone/touch UI unchanged.

### Added / Changed
- **fix716 — Player Channel Bar** — the revealed player OSD now shows a horizontal strip of the current surf group above the Info Bar, centered on the channel you're watching (accent-highlighted) with its neighbours dimmed — channel-surf context. It's display-only: you still surf with ▲▼ and the strip re-centers on the new channel; the D-pad/trigger behavior is unchanged (Option B). Only shows when there's a surfable group.

### Technical
- **fix716**: new `lib/player/tv_osd/channel_bar.dart` (`PlayerChannelBar` — a horizontal `ListView.builder` over `PlaybackPlaylist.channels`, current index = accent border + full opacity, others dimmed 0.55; a `ScrollController` post-frame `jumpTo` centers the tuned channel; `IgnorePointer` + `NeverScrollableScrollPhysics` + no `FocusNode` → not interactive, stays out of the overlay `FocusTraversalGroup`). Wired into `player.dart` `_buildTvOverlay` above the `PlayerInfoBar`, gated `if (_canSurf && widget.playlist != null)`. Reuses the existing surf playlist — no engine/surf/focus change. Adversarial review. `test/fix716_player_channel_bar_test.dart` (5). Version → 4.1.20+716.

## [v4.1.19+715] - 2026-07-12

**TV GUI redesign — Phase 4 (player OSD), unit 2: action-button focus lift.** TV mode only; phone/touch UI unchanged.

### Added / Changed
- **fix715 — OSD action-button lift** — the TV player control buttons (subtitles / audio / channel-surf / seek / aspect / play-pause / etc.) now scale up slightly on focus (the Peer2 "lift"), on top of the accent focus ring the global button theme already draws (fix707). **Option B:** the reveal trigger and all D-pad behavior are unchanged — a short OK still reveals the controls and play/pauses exactly as before.

### Technical
- **fix715**: new `lib/player/tv_osd/action_button.dart` (`OsdActionButton` — wraps the overlay `IconButton` in an `AnimatedScale` 1.0→1.15 on focus, `F4Motion.fast`/`easeOut`; observes the IconButton's focus node — the caller's when supplied, e.g. play/pause's `_overlayFirstFocus`, else an internal one — and disposes only a self-created node). `player.dart` `_ovlButton` now returns `OsdActionButton` (onInteract: `_resetOverlayHideTimer`), so all overlay-button call sites are untouched. No trigger/`_navMode`/`_onPlayerKey`/surf/seek/autofocus change (AnimatedScale is paint-only, not a focus boundary). Focus-lifecycle adversarial review. `test/fix715_osd_action_button_test.dart` (5). Version → 4.1.19+715.

## [v4.1.18+714] - 2026-07-12

**TV GUI redesign — Phase 4 (player OSD), unit 1: Info Bar.** TV mode only; phone/touch UI unchanged.

### Added / Changed
- **fix714 — Player Info Bar** — the TV player overlay's channel identity (logo + name), the NOW programme, and the seek/progress row now live together in a token-glass **Info Bar** anchored at the bottom (Peer2 three-bar anatomy), instead of scattered across the flat top bar. The top bar keeps just Back + Cast + PiP. Playback controls, channel-surf, seek, auto-hide, and the touch (non-TV) control path are all unchanged.

### Technical
- **fix714**: new `lib/player/tv_osd/info_bar.dart` (`PlayerInfoBar` — a display-only, token-glass `Container`: logo `CachedNetworkImage` + `PlayerChannelNameLabel` on top, `PlayerEpgNowLabel` when live, the caller's `_buildOverlayProgress()` row when seekable). `player.dart` `_buildTvOverlay`: top bar slimmed to Back + Cast/PiP; `PlayerInfoBar` added above the action `bottomBar`; the standalone progress row folded into it. Reuses the existing self-updating labels — no engine/focus/key/surf changes; `PlayerInfoBar` has no focusable children so the `FocusTraversalGroup` + `_overlayFirstFocus` autofocus are unaffected. Two-lens adversarial review (layout + focus/regression). `test/fix714_player_info_bar_test.dart` (5). Version → 4.1.18+714.

## [v4.1.17+713] - 2026-07-12

**EPG — Re-match all works when the feed is unchanged.** Backend (authored by the owner).

### Fixed
- **fix713 — Re-match all when feed unchanged** — "Re-match all channels" failed (`⚠ failed to download EPG`) whenever the provider's feed was byte-identical to the last refresh (HTTP 304 / body-hash match, fix695) — inverted from its purpose (matcher updated, feed identical). `downloadAndParseEpg` now returns a tri-state (`EpgDownloadResult` refreshed/unchanged/failed) and re-match passes `forceParse: true` to bypass the unchanged-feed short-circuit. Also relabels an unchanged plain-refresh from the bogus "⚠ 0 programs loaded" to "✓ feed unchanged — kept existing data". Preserves fix709 (match gate) + fix712 (serial refresh).

## [v4.1.16+712] - 2026-07-12

**EPG multi-source refresh — serialize sources (the real fix; fix709 was insufficient).** Backend; all platforms.

### Fixed
- **fix712 — Refresh sources one at a time** — fix709 serialized the channel-match phase, but on-device verification (onn, a 2GB box) proved the *download/parse* phase also races under a concurrent multi-source refresh: with two sources refreshing at once, one source's temp-XML fetch was starved ("0 programs loaded") and the `epg_refresh_log` / insert writes exhausted the SQLITE_BUSY retries ("database is locked, code 5") — both sources failed (non-destructively: existing EPG survived). Sources now refresh **one at a time** (`maxConcurrent` 2→1), matching the proven-good single-source path (Trex: 185,516 programs, 35851/35851 matched). Covers every trigger (manual, background 24h, launch-if-stale) via the shared `refreshAllSources`.

### Technical
- **fix712**: `epg_service.dart` `refreshAllSources` — `const maxConcurrent = 2` → `1`; the chunked loop is unchanged (chunk size 1 = serial). fix709's `_serializeMatch` gate stays as a belt-and-suspenders invariant. Slower for N sources (serial downloads) but this is a nightly background op — correctness >> speed; also gentler on providers. The disproven "HTTP fetches don't fight" doc rationale is corrected. `test/fix712_serialize_refresh_test.dart` (4). Version → 4.1.16+712.

## [v4.1.15+711] - 2026-07-12

**TV GUI — genre stripe visibility (fix708 follow-up).** TV mode only; phone UI unchanged.

### Fixed
- **fix711 — Genre stripe moved to the top edge** — the on-now cell's genre colour tag (fix708) was a left-edge stripe, but on-now cells begin at ~"now", so the stripe landed in the thin sliver under the vertical now-line + its glow and was effectively invisible on-device. Moved it to a full-width 3px **top-edge** stripe, which the now-line never covers, so the genre colour reads clearly.

### Technical
- **fix711**: `tv_guide_view.dart` `_block` — the on-now genre `Positioned` changed from `left:0, top:0, bottom:0, width:3` (vertical left stripe) to `left:0, right:0, top:0, height:3` (horizontal top stripe). Still gated on `isNow`, clipped by the fix705 `Clip.antiAlias`, painted under the title. `test/fix708_genre_test.dart` updated to assert the top-edge geometry. Version → 4.1.15+711.

## [v4.1.14+709] - 2026-07-12

**EPG matching fix — guide empty on all channels (concurrency).** Backend; all platforms.

### Fixed
- **fix709 — Serialize the EPG channel-match phase** — the TV Guide could show "No guide data" on most/all channels even though the EPG had downloaded. Root cause: a multi-source EPG refresh runs sources concurrently (`maxConcurrent=2`), and two channel-match steps at once collided on the `db.sqlite` writer + the WAL **TRUNCATE** checkpoint (an exclusive lock); the SQLITE_BUSY retries exhausted, `matchChannels` threw, and the per-source `catch` swallowed it — leaving that source's channels silently unmatched. (A single-source refresh, with no concurrency, matched 35851/35851 on-device.) This is the recurring trigger behind "works after a manual refresh, empty again after the nightly auto-refresh."

### Technical
- **fix709**: `epg_service.dart` — an in-isolate chained-Future gate (`_matchGate` / `_serializeMatch`) serializes `matchChannels` so no two matches run at once; **downloads stay parallel** (they are already contention-tolerant — retried epg.sqlite writes + a PASSIVE db.sqlite checkpoint, line 378). Only the match's db.sqlite TRUNCATE checkpoint needed serializing. Covers all triggers (manual refresh, background 24h task, launch-if-stale) since they share `refreshAllSources`. In-isolate only, which is where the `maxConcurrent=2` concurrency lives; cross-isolate stays guarded by the app_meta refresh lock + SQLITE_BUSY retries. Gate releases in `finally` (a throwing match can't wedge it). `test/fix709_epg_serialize_match_test.dart` (4): wiring present + gate logic serializes (no overlap, FIFO) + throwing body doesn't wedge. Adversarially reviewed (concurrency-correctness + fixes-bug/regression lenses). Version → 4.1.14+709.

## [v4.1.13+708] - 2026-07-12

**TV GUI redesign — Phase 3 unit 3: guide genre tint.** TV mode only; phone UI unchanged.

### Added / Changed
- **fix708 — Genre colour stripe** — in the TV Guide, the on-now programme cell now shows a small left-edge colour stripe by genre (news / sport / movies / kids / music / docs, with a neutral fallback), so you can spot the kind of show at a glance. Colour is derived per-programme from the XMLTV category (a channel airs many genres through the day, so it's per on-now cell, not per channel). Only shows on channels that carry EPG data.

### Technical
- **fix708**: new `lib/tv/theme/genre.dart` — `normalizeGenre(String? category)` maps free-text XMLTV `Program.category` onto one of the 7 buckets keying `kGenreColors` (case-insensitive substring, most-specific-first, `general` fallback for null/unknown — never guesses a vivid colour); `genreEdgeColor()` returns the bucket's vivid colour. `tv_guide_view.dart` `_block` draws a 3px `Positioned` left-edge stripe on the on-now cell (`if (isNow)`), clipped by the existing `Clip.antiAlias`, painted under the title / over the fix705 progress fill; positioned child, so no layout/size/alignment change. Adversarially reviewed (SHIP; fixed a `'mma'`→`'mixed martial'` false-positive that hit "programma"/"grammar"). `test/fix708_genre_test.dart` (8): normalizer buckets + precedence + false-positive guard + total fallback + edge-colour + guide wiring. Version → 4.1.13+708.

## [v4.1.12+707] - 2026-07-12

**TV GUI redesign — chrome pass: button/dialog/gear focus rings.** TV mode only; phone UI unchanged.

### Added / Changed
- **fix707 — TV chrome focus ring** — the global TV focus ring on buttons, dialogs and the settings gear (Filled / Icon / Text / Outlined buttons) now uses the accent colour (white by default) instead of the old flat yellow, completing the accent-ring language across all TV chrome (tabs fix702, tiles fix703, rails fix704, and now buttons). Phone UI unchanged (all four are gated on `!hasTouchScreen`).

### Technical
- **fix707**: `lib/main.dart` — the 4 `ButtonStyle.side` focused resolvers `Colors.yellow`→`appAccentNotifier.value` (widths 4/3/3/3 kept). Non-const read at theme-build time: accent is white today (no picker UI), so it's visually the intended white ring; a future accent-preset unit adds live reactivity by rebuilding the theme on notifier change. `test/fix704_guide_focus_test.dart`'s "main.dart still yellow" guard retired (that migration is now done); `test/fix707_chrome_accent_test.dart` asserts no `Colors.yellow` + all 4 rings read the notifier + `!hasTouchScreen` gating kept. Version → 4.1.12+707.

## [v4.1.11+706] - 2026-07-12

**TV GUI redesign — Phase 3 unit 4: guide "no guide data" placeholders.** TV mode only; phone UI unchanged.

### Added / Changed
- **fix706 — Never a blank guide row** — channels with no EPG programmes in the window (24/7 loop / VOD-style feeds that carry no XMLTV — common in these bundles) previously rendered an empty grid row that looked broken. They now show a dim full-width **"No guide data"** placeholder. Populated rows are unchanged. (Reordered ahead of the genre-tint unit because it's the higher-value, lower-risk change and is verifiable in the common EPG-sparse state.)

### Technical
- **fix706**: `tv_guide_view.dart` — new `_emptyRowPlaceholder(width)` (a muted `surfaceContainerHighest`@0.35 full-width cell, left-aligned "No guide data", fontSize 11). Added to `_gridRow`'s `Stack` via `if (progs.isEmpty) _emptyRowPlaceholder(c.maxWidth)`. Purely additive — the real-cell `for`-loop and the NOW-line are unchanged, and the collection-if contributes nothing when `progs` is non-empty, so populated rows are byte-identical. No data layer. Version → 4.1.11+706.

## [v4.1.10+705] - 2026-07-12

**TV GUI redesign — Phase 3 unit 2: guide NOW emphasis.** TV mode only; phone UI unchanged.

### Added / Changed
- **fix705 — Guide NOW emphasis** — in the TV Guide: (1) the "now" vertical line now has a soft glow so the current moment reads at 10 feet (colour kept blue/`primary`, deliberately distinct from the white accent focus ring); (2) the on-now programme cell shows a progress-within-cell fill — the elapsed fraction of the show's runtime tints the left portion of the cell a little stronger, a built-in progress bar. Both derive purely from EPG programme times; no new data. HD/SD badges were considered but dropped (the `Program` model has no quality field; a title heuristic would be a separate concern). Guide layout, rail↔grid Y-alignment, :00/:30 snap, live preview, place-memory and the held-OK menu are unchanged.

### Technical
- **fix705**: `tv_guide_view.dart` — `_nowLine` gains a `BoxShadow` (blur = token `nowGlowRadius` 8, spread 0.5, colour `primary`). `_block` wraps the on-now cell content in a `Stack` with a `Positioned.fill(FractionallySizedBox(widthFactor: elapsedFrac))` fill behind the title; `elapsedFrac` guarded against zero/negative duration. `Material.clipBehavior` is `isNow ? Clip.antiAlias : Clip.none` — only on-now cells pay the clip (no per-cell clip layer across the dense grid, protecting scroll fps). Passive-grid `ExcludeFocus` (finding 75) + `onTap: _play(ch)` intact. Adversarially reviewed + on-device scroll-fps checked on the onn. Version → 4.1.10+705.

## [v4.1.9+704] - 2026-07-12

**TV GUI redesign — Phase 3, unit 1: rail focus rings (guide + browse + categories).** TV mode only; phone UI unchanged.

### Added / Changed
- **fix704 — Rail focus ring** — the highlighted rail item on every browsing surface — the TV Guide rail (channel / category / frozen channel column), the browse rail, and the Categories rail — now shows the accent focus ring (white by default), matching the tabs (fix702) and tiles (fix703), instead of the old flat yellow border. This unifies the whole browsing surface on one focus look. Guide layout, rail↔grid Y-alignment, :00/:30 timeline snap, 12/24h clock, dwell-gated live preview, place-memory, and the held-OK (fire-on-release) menu are all unchanged. (The TV button/dialog focus theme in Settings is a separate later pass and still shows the old style for now.)

### Technical
- **fix704**: the three copy-pasted `_FocusTile` rails — `tv_guide_view.dart`, `tv_browse_view.dart`, `tv_categories_view.dart` — ring `Colors.yellow`→`AccentScope.of(context)` (null-safe; falls back to white with no ancestor). Width 3 kept so row itemExtent chrome budgets are unchanged (guide 56px `_rowHeight`). Guide program cells (`_block`) are `ExcludeFocus`/passive and unaffected; guide rail-alignment, held-OK on-release model, and place-memory untouched. The 4 global TV button focus themes in `main.dart` (Filled/Icon/Text/Outlined, `!hasTouchScreen`) remain yellow — deferred to a dedicated chrome pass (needs live-accent reactivity + broad dialog verify). Reviewed adversarially (guide file). Version → 4.1.9+704.

## [v4.1.8+703] - 2026-07-12

**TV GUI redesign — Phase 2 (channel/poster tiles).** TV mode only; phone UI unchanged.

### Added / Changed
- **fix703 — Tile focus** — on TV, a focused channel/movie/series/category tile now shows the accent focus ring (matching the tabs, white by default) and lifts slightly, instead of the old flat yellow border. All the existing tile behavior is unchanged (source-color edge bar, favorite star, category checkbox, D-pad edge-back / arrow navigation, hold-OK menu). The phone UI is untouched.

### Technical
- **fix703**: `channel_tile.dart` — focused-tile ring `Colors.yellow`→`AccentScope.of(context)` (gated on `showSourceEdgeBar`, the TV-only signal; AccentScope sits inside the gated ternary so it is never evaluated on the phone build) + a 1.05× `AnimatedScale` focus lift wrapping the Card on the TV path (phone returns the bare Card). ChannelTile keeps its own FocusNode + specialized key handling (not delegated to TvFocusable, which would risk regressions across 5 screens). Version → 4.1.8+703.

## [v4.1.7+702] - 2026-07-11

**TV GUI redesign — Phase 0 foundation + Phase 1 (top tab bar).** TV mode only; the phone UI is unchanged.

### Added / Changed
- **fix701 — Design foundation (invisible)** — a single design-token tree (`F4Tokens`), a live user-selectable focus accent (`AccentScope`, default white), a shared motion vocabulary, and one focus primitive (`TvFocusable`: an accent focus ring that snaps in and fades out to kill the focus flash, a subtle lift, and the held-OK menu unified onto the safe fire-on-release model). Nothing visible yet — it's the plumbing the rest of the redesign builds on.
- **fix702 — Top tab bar** — the TV top tabs now use the new focus engine: a clean accent ring on the focused tab (replacing the flat yellow border) with a subtle lift; the selected tab keeps its section color. Held-OK still reaches the Live-TV diagnostic / History-clear actions, and a held OK on any other tab still just switches to it.

### Technical
- **fix701**: new `lib/tv/theme/{f4_tokens,accent_scope,f4_motion}.dart` + `lib/tv/focus/{tv_focusable,dpad_repeat_gate}.dart`; `main.dart` attaches `F4Tokens` to `ThemeData.extensions` + installs `AccentScope`. Inert; phone byte-identical.
- **fix702**: `tv_top_tab_bar.dart` `_TabButton` → `TvFocusable` (accent `ringChrome`, section-color pill kept, 600ms held-OK preserved). Version → 4.1.7+702.

## [v4.1.6+700] - 2026-07-11

**Recordings + playback fixes from owner-reported bugs.**

### Added / Changed
- **fix698 — Recording indicator** — the red REC dot now blinks noticeably (was too faint to see), and the Recordings screen refreshes itself while a recording is scheduled or running, so it flips from Scheduled → Recording → Done live without a manual refresh.
- **fix699 — Faster first channel open** — the player now waits for its video surface before starting the stream, avoiding a decoder re-init that could add several seconds to the first time you open a channel.
- **fix700 — Smoother live buffering (optional)** — a new **Live pre-buffer (seconds)** setting (default off) that, when turned on, rides through constant stutter on a slow provider or weak Wi-Fi (and when watching a channel you're also recording) by pausing briefly to build a cushion instead of rebuffering every second. Trades a small delay behind the live edge for fewer interruptions.

### Technical
- **fix698**: `recordings_view.dart` — `_BlinkingDot` 1.0↔0.15 / 450ms; `_RecordingsViewState` quiet 3s poll while any row is transient (cancelled in dispose).
- **fix699**: `mpv_engine.dart open()` — extra un-locked bounded `_waitForTextureId` before `_player.open()` (full-screen only) so mediacodec binds the final surface first (no `vo=null→gpu` restart).
- **fix700**: new `livePrebufferSecs` setting (default 0) → `cache-pause-initial`+`cache-pause-wait` on the mpv live branch (skipped under DVR); mirrors `vodPrebufferSecs` plumbing. Also mitigates watch-while-recording contention (a full playback-from-recording tee is infeasible — mpv can't tail a growing file). Version → 4.1.6+700.

## [v4.1.5+697] - 2026-07-11

**Recordings: completion alert + safe delete of an in-progress recording.**

### Added / Changed
- **fix697 — Recording completion notification (SR backlog item 2)** — when a scheduled recording finishes (or fails), the app now posts a system notification ("Recording complete" / "Recording failed"). It is native and works even when the app is backgrounded or closed — the case a scheduled recording actually finishes in. A matching in-app message also shows if the Recordings screen is open. User-initiated stops don't notify (you're already there).
- **fix697 — Deleting an in-progress recording no longer strands a file (SR backlog item 1)** — a still-recording row now carries its file location, so "Delete + remove file" is offered while recording, and choosing it cleanly removes the partial clip instead of leaving an orphaned file in your gallery.

### Technical
- **fix697**: `RecordingCaptureService.kt` — new `free4me_recording_done` notification channel + `postCompletion()` (id `48000+id`, survives `stopForeground`), fired on natural done/failed and suppressed on user cancel; `deleteOnCancel` + `EXTRA_DELETE_FILE` so the service deletes its own partial after the output stream closes (no open-fd race); output URI now persisted at `status=recording`. `MainActivity.kt` — one-time `POST_NOTIFICATIONS` request (API 33+); `stopCapture` passes `deleteFile`. Dart — `RecordingCapture.stop(deleteFile:)`, `_delete` routes a running-row remove through the native stop, `RecordingStatusJournal.drain()` returns terminal completions for the in-app SnackBar. Version → 4.1.5+697.

## [v4.1.1+693] - 2026-07-10

**Recordings list UX:** blinking record indicator, keep-or-remove-file delete, and a details view.

### Added / Changed
- **fix693 — Recordings-list interactions** — (1) The red record indicator now pulses while a recording is actively in progress (`_BlinkingDot`, fades between full and dim so layout/focus stay stable). (2) Deleting a recording that has a saved file now offers three choices — Cancel / Delete + remove file / Delete, keep file — removing the file via the existing MediaStore delete channel; recordings with no file keep the simple confirm. (3) Long-press (touch) or held-OK (D-pad, reusing the fix607 hold-timer pattern) on a row opens a details sheet showing resolution, duration, bitrate, format, size, and the saved path, read via a new `recordingFileInfo` channel method (MediaMetadataRetriever + MediaStore query).

### Technical
- **fix693**: `recordings_view.dart` (new `_BlinkingDot`, `_RecordingTile` with held-OK+long-press, `_DetailsSheet`; 3-way `_delete`; `_showDetails`), `MainActivity.kt` (`recordingFileInfo` on the recording channel); version → 4.1.1+693. Verified with real `flutter analyze` (Flutter 3.44.5) → "No issues found!".

## [v4.0.7+691] - 2026-07-10

**Correct duration + working seek bar** on converted recordings.

### Fixed
- **fix691 — Zero-base recording timestamps** — after fix690 gave clean audio, the converted MP4 reported a huge bogus duration (e.g. 8:46:42 for a 1-minute clip) and the seek bar was unusable. Live MPEG-TS packets carry the broadcast-clock PTS/DTS (a large value), which was copied straight into the MP4, leaving an ~8-hour start offset. The remux now captures the first packet's DTS (or PTS) as a single global reference and subtracts it from every packet's timestamps before muxing, so the recording starts at ~0. One offset is used for all streams to preserve A/V sync; `AV_NOPTS_VALUE` packets are left untouched. Verified against libavformat on a large-offset TS: start_time went from ~30000s to ~0 with duration intact and audio still clean.

### Technical
- **fix691**: `recording_remux.dart` — global `startTs` offset applied to `pkt->pts`@8 / `pkt->dts`@16 (shallow, already-verified offsets; no deep AVFormatContext field); version → 4.0.7+691. Verified with Dart 3.12.2 + repo `analysis_options` → "No issues found!".

## [v4.0.6+690] - 2026-07-10

**Converted recordings play everywhere:** the re-mux now writes a standards-compliant AAC track, so recordings play in the default Android video player, not only VLC.

### Fixed
- **fix690 — Apply `aac_adtstoasc` when muxing AAC into MP4** — recordings converted fine (fix685–689) and played in VLC, but the stock Android "Video Player" reported *audio codec not supported* (video was fine). Cause: live-TV AAC is ADTS-framed, and our pinned ffmpeg **n6.0** mp4 muxer does not synthesize a valid AudioSpecificConfig (`esds`) from ADTS on its own — it needs the `aac_adtstoasc` bitstream filter (the device `.so` even carries the *"use the audio bitstream filter 'aac_adtstoasc'"* message). Tolerant players (VLC) decode the malformed track; strict ones reject it. Now, for AAC→MP4, the filter is initialised before `write_header` (so the corrected `par_out`/extradata reaches the output stream) and audio packets are run through it. Verified end-to-end against libavformat: filtered output decodes cleanly with a valid `esds`. MKV path and video are unchanged; `[SRDBG]` diagnostics retained.

### Technical
- **fix690**: `recording_remux.dart` — new BSF typedefs (`av_bsf_get_by_name/alloc/init/send_packet/receive_packet/free`, all exported from the vnext `libmpv.so`) + `AVBSFContext` offsets (par_in@24, par_out@32, time_base_in@40, n6.0); send/receive loop with EAGAIN/EOF handling; version → 4.0.6+690. Verified with Dart 3.12.2 + repo `analysis_options` → "No issues found!".

## [v4.0.5+689] - 2026-07-10

**Recording conversion completes:** the last re-mux bug is fixed — `.ts` recordings now become playable `.mp4`/`.mkv` files.

### Fixed
- **fix689 — Pass AVRational to `av_packet_rescale_ts` by value** — fix688 got the re-mux to the packet loop, where fix687's diagnostics then showed `write_frame rc=-22 (after 0 frames)` for every recording. `av_packet_rescale_ts(pkt, AVRational src, AVRational dst)` takes its two time-base rationals **by value**, but the FFI typedef decomposed each `{num,den}` into separate int32 args — the wrong arm64 ABI, which corrupted every packet's pts/dts to `AV_NOPTS_VALUE` and made the first `av_interleaved_write_frame` fail with EINVAL. Verified against libavformat directly: the decomposed call yields `pts=INT64_MIN`, while a by-value `AVRational` rescales correctly, and the full remux of a real H.264+AAC `.ts` then produces a valid MP4. Added an `AVRational` FFI struct and pass both rationals by value.

### Technical
- **fix689**: `recording_remux.dart` — `final class AVRational extends Struct`, `av_packet_rescale_ts` typedef → by-value structs, call site populates reusable src/dst rationals; version → 4.0.5+689. fix687 `[SRDBG]` diagnostics retained. Verified with Dart 3.12.2 + repo `analysis_options` → "No issues found!".

## [v4.0.4+688] - 2026-07-10

**Recording conversion works:** the fix687 diagnostics pinpointed the failure — `.ts` recordings now convert to `.mp4`/`.mkv` as intended.

### Fixed
- **fix688 — Pass the fd to ffmpeg's `fd:` protocol as an option, not in the URL** — fix687's instrumentation showed every re-mux failing at `open_input(fd:N) rc=-22` (`AVERROR(EINVAL)`) for both MP4 and MKV. Verified against libavformat directly: ffmpeg n6.x's `fd:` protocol rejects a URL-embedded descriptor (`fd:N`) and requires the fd via the `fd` **AVDictionary option** with a bare `fd:` URL (stderr: *"Doesn't support pass file descriptor via URL, please set it via -fd"*). Input now uses `avformat_open_input("fd:", opts{fd})`; output moves from `avio_open` to `avio_open2("fd:", …, opts{fd})`. Both confirmed working (open succeeds; `avio_open2` returns 0). fix687's gated `[SRDBG]` diagnostics are retained.

### Technical
- **fix688**: `recording_remux.dart` — new typedefs `avio_open2`/`av_dict_set_int`/`av_dict_free` (all exported from the vnext `libmpv.so`), `_AvOpenInput` dict arg corrected to `AVDictionary**`, `avio_open` removed; version → 4.0.4+688. Verified with the project's Dart 3.12.2 + repo `analysis_options` → "No issues found!".

## [v4.0.3+687] - 2026-07-10

**Recording-conversion diagnostics:** the re-mux still failed on-device (v4.0.2: both MP4 and MKV failed with no visibility). This adds per-step instrumentation so the next attempt reports exactly which libavformat call failed.

### Changed
- **fix687 — Instrument the FFI re-mux** — `_RemuxNative.streamCopy` now returns a short `step rc=<AVERROR>` diagnostic instead of a bare bool, surfaced through the background isolate and logged via the existing gated `[SRDBG]` channel (e.g. `open_input rc=…`, `write_header(mp4) rc=…`, `avio_open rc=…`, `exception: …`). No change to the re-mux logic — pure visibility to locate the v4.0.2 failure. `_processOne` also logs a null `createOutput`.

### Technical
- **fix687**: `lib/backend/recording_remux.dart` — `streamCopy`→`String`, `_copyInIsolate`→`String`, failure tags at every avformat call site; version → 4.0.3+687. Verified with standalone `dart analyze` → "No issues found!".

## [v4.0.2+686] - 2026-07-10

**Recording conversion now actually runs:** the fix685 re-mux was silently skipped for every recording; this makes `.ts` → `.mp4`/`.mkv` conversion fire as intended.

### Fixed
- **fix686 — Re-mux skip guard used the wrong path shape** — fix685 wired the FFI re-mux but `_processOne` gated on `outputPath.endsWith('.ts')`. Captured recordings are MediaStore entries whose `output_path` is a `content://` URI, which never ends in `.ts` (only the display name does), so the guard skipped **every** recording — confirmed on v4.0.1 (`remux: id=17 skip … path=content://media/external_primary/video/media/1000062227`), leaving the file a `.ts`. Removed the suffix test: `RecordingStatusJournal.drain()` already calls `process()` only for ids the native service flagged `"remux":true` on a fresh capture, so `status==done` + non-null path is the correct, sufficient guard. Container choice remains codec-probed (not extension-based), so nothing downstream assumed `.ts`.

### Technical
- **fix686**: one-guard fix in `lib/backend/recording_remux.dart` (`_processOne`); version → 4.0.2+686. Verified with a standalone `dart analyze` → "No issues found!".

## [v4.0.1+685] - 2026-07-10

**Scheduled Recording re-mux (works at last):** captured `.ts` recordings are now repackaged into a real `.mp4` (or `.mkv`) container when the re-mux option is on — no re-encode, no quality loss.

### Fixed
- **fix685 — App-side FFI re-mux of scheduled recordings** — The fix671 native MediaExtractor/MediaMuxer re-mux was a dead end: Android's extractor cannot parse these live-TV `.ts` streams (`Failed to instantiate extractor`), so re-mux always failed and the recording stayed a `.ts`. Re-mux now runs in Dart via FFI over the FFmpeg (libavformat n6.0) symbols exported by the v4.0.0 custom `libmpv.so` (muxer allowlist added in the vnext libmpv build). After a capture finishes, the native service records that re-mux was requested; on the next Recordings load, Dart stream-copies the `.ts` into MP4 (h264/hevc + aac/mp3) or falls back to MKV, then deletes the `.ts`. Fully fail-open — any failure keeps the original `.ts`, so a recording is never lost. The heavy copy runs in a background isolate; MediaStore access and DB writes stay on the UI isolate (single-writer invariant from fix681 preserved).

### Technical
- **fix685**: app-side re-mux over exported libavformat, no NDK / no JNI shim baked into libmpv
  - New `lib/backend/recording_remux.dart` — Dart FFI bindings to 22 libavformat/avio functions in `libmpv.so`; stream-copy demux→mux via the ffmpeg `fd:` protocol. Struct offsets pinned to n6.0 (LP64), guarded at runtime by `avformat_version()` major == 60 (ABI drift → abort, keep `.ts`).
  - `RecordingCaptureService.kt` — removed the dead `remuxToMp4`/`abort` (MediaExtractor/MediaMuxer) path and imports; capture now always finishes on the `.ts` and journals `"remux": true` when requested.
  - `MainActivity.kt` — added `remuxOpenRead` / `remuxCreateOutput` / `remuxFinalize` / `remuxDiscard` / `remuxDeleteTs` / `remuxCloseFd` on the `me.free4me.iptv/recording` channel, handing MediaStore fds to Dart.
  - `recording_status_journal.dart` — `drain()` collects re-mux-flagged `done` ids and invokes `RecordingRemux.process` after the DB is current.
  - `pubspec.yaml` — added `ffi: ^2.1.0`; version → 4.0.1+685.

## [v1.25.7+256] - 2026-06-04

**Per-source channel order toggle:** preserve provider order vs sort alphabetically.

### Fixed
- **fix256 — Per-source provider channel order toggle** — Providers like Z2U (barfik.org) ship channels in curated order using inline headers (e.g. `#### ABC ####` → ABC Alabama → ABC Alaska). After import, headers floated to the top (they sort first alphabetically), breaking the intended interleave. Now captures the provider's order (Xtream `num` field or M3U line sequence) in `channels.provider_order`, and adds a per-source 'Use provider channel order' toggle in the source edit dialog that switches between provider order and alphabetical (default). Browse views (Live / Movies / Series / All) sort per-source mode; existing sources unaffected (default alphabetical). Migration 20 adds `channels.provider_order INTEGER` and `sources.sort_mode TEXT`.

### Technical
- **fix256**: 12-part systematic fix across 8 files
  - Migration 20: `channels.provider_order` + `sources.sort_mode` columns (`lib/backend/db_factory.dart`)
  - Parser: `XtreamStream.providerNum` from `num` field (`lib/models/xtream_types.dart`)
  - Models: `Channel.providerOrder` + `Source.sortMode` (`lib/models/channel.dart`, `lib/models/source.dart`)
  - Import: `xtreamToChannel` sets `providerOrder`; both `insertChannel` (M3U) and `insertChannelsBulk` (Xtream CRITICAL) write `provider_order` (`lib/backend/xtream.dart`, `lib/backend/sql.dart`)
  - M3U: line-sequence counter passed to `getChannelFromLines` → `providerOrder` (`lib/backend/m3u.dart`)
  - Read: `rowToChannel` maps column 19; `rowToSource` maps column 11 (`lib/backend/sql.dart`)
  - Sort: browse `ORDER BY` mode-aware via correlated subquery on `sources.sort_mode` (`lib/backend/sql.dart`)
  - Persist: `updateSource` writes `sort_mode`; also fixes latent color-wipe bug (omitted color in edit) (`lib/backend/sql.dart`)
  - UI: toggle "Use provider channel order" in edit dialog; state management + color preservation (`lib/edit_dialog.dart`)
- `flutter analyze --no-fatal-infos` clean (2 pre-existing tolerated INFOs)

---

## [v1.25.5+252] - 2026-06-03

**Three fixes:** changelog documentation (fix248) + TV D-pad cell menu (fix250) + TV channel selector focus (fix252).

### Fixed
- **fix248 — Changelog documentation** — Added missing detailed entries for releases 1.25.3 and 1.25.4 to `_changelog` in `whats_new_modal.dart`. These entries now appear in the "Full changelog" history and the "What's new" summary (1.25.4 release notes). Previously both versions fell back to placeholder text. Regenerated `version.json` with 1.25.4 release notes.
- **fix250 — TV D-pad access to cell options menu** — On TV, once all cells in a multi-view grid were filled, the cell options menu (Replace channel / Full screen / Close) became unreachable because it was bound to `onLongPress` (touch only). Added D-pad shortcuts: `select`, `enter`, `gameButtonA`, and `contextMenu` keys now open the cell menu via `FocusableActionDetector`. Also improved the empty-cell "+" button: replaced `FloatingActionButton` with a focusable circular button that autofocuses on cell 0 with visible focus ring and highlights.
- **fix252 — TV channel selector focus** — Channel picker's search field no longer autofocuses, so the first channel tile receives initial D-pad focus. Users can now scroll immediately with the D-pad; pressing UP from the top row moves focus into the search bar (via existing `DpadTextField` traversal). The "UP → search" plumbing already existed; fix252 unblocks it by stopping autofocus trapping.

### Technical
- **fix248**: Two edits to `lib/whats_new_modal.dart` (added 1.25.4 and 1.25.3 changelog entries); regenerated `version.json` via `scripts/update_version_json.py`
- **fix250**: Five edits to `lib/multi_view_cell.dart` (services import, `_CellMenuIntent` class, `_addButtonFocused` state, D-pad shortcuts/actions on filled cells, focusable "+" on empty cells)
- **fix252**: Four edits to `lib/channel_picker_screen.dart` (`autofocus: false` on search field, `autofocus` parameter on `_buildTile`, pass `autofocus: i == 0` at both call sites)
- `flutter analyze --no-fatal-infos` clean (2 pre-existing tolerated INFOs)

---

## [v1.25.4+246] - 2026-06-03

**Two fixes:** EPG auto-match performance (fix244) + multi-view cell self-healing (fix246).

### Fixed
- **fix244 — EPG auto-match scan 1.3s → sub-second** — Partial index `idx_epg_unmatched` on `channels(source_id)` with `WHERE media_type=0 AND epg_manual_override IS NULL AND epg_channel_id IS NULL` turns the unmatched-live-channel scan (runs during EPG refresh) from a `media_type` index scan into a targeted lookup. Pre-verified on a 320k catalog: query time 9.05ms → 2.25ms. Storage overhead negligible (index only covers unmatched rows).
- **fix246 — Multi-view cells self-heal mid-session drops** — After exhausting fast transient retries (5 × 3s), cells now attempt bounded slow recovery: up to 5 re-opens at 60 s intervals, then permanent error UI. Each slow attempt gets a fresh fast budget. Gentle on provider connection limits (important for 4-connection accounts). If the stream recovers and plays stably for 15 s, both budgets reset and it can self-heal again. Cancelled on dispose / channel change. Pre-verified against the TV 2×2 scenario (cells dropped at +22, +28, +56 min).

### Technical
- **fix244**: Migration 19 in `lib/backend/db_factory.dart` (partial index creation)
- **fix244**: Comment-only fix to default doc in `lib/models/settings.dart` (no code behavior change)
- **fix246**: Five edits to `lib/multi_view_cell.dart`: new slow-recovery fields + scheduler; reset on fresh start & stable playback; call scheduler in transient give-up branch
- `flutter analyze --no-fatal-infos` clean (2 pre-existing tolerated INFOs)

---

## [v1.25.3+240] - 2026-06-03

**Bug fix** — "Analyze playback & suggest settings" can recommend values outside the slider range.

### Fixed
- **Analyzer bounds mismatch** — `PlaybackAnalyzer.recommend()` was clamping suggestions to its own hardcoded numbers instead of the settings UI sliders' min/max. Example: `liveCacheSecs` could suggest up to 120 while the slider maxes at 60; `startupGraceMs` could suggest below 100 while the slider floor is 100.
- **Solution** — introduce `SettingBounds` as the single source of truth for all playback setting min/max values; the analyzer now clamps to these bounds, which exactly match the current sliders.

### Technical
- New file: `lib/backend/setting_bounds.dart` (SettingBounds class with 5 pairs of min/max constants)
- Modified: `lib/backend/playback_analyzer.dart` (import SettingBounds; 5 clamp sites updated)
- Constants are device-dependent where applicable: `bufferSizeMax` is a getter returning `DeviceMemory.maxBufferSizeMb`
- Future hardening: sliders can be migrated to read their min/max from SettingBounds for guaranteed lock-step (values already match, migration is mechanical)


## [v1.23.29+222] - 2026-06-02

**Diagnostic release** for refresh slowness (supersedes v1.23.28+218, fix220).

### Added
- **Per-closure timing diagnostics** inside write transactions to identify which refresh phase (insert batch / updateGroups / restorePreserve) is slow on-device
- **Raw Xtream response export** to files (`xtream_dump_*.json`) when debug logging is on, allowing exact apples-to-apples sandbox replay of the parse + insert workload
- **One-shot EXPLAIN QUERY PLAN** logging for the two index-sensitive refresh statements (restorePreserve UPDATE and updateGroups UPDATE+correlated-subquery), executed once per refresh, not per row

### Changed
- Dropped fix220's `synchronous=OFF` SQLite pragma experiment (Samsung S25 with fast UFS storage shows the bottleneck is not storage I/O but likely Dart/isolate round-trip overhead, and the durability risk isn't justified)
- Enhanced logging in `Sql.commitWriteBatched`: per-closure timing callback, slow-closure count summary

### Technical
- All changes are diagnostic/logging only; no behavior changes
- New symbols: `Sql.onClosureTimed` callback parameter; `Sql.logRefreshQueryPlans(sourceId)`
- New imports: `dart:io`, `utils.dart` in `xtream.dart`; `dart:io` in `settings_view.dart`
- UI: long-press "Export log file" tile now exports raw Xtream dumps (concatenated) for easier diagnostic collection on phones (separate from the normal log export)
- `flutter analyze --no-fatal-infos` clean (2 pre-existing tolerated INFOs in settings_view.dart only)

### How to use
1. Enable debug logging in Settings
2. Refresh Emjay (and Aniel) — this generates `xtream_dump_*.json` files in the app directory
3. **TAP** "Export log file" to save the normal debug log (unchanged)
4. **LONG-PRESS** "Export log file" to export the raw source dumps concatenated into a single file (diagnostic)
5. Send both the log and the source dumps back — the raw payloads enable true apples-to-apples sandbox replay of the exact parse + insert workload

---
