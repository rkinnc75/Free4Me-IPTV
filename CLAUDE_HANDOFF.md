# Free4Me-IPTV — Claude Session Handoff Document

> **Purpose:** Read this at the start of any new Claude session working on this
> repo. It contains every convention, constraint, and workflow needed to
> implement and release fixes without asking the user a single question.
>
> **Last updated:** 2026-05-29 — v1.22.12+146
>
> **Sufficient for:** new chat on same Mac ✓ | new Mac (see Section 17) ✓

---

## 1. Project Identity

| Field | Value |
|---|---|
| App name | Free4Me-IPTV |
| Package name | `open_tv` (Dart package / Android app ID) |
| Repo | `https://github.com/rkinnc75/Free4Me-IPTV` |
| Local path | `/Users/builder/git/free4me-iptv` |
| Platform | Android TV (Flutter/Dart) |
| Origin | Fork of open-tv / Fred TV |
| Current version | `1.22.12+146` |

The app is an IPTV player for Android TV. It plays M3U/Xtream streams using
`media_kit` (mpv) as the primary engine, with an ExoPlayer fallback. It has
a mini-player overlay, full-screen player, channel list (Home), EPG, stream
scanner, and settings screen.

---

## 2. Repository Layout

```
free4me-iptv/
├── lib/
│   ├── main.dart                         # App entry, MaterialApp, navigator setup
│   ├── home.dart                         # Channel list (root route / MaterialApp.home)
│   ├── player.dart                       # Full-screen player widget
│   ├── settings_view.dart                # Settings screen
│   ├── whats_new_modal.dart              # Per-version changelog (const _changelog map)
│   ├── bottom_nav.dart                   # Bottom navigation bar
│   ├── channel_tile.dart                 # Individual channel list row
│   ├── channel_picker_screen.dart        # Channel picker (modal)
│   ├── multi_view_screen.dart            # Multi-view layout screen
│   ├── backend/
│   │   ├── sql.dart                      # All DB access (SQLite via sqlite_async)
│   │   ├── settings_service.dart         # Settings singleton
│   │   ├── settings_io.dart              # Settings export/import
│   │   ├── app_logger.dart               # AppLog (ring-buffer log + file)
│   │   ├── channel_search_cache.dart     # In-memory search cache
│   │   ├── db_factory.dart               # DB connection factory + migrations
│   │   ├── epg_service.dart              # EPG fetch + matching
│   │   └── stream_scanner.dart           # Stream validation scanner
│   ├── player/
│   │   ├── player_engine.dart            # Abstract PlayerEngine interface
│   │   ├── mpv_engine.dart               # MpvEngine (media_kit, primary)
│   │   ├── exo_engine.dart               # ExoEngine (video_player, fallback)
│   │   ├── overlay_player_controller.dart # Mini-player state (ChangeNotifier singleton)
│   │   ├── overlay_player_widget.dart    # Mini-player UI + swap logic
│   │   └── pip_controller.dart           # PiP mode controller
│   └── models/
│       ├── app_navigator.dart            # appNavigatorKey + playerRouteObserver
│       ├── settings.dart                 # Settings data class
│       ├── channel.dart                  # Channel model
│       ├── media_type.dart               # MediaType enum (livestream/movie/series)
│       └── filters.dart                  # Search/filter state
├── pubspec.yaml                          # Version + dependencies
├── version.json                          # In-app update checker manifest
├── scripts/
│   ├── update_version_json.py            # Regenerates version.json from pubspec + modal
│   ├── pre_commit_check.py               # Fast static checks before every commit
│   └── commit_and_release.sh            # Bindfs commit + push helper (use this)
├── android/
│   └── app/
│       ├── build.gradle                  # Android build config
│       └── release.keystore              # PKCS12 signing key (NEVER commit changes)
├── .github/
│   └── workflows/
│       ├── release.yml                   # CI: tag push → build + sign APK
│       └── analyze.yml                   # CI: main push → flutter analyze (fast check)
├── .github-token                         # GitHub PAT — GITIGNORED, NEVER COMMIT
├── fix*.md                               # Per-fix runbooks (untracked, stay local)
└── CLAUDE_HANDOFF.md                     # This file
```

---

## 3. Key Architecture Concepts

### Navigation
- `appNavigatorKey` — global `GlobalKey<NavigatorState>` in `app_navigator.dart`,
  used by the overlay widget to push/pop routes without a BuildContext.
- `playerRouteObserver` — `RouteObserver<PageRoute>` registered in `main.dart`.
  **Does NOT fire `didPopNext` for the root/home route** (Home is mounted as
  `MaterialApp.home`, never pushed through the observer). Do not use RouteAware
  on Home.
- Route stack normal shape: `[Home, Player]`. Home is always the root.
- **One route per Player** — `media_kit`'s `enterFullscreen()` was disabled
  (fix130) because it pushed a hidden second route onto the root navigator,
  causing swap to desync. The app now drives fullscreen itself via
  `_enterSystemFullscreen()` for both MpvEngine and ExoEngine.

### Player Engine Handoff (fix116)
- `MpvEngine` objects are handed live between player roles on swap instead of
  being disposed and reopened.
- `detachForSwap()` on `_PlayerState` — stops timers/subs, sets
  `_engineDisposed=true` (prevents `dispose()` from double-killing it), returns
  the live engine.
- `detachMain()` / `detachOverlayEngine()` on `OverlayPlayerController` — clear
  refs WITHOUT disposing, return engine + metadata.
- `adoptOverlayEngine()` — installs an already-playing engine as the mini-player.
- `adoptEngine` param on `Player` widget — when non-null, `initState` adopts it,
  `initAsync` calls `onAdopt()` on the engine then skips `_startPlayback`.

### onExit Pattern (fix118 + fix130.3)
Pop the route FIRST, synchronously, before any `await`. Before the pop, set
`_videoDetached = true` (fix130.3) to unmount the Texture immediately. Engine
teardown is fire-and-forget (`unawaited(() async { … })()`). `_engineDisposed =
true` is set BEFORE async teardown so `dispose()` skips re-dispose.

### Home Repaint (fix124)
After `navigator.pop()` in `onExit`, immediately:
1. `WidgetsBinding.instance.scheduleFrame()`
2. `addPostFrameCallback` → `(navigator.context as Element).markNeedsBuild()` +
   second `scheduleFrame()`

Home also listens to `OverlayPlayerController.instance` via `addListener` and
calls `setState(() {}) + scheduleFrame()` on any controller change.

### Swap Route Shape (fix120.2)
`_swap` in `overlay_player_widget.dart` uses `_nav.pop(); _nav.push(promoted)`,
NOT `pushReplacement`. The pop+push reaches the same stack shape via operations
the navigator handles cleanly.

### MpvEngine Fullscreen (fix130)
`handlesOwnFullscreen` returns `false`. `enterFullscreen()`, `exitFullscreen()`,
and `isFullscreen` are no-ops. The app calls `_enterSystemFullscreen()` (immersive
system UI + landscape orientation) exactly as it does for ExoEngine. This
eliminates the hidden second root-navigator route that media_kit's fullscreen
used to push, which was the root cause of the post-swap black screen.

### Channel Sort Order (fix138)
Six-tier sort applies to picker AND all Home browse views (Live/Movies/Series/All):
- Tier 0: Favourite + Validated
- Tier 1: Favourite
- Tier 2: History (watched) + Validated
- Tier 3: History
- Tier 4: Validated only
- Tier 5: Everything else

Section headers: **Favourites** (amber) / **History** (light blue) / **All channels** (grey).
No "Validated" header — validation shown by green-circle badge only.
Validated = `channel.streamValidated == true` OR `StreamScanner.results[id] == true`.

---

## 4. Fix Numbering Convention

| Session | Fix numbers |
|---|---|
| Mac / Cowork (this tool) | **ODD** numbers: 115, 117, 119, 121, 123… |
| Phone (mobile Claude) | **EVEN** numbers: 116, 118, 120, 122, 124… |

Each fix has a `fixNNN.md` runbook at the repo root. These files are **untracked**
(gitignored) — committed to the repo as part of the fix commit (`git add fixNNN.md`).

When the user says "fixNNN", read `fixNNN.md` and implement it exactly as
specified. The runbook is authoritative. Do not deviate from it.

---

## 5. Release Version Convention

- Version string: `MAJOR.MINOR.PATCH+BUILD`
- `BUILD` = fix number (e.g. fix124 → build `+124`)
- `version.json` contains `"latest": "MAJOR.MINOR.PATCH"` (no build number)
- Tag format: `vMAJOR.MINOR.PATCH` (e.g. `v1.22.9`)
- **Multiple fixes at the same patch version share the same tag** — force-push
  the tag to the new commit when the patch version doesn't change.

### Recent version history
| Version | Build | Fix | Notes |
|---|---|---|---|
| 1.22.8 | +120 | fix120 | Home RouteAware repaint + pop+push swap |
| 1.22.8 | +122 | fix122 | Remove invalid autofocus from ExpansionTile |
| 1.22.9 | +124 | fix124 | Force post-pop Home repaint; overlay-controller listener |
| 1.22.10 | +126 | fix126 | Release mpv texture on dispose; fresh VideoState on adopt |
| 1.22.10 | +128 | fix128 | What's New dialog shown immediately; cache builds in parallel |
| 1.22.11 | +130 | fix130 | ROOT CAUSE: drop media_kit route-based fullscreen; app owns it |
| 1.22.11 | +132 | fix132 | Remove stray @override on logSurface (build break) |
| 1.22.12 | +136 | fix136 | Rotation diagnostic logging |
| 1.22.12 | +138 | fix138 | 6-tier channel sort + 3 section headers |
| 1.22.12 | +140 | fix140 | Multi-view restore: skip non-livestream channels |
| 1.22.12 | +142 | fix142 | Validated highlight persists across restarts |
| 1.22.12 | +144 | fix144 | Missing MediaType import in multi_view_screen |
| 1.22.12 | +146 | infra | Pre-commit checker, analyze workflow, commit script |

---

## 6. Static Analysis — Three Layers

Flutter is not installable in the VM sandbox (Google/GitHub storage is blocked).
Three complementary layers replace it:

### Layer 1 — Python pre-checker (instant, runs in VM before every commit)

```bash
cd /sessions/<name>/mnt/free4me-iptv
python3 scripts/pre_commit_check.py
```

Catches: stray `@override` on mpv-only methods, apostrophes in single-quoted
changelog strings, duplicate changelog version keys, `version.json` out of sync,
`autofocus` on `ExpansionTile`, targeted missing imports (`MediaType`, etc.).

**Run this before every commit. If it exits non-zero, fix the issues first.**

### Layer 2 — `analyze.yml` GitHub Action (real flutter analyze, ~2 min)

Triggers automatically on every push to `main`. Runs `flutter analyze
--no-fatal-infos` and the `version.json` freshness check. Results appear as a
commit status in GitHub before you push the tag. If it fails, push a fix to main
and the workflow re-runs — only push the tag once analyze is green.

### Layer 3 — `release.yml` gate (final safety net)

The existing CI build also runs analyze before building the APK. This is the
last line of defence — aim to never need it by passing Layers 1 and 2 first.

### Tolerated infos (leave these alone)
- `use_build_context_synchronously` in `lib/settings_view.dart` (~lines 1861, 2421)

### Fatal — must fix before committing
- Any `error` level finding
- Any `warning` level finding (unused imports, unused fields, stray `@override`)

### PlayerEngine interface — which methods may carry @override in mpv_engine.dart
Only these 17: `buildVideoView`, `open`, `dispose`, `bufferingStream`,
`completedStream`, `errorStream`, `positionStream`, `position`,
`supportsTrackSelection`, `subtitleTracks`, `audioTracks`, `setSubtitleTrack`,
`setAudioTrack`, `setVolume`, `handlesOwnFullscreen`, `enterFullscreen`,
`exitFullscreen`, `isFullscreen`. Everything else (`onAdopt`, `logSurface`,
`videoWidth`, `videoHeight`, `reapplyOptions`) is mpv-only — **no `@override`**.

---

## 7. Git Workflow — The bindfs Commit Workaround

**Why:** The workspace is mounted via virtiofs. The VM can create and rename
files but **cannot delete/unlink files**. Normal `git commit` fails because it
tries to unlink temp files. The workaround uses a temporary index file.

### Use the commit helper script (preferred)

```bash
cd /sessions/<name>/mnt/free4me-iptv

bash scripts/commit_and_release.sh \
  "fixNNN: description (vX.Y.Z+NNN)" \
  vX.Y.Z \
  [--force-tag] \
  file1 file2 fixNNN.md pubspec.yaml version.json
```

The script: runs pre_commit_check → bindfs commit → writes tag → **syncs index
BEFORE push** → pushes main → pushes tag. No `index.lock` left behind.

### Manual commit (when you need fine control)

```bash
python3 scripts/pre_commit_check.py          # abort if issues
TMPIDX=$(mktemp)
GIT_INDEX_FILE="$TMPIDX" git read-tree HEAD
GIT_INDEX_FILE="$TMPIDX" git add <files>
TREE=$(GIT_INDEX_FILE="$TMPIDX" git write-tree)
PARENT=$(git rev-parse HEAD)
COMMIT=$(GIT_INDEX_FILE="$TMPIDX" git commit-tree "$TREE" -p "$PARENT" \
  -m "fixNNN: <message> (vX.Y.Z+NNN)")
printf '%s\n' "$COMMIT" > .git/refs/heads/main
printf '%s\n' "$COMMIT" > .git/refs/tags/vX.Y.Z
rm "$TMPIDX"
git read-tree HEAD          # ← sync index BEFORE push (prevents index.lock)
PAT=$(cat .github-token)
git push "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" main
git push "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" refs/tags/vX.Y.Z
```

**Critical ordering:** `git read-tree HEAD` must run BEFORE `git push`. The push
creates an `index.lock` that the VM cannot remove; syncing first avoids this.

### Force-pushing a tag (same patch version, new build)

```bash
git push --force "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" refs/tags/vX.Y.Z
```

Or pass `--force-tag` to `commit_and_release.sh`.

**Never use `git tag -d`.** Write ref files directly.

### If index.lock is already present (rare — from an interrupted Mac-side git op)

The VM cannot delete it. Ask the user to run from their **Mac Terminal**:
```bash
rm /Users/builder/git/free4me-iptv/.git/index.lock
```
Then `git read-tree HEAD` will work from the VM.

### VM Path Translation

| Mac path | VM path |
|---|---|
| `/Users/builder/git/free4me-iptv` | `/sessions/<name>/mnt/free4me-iptv/` |
| `.../local-.../outputs` | `/sessions/<name>/mnt/outputs/` |

The session name changes every session. Find it with `mount | grep free4me`.

---

## 8. Release Sequence — Exact Order of Operations

```
1.  Read fixNNN.md — understand every change required
2.  Read the affected source files
3.  Apply all code changes
4.  Update lib/whats_new_modal.dart — add '1.X.Y': [...] entry at the TOP
    of the _changelog map. NO apostrophes in single-quoted strings.
5.  Update pubspec.yaml — bump `version: X.Y.Z+NNN`
6.  Run: python3 scripts/update_version_json.py
    (MUST run AFTER step 4 — reads whats_new_modal.dart)
7.  Run: python3 scripts/pre_commit_check.py
    Fix any issues before proceeding.
8.  Commit + push using commit_and_release.sh (or manual script above)
    The script handles: pre-check → commit → tag → index sync → push main → push tag
```

### whats_new_modal.dart rules

```dart
const _changelog = <String, List<String>>{
  '1.22.12': [                              // ← newest version at top
    'Fix: description without apostrophes.',
    'Improvement: second bullet if needed.',
  ],
  '1.22.11': [
    // older entry...
  ],
```

- Single-quoted Dart strings only
- **No apostrophes** inside single-quoted strings — reword (e.g. "engine's" → "engine", "doesn't" → "does not")
- Bullet start lines: 4-space indent. Continuation lines: 8-space indent.
- The `update_version_json.py` script reads this indent pattern to extract bullets.
- The pre-checker catches apostrophes and duplicate keys before they reach CI.

---

## 9. Signing and Secrets

| Secret | Location |
|---|---|
| GitHub PAT | `.github-token` at repo root (gitignored) — `$(cat .github-token)` |
| Release keystore | `android/app/release.keystore` (PKCS12, RSA-4096) |
| Keystore alias | `free4me-iptv` |
| Keystore SHA-256 | `D8:D3:4D:5A:2F:35:7B:A4:40:3B:C0:C3:1D:65:2F:CD:D7:B5:50:4A:F9:DA:48:54:65:78:0A:FF:A0:46:9E:A2` |

**Never commit `.github-token`.** CI secrets are in GitHub Actions — not in
the repo and not accessible from the VM.

---

## 10. Permanent Hard Rules

1. **Commit IDs are fix numbers**, not `PO-xxxx` or any other format
2. **Mac/Cowork = odd fix numbers; Phone = even fix numbers**
3. **Never use `git tag -d`** — write ref files directly
4. **Never commit `.github-token`**
5. **Never hand-write version.json** — always run `python3 scripts/update_version_json.py`
6. **Tag push is mandatory** — commit push alone does not build APK
7. **whats_new_modal.dart updated BEFORE running update_version_json.py**
8. **Pre-commit check BEFORE every commit** — `python3 scripts/pre_commit_check.py`
9. **Index synced BEFORE push** — prevents index.lock
10. **No pushReplacement in navigator** — use `pop()` + `push()` (fix120.2)
11. **fix116/118/120.2/124/130 must not be reverted** — load-bearing; all subsequent fixes build on them
12. **MpvEngine.handlesOwnFullscreen = false** — media_kit fullscreen was the black-screen root cause; keep it disabled

---

## 11. AppLog Usage

```dart
AppLog.info('ComponentName: message detail="${value}"');
AppLog.warn('ComponentName: warning context — $e');
```

Defined in `lib/backend/app_logger.dart`. Already imported in all player files.
Engine identity tracing: `identityHashCode(engine)` (no import — `dart:core`), logged as `eid=NNNNNN`.

---

## 12. Diagnostic Tripwires

| Log line | Meaning |
|---|---|
| `Player: onExit START` | onExit began |
| `Player: onExit popping route` | navigator.pop() about to be called |
| `Player: onExit DONE` | onExit completed cleanly |
| `Player: dispose() SKIP` | widget disposed — confirms pop happened |
| `Player: onExit forced post-pop repaint` | fix124.1 ran |
| `Home: overlay changed — forcing repaint` | fix124.2 ran |
| `OverlayWidget: _swap pop+push` | correct swap path (fix120.2) |
| `OverlayWidget: _swap nav.canPop(before/after)` | route count at swap time (fix130.4) |
| `MpvEngine: onAdopt (no-op…)` | engine adopted into new Player (fix130.2) |
| `MpvEngine: SURFACE[…]` | texture id + rect dump (fix130.4 logSurface) |
| `MpvEngine: dispose() player disposed (surface released by media_kit)` | clean teardown |
| `Player: ROTATE portrait → landscape … (no reconnect)` | rotation logged (fix136) |
| `MultiViewScreen: restore skipped non-livestream cell N` | saved cell was non-live (fix140) |
| `startup watchdog fired` | channel took too long to start |

**Single back press exits player** (fix130 bonus — the hidden media_kit fullscreen
route that required a double-back is gone).

---

## 13. Known Virtiofs Limitations

The VM workspace mount (virtiofs) allows **create** and **rename** but blocks **unlink**.

- `rm` of any file → `Operation not permitted`
- `git tag -d` → fails
- `git reset HEAD -- .` → fails (creates index.lock, then can't remove it)
- `git read-tree HEAD` → **works** (uses rename internally)
- `git push` creates an index.lock internally → sync index BEFORE push, not after

The `warning: unable to unlink '.git/objects/xx/tmp_obj_*'` messages during
`git write-tree` are **harmless** — objects created successfully, git just can't
clean up its temp names.

---

## 14. Dependencies Worth Knowing

```yaml
media_kit: ^1.2.6           # Primary mpv-based player
media_kit_video: ^2.0.1     # Video rendering
sqlite_async: ^0.13.0       # Async SQLite
connectivity_plus: ^7.0.0   # Network state
workmanager: ^0.9.0         # Background tasks
```

Source archives committed for reference: `media_kit-1.2.6.tar.gz`,
`media_kit_video-2.0.1.tar.gz` (fix130 investigation).

Upgrade constraint: `file_picker`, `device_info_plus`, `package_info_plus` are
locked together (all depend on `win32`). Upgrade all three together when
`file_picker ^12.0.0` stable ships.

Flutter version in CI: `3.44.0` (stable). See `.github/workflows/release.yml`.

---

## 15. Quick Reference

### Implement and release a fix

```bash
REPO=/sessions/<name>/mnt/free4me-iptv
cd $REPO

# 1. Read the runbook
cat fixNNN.md

# 2. Apply code changes (python/sed edits to source files)

# 3. Update changelog (newest entry at top, no apostrophes)
#    lib/whats_new_modal.dart

# 4. Bump version
sed -i 's/version: X.Y.Z+OLD/version: X.Y.Z+NNN/' pubspec.yaml

# 5. Regenerate version.json (AFTER changelog)
python3 scripts/update_version_json.py

# 6. Run pre-checker
python3 scripts/pre_commit_check.py   # must pass before continuing

# 7. Commit + push (handles everything including index sync)
bash scripts/commit_and_release.sh \
  "fixNNN: description (vX.Y.Z+NNN)" \
  vX.Y.Z \
  lib/changed_file.dart pubspec.yaml version.json fixNNN.md

# For force-push (same patch version, new build):
bash scripts/commit_and_release.sh \
  "fixNNN: description (vX.Y.Z+NNN)" \
  vX.Y.Z --force-tag \
  lib/changed_file.dart pubspec.yaml version.json fixNNN.md
```

### Check repo state

```bash
cd /sessions/<name>/mnt/free4me-iptv
git log --oneline -5
git status --short
grep "^version:" pubspec.yaml
python3 -c "import json; d=json.load(open('version.json')); print(d['latest'])"
```

### Find the VM session path

```bash
mount | grep free4me   # look for the fuse/virtiofs line
```

### Verify analyze is green on GitHub

After pushing to main, check:
`https://github.com/rkinnc75/Free4Me-IPTV/actions/workflows/analyze.yml`

Green = safe to push the tag. Red = fix and push to main again before tagging.

---

## 16. Starting Fresh on a Different Mac

Everything in this document applies unchanged. Three additional steps first time only.

### Step 1 — Clone the repo

```bash
git clone https://github.com/rkinnc75/Free4Me-IPTV.git \
  /Users/<you>/git/free4me-iptv
```

The keystore (`android/app/release.keystore`) is tracked and comes with the
clone. `fix*.md` runbooks are **untracked** — transfer them manually or paste
their contents into the chat if needed.

### Step 2 — Recreate `.github-token`

```bash
echo "ghp_YourPersonalAccessTokenHere" > \
  /Users/<you>/git/free4me-iptv/.github-token
```

PAT needs `repo` scope. This is the **one question** Claude may ask on a new Mac.

### Step 3 — Open in Cowork and verify

In Cowork, select the repo folder. Then from the VM:

```bash
# Repo accessible
ls /sessions/<name>/mnt/free4me-iptv/pubspec.yaml

# PAT works
PAT=$(cat /sessions/<name>/mnt/free4me-iptv/.github-token)
git ls-remote "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" HEAD

# Pre-checker works
python3 /sessions/<name>/mnt/free4me-iptv/scripts/pre_commit_check.py
```

All three green → ready to implement and release fixes.

---

*End of handoff document. A new session reading this file should be able to
implement and release any fix without asking the user any questions, on the
same Mac or a different one.*
