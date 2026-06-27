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

## Where we are (v2.1.0+571, shipped + verified)

- Custom LGPL-max libmpv on `main` (435 filters incl. `fps`). See
  `docs/CUSTOM_LIBMPV.md` (+ `docs/LIBMPV_COMPONENTS.md`).
- `framedrop=decoder` auto-applies on low-RAM Android (onn 4K Plus) → smooth
  high-fps at default settings. See `runbooks/fix571.md`.
- The fps-output-cap (`vf=lavfi=[fps=fps=30]`) is parked OFF on branch
  `libmpv-lgplmax-verify` (the custom libmpv has the filter; untested in-app).

## Backlog (status-audited against HEAD 2026-06-27)

Legend: ✅ done/close · 🔧 done-in-code, needs on-device validation · ⚠️ re-verify
or partial · ❌ open. File:line evidence in parens.

**A. Playback smoothness (v2.1.0 arc)**
1. 🔧 **Validate v2.1.0 on the onn** — `framedrop=decoder` is SHIPPED
   (`mpv_engine.dart:1058`); just confirm it's smooth at default settings on a
   real high-fps/live stream (ADB STATS: `voDrop≈0`).
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
7. ❌ **TV full-screen transport controls** — no D-pad-CENTER handler raises
   play/pause/seek (`player.dart:1139` handles only CH+/CH−); transport lives only
   in the always-on bottom bar. Glaring UX gap.

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
9. ❌ **Stream-info label — still broken (phone re-confirmed 2026-06-27); use the
   simpler approach.** fix522's latch+seed (separate `PlayerStreamInfoLabel` in
   `topButtonBar`, `player.dart:1601`) did NOT fix it. **DECIDED — do NOT revive
   the latch widget:** concatenate the stream-info onto the channel-NAME string
   already rendering in the top bar — e.g. `|4K| ESPN HD` → `|4K| ESPN HD (720p
   H.264)` (resolution-only like `(1080p)` if codec unavailable); leave the EPG
   line as-is. Appending to the already-rendering name text sidesteps the
   `MaterialVideoControlsTheme` frozen-slot listener-race entirely — model it on
   the self-updating `PlayerEpgNowLabel` / `now_next_strip` pattern. Full note:
   memory `free4me-pending-player-tv.md`.
10. ❌ **Export files accumulate — purge on new QR session (confirmed 2026-06-27).**
    Old timestamped export files remain on disk. **DECIDED fix:** when a NEW QR/LAN
    export session starts, delete any prior timestamped export files EXCEPT the
    current session's. (Log rotation 20 MB + `.old` already exists in
    `app_logger.dart:23`; this is specifically the export/QR-served files —
    `export_server.dart` / `settings_io.dart`.)
11. ❌ **Backup/restore drops 3 settings** — `multiViewDecode`,
    `devControlsHideSecs`, `playerZoomMode` are NOT in `settings_io.dart`
    toJson/fromJson → reset to defaults on restore. Small, well-scoped fix.

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

### Bottom line & suggested order
Already done/closeable: **#12, #13, #14, #15, #17** (+ **#1** shipped→validate,
**#20** known). Confirmed open with a DECIDED approach (ready to implement):
**#8, #9, #10**. Other open: **#2, #3, #4, #5, #6, #7, #11, #16, #18, #21, #22**
(#19 cosmetic).

**Suggested first-pass order (propose a plan before coding each):**
1. **#1** — validate v2.1.0 on the onn (~10 min). Confirm the shipped
   `framedrop=decoder` fix is actually smooth (`voDrop≈0`) before building on it.
2. **#8** — Shield regression, **IF a Shield is in the fleet**: v2.1.0's custom
   libmpv black-screened the Shield (it was working under stock libmpv). A live
   regression outranks every enhancement — confirm a Shield is in use, then
   prioritize it. If no Shield, defer.
3. **#10** — export-file purge on new QR session (storage/data-loss bug; decided
   spec; bounded).
4. **#9** — stream-info append-to-channel-name (long-running annoyance, now a
   small decided change; not the latch widget).
5. **#11** — backup drops 3 settings (small data-loss fix).

Then features (**#7** TV transport controls, **#2** force-30 toggle, **#4/5/6** TV
Live-view UX) → debt (**#16** R8, **#18** groups key, **#22** overlay, **#21**
prune docs, **#19** cosmetic).

## On-device testing

- onn 4K Plus on ADB at `10.0.168.194:45981` (verify it's still reachable).
- `debugLogging` on → per-stream `STATS` in logcat: `voDrop`/`decDrop` are
  authoritative, `vfFps` is NOT.
- `screencap` shows BLACK for live video (hardware texture plane) even when
  playing — trust the `HEARTBEAT` log (`pos` advancing), not the screenshot.

Tell me what you'd tackle first, or I'll point you at one.
