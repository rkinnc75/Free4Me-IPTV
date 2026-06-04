# fix292 — Pipeline validation release (README-only payload) → v1.26.11

> ## ⚠️ BUILD MACHINE — EXECUTE EXACTLY, IN ORDER. NO OTHER STEPS.
> Purpose: prove the release pipeline works end-to-end after the rollback, using a harmless README-only change so there is zero code risk. If this release succeeds (tag on main, CI guard passes), the pipeline is trusted. PREREQUISITE: fix290 (pre-push guard + procedure) must already be applied to main. There are NO app code changes here.

## Preconditions — verify main is the recovered code FIRST
```bash
cd /path/to/Free4Me-IPTV
git checkout main
git fetch origin
git reset --hard origin/main
grep '^version:' pubspec.yaml          # MUST be 1.26.10+284 (recovered). If not, STOP.
grep -oE "SqliteMigration\([0-9]+" lib/backend/db_factory.dart | grep -oE "[0-9]+" | sort -n | tail -1   # MUST be 23
git config core.hooksPath             # SHOULD print .githooks (fix290 guard active). If empty, apply fix290 first.
```
If pubspec is not 1.26.10+284 or migration is not 23, STOP — main is not the recovered code.

## Step 1 — the harmless payload: touch README + add changelog entry + bump version
### Edit `README.md` — append this line at the very end of the file (verbatim):
```
<!-- Release pipeline validated on v1.26.11 (no functional changes). -->
```

### Edit `lib/whats_new_modal.dart` — insert at the TOP of the `_changelog` map.
The en-dash / quotes here are plain ASCII, so no escaping concerns.
#### Current code (verbatim)
```dart
const _changelog = <String, List<String>>{
```
#### Replacement code (verbatim)
```dart
const _changelog = <String, List<String>>{
  '1.26.11': [
    'Maintenance: internal release-process validation. No changes to app behavior.',
  ],
```

### Edit `pubspec.yaml`
#### Current code (verbatim)
```yaml
version: 1.26.10+284
```
#### Replacement code (verbatim)
```yaml
version: 1.26.11+286
```

## Step 2 — analyze (must be clean) 
```bash
flutter analyze --no-fatal-infos       # 2 tolerated INFOs, no errors/warnings
```

## Step 3 — cut the release via fix290 Part A (the ONLY allowed path)
```bash
# already on main, already reset to origin/main from Preconditions
grep '^version:' pubspec.yaml          # confirm 1.26.11+286
git add -A
git commit -m "fix292: pipeline validation release (README touch) v1.26.11"
git push origin main
./scripts/build_and_release.sh
```
> Do NOT git checkout any tag. Do NOT create the tag manually. The script pushes main (already done above is the code commit; the script handles version.json regen+commit+push+tag on the pushed commit). The fix290 pre-push hook will BLOCK the tag if it is somehow not on main — if you see "PRE-PUSH BLOCK", STOP and report (it means the release tried to tag an off-main commit again).

## Step 4 — verify the pipeline worked (this is the whole point)
```bash
git fetch origin --tags
echo "=== is the tag ON main? (must say it IS an ancestor) ==="
git merge-base --is-ancestor v1.26.11 origin/main && echo "v1.26.11 IS on main — GOOD" || echo "v1.26.11 NOT on main — PIPELINE STILL BROKEN"
echo "=== does main now show 1.26.11? ==="
git show origin/main:pubspec.yaml | grep '^version:'      # expect 1.26.11+286
echo "=== version.json on the tag matches generator? (CI guard would pass) ==="
git checkout v1.26.11
python3 scripts/update_version_json.py
git diff --quiet version.json && echo "version.json CURRENT on tag — GUARD PASSES" || { echo "STILL STALE"; git --no-pager diff version.json; }
git checkout main
echo "=== confirm code is still intact (not rolled back) ==="
grep -oE "SqliteMigration\([0-9]+" lib/backend/db_factory.dart | grep -oE "[0-9]+" | sort -n | tail -1   # 23
grep -c groupEnabled lib/backend/sql.dart                                                                 # >0
```

## What success looks like
- "v1.26.11 IS on main — GOOD"
- main shows 1.26.11+286
- "version.json CURRENT on tag — GUARD PASSES"
- migration 23, groupEnabled >0 (code intact, no rollback)
- The GitHub Actions release run for v1.26.11 completes green (no "version.json on the tagged commit is stale")

If ALL of the above hold, the pipeline is fixed and trusted. Paste the Step 4 output.

## If it fails
- "PRE-PUSH BLOCK" at Step 3 → the release path still tried to tag an off-main commit; the guard did its job. Report which command triggered it.
- "NOT on main" or "STILL STALE" at Step 4 → paste everything; do NOT retry blindly.
