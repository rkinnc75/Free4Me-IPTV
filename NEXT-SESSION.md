# NEXT-SESSION.md — kickoff for a fresh coder+builder session

Paste this (or just tell the session "read NEXT-SESSION.md and begin").

---

I'm working on free4me-iptv (this repo). You are the CODER + BUILDER — you can
edit, build, push, tag, and release. **This desktop env IS the builder**
(`flutter`, `gh`, `adb`, CI all work — see memory `free4me-desktop-is-builder`).
The "Claude does NOT build" framing in `GROUND_ZERO.md` is for the separate
PHONE-coder env only; ignore it here.

**START by reading `ONBOARDING.md`** (current state, build/ship, key files,
gotchas). `AGENTS.md` auto-routes there; your memory index auto-loads the
cross-cutting state.

## Current state — v2.2.21+610 (shipped, on `main`, tagged)

Last tag on the remote = **v2.2.21**. Verify with
`git ls-remote <url> refs/heads/main refs/tags/v2.2.21` before branching.

Custom LGPL-max libmpv (435 filters incl. `fps`) is on `main` via
`dependency_overrides` (don't touch it). `framedrop=decoder` auto-applies on
low-RAM Android (onn). See `docs/CUSTOM_LIBMPV.md`, memory
`free4me-custom-libmpv` / `free4me-onn-framedrop-decoder`.

### This session's arc (v2.2.11 → v2.2.21) — TV Live-guide hardening + Shield
Driven by two real-remote test rounds on the onn 4K Plus. Each shipped fix went
through `flutter analyze` + a debug build + a **multi-agent adversarial review**
(Workflow) before commit; runbooks/fix600–610.md carry the details.

- **v2.2.11–2.2.13 (fix600–602):** EPG-stays-current ("Both": launch
  stale-refresh + source-refresh-also-EPG + live guide reload via
  `EpgService.epgVersion`); TV search DOWN/Enter → first result card; held-OK
  channel context menu on the Live guide (Play / Open in Multi-view / favorite),
  + a touch-long-press path so it's adb-verifiable.
- **v2.2.14–2.2.17 (fix603–606):** Live-guide behavioral fixes — category-enter
  no longer auto-plays (orphan-KeyUp guard + 700ms `_play` backstop); held-OK
  opens on RELEASE (no flash-then-play/cycling); browsing categories shows an
  EMPTY grid until you open one; favorite STARS; **EPG rows align with the
  channel rail** (equal `_rowHeight`, rail→grid scroll mirror, header in a top
  row); timeline snaps to :00/:30; **12/24-hour clock setting** (default 12h,
  **no AM/PM** — shared `guideClockFmt()` in settings_service, used by the guide
  + now/next strip + schedule + player label).
- **v2.2.18–2.2.21 (fix607–610):** **Live-TV-tab held-OK diagnostic easter egg**
  (gated `debugLogging && !logUserPass`) via shared `IssueReporter`; tab held-OK
  detector (History clear-long-press now works by remote too); **Shield
  startup-freeze** fixes (gate `refreshIfStale` until warm-up; migration pragmas;
  `IF NOT EXISTS` on browse indexes; the "Preparing for the best Free4Me
  experience…" loading splash); **Live TV remembers your place** on tab return.

## Hard rules (non-negotiable)

- **GitHub credential: the `rkinnc75` PAT in `.github-token` ONLY. NEVER the
  `rkalsky` `gh` account** (403s here). Push via the inline PAT URL:
  `git push "https://$(tr -d '\r\n' < .github-token)@github.com/rkinnc75/Free4Me-IPTV.git" main`.
  The inline-PAT push is covered by a NARROW allow rule in
  `.claude/settings.local.json` — do NOT grep `~/.git-credentials`, force a
  credential helper, or add a broad `Bash(git push:*)` rule (the classifier
  blocks all three). The private-repo read-only review PAT is pasted per-session
  by Rich — NEVER store it in any file.
- **Push ONE tag at a time** (`… main`, then `… vX.Y.Z`). NEVER `git push --tags`
  (GitHub fires the release workflow only for ≤3 new tags at once → a 4th is
  silently skipped; this stranded v2.2.2).
- A release ships ONLY when a `vX.Y.Z` tag is pushed, and ONLY after: bump
  `pubspec.yaml`, add the changelog entry to `lib/whats_new_modal.dart`
  (apostrophe-free strings — `…`/`don't`→ avoid `'`), run
  `python3 scripts/update_version_json.py` (version.json MUST be on `main`
  BEFORE the tag), and `flutter analyze` is clean. Stage explicit files —
  **never `git add -A`** (the export zip + secrets must not be swept; see memory
  `apply-fix-script-gaps`).
- Commits: `vX.Y.Z: <subject> (fixNNN)`. No Jira keys, no AI co-author trailers.
- Don't remove `dependency_overrides` (custom libmpv); don't change the signing
  identity (`free4me-iptv`) or package names (`open_tv` / `me.free4me.iptv`).
- **Root-cause before fixing.** SQL inside Dart strings is invisible to
  `flutter analyze` — reason about / run DB paths for SQL changes.
- **NEVER run a fork/subagent that EDITS this same working copy** while you're
  also editing — they interleave commits. (The fix607 fork wrote `13f3608` into
  this tree and it became an ancestor of my commit. Use read-only agents, or a
  `worktree`-isolated agent, for parallel work.)

## New procedures this session (FOLLOW THESE)

- **iMessage on every release + every stopping point** (memory
  `imessage-alert-rule`). Send to `rkalsky@kalsky.com` via:
  `osascript scratchpad/imsg.applescript "rkalsky@kalsky.com" "<msg>"` where the
  script is `on run {theAddr, msg} … buddy theAddr of (1st service whose service
  type = iMessage) … send msg to it`. **GOTCHA: do NOT name the var `handle`** —
  it collides with a Messages keyword (`-1728`); use `theAddr`. **Every
  test-requiring completion's iMessage includes a flat, continuously-NUMBERED
  validation plan** (1,2,3… across all features) so Rich can reply with exact
  step numbers. Send-only (receiving needs Full Disk Access on Claude.app +
  reading `chat.db` — not set up).
- **Adversarial-review each substantive fix** with a Workflow (find → verify),
  apply confirmed findings, THEN ship. It has caught a real (often HIGH) bug in
  most rounds.
- **Build/verify loop:** `flutter` is at `~/development/flutter/bin`
  (3.44.2). Debug-build to compile-check (`flutter build apk --debug`). On
  tag-push, CI builds the signed release (~8–9 min); poll
  `actions/runs?...head_branch=vX.Y.Z`, then download the APK via the release
  asset API + `adb -s 10.0.168.194:45981 install -r`. Verify with `screencap`
  (coords are in the **1920×1080 override** space; the onn is physically 4K).
- **adb CANNOT inject a held key** (no root; `sendevent` permission-denied;
  `input keyevent --longpress` = a quick press). So held-OK GESTURES (the channel
  menu, the easter egg, tab long-press) are NOT adb-verifiable — verify by review
  + the proven fix586 detector, the synthetic touch-long-press where a widget
  wires `InkWell.onLongPress`, and the real remote. See
  `free4me-tv-longpress-menu`.

## Open / pending

- **Verify on the REAL REMOTE / a SHIELD** (Rich's side; numbered plan texted):
  the held-OK gestures, and the Shield startup-freeze coverage — **the onn can't
  reproduce the Shield freeze** (it cache-skips below 2300 MB; the Shield is
  ~2945 MB and rebuilds the 272k-entry cache ~75 s). See `shield-startup-freeze`.
- **#8 Shield BLACK-screen — STILL OPEN** (distinct from the white-screen, which
  this session fixed). Regression from the v2.1.0 custom libmpv (`.so`); was
  fixed under stock libmpv by fix410 (Impeller off) + Tegra→`mediacodec-copy`.
  Needs a Shield to repro + the fix396 decision tree under the custom build.
  Memory `shield-blackscreen-investigation`. Options: gate Tegra to stock libmpv,
  rebuild the `.so` for Tegra, or the Media3 contingency (#24, parked).
- **EPG window doesn't re-anchor on a bare app-RESUME** (foregrounding next-day
  WITHOUT a tab switch) — no lifecycle observer re-anchors `_windowStart`. Small
  enhancement: add a `resumed` branch that calls `_reloadGridProgrammes()`.
  (fix610 fixed the tab-return case.)
- **#7 Mode B** (TV player D-pad navigates the control-bar buttons) — needs a
  custom focusable overlay (media_kit's bars can't be focus-driven). Deferred;
  memory `free4me-pending-player-tv`. (Direct-map ▲▼/◀▶/OK is DONE + verified.)
- **Music/Radio section — PARKED** (Rich, 2026-06-29). Confirmed via the export
  that Dino's "Music" is just livestream channels in categories named
  `|AR| MUSIC` / `|ALB| MUSIC` / `|UK| MUSIC` (no separate type) — a derived
  view by category-name would replicate it, but not building it now. Memory
  `free4me-audio-music-level`.
- **#24 Media3-as-default — BACKLOGGED INDEFINITELY** (ADR
  `docs/media3-engine-scoping.md`): don't; libmpv can't be dropped. Try
  `forceHardware`/libmpv-HW first.

## On-device testing
- onn 4K Plus on ADB at `10.0.168.194:45981` (verify reachable). Input space =
  1920×1080 (override). Has a full Dino Xtream source (~149k ch) + EPG.
- `debugLogging` on → per-stream `STATS` in logcat: `voDrop`/`decDrop` are
  authoritative; `vfFps` is NOT.
- `screencap` shows BLACK for live video (hardware texture plane) even when
  playing — trust the `HEARTBEAT`/`STATS` log, not the screenshot. (Guide UI,
  splash, menus, focus DO render in screenshots.)
- Blind D-pad nav on the deep category list is flaky (focus escapes to the nav;
  traversal order is nav → Watch button → rail). Screenshot between steps.

Tell me what you'd tackle first, or I'll point you at one.
