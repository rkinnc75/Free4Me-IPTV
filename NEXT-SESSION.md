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
8. ⚠️ **Shield black-screen — RE-VERIFY.** Root-cause routing fix shipped (fix395,
   `hwdec_routing.dart:47` Tegra→`mediacodec-copy`) + fix396 diag + fix410
   Impeller-disable diag. The investigation was awaiting a device log, AND v2.1.0
   now ships the custom libmpv to ALL devices — re-test on Shield to confirm
   resolved (don't assume). ExoPlayer revert was the old contingency.
9. ⚠️ **Stream-info label — RE-VERIFY.** Latch+seed shipped (fix522,
   `mpv_engine.dart` `lastStreamInfo`), but a memory flagged it still broken on
   phone after fix522. Confirm on device; if still broken, root-cause beyond the
   mount-race.
10. ⚠️ **Export/backup storage — verify.** Log rotation (20 MB + `.old`,
    `app_logger.dart:23`) and temp-export cleanup ARE in place, and Xtream dumps
    purge on log-clear — yet an onn data-clear happened 2026-06-26. Find what
    actually filled storage (likely Xtream dumps accumulating until a manual clear)
    and add an auto-cap if so.
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

### Bottom line
Already done/closeable: **#12, #13, #14, #15, #17** (+ **#1** shipped→validate,
**#20** known). Need a quick re-verify: **#8, #9, #10**. Genuinely open:
**#2, #3, #4, #5, #6, #7, #11, #16, #18, #21, #22** (#19 is cosmetic).
Suggested first picks: **#1** (cheap confirm the shipped fix works), **#7** (TV has
zero transport controls), **#11** (small, real data-loss), **#8** (regression risk
from the new libmpv on Shield).

## On-device testing

- onn 4K Plus on ADB at `10.0.168.194:45981` (verify it's still reachable).
- `debugLogging` on → per-stream `STATS` in logcat: `voDrop`/`decDrop` are
  authoritative, `vfFps` is NOT.
- `screencap` shows BLACK for live video (hardware texture plane) even when
  playing — trust the `HEARTBEAT` log (`pos` advancing), not the screenshot.

Tell me what you'd tackle first, or I'll point you at one.
