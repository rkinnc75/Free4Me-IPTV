# Continuation Summary — free4me-iptv fix release process

**Last updated: 2026-06-16 · covers fix369–fix382 · current version: 1.34.11+382**

This document is ground zero. A fresh session with only this file should be able to release any `fixNNN.md` without asking the user a single question.

---

## 1. Project basics

| Item | Value |
|---|---|
| Repo path | `~/git/free4me-iptv` |
| Remote | `https://github.com/rkinnc75/Free4Me-IPTV` (HTTPS) |
| Token file | `.github-token` in repo root (gitignored) |
| Remote user | `rkinnc75` |
| Active branch | `main` (fix290 main-only flow — never check out a tag) |
| Flutter SDK | `~/tools/flutter/bin/flutter` |
| Android SDK | `~/Library/Android/sdk` |
| App version format | `X.Y.Z+NNN` — Z increments per release, NNN equals the fix number |

---

## 2. Current state (as of this summary)

- **Last released: fix382 → v1.34.11+382**
- All fix files through fix382 are in `runbooks/`. No `fixNNN.md` in repo root.
- Test suite: 18 files in `test/`, 64 tests. CI runs `flutter test` on every tag push.
- Analyze gate: **0 issues** — `No issues found!` is the expected analyzer output as of fix369.
- SQLite migration ceiling: **migration 30** (`idx_channels_browse_mt`).

---

## 3. How to identify fix format (do this first)

Open `fixNNN.md` and check for an embedded diff block:

```bash
grep -c '^\`\`\`diff' fixNNN.md
```

- **1 or more:** patch format → use `apply_fix.sh` (Section 4).
- **0:** FIND/REPLACE format (like fix374) → manual apply (Section 5).

FIND/REPLACE fixes use numbered steps like:
```
**Step 1** — In `lib/models/settings.dart`, find: ...
```

**One more check — does the `## Release — EXECUTE` section run `git rm` (or any git command beyond add/commit)?**
```bash
awk '/^## Release — EXECUTE/{f=1} f' fixNNN.md | grep -n 'git rm\|git mv'
```
If it does (fix382 was the first), **do NOT use `apply_fix.sh`** — its step-2 `git reset --hard origin/main` wipes any pre-emptive `git rm`, and it has no hook to run the deletions between patch-apply and commit. Release manually (Section 5), inserting the `git rm` after the patch applies and before the commit. Verify the deletion targets match the doc's description first (they are not compiled — only `lib/` is — but confirm nothing in `lib/` imports them).

---

## 4. Patch-format fix release (the normal case)

### 4a. Clean the repo root first (CRITICAL)

`apply_fix.sh` uses `git add -A` twice (steps 7 and 10). Any untracked file in the repo root will be swept into the release commit. Before every release:

```bash
ls ~/git/free4me-iptv/*.md ~/git/free4me-iptv/*.txt 2>/dev/null
```

Move or remove any stale files (e.g., old CONTINUATION-*.md, scratch notes) before proceeding.

### 4b. Extract the patch (optional — script does it automatically)

`apply_fix.sh` now auto-extracts `fixNNN.patch` from the embedded diff block when the `.patch` file is missing (updated in the fix379 window). You can still extract manually to do a pre-flight check:

```bash
cd ~/git/free4me-iptv
awk '/^```diff$/{f=1;next}/^```$/{if(f)exit}f' fixNNN.md > fixNNN.patch
head -5 fixNNN.patch   # should start with "diff --git a/..."
```

### 4c. Pre-flight check

```bash
export PATH="/Users/rich.kalsky/tools/flutter/bin:$PATH"
git apply --check fixNNN.patch
```

A `version.json` conflict is expected and harmless — the script handles it. Any other conflict means the patch is stale (see Section 6).

### 4d. Run the script

```bash
export PATH="/Users/rich.kalsky/tools/flutter/bin:$PATH"
bash scripts/apply_fix.sh fixNNN
```

Success output:
```
╔════════════════════════════════════════════════════════════════╗
║                  ✓ FIX RELEASE COMPLETE                        ║
╚════════════════════════════════════════════════════════════════╝
Release: v1.34.X
```

### 4e. Report to user

```
Released fixNNN → v1.34.X
https://github.com/rkinnc75/Free4Me-IPTV/releases/tag/v1.34.X
GitHub Actions will build the APK in ~5 minutes.
```

Do NOT poll CI for standard Dart-only fixes.

---

## 5. FIND/REPLACE format fix release (manual apply)

Apply each numbered step using the `Edit` tool. After all edits are done:

```bash
export PATH="/Users/rich.kalsky/tools/flutter/bin:$PATH"
cd ~/git/free4me-iptv

# Only if pubspec.yaml changed:
flutter pub get

# Analyze — must print "No issues found!"
flutter analyze --no-fatal-infos

# Commit (use the commit message from "## Release — EXECUTE" section of the fix file)
git add -A
git commit -m "fixNNN: release X.Y.Z"

# Push main
git push origin main

# Tag
git tag -f vX.Y.Z HEAD
git push -f origin refs/tags/vX.Y.Z

# Move fix file to runbooks (no .patch file for FIND/REPLACE fixes)
mkdir -p runbooks
mv fixNNN.md runbooks/
git add -A
git commit -m "fixNNN: move fix files to runbooks/"
git push origin main

# Verify tag
git fetch origin tag vX.Y.Z
git log -1 vX.Y.Z --format='%h %s'
```

---

## 6. apply_fix.sh inner workings

```
Step 0   Verify: .github-token exists; fixNNN.md exists; fixNNN.patch exists
Step 1   Write ~/.git-credentials from .github-token; configure credential helper
Step 2   git checkout main && git fetch origin && git reset --hard origin/main
Step 3   Print first 20 lines of fixNNN.md (informational)
Step 4   git apply fixNNN.patch
           → On conflict: retry with --reject
           → If only version.json.rej produced: delete it (harmless — CI regenerates it)
           → On other conflicts: exit 1
Step 5   flutter pub get if new dep detected; flutter analyze --no-fatal-infos
Step 6   Extract VERSION and BUILD from pubspec.yaml; verify changelog entry in whats_new_modal.dart
Step 7   git add -A  ← sweeps ALL untracked files — clean root before running
           Commit message: extracted from "## Release — EXECUTE" section, or fallback "fixNNN: release X.Y.Z"
Step 8   git push origin main
Step 9   git tag -f vX.Y.Z HEAD && git push -f origin refs/tags/vX.Y.Z
Step 10  mv fixNNN.md fixNNN.patch runbooks/ && git add -A && git commit && git push origin main
Step 11  git fetch origin tag vX.Y.Z → verify tag exists on GitHub
```

### Analyze gate note

Since the fix379 window, the script requires the literal string `No issues found!` in the `flutter analyze` output (and zero exit code). The previous success log "2 tolerated INFOs accepted" was stale text — it has been corrected in the script. Any warnings or errors must be fixed before proceeding.

---

## 7. Known hazards

### git add -A sweeps untracked files

Any file in the repo root that is untracked when step 7 or step 10 runs will be committed. Past incidents: `CONTINUATION-waggles-sw-forms-validation.md` swept into fix375 commit; `CONTINUATION-shopwindow-forms-ids.md` swept in separately. Both required `git rm` + commit + push to clean up. **Always check the root before running.**

### CI version.json commits arrive after tag push

GitHub Actions pushes a version.json update commit to `origin/main` after the APK uploads (`APK_BEFORE_VERSIONJSON: 'true'`). This is expected — `origin/main` will be 1 commit ahead of your local `main` after every release. The `git reset --hard origin/main` in step 2 of the next run picks it up automatically.

### Stale patch hunks on pubspec/changelog lines

If two fixes are applied back-to-back and the second patch references the first fix's version as context lines, the second patch will fail. Fix: edit the `.patch` file to update the `- version:` context line and the changelog anchor to match the just-released version.

### doc comment angle-bracket tokens trigger INFOs

If a patch adds doc comments containing raw `<NAME>` tokens (HTML-like), `unintended_html_in_doc_comment` INFOs appear. Fix: wrap tokens in backticks (`` `<NAME>` ``). This was the issue with fix374 — required manual correction before analyze passed.

---

## 8. CI pipeline overview

- **`release.yml`** — triggered by tag push `v*`. Runs `flutter analyze` + `flutter test` → builds APK → uploads to GitHub release → pushes version.json commit to main.
- **`analyze.yml`** — triggered by push to `main`, excluding `runbooks/` paths. The `paths-ignore` prevents the runbooks-move commit from triggering a redundant analyze run.
- **`APK_BEFORE_VERSIONJSON: 'true'`** — in both workflow files. When true: version.json is published after APK upload. Rollback: set to `'false'` in both.
- **Post-APK version.json step** has a `git stash` + push-retry/rebase loop to survive dirty trees and simultaneous-release races.

**Verify CI build** (not just analyze) when a release touches: native code, `AndroidManifest.xml`, new pub dependencies, `.github/workflows/*`, `apply_fix.sh`, or version.json logic. For native fixes, also run `flutter build apk --debug` locally before pushing.

---

## 9. Key architecture files (added/modified in fixes 369–377)

| File | Fix | Purpose |
|---|---|---|
| `lib/backend/visibility_clause.dart` | NEW fix371 | Single source of truth for channel-visibility SQL WHERE predicates |
| `lib/backend/browse_order.dart` | MOD fix375 | ORDER BY generation; `_valFloat` floats validated favorites above unvalidated |
| `lib/backend/sql.dart` | MOD fix371–377 | Core DB layer — see per-fix changes below |
| `lib/backend/db_factory.dart` | MOD fix373 | Migration 30: `idx_channels_browse_mt` (media_type-led partial index) |
| `lib/backend/app_logger.dart` | MOD fix374 | Credential redaction via `setSourceSecrets()` / `_redactSecrets()`; toggle: `AppLog.logUserPass` |
| `lib/backend/channel_search_cache.dart` | MOD fix375 | In-memory search cache; `providerOrder` field; pre-sorted views; `sortMode` param on `search()` |
| `lib/backend/xtream.dart` | MOD fix376 | Commits source row up front; threads shared `memory` map into `commitWriteBatched` |
| `lib/main.dart` | MOD fix373/374 | Unawaited `Sql.warmBrowseCache()` at startup; wires `logUserPass` and initial `setSourceSecrets()` |
| `lib/models/settings.dart` | MOD fix374 | `bool logUserPass` field |
| `lib/backend/settings_service.dart` | MOD fix374 | `logUserPassProp` constant; read/write in `_readFromDb`/`updateSettings` |
| `lib/backend/settings_io.dart` | MOD fix374 | `logUserPass` in import/export maps |
| `lib/settings_view.dart` | MOD fix374 | "Log User/Pass" switch tile below Debug Logging toggle |

**sql.dart changes by fix:**
- fix371: `search()` and `_searchLike()` call `VisibilityClause.build(alias: 'c.', ...)`
- fix372: `searchGroup()` ORDER BY adds `COALESCE(enabled, 1) DESC` tier
- fix373: `warmBrowseCache(settings)` static; `_allSourceIds()` helper
- fix374: `getSources()` calls `AppLog.setSourceSecrets(sources)` after every read
- fix375: `getAllChannelNamesForCache()` adds `c.provider_order`; `_searchInMemory` resolves `_uniformSortMode` and passes `sortMode` to cache; removes redundant `mapped.sort(...)`
- fix376: `getOrCreateSourceByName` committed up front with shared `memory` map; `memory: memory` threaded into `commitWriteBatched`
- fix377: Favorites branch resolves `_uniformSortMode` → `BrowseOrder.orderBy(uniformMode)`; falls back to fix356 source-name A–Z subquery when null/mixed
- fix378: Categories view groups by source when `sort_mode` is `provider` (new `searchGroup` branch)
- fix379: `isLowRamTv` renamed to `isLowRamDevice`; isTV gate dropped — low-RAM phones get same multi-view mitigation
- fix380: Suppressed-seek-probe-error log latched to once-per-open during startup grace period
- fix381: Add Source wizard collapsed to single form page (name + url/credentials/file + EPG, conditional per source type)
- fix382: `ChannelSearchCache.search` gates the disabled-category exclusion on `groupId == null` (HIGH-1, mirrors `VisibilityClause`); `home.dart` re-enables `_searchReady` in a `finally` so a cache-build throw can't strand the search box (MED-1); removed 7 stale tracked root duplicates (LOW-1)

---

## 10. Test suite (18 files as of fix382)

```
test/browse_enabled_index_test.dart
test/browse_mt_index_test.dart              (fix373)
test/browse_order_test.dart
test/device_lowram_threshold_test.dart      (fix379)
test/device_tag_test.dart
test/export_zip_test.dart
test/in_memory_disabled_category_test.dart  (fix382)
test/in_memory_sort_mode_test.dart          (fix375)
test/player_seek_probe_log_test.dart        (fix380)
test/series_episodes_test.dart
test/series_search_query_test.dart
test/setup_form_test.dart                   (fix381)
test/sql_favorites_sort_mode_test.dart      (fix377)
test/sql_searchgroup_sort_mode_test.dart    (fix378)
test/visibility_clause_test.dart            (fix371)
test/wipe_source_test.dart
test/xtream_first_add_counts_test.dart      (fix376)
test/xtream_refresh_logic_test.dart
```

---

## 11. Version numbering

```
pubspec.yaml:  version: X.Y.Z+NNN
Tag:           vX.Y.Z           (no +NNN in tag)
Changelog:     lib/whats_new_modal.dart must have entry for 'X.Y.Z':
Release URL:   https://github.com/rkinnc75/Free4Me-IPTV/releases/tag/vX.Y.Z
```

Each fix bumps both Z and NNN by 1. apply_fix.sh exits at step 6 if the changelog entry is missing.

---

## 12. Output style preference

- Responses: ≤150 words, bullets/code over prose, skip setup explanations.
- "explain more" = give depth on request.
- Don't poll CI for standard Dart-only fixes — report from script output and stop.
