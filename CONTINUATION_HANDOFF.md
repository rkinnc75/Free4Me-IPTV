# Free4Me-IPTV — Continuation Handoff for Any Claude Session

> **Read this entire file before doing anything.** It contains every convention,
> constraint, and workflow needed to implement and release fixes without asking
> the user a single question. This file is the single source of truth for
> continuing this project in any new session or model.
>
> **Last updated:** 2026-06-01 — v1.23.16+186
> **Repo:** `https://github.com/rkinnc75/Free4Me-IPTV`
> **Local path:** `~/git/free4me-iptv`
> **Current version:** `1.23.16+186`

---

## FIRST ACTIONS IN ANY NEW SESSION

Run these immediately before anything else:

```bash
# 1. Find the VM mount path (changes every session)
mount | grep free4me
# → /sessions/<SESSION-NAME>/mnt/free4me-iptv

# 2. Set git identity (required after history scrub — commit-tree fails without it)
git -C /sessions/<NAME>/mnt/free4me-iptv config user.email "builder@users.noreply.github.com"
git -C /sessions/<NAME>/mnt/free4me-iptv config user.name "builder"

# 3. Verify sync with remote
cd /sessions/<NAME>/mnt/free4me-iptv
PAT=$(cat .github-token)
git ls-remote "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" HEAD | cut -f1
git rev-parse HEAD
# Both hashes must match. If remote is ahead, the user made changes on GitHub — see DIVERGENCE section.
```

---

## PROJECT IDENTITY

| Field | Value |
|---|---|
| App | Free4Me-IPTV — Android TV IPTV player |
| Package | `open_tv` |
| Repo | `https://github.com/rkinnc75/Free4Me-IPTV` |
| Local | `~/git/free4me-iptv` |
| Platform | Flutter/Dart, Android TV |
| Current version | `1.23.16+186` |

---

## CORE WORKFLOW: IMPLEMENT A FIX AND RELEASE

When the user says "fixNNN":

### Step 1 — Read the runbook
```bash
cat /sessions/<NAME>/mnt/free4me-iptv/fixNNN.md
```
The runbook is authoritative. Implement it exactly.

### Step 2 — Read current source files
Use `sed -n 'LINE,LINEp'` or `grep -n` to verify current code before patching.
**Never patch blind** — always confirm the exact text you're replacing is present.

### Step 3 — Apply code changes
Use Python scripts for multi-line patches (reliable, no shell escaping issues):
```python
path = '/sessions/<NAME>/mnt/free4me-iptv/lib/...'
with open(path) as f: c = f.read()
c = c.replace(OLD, NEW, 1)
assert OLD in original_content  # verify before writing
with open(path, 'w') as f: f.write(c)
```

### Step 4 — Update changelog (BEFORE running version script)
Add a new entry at the TOP of `_changelog` in `lib/whats_new_modal.dart`:
```dart
const _changelog = <String, List<String>>{
  '1.X.Y': [
    'Description without apostrophes in single-quoted strings.',
  ],
  '1.X.Y-1': [  // previous entry
```
**Rules:** no `\'` or `\$` or `\u` inside single-quoted strings — reword instead.

### Step 5 — Bump version
```bash
sed -i 's/version: OLD/version: NEW/' pubspec.yaml
```

### Step 6 — Regenerate version.json (AFTER changelog)
```bash
cd /sessions/<NAME>/mnt/free4me-iptv
python3 scripts/update_version_json.py
```

### Step 7 — Pre-commit check
```bash
python3 scripts/pre_commit_check.py
# Must exit 0. Fix any issues before continuing.
```

### Step 8 — Commit and release
```bash
cd /sessions/<NAME>/mnt/free4me-iptv

# Bindfs commit (NEVER use git commit directly — it fails on virtiofs)
TMPIDX=$(mktemp)
GIT_INDEX_FILE="$TMPIDX" git read-tree HEAD
GIT_INDEX_FILE="$TMPIDX" git add file1.dart file2.dart pubspec.yaml version.json fixNNN.md
TREE=$(GIT_INDEX_FILE="$TMPIDX" git write-tree)
PARENT=$(git rev-parse HEAD)
COMMIT=$(GIT_INDEX_FILE="$TMPIDX" git commit-tree "$TREE" -p "$PARENT" \
  -m "fixNNN: description (vX.Y.Z+NNN)")
printf '%s\n' "$COMMIT" > .git/refs/heads/main
printf '%s\n' "$COMMIT" > .git/refs/tags/vX.Y.Z   # new tag or force-overwrite same-patch tag
rm "$TMPIDX"

# Sync index BEFORE push (prevents index.lock)
git read-tree HEAD

# Push
PAT=$(cat .github-token)
git push "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" main
git push "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" refs/tags/vX.Y.Z
# If tag already exists (same patch, new build): add --force to tag push
```

---

## FIX NUMBERING CONVENTION

| Lane | Numbers |
|---|---|
| Mac / Cowork (this session) | **ODD**: 183, 185, 187… |
| Phone (mobile Claude) | **EVEN**: 184, 186, 188… |

- Version string: `MAJOR.MINOR.PATCH+BUILD` where BUILD = fix number
- Multiple fixes at same patch share same tag (force-push tag to new commit)
- **Never reuse, delete, or recreate a tag**

### Recent version history
| Version | Build | Fix | Notes |
|---|---|---|---|
| 1.23.12 | +178 | fix178 | Critical: cures upgrade freeze (bad migration) |
| 1.23.13 | +180 | fix180 | Clear playback_metrics on version change |
| 1.23.14 | +182 | fix182 | D-pad focus on first element everywhere |
| 1.23.15 | +184 | fix184 | Provider connection limit gates multi-view |
| 1.23.15 | +186 | fix186 | Missing fetchXtreamMaxConnections definition |

---

## VIRTIOFS LIMITATIONS (critical to understand)

The VM workspace mount (virtiofs) **cannot delete/unlink files**. This means:

- `rm` of any file → `Operation not permitted`
- Normal `git commit` fails (tries to unlink temp objects)
- `git tag -d` fails
- `git read-tree HEAD` **works** (uses rename, not unlink)

**The bindfs commit workaround** (above) avoids all unlink calls by using a temp index file. The harmless `warning: unable to unlink ... tmp_obj_*` messages are expected.

**index.lock**: After `git push`, a lockfile may be left that blocks `git read-tree HEAD`. If this happens, the user must run from their Mac Terminal:
```bash
rm ~/git/free4me-iptv/.git/index.lock
```
The index sync (`git read-tree HEAD`) in the commit script runs **before** push to minimize this.

---

## VERSION.JSON CRITICAL RULE

CI re-runs `python3 scripts/update_version_json.py` and diffs `version.json`.
If the output differs from what's committed, the build **fails**.

**Order that must be followed every time:**
1. Update `whats_new_modal.dart` changelog
2. Update `pubspec.yaml` version
3. Run `update_version_json.py`
4. Run `pre_commit_check.py`
5. Commit all four files together

---

## STATIC ANALYSIS — THREE LAYERS

Flutter SDK cannot be installed in the VM sandbox (storage.googleapis.com blocked).

**Layer 1 — Python pre-checker** (instant, VM):
```bash
python3 scripts/pre_commit_check.py
```
Catches: stray `@override` on mpv-only methods, apostrophes in changelog strings,
duplicate changelog keys, version mismatch, `autofocus` on `ExpansionTile`,
missing `MediaType` import.

**Layer 2 — `analyze.yml`** GitHub Action on every `main` push (~2 min).
Check at: `https://github.com/rkinnc75/Free4Me-IPTV/actions/workflows/analyze.yml`

**Layer 3 — `release.yml`** runs analyze before building APK (final gate).

**Tolerated INFOs** (do NOT fix):
- `use_build_context_synchronously` in `lib/settings_view.dart` (~lines 2143, 2731)

**FATAL** (must fix before commit):
- Any `error` or `warning` level finding
- Unused imports/fields/methods, stray `@override`, undefined names

---

## HARD RULES (never break these)

1. Fix numbers are the commit IDs (not PO-xxxx)
2. Mac/Cowork = odd; Phone = even
3. Never `git tag -d` — write ref files directly
4. Never commit `.github-token`
5. Never hand-write `version.json` — always run `update_version_json.py`
6. Tag push is mandatory — commit push alone does NOT build APK
7. `whats_new_modal.dart` updated BEFORE running `update_version_json.py`
8. Pre-commit check BEFORE every commit
9. Index synced BEFORE push (prevents index.lock)
10. No pushReplacement in navigator — use pop+push
11. No `\'` `\$` `\u` in Dart string literals in runbooks or changelog
12. Every SQL column reference must have its schema declaration cited (RUNBOOK-PREFLIGHT rule 7)
13. Any migration must be tested against seeded prior-schema DB (RUNBOOK-PREFLIGHT rule 8)
14. `MpvEngine.handlesOwnFullscreen = false` — media_kit fullscreen was the root cause of black screen; keep it disabled

---

## GIT USER IDENTITY

After the history scrub, git identity is not set globally. **Must set per-clone:**
```bash
git config user.email "builder@users.noreply.github.com"
git config user.name "builder"
```
`commit-tree` fails with "Author identity unknown" if not set.

---

## KEY FILE LOCATIONS

```
lib/
  main.dart               App entry, ThemeData, lifecycle observer
  home.dart               Channel list (root route — MaterialApp.home)
  player.dart             Full-screen player
  settings_view.dart      Settings screen
  whats_new_modal.dart    Changelog (const _changelog map)
  channel_tile.dart       Channel list row
  multi_view_picker_dialog.dart  Layout picker (StatefulWidget, gates by connection limit)
  backend/
    sql.dart              All DB access; insertChannelsBulk; rowToSource
    db_factory.dart       Migrations (current highest: 16)
    xtream.dart           Xtream fetch + fetchXtreamMaxConnections
    settings_service.dart maybeRotateLogOnVersionChange (clears log + playback_metrics)
    playback_analyzer.dart PlaybackMetrics, Recommender
    export_server.dart    TV HTTP export server (:9479)
  models/
    source.dart           Source model (has maxConnections field since fix184)
scripts/
  update_version_json.py  MUST run after changelog update
  pre_commit_check.py     MUST run before every commit
  commit_and_release.sh   Bindfs commit helper (use this)
RUNBOOK-PREFLIGHT.md      Rules for writing fix runbooks
RUNBOOK-PREFLIGHT-PHONE.md Phone-side rules
CLAUDE_HANDOFF.md         Extended session handoff doc
```

---

## DATABASE MIGRATIONS (current state)

Latest migration: **16** (`max_connections` column on `sources`)

| Migration | What |
|---|---|
| 1–9 | Initial schema, sources, channels, groups, settings |
| 10 | `stream_validated` column on channels |
| 11 | FTS trigger on name-only UPDATE + browse-order index |
| 12 | `playback_metrics` table (fix154) |
| 13 | Guarantee `playback_metrics` exists (fix170, idempotent IF NOT EXISTS) |
| 14 | NEUTRALISED — was bad coalesced UNIQUE index (fix178) |
| 15 | Two partial unique indexes: `channels_unique_stream` + `channels_unique_series` |
| 16 | `max_connections INTEGER` column on sources (fix184) |

---

## QUICK REFERENCE

### Find VM path
```bash
mount | grep free4me
```

### Check repo state
```bash
cd /sessions/<NAME>/mnt/free4me-iptv
git log --oneline -3
grep "^version:" pubspec.yaml
python3 scripts/pre_commit_check.py
```

### Force-push tag (same patch version, new build)
```bash
printf '%s\n' "$COMMIT" > .git/refs/tags/vX.Y.Z
git push --force "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" refs/tags/vX.Y.Z
```

### Remote is ahead (user made changes on GitHub)
```bash
# Fetch remote HEAD
PAT=$(cat .github-token)
REMOTE=$(git ls-remote "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" HEAD | cut -f1)
# Rebase our commit on top of remote
TMPIDX=$(mktemp)
GIT_INDEX_FILE="$TMPIDX" git read-tree "$REMOTE"
GIT_INDEX_FILE="$TMPIDX" git add <files>
TREE=$(GIT_INDEX_FILE="$TMPIDX" git write-tree)
COMMIT=$(GIT_INDEX_FILE="$TMPIDX" git commit-tree "$TREE" -p "$REMOTE" -m "msg")
printf '%s\n' "$COMMIT" > .git/refs/heads/main
rm "$TMPIDX"
```

### New Mac / fresh clone
```bash
git clone https://github.com/rkinnc75/Free4Me-IPTV.git ~/git/free4me-iptv
echo "ghp_YourToken" > ~/git/free4me-iptv/.github-token
cd ~/git/free4me-iptv
git config user.email "builder@users.noreply.github.com"
git config user.name "builder"
```

---

## SIGNING

| Secret | Value |
|---|---|
| Keystore alias | `free4me-iptv` |
| Keystore SHA-256 | `D8:D3:4D:5A:...` (see CLAUDE_HANDOFF.md) |
| Type | PKCS12, RSA-4096 |

CI secrets stored in GitHub Actions: `RELEASE_KEYSTORE_B64`, `RELEASE_KEYSTORE_PASSWORD`, `RELEASE_KEY_ALIAS`, `RELEASE_KEY_PASSWORD`. Not accessible from VM. Keystore file was never committed (gitignored).

---

## COMMON PITFALLS

| Symptom | Fix |
|---|---|
| `commit-tree: Author identity unknown` | `git config user.email/name` in the repo |
| `git push` rejected non-fast-forward | Remote is ahead — rebase on remote HEAD |
| `index.lock: File exists` blocking `git read-tree HEAD` | User runs `rm ~/git/free4me-iptv/.git/index.lock` from Mac Terminal |
| CI fails on `version.json` mismatch | Changelog was updated AFTER running `update_version_json.py` |
| CI fails `undefined_named_parameter` | Check `@override` on mpv-only methods; check `ListTileThemeData` vs `ThemeData` |
| App freezes on logo after upgrade | Bad migration — add a new highest-version migration with IF NOT EXISTS |
| `warning: unable to unlink ... tmp_obj_*` | Normal/harmless virtiofs behavior |

---

*End of handoff. Read RUNBOOK-PREFLIGHT.md before writing any fix runbook.*
