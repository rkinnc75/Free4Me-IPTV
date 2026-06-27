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

## Pending items (pick one; propose a plan before coding)

**A. Playback smoothness (the v2.1.0 arc)**
1. Validate v2.1.0 on the onn — confirm `framedrop=decoder` is smooth at default
   settings on a real high-fps/live stream (ADB STATS: `voDrop≈0`).
2. Force-30fps opt-in toggle — finish the parked `libmpv-lgplmax-verify` work:
   re-enable the cap behind the existing `devCapFpsLowRam` setting (default OFF),
   verify `vf=lavfi=[fps=fps=30]` on-device, then sweep `framedrop=decoder` vs the
   30fps cap on LIVE sport (replays don't show judder clearly).
3. Settings layout — optionally co-locate the 4K→1080p (`cap1080pOnLowRam`) and
   force-30 toggles under one "Performance / low-RAM" group in Playback (keep them
   independent toggles).

**B. TV Live-view UX — details + build notes in `BACKLOG_TV_UI.md` (build 5→6→7 in order)**
4. #5 Collapse the category rail on category-select (animate the fixed 210px rail
   to a sliver; D-pad LEFT from channels re-expands; preserve restored focus).
5. #6 Auto-preview on 3s dwell in Live TV browsing — ONE shared, reused preview
   player (never spawn per channel); keep the last preview until a new dwell
   replaces it. **RAM risk on the 2GB onn — measure before shipping.**
6. #7 Long-press channel menu: add the **Multi-view** entry (the rest of the menu
   is already built; live-TV-only).
7. **TV playback transport controls are missing** — center D-pad during
   full-screen TV playback should raise play/pause/seek like phone mode; nothing
   appears today. Related: TV mode has no D-pad nav (`free4me-pending-player-tv`).

**C. Known bugs / stability**
8. Shield black-screen (unresolved through fix395/396) — now that the custom
   libmpv ships to ALL devices, re-check whether Shield behavior changed;
   ExoPlayer revert was the old contingency.
9. Stream-info label still broken after fix522 (phone-confirmed).
10. **Export/backup files have no rotation/cap** → can fill device storage (forced
    an onn data-clear 2026-06-26).

**D. Performance**
11. Import/refresh index-recreate ~9 min bottleneck (fix523 in design): add
    `temp_store`/`cache_size` pragmas to stop disk-spill. fix549 added per-index
    timing — target the worst indexes first. (= BACKLOG #1.)

**E. Tech-debt / audit (fix504+ candidates — see `free4me-audit-2026-06` memory)**
12. DVR-seek dead code, duck-mute, settings-backup drops, LAN-export secret scrub,
    R8 off, unused deps/dead files.
13. Minor: groups unique-key migration needs `media_type` (BACKLOG #2, low impact);
    empty-state hint on Live when Favorites-default is empty (BACKLOG #3, minor).

**F. Housekeeping**
14. APK is ~109 MB (full libmpv × universal arm+arm64) — per-ABI split / trim
    unused decoders if size matters. Stale `multi-view-plan.md` +
    `updated-help-messages.md` are prunable.

## On-device testing

- onn 4K Plus on ADB at `10.0.168.194:45981` (verify it's still reachable).
- `debugLogging` on → per-stream `STATS` in logcat: `voDrop`/`decDrop` are
  authoritative, `vfFps` is NOT.
- `screencap` shows BLACK for live video (hardware texture plane) even when
  playing — trust the `HEARTBEAT` log (`pos` advancing), not the screenshot.

Tell me what you'd tackle first, or I'll point you at one.
