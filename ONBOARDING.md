# ONBOARDING.md — Free4Me-IPTV (coder + builder)

**Single entry point for a session that both writes code and ships releases on the desktop.**
This machine has the full toolchain (`flutter`, `gh`, `adb`, git push, CI) working locally.

> The auto-loaded `AGENTS.md` just points here. `GROUND_ZERO.md` is the *phone* coder's
> handoff (read-only mobile context) — leave it for that audience.
>
> **Source of truth for "current state" is git tags + the auto-loaded memory index, not prose docs.**

---

## 1. Current state (2026-06-29)

| Item | Value |
|---|---|
| Latest release | **v2.2.21+610** (`git ls-remote <url> refs/tags/* \| sort` for absolute truth — the desktop ships frequently) |
| Releases | https://github.com/rkinnc75/Free4Me-IPTV/releases |
| Player engine | **media_kit / libmpv only.** ExoPlayer was removed in fix350 — no `ExoEngine`/`engine_picker`. (Media3-default **backlogged indefinitely** — `docs/media3-engine-scoping.md`.) |
| libmpv | **Custom LGPL-max build**: all 435 non-GPL filters incl. `fps`/`select`/`scale`/`tonemap`, all decoders/demuxers. Wired via `dependency_overrides` → `rkalsky/media-kit` fork. LGPLv3. **Do not remove the override block in `pubspec.yaml`.** `docs/CUSTOM_LIBMPV.md`. |
| Playback smoothness | `framedrop=decoder` auto-applies on low-RAM Android (onn 4K Plus class) → smooth high-fps; **on-device validated** (decoder = 0 VO drops @ 1080p60). An opt-in `vf=fps=30` cap exists behind `forceCapFps30LowRam_v2` (OFF by default). |
| TV Live guide (v2.2.11–2.2.21) | Reworked: EPG stays current (launch stale-refresh + source-refresh-also-EPG + live reload via `EpgService.epgVersion`); search DOWN/Enter→first card; held-OK channel menu (Play/Multi-view/favorite); category-enter no longer auto-plays; empty grid while browsing categories; favorite STARS; **EPG rows align with the rail**; timeline snaps :00/:30; **12/24h clock setting (default 12h, no AM/PM)** via shared `guideClockFmt()`; **Live-TV-tab held-OK diagnostic easter egg** (gated `debugLogging && !logUserPass`); **Shield startup-freeze** mitigations + a "Preparing…" loading splash; **Live TV remembers your place** on tab return. Runbooks fix600–610. |
| TV remote (player) | D-pad **direct-map** shipped + verified: ▲▼ channel, ◀▶ seek (DVR), OK play-pause + reveal bars. D-pad **bar navigation** (Mode B) NOT done (media_kit bars can't host focus nav → needs a custom overlay). |
| `flutter analyze` | Clean (*No issues found!*). `flutter test` must be green. |

---

## 2. Repo facts & do-NOT-change

- Dart package name **`open_tv`** (intentional — do not rename).
- Android application ID **`me.free4me.iptv`**.
- Release signing alias **`free4me-iptv`** — changing the signing identity forces **every user to uninstall before updating**. The keystore lives in **CI secrets** (`RELEASE_KEYSTORE_*`), not on this machine.
- Don't change without asking: upstream Fredolx credit/donation links, default EPG window (1 day past / 7 forward), buffer slider ranges.
- **Commit convention is `fixNNN: <imperative subject>`** (e.g. `fix571: framedrop=decoder ...`), or `deps:` / `vX.Y.Z:` for non-fix work. **There is NO Jira/`PO-XXXXX` requirement here** — older docs that say so are Pinogy-template bleed-over and are wrong for this repo. **No AI co-author trailers.**

---

## 3. Build environment (this desktop)

- Flutter SDK: **`~/development/flutter/bin`** (verified). Some scripts hardcode `~/tools/flutter/bin` — adjust if you hit a "flutter not found".
- `flutter pub get` / `analyze` / `test` all run locally. First `pub get` after a fresh clone is slow — it clones the `media-kit` monorepo git dep and downloads the custom libmpv jars (MD5-verified).
- CI mirrors: **Flutter 3.44.0, Java 21 Temurin, Android SDK 36, NDK 28.2.13676358** (see `BUILD-ENV.md` for the exact pinned env).
- No local release keystore → **release builds happen in CI** (the tag push), not via `scripts/build_and_release.sh` (which requires `android/key.properties` + `release.keystore`).

---

## 4. Shipping a release (the builder path)

A `v*` tag push is the **only** trigger for a build. Commits to `main` alone do **not** build.

1. **Start from latest `main`:** `git fetch origin && git merge --ff-only origin/main` (stash local edits first if needed).
2. **Edit code.**
3. **Bump `pubspec.yaml`:** `version: X.Y.Z+N` (N strictly increases — CI enforces monotonic build numbers).
4. **Add a changelog entry** at the TOP of `_changelog` in `lib/whats_new_modal.dart`:
   ```dart
   'X.Y.Z': [
     'Concise user-facing bullet. Avoid apostrophes (the pre-commit gate rejects '
     'unescaped possessives/contractions in single-quoted Dart strings).',
   ],
   ```
5. **Regenerate `version.json`:** `python3 scripts/update_version_json.py` (it reads pubspec + the changelog entry; `latest` MUST equal the pubspec version or `pre_commit_check.py` fails).
6. **Run the gates CI also enforces:** `flutter analyze --no-fatal-infos` (expect *No issues found!*) and `flutter test` (expect *All tests passed!*).
7. **Commit with an explicit file list — never `git add -A`** (untracked screenshots / scratch docs would be swept in). Move any `fixN.md`/`.patch` into `runbooks/` first to keep root clean.
8. **Push `main`, then tag and push the tag:**
   ```bash
   PAT=$(tr -d '\n' < .github-token)
   R="https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git"
   git push "$R" main
   git tag -a vX.Y.Z -m "Release vX.Y.Z" HEAD
   git push "$R" refs/tags/vX.Y.Z      # ← fires .github/workflows/release.yml
   ```
9. **Verify** the run + published release + APK asset (HTTP 200) + `version.json` `latest` on `main`.

**🔴 Credential rule (do not violate):** Free4Me-IPTV uses the **`rkinnc75` PAT in `.github-token` — and ONLY that.** For any `github.com/rkinnc75/Free4Me-IPTV` operation, authenticate via the inline HTTPS PAT URL (above). **NEVER use the `rkalsky` `gh` account — it has no write access (403).** Do not rely on plain `git push`: `gh auth setup-git` configured the credential helper to resolve to `rkalsky`, so a plain push will fail; always use the explicit `.github-token` PAT URL, and keep the token out of logs (`sed "s/${PAT}/***/g"`). Also use `set -o pipefail` so a `git push | sed` pipeline surfaces git's real exit code (otherwise a rejected push reports false success).

**version.json + tag ordering:** `version.json` must be on `main` before the tag (the in-app updater fetches it from `raw.githubusercontent.com/.../main/version.json`). CI re-syncs `version.json` and re-points the tag *after* the APK uploads (closes the 404 window) — so a tooling commit landing on `main` mid-release is tolerated by CI's retry loop.

**Scripts (`scripts/`):**
- `commit_and_release.sh "msg" vX.Y.Z file…` — stages **only named files**, runs `pre_commit_check.py`, commits + pushes main + tag. (Its bindfs `commit-tree` dance is for the old Cowork sandbox; plain git works on this desktop.)
- `apply_fix.sh fixN` — runbook-driven; **does `git reset --hard origin/main` + `git clean -fd`** → it will WIPE uncommitted edits + untracked files. Only for the `fixN.md`+`.patch` workflow, not already-applied working-tree changes.
- `build_and_release.sh` — local Mac build+release; needs the keystore (absent here).
- `pre_commit_check.py` / `update_version_json.py` / `gen_changelog.py` — gates + generators.

**Deep dives:** `CLAUDE-WORKFLOW.md` (failure modes, the `fix290` orphaned-tag guard, PAT/keystore recovery), `BUILD-ENV.md` (pinned toolchain + signing), `CREDENTIALS-AND-SECRETS.md` (PAT + `RELEASE_KEYSTORE_*` recovery).

---

## 5. Gotchas & invariants (hard-won — don't relearn the hard way)

- **SQL inside Dart string literals is invisible to `flutter analyze`.** A syntax error compiles clean and only crashes at runtime. Never blindly tidy/rewrite SQL. `DESC`/`ASC` are direction keywords and are **never** valid inside `CASE … THEN … END` (use `CASE WHEN COALESCE(favorite,0)=1 THEN 0 ELSE 1 END`). For any DB/SQL change, **run the app** — analyze is not sufficient.
- **No orphaned declarations** — an unreferenced function/var is a fatal `unused_element` warning that fails the build.
- **`pre_commit_check.py` allowlist:** every `@override` in `lib/player/mpv_engine.dart` must name a real member of the `PlayerEngine` interface (`lib/player/player_engine.dart`). When the interface grows, update `PLAYER_ENGINE_INTERFACE` in the checker (it has gone stale before).
- **media_kit libmpv `vf` filters are device-strict** — the custom build has them, but the on-device libavfilter parser wants `filter=opt=val` with escaped commas (`\,`). Test filter strings on the actual `.so`, never assume from desktop mpv/ffmpeg.
- **Read the `STATS` logcat line for playback diagnosis** (debug logging on): `voDrop`/`decDrop` are authoritative; `vfFps`/estimated-vf-fps is unreliable on this build.
- APK is **~109 MB** (full libmpv all-filters/decoders × universal arm+arm64). Universal ABI is required — 32-bit-only TV boxes (onn 4K) can't load an arm64-only APK.
- **adb cannot inject a HELD key** (no root; `sendevent` is permission-denied; `input keyevent --longpress` registers as a quick press). So held-OK GESTURES — the Live-guide channel menu, the History-clear long-press, the Live-TV-tab diagnostic easter egg — are NOT adb-verifiable. Verify by review + the proven fix586 `node.onKeyEvent` held detector, the synthetic touch-long-press (`adb shell input swipe X Y X Y 700`) where a widget also wires `InkWell.onLongPress`, and the real remote. Coords are in the **1920×1080 override** space (the onn is physically 4K). See memory `free4me-tv-longpress-menu`.
- **The onn cannot reproduce the SHIELD startup freeze** — it cache-skips below 2300 MB (`ChannelSearchCache._minRamMbForCache`), so the ~75 s 272k-entry cache rebuild only happens on 3 GB+ boxes (Shield). Memory `shield-startup-freeze`.

## 5a. Session rules (memory-backed)
- **iMessage `rkalsky@kalsky.com` on every release submission + every stopping point**, and include a flat continuously-NUMBERED validation plan on every test-requiring completion. `osascript` with the var named `theAddr` (NOT `handle` → `-1728` keyword clash). Memory `imessage-alert-rule`.
- **Adversarially review** each substantive fix with a Workflow (find → verify), apply confirmed findings, then ship. It has caught a HIGH bug most rounds.
- **Never run a fork/subagent that EDITS this working copy in parallel** — it interleaves commits (the fix607 incident). Use read-only or `worktree`-isolated agents.

---

## 6. Key files

| Area | File(s) |
|---|---|
| Player (engine) | `lib/player.dart`, `lib/player/mpv_engine.dart` |
| Player engine contract | `lib/player/player_engine.dart` |
| HW decode routing | `lib/player/hwdec_routing.dart`, `lib/player/hwdec_decode_state.dart` |
| Playback stats overlay | `lib/player/debug_stats_overlay.dart` |
| PIP / overlay | `lib/player/overlay_player_controller.dart`, `overlay_player_widget.dart`, `pip_controller.dart` |
| Cast | `lib/player/cast_controller.dart` |
| Multi-view | `lib/multi_view_screen.dart`, `lib/multi_view_cell.dart`, `lib/channel_picker_screen.dart` |
| Settings | `lib/settings_view.dart`, `lib/models/settings.dart`, `lib/models/dev_mpv_options.dart`, `lib/backend/settings_service.dart`, `lib/backend/settings_io.dart` |
| Database (SQLite, key-value Settings table) | `lib/backend/sql.dart` |
| EPG | `lib/backend/epg_service.dart`, `xmltv_parser.dart`, `xtream_epg.dart`, `epg_matcher.dart` |
| Home / search | `lib/home.dart`, `lib/channel_tile.dart` |
| TV shell / Live guide | `lib/tv/tv_shell.dart` (tabs, `_onTabLongPress`, `_select`/`reloadGuide`), `lib/tv/tv_guide_view.dart` (the EPG guide: rail/grid, `_FocusTile` held-OK, `reloadGuide` remember-place, `_StartupSplash` gate in `lib/main.dart`), `lib/tv/tv_top_tab_bar.dart` (held-OK tab detector), `lib/tv/tv_search_view.dart`, `lib/tv/tv_hero_preview.dart` |
| Diagnostic report | `lib/backend/issue_reporter.dart` (shared submitter — Settings + the Live-TV easter egg), Worker `free4me-issue-reporter.rkinnc75.workers.dev` |
| Clock format | `guideClockFmt()` in `lib/backend/settings_service.dart` (12/24h, `use24HourTime` setting) |
| Logging | `lib/backend/app_logger.dart` (`AppLog`) |
| Models | `lib/models/channel.dart`, `source.dart`, `media_type.dart` |
| Versioning | `pubspec.yaml`, `lib/whats_new_modal.dart`, `version.json` |
| CI | `.github/workflows/release.yml` (tag → build/sign/publish), `analyze.yml` (PR/main gate) |

---

## 7. Reference docs (kept)

| Doc | Read when |
|---|---|
| `ONBOARDING.md` (this) | First — coder + builder entry point. |
| `NEXT-SESSION.md` | Live backlog + kickoff prompt — the pending items to pick from. |
| `BACKLOG_TV_UI.md` | TV Live-view UX backlog (rail-collapse, 3s dwell-preview, long-press Multi-view) with per-item build notes. |
| `GROUND_ZERO.md` | Phone-coder handoff / narrative current state. |
| `CLAUDE-WORKFLOW.md` | Release pipeline detail, failure recovery, `fix290` guard, PAT/keystore bootstrap. |
| `BUILD-ENV.md` | Exact build toolchain + signing identity. |
| `CREDENTIALS-AND-SECRETS.md` | PAT + `RELEASE_KEYSTORE_*` setup/recovery. |
| `DEVELOPMENT-HANDBOOK.md` | Feature architecture + UI copy strings. |
| `docs/CUSTOM_LIBMPV.md` | The custom LGPL-max libmpv: why, what's enabled, wiring, license, **rebuild steps** after a media_kit/libmpv bump. |
| `docs/LIBMPV_COMPONENTS.md` | Full enumerated filter/decoder/demuxer/protocol lists in the custom `.so`. |
| `CHANGELOG.md` / `README.md` | History / project overview. |
| `runbooks/` | Per-fix runbooks (`fixNNN.md`). |
| Auto-memory (`MEMORY.md` index) | Loaded automatically each session — freshest cross-cutting state (libmpv saga, framedrop fix, builder gotchas). |

*Stale/redundant handoff, continuation, fix-guide, preflight, and CI-state docs were consolidated into this file and removed.*
