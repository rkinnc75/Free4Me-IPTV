# NEXT-SESSION.md — kickoff for a fresh coder+builder session

Paste this (or just tell the session "read NEXT-SESSION.md and begin").

---

I'm working on free4me-iptv (this repo). You are the CODER + BUILDER for it —
you can edit, build, push, tag, and release.

**START by reading `ONBOARDING.md`** (repo root): current state, build/ship
process, key files, gotchas. `AGENTS.md` auto-loads and routes there; your memory
index auto-loads the cross-cutting state. `GROUND_ZERO.md` is the phone-coder
narrative (skim only if useful).

## Hard rules (non-negotiable)

- **GitHub credential: use the `rkinnc75` PAT in `.github-token` ONLY. NEVER the
  `rkalsky` `gh` account** (it 403s on this repo). Always push via the inline PAT
  URL with `set -o pipefail` (a bare `git push | sed` reports a rejected push as
  false success).
- Commits: `fixNNN: <subject>` convention. No Jira keys. No AI co-author trailers.
- A release ships ONLY when a `vX.Y.Z` tag is pushed — and only after the version
  bump (`pubspec.yaml`), changelog (`lib/whats_new_modal.dart`, apostrophe-free),
  and `python3 scripts/update_version_json.py` are done and `flutter analyze` +
  `flutter test` are green. Stage explicit files, never `git add -A`.
- Don't remove the `dependency_overrides` (custom libmpv) block; don't change the
  signing identity (alias `free4me-iptv`) or package names (`open_tv` /
  `me.free4me.iptv`).
- Root-cause before fixing. SQL inside Dart strings is invisible to `flutter
  analyze` — run the app for DB/SQL changes.

## Where we are (v2.1.6+579, shipped + verified)

- Custom LGPL-max libmpv on `main` (435 filters incl. `fps`). See
  `docs/CUSTOM_LIBMPV.md` (+ `docs/LIBMPV_COMPONENTS.md`).
- `framedrop=decoder` auto-applies on low-RAM Android (onn 4K Plus) → smooth
  high-fps at default settings. See `runbooks/fix571.md`. **Validated on-device.**
- The fps-output-cap (`vf=lavfi=[fps=fps=30]`) is parked OFF on branch
  `libmpv-lgplmax-verify` (the custom libmpv has the filter; untested in-app).
- **Shipped this session (2026-06-27):** v2.1.1 export purge + diag drop/sync line
  (fix572) · v2.1.2 backup-fields fix573 + stream-info-on-name fix575 · v2.1.3–4
  TV player D-pad direct-map (fix576/577, on-device verified) · v2.1.5 Mode B
  attempt (fix578) → **reverted** v2.1.6 (fix579) as a regression. Media3 engine
  (#24) scoped → backlogged indefinitely (`docs/media3-engine-scoping.md`).

## Backlog (status-audited against HEAD 2026-06-27)

Legend: ✅ done/close · 🔧 done-in-code, needs on-device validation · ⚠️ re-verify
or partial · ❌ open. File:line evidence in parens.

**A. Playback smoothness (v2.1.0 arc)**
1. ✅ **DONE — validated v2.1.0 on the onn (2026-06-27).** `framedrop=decoder`
   confirmed smooth on a live 1080p60 stream (SP-YES): voDrop 0(+0) over 9.5 min,
   software decode. Note `hwdec=no` on the onn (software by design — see #8/#24).
2. ❌ **Force-30fps opt-in toggle** — still disabled on `main` (`mpv_engine.dart`
   `const capFps=false`, `vf=''`); real work parked on branch
   `libmpv-lgplmax-verify`. The custom libmpv now HAS the `fps` filter, so this is
   the main open playback task: re-enable behind `devCapFpsLowRam` (default OFF),
   verify `vf=lavfi=[fps=fps=30]` on-device, then sweep decoder vs 30fps-cap on
   LIVE sport.
3. ❌ **Settings "Performance / low-RAM" group** — render cap (`cap1080pOnLowRam`,
   Playback §, `settings_view.dart:~2825`) and framedrop/capFps (Developer §,
   `~4262`) are still in SEPARATE sections; no unified group.

**B. TV Live-view UX** *(details + build notes in `BACKLOG_TV_UI.md`; build 5→6→7)*
4. ❌ **Collapse category rail on select** — rail still FIXED 210px
   (`tv_browse_view.dart:191`); no collapse/sliver/D-pad-LEFT re-expand.
5. ❌ **Auto-preview on 3 s dwell in Live browse** — does NOT exist. (`tv_hero_preview.dart`
   is a DIFFERENT feature: 700/1100 ms muted preview in the EPG *guide*, not Live
   browse.) RAM risk on the 2 GB onn — one shared reused player.
6. ❌ **Long-press menu → Multi-view entry** — menu has fav/category/mini-player/
   history (`channel_tile.dart:331-366`); Multi-view entry still missing.
7. ✅/⚠️ **TV player D-pad — direct-map DONE + verified; bar-nav (Mode B) deferred.**
   Shipped fix576/577 (v2.1.3–4), on-device verified: ▲▼ = channel up/down,
   ◀▶ = seek ∓10s (when DVR active), OK = play-pause + reveal the bars (synth tap).
   fix577 also fixed the guide launching `Player` with no playlist (`_canSurf` was
   always false). **Mode B** (D-pad navigates the bar buttons Cast/PiP/Subtitles/
   Audio/Aspect) was attempted in fix578/v2.1.5 by disabling media_kit auto-hide +
   pushing focus into the bars — it FAILED on-device (media_kit's bars auto-hide on
   a pointer timer that ignores key/focus, and its buttons are not reachable by
   directional traversal) and REGRESSED the D-pad, so it was reverted in
   fix579/v2.1.6. Real Mode B needs a **custom focusable overlay** (deterministic
   visibility + focus), NOT media_kit's bars — its own follow-up. See
   runbooks/fix578.md + fix579.md and memory `free4me-pending-player-tv`.

**C. Known bugs / stability**
8. ❌ **Shield black-screen — REGRESSION in v2.1.0 (custom libmpv).** CONFIRMED
   2026-06-27: Shield was **WORKING before the new libmpv** — it had been fixed by
   **fix410 (`EnableImpeller=false`)** + fix395's Tegra→`mediacodec-copy` routing,
   stable under the STOCK libmpv. The v2.1.0 custom LGPL-max `.so` re-broke it
   (Shield isn't low-RAM, so fix571's framedrop change doesn't apply — the libmpv
   swap is the only relevant change). Reproduce on a Shield with debug logging and
   re-run the fix396 `DECODE`/`HEARTBEAT` decision tree under the custom build
   (decode vs texture vs compositing) — see memory `shield-blackscreen-investigation`.
   Options: gate Shield/Tegra back to stock libmpv (the `dependency_overrides` is
   all-or-nothing today), rebuild the custom `.so` differently for Tegra, or the
   ExoPlayer-revert contingency.
9. ✅ **DONE — stream-info appended to channel name (fix575 / v2.1.2, on-device
   verified 2026-06-27).** New self-updating `PlayerChannelNameLabel` polls
   `engine.lastStreamInfo` (bounded) and renders `name  (1080p H.264)`; the broken
   `PlayerStreamInfoLabel` latch widget + its test were deleted. Verified on the
   onn: top bar shows "SP - YES NETWORK HD (1080p H.264)".
10. ✅ **DONE — export-artifact purge (fix572 / v2.1.1).** `SettingsIo.purgeStaleExportArtifacts`
    (pure `staleExportArtifactNames` + fail-soft IO) runs at the start of each
    export session (QR/LAN `_buildExportBundle` + save-to-file `exportToFile`),
    keeping only the current artifact. Test: `test/fix572_export_purge_test.dart`.
11. ✅ **DONE — backup/restore preserves the 3 settings (fix573 / v2.1.2).**
    `multiViewDecode`, `devControlsHideSecs`, `playerZoomMode` added to
    `settings_io` toJson/fromJson; pinned by `test/fix573_settings_roundtrip_test.dart`.

**D. Performance**
12. ✅ **DONE — index-recreate speedup.** fix523 added `temp_store=FILE` +
    `cache_size` pragmas (`sql.dart:461`), ~9 min → ~3 min. Close.

**E. Tech-debt / audit** *(the `free4me-audit-2026-06` "fix504+" list — mostly already resolved)*
13. ✅ **CLOSE — not dead.** "DVR-seek dead code" is actually ACTIVE and wired to
    UI buttons (`player.dart:1055` `_dvrSeekBy`/`_dvrGoLive`). Stale flag.
14. ✅ **DONE — duck-mute** implemented via `audio_session` (`multi_view_screen.dart:61-100`).
15. ✅ **DONE — LAN-export secret scrub.** Credentials stripped by default;
    user-gated "include credentials" dialog (`settings_io.dart:773`,
    `settings_view.dart:3675`).
16. ❌ **R8 / minification OFF** — no `minifyEnabled`/`shrinkResources` in
    `android/app/build.gradle` (Flutter default = off). Enabling shrinks the APK
    (#20) but can break reflection/JNI — test thoroughly.
17. ✅ **CLOSE — no unused deps / dead files** (ExoPlayer fully gone, Cast still used).

**F. Minor / housekeeping**
18. ❌ **Groups unique key missing `media_type`** (low impact) — index still
    `(name, source_id)` (`db_factory.dart:86`); the `media_type` column was added
    (migration 33) but not to the constraint → same-named Live/VOD categories
    collide.
19. ⚠️ **Live empty-state hint** — generic "No titles" shows when empty
    (`tv_browse_view.dart:228`); no Favorites-specific "No favorites yet…" copy.
    Cosmetic.
20. ✅ **KNOWN — APK ~109 MB** (universal arm+arm64, intended; `release.yml:295`).
    Shrinkable via #16 / per-ABI split if it matters.
21. ❌ **Prune stale docs** — `multi-view-plan.md` + `updated-help-messages.md`
    (root, May 29, superseded). Trivial.
22. ⚠️ **NEW — Diag overlay on all devices.** `DebugStatsOverlay`
    (`debug_stats_overlay.dart`) is gated at `player.dart:1410` to **single-cell
    full-screen + `debugLogging` + MpvEngine**. It is NOT device-gated (any
    phone/TV/Shield shows it in full-screen), but it's absent in multi-view cells
    and PiP. Goal "show on all devices when diag enabled": already true for
    full-screen — extend to multi-view/PiP; and if it genuinely fails to appear on
    a specific device, repro that as a render bug.

**G. New requests (2026-06-27)**
23. ⚠️ **"Confirm to exit" (double-back-to-exit) — BUILT then REVERTED from
    v2.1.2; redo for v2.1.3.** A first implementation (setting + `ConfirmToExit`
    PopScope wrapper at the `_RootPage` root, default ON) was reverted after the
    pre-release review found a **phone-path defect**: the touch bottom-nav swaps
    SOLE routes via `Navigator.pushAndRemoveUntil(..., (route)=>false)` (sites:
    `bottom_nav.dart:97`, `settings_view.dart:627`, `home.dart:531`,
    `setup.dart:329`) — which removes the root route AND the guard, so after the
    first view switch a single BACK exits. (TV is unaffected: `TvShell` is a
    persistent `IndexedStack`, so a root wrap survives there.) **Correct design
    for v2.1.3:** put the guard inside each PERSISTENT top-level surface, gated on
    the setting — phone destinations are exactly `Home` and `SettingsView` (both
    always pushed as sole routes, so a PopScope at their build root only fires at
    the true exit moment) plus `TvShell` for TV; NOT a single root wrap. A
    root-level `PopScope` in `MaterialApp.builder` does NOT work (PopScope needs an
    enclosing route). Add a widget test: `pushAndRemoveUntil` a replacement `Home`,
    then assert the first system BACK shows the pill instead of `SystemNavigator.pop`.
    Setting/persistence/backup plumbing is straightforward (mirror `safeMode` in
    `settings_service.dart`; default-on-absent; add to `settings_io` round-trip —
    pinned by the fix573 test).
24. 🅿️ **REVIEWED → BACKLOGGED INDEFINITELY (2026-06-27).** Decision: not pursuing a
    Media3 default. Revisit only if Phase 0/1 (libmpv HW decode on the onn) fails AND
    a future need justifies the permanent dual-engine cost. Full ADR below.
    📋 **FILED + SCOPED — Media3/ExoPlayer HW-decode parity.** Full ADR:
    [`docs/media3-engine-scoping.md`](docs/media3-engine-scoping.md) (9-agent
    workflow: investigate → ADR → adversarial critique, claims tree-verified).
    **Recommendation: do NOT make Media3 the blanket default** ("Media3 default,
    libmpv fallback" reverses the fix350 consolidation AND libmpv can never be
    dropped — it is the sole engine on 5/6 platforms and the only path for
    RTMP/MMS/UDP/MKV/AVI/exotic-audio/malformed-TS/DVR/the fps filter — so Media3
    is strictly additive, no licensing/maintenance win). Ordered plan with gates:
    **(0, hours)** A/B the existing `forceHardware` knob (fix505) on the onn under
    the custom build — may dissolve #24 today. **(1, days)** root-cause the onn
    `hwdec_routing.dart` software routing (predates the custom build + the
    `framedrop=decoder` 0-drop win); caveat — zero-copy may be unreachable under our
    texture renderer (0 PlatformViews today). **(2, parallel)** measure real-stream
    Media3 TS failures (sustained playback, not prepare-at-t0; unbounded-by-design).
    **(3+, only if 1 fails & 2 favorable)** Media3 engine behind `PlayerEngine` →
    ship as **Option C** scoped per-format/per-device routing (Android-only;
    playback-failure fallback, never URL heuristic; FFmpeg audio ext up front),
    NOT a blanket default. Gotchas the ADR nails: 46 `MpvEngine` couplings across 11
    files (not 4); the fix350 engine-swap fallback is fully deleted; MP2/AC-3 TS
    audio needs an NDK FFmpeg ext (common, not exotic). Strongly relates to Shield #8
    (the ExoPlayer-revert contingency).

### Bottom line & suggested order
**Shipped/validated this session (2026-06-27), latest = v2.1.6+579:**
- **#1** validated (v2.1.0 decoder = 0 drops, 9.5 min @ 1080p60).
- **#10** export purge + diag drop/sync line — fix572 / **v2.1.1**.
- **#11** backup round-trip + **#9** stream-info-on-name — fix573/575 / **v2.1.2** (#9 on-device verified).
- **#7** TV player D-pad direct-map (▲▼ channel, ◀▶ seek, OK play-pause+reveal) —
  fix576/577 / **v2.1.3–4**, on-device verified.
- **#7 Mode B** (D-pad nav of bars) — fix578 / v2.1.5 → **reverted** fix579 / **v2.1.6**
  (failed on media_kit focus + regressed the D-pad; needs a custom overlay).
- **#24** Media3 — scoped → backlogged indefinitely.
- **#23** confirm-to-exit — built then reverted from v2.1.2 (phone bottom-nav); redo later.

Done/closeable: **#1, #9, #10, #11, #12, #13, #14, #15, #17** (+ **#20** known) and
**#7 direct-map**. Deferred: **#8** (Shield tester), **#23** (redo), **#7 Mode B**
(custom overlay), **#24** (parked). Other open: **#2, #3, #4, #5, #6, #16, #18, #21,
#22** (#19 cosmetic).

**Suggested first-pass order (propose a plan before coding each):**
1. **#7 Mode B** (custom focusable overlay for the bar buttons) OR **#23**
   confirm-to-exit (the Home/SettingsView/TvShell wrap + widget test) — the two
   reverted/deferred TV/UX items with known correct designs.
2. **#2** force-30fps toggle (custom libmpv has the `fps` filter; re-enable behind
   `devCapFpsLowRam`, verify on-device, sweep decoder vs 30-cap on live sport).
3. **#4/5/6** TV Live-view UX trio (rail collapse, 3 s dwell preview, Multi-view entry).
4. Debt: **#3** perf/low-RAM settings group, **#16** R8, **#18** groups key, **#22**
   overlay in multi-view/PiP, **#21** prune stale docs, **#19** cosmetic.
5. **#8** Shield regression — when a Shield is available to the 2nd-person tester.

## On-device testing

- onn 4K Plus on ADB at `10.0.168.194:45981` (verify it's still reachable).
- `debugLogging` on → per-stream `STATS` in logcat: `voDrop`/`decDrop` are
  authoritative, `vfFps` is NOT.
- `screencap` shows BLACK for live video (hardware texture plane) even when
  playing — trust the `HEARTBEAT` log (`pos` advancing), not the screenshot.

Tell me what you'd tackle first, or I'll point you at one.
