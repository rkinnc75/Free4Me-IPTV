# Free4Me-IPTV — Claude Session Handoff Document

> **Purpose:** Read this at the start of any new Claude session working on this
> repo. It contains every convention, constraint, and workflow needed to
> implement and release fixes without asking the user a single question.
>
> **Last updated:** 2026-05-29 — v1.22.9+124 (fix124)
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
| Current version | `1.22.9+124` |

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
│       └── filters.dart                  # Search/filter state
├── pubspec.yaml                          # Version + dependencies
├── version.json                          # In-app update checker manifest
├── scripts/
│   ├── update_version_json.py            # Regenerates version.json from pubspec + modal
│   └── build_and_release.sh             # Local build script (not used in CI flow)
├── android/
│   └── app/
│       ├── build.gradle                  # Android build config
│       └── release.keystore              # PKCS12 signing key (NEVER commit changes)
├── .github/
│   └── workflows/
│       └── release.yml                   # CI: triggered by tag push, builds + signs APK
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
  `initAsync` skips `_startPlayback`.

### onExit Pattern (fix118)
Pop the route FIRST, synchronously, before any `await`. Engine teardown is
fire-and-forget (`unawaited(() async { … })()`). `_engineDisposed = true` is
set BEFORE async teardown so `dispose()` skips re-dispose.

### Home Repaint (fix124)
After `navigator.pop()` in `onExit`, immediately:
1. `WidgetsBinding.instance.scheduleFrame()`
2. `addPostFrameCallback` → `(navigator.context as Element).markNeedsBuild()` +
   second `scheduleFrame()`

Home also listens to `OverlayPlayerController.instance` via `addListener` and
calls `setState(() {}) + scheduleFrame()` on any controller change. This fires
on `unregisterMain` exactly when the full-screen player exits.

### Swap Route Shape (fix120.2)
`_swap` in `overlay_player_widget.dart` uses `_nav.pop(); _nav.push(promoted)`,
NOT `pushReplacement`. The pop+push reaches the same stack shape via operations
the navigator handles cleanly.

---

## 4. Fix Numbering Convention

| Session | Fix numbers |
|---|---|
| Mac / Cowork (this tool) | **ODD** numbers: 115, 117, 119, 121, 123, 125… |
| Phone (mobile Claude) | **EVEN** numbers: 116, 118, 120, 122, 124, 126… |

Each fix has a `fixNNN.md` runbook at the repo root. These files are **untracked**
(gitignored) — they stay local and are also committed to the repo only as part of
the fix commit (`git add fixNNN.md`).

When the user says "fixNNN", read `fixNNN.md` and implement it exactly as
specified. The runbook is authoritative. Do not deviate from it.

---

## 5. Release Version Convention

- Version string: `MAJOR.MINOR.PATCH+BUILD`
- `MAJOR.MINOR.PATCH` in `pubspec.yaml` version field
- `BUILD` = fix number (e.g. fix124 → build `+124`)
- `version.json` contains `"latest": "MAJOR.MINOR.PATCH"` (no build number)
- Tag format: `vMAJOR.MINOR.PATCH` (e.g. `v1.22.9`)
- **Multiple fixes at the same patch version get the same tag** (force-push the
  tag to the new commit if the patch version doesn't change).
- Phone fixes (even) bump only the build number unless the patch was already
  bumped by the immediately preceding Mac fix.

### Recent version history
| Version | Build | Fix | Notes |
|---|---|---|---|
| 1.22.5 | +116 | fix116 | Engine handoff on swap |
| 1.22.6 | +118 | fix118 | onExit pop-first |
| 1.22.7 | +65  | fix65  | Remove Donate (phone) |
| 1.22.8 | +120 | fix120 | Home RouteAware repaint + pop+push swap |
| 1.22.8 | +122 | fix122 | Remove invalid autofocus from ExpansionTile |
| 1.22.9 | +124 | fix124 | Force post-pop Home repaint; overlay-controller listener |

---

## 6. Git Workflow — The bindfs Commit Workaround

**Why:** The workspace folder is mounted into Claude's VM via virtiofs. The VM
can create and rename files but **cannot delete/unlink files**. Normal `git
commit` fails because it tries to unlink temp files. The workaround uses a
temporary index file so git never touches the real `.git/index`.

### The Commit Script (use this every time)

```bash
cd /sessions/<session-name>/mnt/free4me-iptv   # VM path to repo

TMPIDX=$(mktemp)
GIT_INDEX_FILE="$TMPIDX" git read-tree HEAD
GIT_INDEX_FILE="$TMPIDX" git add <file1> <file2> ...   # exact files for this commit
TREE=$(GIT_INDEX_FILE="$TMPIDX" git write-tree)
PARENT=$(git rev-parse HEAD)
COMMIT=$(GIT_INDEX_FILE="$TMPIDX" git commit-tree "$TREE" -p "$PARENT" \
  -m "fixNNN: <message> (vX.Y.Z+NNN)")
printf '%s\n' "$COMMIT" > .git/refs/heads/main
rm "$TMPIDX"
```

The `warning: unable to unlink ... tmp_obj_*` messages are **expected and
harmless** — the objects were created successfully, git just can't clean up its
temp files.

### Tagging

```bash
printf '%s\n' "$COMMIT" > .git/refs/tags/vX.Y.Z
```

**Never use `git tag`, `git tag -d`, or any interactive git tag commands.**
Write the ref file directly.

### Pushing

```bash
PAT=$(cat .github-token)
git push "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" main
git push "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" refs/tags/vX.Y.Z
```

If the tag already exists on the remote (same patch version, different build):
```bash
git push --force "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" refs/tags/vX.Y.Z
```

**The tag push is mandatory.** CI is triggered only by a tag push. A commit push
alone does not build.

### Index Sync After Commit

After every bindfs commit, the real `.git/index` is stale (it still reflects
the pre-commit state). Sync it immediately after pushing:

```bash
git read-tree HEAD
```

This uses `rename()` internally (allowed by virtiofs), not `unlink()`. Run it
right after the `rm "$TMPIDX"` line.

### The index.lock Problem

If `git read-tree HEAD` fails with:
```
fatal: Unable to create '.git/index.lock': File exists.
```

The lockfile was left by a Mac-side git process and the VM cannot delete it.
The user must run from their **Mac Terminal**:
```bash
rm /Users/builder/git/free4me-iptv/.git/index.lock
```

Then the VM can run `git read-tree HEAD` to sync the index.

**Do not ask the user to do this unless the lockfile is actually blocking
something.** After a clean session the lockfile may not be present.

### VM Path Translation

| Mac path | VM path |
|---|---|
| `/Users/builder/git/free4me-iptv` | `/sessions/<name>/mnt/free4me-iptv/` |
| `.../local-.../outputs` | `/sessions/<name>/mnt/outputs/` |

The session name (e.g. `loving-stoic-bell`) changes each session. Use
`mount | grep free4me` to find the current VM path if unsure.

---

## 7. Release Sequence — Exact Order of Operations

This is the order that must be followed every time. Steps out of order cause
CI failures (version.json mismatch is the most common).

```
1.  Read fixNNN.md — understand every change required
2.  Read the affected source files (use Read tool or bash cat/sed)
3.  Apply all code changes to source files
4.  Update lib/whats_new_modal.dart — add '1.X.Y': [...] entry at the TOP
    of the _changelog map (before the existing entries)
5.  Update pubspec.yaml — bump `version: X.Y.Z+NNN`
6.  Run: python3 scripts/update_version_json.py
    (MUST run AFTER step 4 — the script reads whats_new_modal.dart)
7.  Verify version.json matches pubspec: both must say the same X.Y.Z
8.  Run the bindfs commit script, adding all changed files + fixNNN.md
9.  Write the tag ref file
10. Push main branch
11. Push tag (triggers CI)
12. Run git read-tree HEAD to sync the index
```

### whats_new_modal.dart format

```dart
const _changelog = <String, List<String>>{
  '1.22.9': [                                    // ← newest version at top
    'Fix (critical): description of what changed '
        'and why it matters to the user.',
    'Fix: second bullet if needed.',
  ],
  '1.22.8': [
    // older entry...
  ],
```

**Rules:**
- Use single-quoted Dart strings
- **Never use an apostrophe inside a single-quoted string** — reword to avoid
  it (e.g. "Flutter's" → "Flutter" or use a different phrasing)
- Continuation lines are indented 8 spaces; bullet start lines are 4 spaces
- The script's `extract_notes()` function uses this indent pattern to detect
  bullet boundaries

### version.json CI check

CI runs `python3 scripts/update_version_json.py` on the checked-out commit and
then does `git diff --quiet version.json`. If the output differs from what's
committed, the build **fails**. This catches:
- version.json committed before whats_new_modal.dart was updated
- Manual edits to version.json instead of running the script
- Apostrophe bugs in the changelog (cause mangled output)

---

## 8. Signing and Secrets

| Secret | Location |
|---|---|
| GitHub PAT | `.github-token` at repo root (gitignored) — `$(cat .github-token)` |
| Release keystore | `android/app/release.keystore` (PKCS12, RSA-4096) |
| Keystore alias | `free4me-iptv` |
| Keystore SHA-256 | `D8:D3:4D:5A:2F:35:7B:A4:40:3B:C0:C3:1D:65:2F:CD:D7:B5:50:4A:F9:DA:48:54:65:78:0A:FF:A0:46:9E:A2` |

**Never commit `.github-token`.** It is in `.gitignore`. Never reference its
contents in commit messages or log output.

CI secrets (`RELEASE_KEYSTORE_B64`, `RELEASE_KEYSTORE_PASSWORD`,
`RELEASE_KEY_ALIAS`, `RELEASE_KEY_PASSWORD`) are stored in GitHub Actions
secrets — not accessible from the VM, only used by CI.

---

## 9. flutter analyze Requirements

Before committing any Dart change:
- `flutter analyze --no-fatal-infos` must exit 0 (no errors or warnings)
- Flutter is not available in the VM sandbox — the user must run analyze on
  their Mac, or trust that the CI gate will catch it
- **Tolerated infos** (these are fine, do not fix them):
  - `use_build_context_synchronously` in `lib/settings_view.dart` (~lines 1861, 2421)
- **Fatal** (must fix before committing):
  - Any `error` level finding
  - Any `warning` level finding (unused imports, unused fields, etc.)
  - `undefined_named_parameter`, `unused_import`, `unused_field` etc.

### Common analyze traps
- `with RouteAware` mixin: all four methods (`didPush`, `didPop`, `didPushNext`,
  `didPopNext`) must be used, or the mixin must be removed entirely
- `_overlayListenerAttached` and similar `bool` flags: must be read somewhere or
  the linter flags `unused_field`
- `// ignore: invalid_use_of_protected_member` — suppress the `markNeedsBuild`
  lint; it is intentional
- Apostrophes in single-quoted strings crash the script and may cause analyze
  failures in adjacent string expressions

---

## 10. Permanent Hard Rules

These never change. Follow them unconditionally.

1. **Commit IDs are fix numbers**, not `PO-xxxx` or any other format
2. **Mac/Cowork = odd fix numbers; Phone = even fix numbers**
3. **Never use `git tag -d`** — write `printf '%s\n' "$COMMIT" > .git/refs/tags/vX.Y.Z` directly
4. **Never commit `.github-token`**
5. **Never hand-write version.json** — always run `python3 scripts/update_version_json.py`
6. **Tag push is mandatory** — commit push alone does not trigger CI
7. **whats_new_modal.dart must be updated before running update_version_json.py**
8. **Do not use pushReplacement in the navigator** — use explicit `pop()` + `push()` (fix120.2)
9. **fix116/118/120.2 must not be reverted** — they are load-bearing; all subsequent fixes build on them

---

## 11. AppLog Usage

```dart
AppLog.info('ComponentName: message with detail="${value}"');
AppLog.warn('ComponentName: warning with context — $e');
```

`AppLog` is defined in `lib/backend/app_logger.dart`. It is already imported in
all player-related files. Import it with:
```dart
import 'package:open_tv/backend/app_logger.dart';
```

Log messages follow the pattern `ClassName: verb noun detail=value`. Engine
identity tracing uses `identityHashCode(engine)` (no import needed — it's
`dart:core`), logged as `eid=NNNNNN`.

---

## 12. Diagnostic Tripwires (what to look for in logs)

| Log line | Meaning |
|---|---|
| `Player: onExit START` | onExit began |
| `Player: onExit popping route` | navigator.pop() is about to be called |
| `Player: onExit DONE` | onExit completed |
| `Player: dispose() SKIP` | widget disposed (confirms pop happened) |
| `Player: onExit forced post-pop repaint` | fix124.1 ran |
| `Home: overlay changed — forcing repaint` | fix124.2 ran |
| `Home: didPopNext` | fix120.1 (now dead for root route — should NOT appear) |
| `OverlayWidget: _swap pop+push` | fix120.2 swap path (correct) |
| `OverlayWidget: _swap pushReplacement` | old broken path — should never appear |
| `MpvEngine: created eid=` | new engine created |
| `MpvEngine: dispose() eid=` | engine disposed |
| `startup watchdog fired` | channel took too long to start |

**If both fix124 tripwires appear but screen is still black** → the problem is
the native mpv video surface not releasing (fix126 territory — `mpv_engine.dart`
platform view teardown). Navigation and Flutter repaint are ruled out.

---

## 13. Current Open Investigation

**Black screen after close-mini-then-close-full after swap**

Sequence: mini-player active → open full-screen → swap → close mini → press back on full-screen → black screen, force-close required.

Fix history:
- fix118: confirmed working — `onExit` pops correctly
- fix120.1: dead — `didPopNext` never fires for Home (root route)
- fix120.2: confirmed working — swap uses pop+push
- fix124: **just shipped** — forces repaint from onExit + overlay controller

**Next diagnostic:** after 1.22.9 is installed and the repro is run, check the
log for:
- `Player: onExit forced post-pop repaint of revealed route` (fix124.1)
- `Home: overlay changed — forcing repaint of revealed Home` (fix124.2)

If both present but still black → fix126 (even, phone) targets mpv surface
disposal in `mpv_engine.dart`. Note: the engines involved in the black-screen
repro were both `previewMode=true` at dispose (they were adopted engines from
the mini-player).

---

## 14. Quick Reference — Common Tasks

### Implement a fix from a runbook

```bash
# 1. Read the runbook
cat /sessions/<name>/mnt/free4me-iptv/fixNNN.md

# 2. Apply changes (sed, python, or bash edits)

# 3. Update changelog (add entry at TOP of _changelog map)
# lib/whats_new_modal.dart

# 4. Bump version
sed -i 's/version: X.Y.Z+OLD/version: X.Y.Z+NNN/' \
  /sessions/<name>/mnt/free4me-iptv/pubspec.yaml

# 5. Regenerate version.json (AFTER changelog update)
cd /sessions/<name>/mnt/free4me-iptv && python3 scripts/update_version_json.py

# 6. Verify
grep "^version:" pubspec.yaml
cat version.json | python3 -m json.tool | grep '"latest"'

# 7. Commit
TMPIDX=$(mktemp)
GIT_INDEX_FILE="$TMPIDX" git read-tree HEAD
GIT_INDEX_FILE="$TMPIDX" git add <files> fixNNN.md
TREE=$(GIT_INDEX_FILE="$TMPIDX" git write-tree)
PARENT=$(git rev-parse HEAD)
COMMIT=$(GIT_INDEX_FILE="$TMPIDX" git commit-tree "$TREE" -p "$PARENT" \
  -m "fixNNN: <description> (vX.Y.Z+NNN)")
printf '%s\n' "$COMMIT" > .git/refs/heads/main
printf '%s\n' "$COMMIT" > .git/refs/tags/vX.Y.Z
rm "$TMPIDX"

# 8. Push
PAT=$(cat .github-token)
git push "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" main
git push "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" refs/tags/vX.Y.Z

# 9. Sync index
git read-tree HEAD
```

### Check repo state

```bash
cd /sessions/<name>/mnt/free4me-iptv
git log --oneline -5
git status --short
grep "^version:" pubspec.yaml
cat version.json | python3 -m json.tool | grep '"latest"'
```

### Find the VM session path

```bash
mount | grep free4me
# Look for the fuse line — the mount point is the VM path
```

### Verify no stale autofocus/RouteAware/dead code

```bash
grep -n "autofocus" lib/settings_view.dart      # should be exactly 1 (TextField)
grep -n "with RouteAware" lib/home.dart          # should be 0
grep -n "playerRouteObserver" lib/home.dart      # should be 0
grep -n "pushReplacement" lib/player/overlay_player_widget.dart  # should be 0
```

---

## 15. Known Virtiofs Limitations

The VM workspace mount (virtiofs) allows file creation and rename but **blocks
`unlink()`**. This means:

- `rm` of any file → `Operation not permitted`
- `git tag -d` → fails
- `git reset HEAD -- .` → fails (creates index.lock which then can't be removed)
- `git read-tree HEAD` **works** (uses rename internally)

The user's Mac Terminal can delete files normally. If the VM needs a file
deleted, ask the user to run `rm <path>` from their Terminal.

The `warning: unable to unlink '.git/objects/xx/tmp_obj_*'` messages during
`git write-tree` are **harmless** — the objects were created successfully at
their final path before git tried to clean up the temp name.

---

## 16. Dependencies Worth Knowing

```yaml
media_kit: ^1.2.6           # Primary mpv-based player
media_kit_video: ^2.0.1     # Video rendering
sqlite_async: ^0.13.0       # Async SQLite
connectivity_plus: ^7.0.0   # Network state
workmanager: ^0.9.0         # Background tasks
```

Upgrade constraint note (in pubspec.yaml comments):
- `file_picker`, `device_info_plus`, `package_info_plus` are locked together
  because they all depend on `win32`. Upgrade all three together when
  `file_picker ^12.0.0` stable ships.

Flutter version in CI: `3.44.0` (stable channel). See `.github/workflows/release.yml`.

---

---

## 17. Starting Fresh on a Different Mac

Everything in this document applies unchanged on a different Mac. Three
additional setup steps are required the first time only.

### Step 1 — Get the repo

```bash
git clone https://github.com/rkinnc75/Free4Me-IPTV.git \
  /Users/<you>/git/free4me-iptv
```

The keystore (`android/app/release.keystore`) is tracked and will be present
after the clone. All source, scripts, and CI config come with it.

`fix*.md` runbook files are **untracked** (local-only). They will NOT be present
after a fresh clone. If a pending fix exists (e.g. the phone has authored
`fix126.md` but Mac hasn't implemented it yet), the user must transfer that file
manually — or paste its contents into the chat. Claude should ask for the fix
content if the runbook file is missing.

### Step 2 — Recreate `.github-token`

This file is gitignored and will not be in the clone. Without it every push
fails. Create it:

```bash
echo "ghp_YourPersonalAccessTokenHere" > \
  /Users/<you>/git/free4me-iptv/.github-token
```

The PAT needs `repo` scope (push to the private repo + push tags). If the file
is missing, Claude should tell the user exactly this: "Please create
`.github-token` at the repo root containing your GitHub PAT with repo scope."
That is the one question Claude is permitted to ask on a new Mac.

### Step 3 — Open the folder in Cowork

In the Cowork desktop app, select the cloned repo folder as the workspace.
Cowork mounts it into the VM. The VM path will be something like
`/sessions/<new-session-name>/mnt/free4me-iptv/`.

### Finding the VM path in a new session

The session name changes every session. Find it at the start of any session:

```bash
mount | grep free4me
# Output will contain something like:
# /mnt/.virtiofs-root/shared/Users/builder/git/free4me-iptv
#   on /sessions/some-session-name/mnt/free4me-iptv type fuse ...
```

All bash commands in this document use the VM path. Substitute the actual
session name. The Read/Write/Edit file tools use the Mac path
(`/Users/builder/git/free4me-iptv/...`) directly and do not need
translation.

### Verify the setup before first commit

```bash
# Repo accessible from VM
ls /sessions/<name>/mnt/free4me-iptv/pubspec.yaml

# PAT file present and push works (dry-run check)
PAT=$(cat /sessions/<name>/mnt/free4me-iptv/.github-token)
git ls-remote "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" HEAD

# Current version matches remote
grep "^version:" /sessions/<name>/mnt/free4me-iptv/pubspec.yaml
```

If `ls-remote` succeeds, everything needed to implement and release fixes is
in place.

---

*End of handoff document. A new session reading this file should be able to
implement and release any fix without asking the user any questions, on the
same Mac or a different one.*
