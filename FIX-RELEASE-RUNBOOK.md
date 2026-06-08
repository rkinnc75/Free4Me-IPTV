# Fix Release Runbook (fix300+ workflow)

**Version**: 1.0  
**Last Updated**: 2026-06-08  
**Scope**: free4me-iptv fix releases (fix300 onward)  
**Environments**: Claude Cowork, Claude Code  

---

## Overview

This runbook documents the complete automated workflow for applying, verifying, and releasing fixes 300+. The process follows the **fix290 main-only procedure**: all work happens on `main`, never on tag branches, with GitHub Actions handling the build on tag push.

## Critical Files & Locations

| File | Location | Purpose |
|------|----------|---------|
| `.github-token` | Repo root | GitHub API authentication (PAT) |
| `fix*.md` | Repo root → `/runbooks` | Fix specification & verification steps |
| `fix*.patch` | Repo root → `/runbooks` | Git patch file (verbatim code changes) |
| `pubspec.yaml` | Repo root | Version number (MAJOR.MINOR.PATCH+BUILD) |
| `version.json` | Repo root | In-app update checker feed (auto-regenerated) |
| `lib/whats_new_modal.dart` | `/lib` | Changelog entries (keyed by version) |
| `CLAUDE-WORKFLOW.md` | Repo root | Developer workflow documentation |
| `.gitconfig` | Home dir | Git configuration (credential helper = store) |
| `~/.git-credentials` | Home dir | Cached HTTPS credentials (auto-created) |

---

## Prerequisite: Credential Setup

**This must be done ONCE per environment.** Claude instances should check for this immediately when beginning fix work.

### Locate Credentials
```bash
# FIRST: Always check if .github-token exists
if [ -f .github-token ]; then
  echo "✓ Credentials found"
  TOKEN=$(cat .github-token | tr -d '\n')
else
  echo "ERROR: .github-token not found in repo root"
  exit 1
fi
```

### Configure Git Credentials (One-Time)
```bash
# Set credential helper to 'store'
git config --global credential.helper store

# Create ~/.git-credentials with HTTPS credentials
# Format: https://USERNAME:TOKEN@github.com
TOKEN=$(cat .github-token | tr -d '\n')
echo "https://rkinnc75:${TOKEN}@github.com" > ~/.git-credentials
chmod 600 ~/.git-credentials

# Verify git remote uses HTTPS, not SSH
git remote -v
# Should show: origin  https://github.com/rkinnc75/Free4Me-IPTV.git
```

**Why this matters**: The script will fail with "No such device or address" if it tries SSH before credentials are set up.

---

## Complete Fix Release Workflow

### Step 1: Prepare Environment
```bash
cd ~/git/free4me-iptv
git checkout main
git fetch origin
git reset --hard origin/main
```

**Verification**: `git log -1 --oneline` should show latest commit from origin/main.

---

### Step 2: Read Fix Specification
```bash
# fixN.md contains:
# - What this fix does
# - Files modified
# - Verification steps
# - Any special build requirements

cat fixN.md | head -50
```

**Key sections to check**:
- ⚠️ WARNING banner (e.g., "BUILD MACHINE", "NEW DEPENDENCY")
- Database migrations needed? (pubspec.yaml, db_factory.dart)
- New pub dependencies? (requires `flutter pub get`)
- Version.json changes? (auto-regenerated, OK if patch conflicts)

---

### Step 3: Apply Patch Verbatim
```bash
git apply fixN.patch

# If version.json hunk fails (expected), use --reject flag
if [ $? -ne 0 ]; then
  git reset --hard HEAD
  git apply fixN.patch --reject
  rm -f *.rej
fi
```

**Why --reject works**: `version.json` is regenerated during release by `scripts/update_version_json.py`, so a stale patch hunk is harmless.

---

### Step 4: Handle New Dependencies
```bash
# Always check pubspec.yaml for new packages
grep -E "^\s+\w+:" pubspec.yaml | tail -5

# If new dependency added, fetch it
flutter pub get
```

**Example**: fix310 adds `open_filex: ^4.5.0`

---

### Step 5: Verify Build & Analysis
```bash
# Run Flutter analysis (allows 2 tolerated INFOs)
flutter analyze --no-fatal-infos

# Check version bump
grep '^version:' pubspec.yaml

# Check changelog entry exists
MAJOR_MINOR=$(grep '^version:' pubspec.yaml | cut -d. -f1-2 | tr '+' '\n' | head -1)
grep "'$MAJOR_MINOR':" lib/whats_new_modal.dart
```

**Expected**: 
- Analysis: no errors/warnings (2 INFOs from settings_view.dart are tolerated)
- Version: should be `X.Y.Z+N` where N is the fix number
- Changelog: should have entry for the version

---

### Step 6: Commit to Main
```bash
git add -A
git commit -m "fixN: <description> (VERSION)"

# Example:
# git commit -m "fix310: in-app auto-update — download APK + launch installer (1.26.26)"
```

**Format**: `fixN: <user-facing description> (VERSION)`

**Verification**:
```bash
git log -1 --format='%h %s'
# Should show: abc1234 fixN: description (VERSION)
```

---

### Step 7: Push Main Branch
```bash
# Ensure credentials are set up (Step 1 of this section)
git push origin main

# Verify
git fetch origin
git log origin/main -1 --oneline
# Should show your new commit
```

**If push fails**: Check credential setup above. Error "No such device or address" = missing `.github-token` or `~/.git-credentials`.

---

### Step 8: Create & Push Tag
```bash
VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)
TAG="v${VERSION}"

# Create tag on current HEAD
git tag -f "$TAG" HEAD

# Push tag to GitHub
git push -f origin "refs/tags/$TAG"

# Verify tag is on GitHub
git fetch origin tag "$TAG"
git log -1 "$TAG" --oneline
```

**Why `-f` flag**: Ensures tag always points to the right commit (safety against race conditions).

**Verification**: Tag appears on GitHub releases page automatically.

---

### Step 9: Organize Fix Files
```bash
# Move fix specification and patch to /runbooks
mkdir -p runbooks
mv fixN.md fixN.patch runbooks/

# Commit the reorganization
git add -A
git commit -m "fixN: move fix files to runbooks/"
git push origin main
```

**Why separate commit**: Keeps the "fix code changes" commit distinct from "housekeeping" commit.

---

### Step 10: Verify Release on GitHub
```bash
# Wait ~30 seconds for GitHub Actions to trigger
# Then check:

# 1. Tag exists on GitHub
git fetch origin --tags
git tag -l | grep "v1.26.26"

# 2. Verify tag points to commit with correct version.json
git show v1.26.26:version.json | grep '"latest"'
# Should show: "latest": "1.26.26"

# 3. Check releases page
# https://github.com/rkinnc75/Free4Me-IPTV/releases/tag/vX.Y.Z
# Should show release with APK asset (once GitHub Actions completes ~5min)
```

---

## Error Recovery

### Error: "No such device or address" on git push
**Cause**: Credentials not configured, SSH unavailable, or network issue.

**Recovery**:
```bash
# 1. Verify .github-token exists
test -f .github-token && echo "✓ Found" || echo "✗ Missing"

# 2. Reconfigure credentials
TOKEN=$(cat .github-token | tr -d '\n')
git config --global credential.helper store
echo "https://rkinnc75:${TOKEN}@github.com" > ~/.git-credentials
chmod 600 ~/.git-credentials

# 3. Try push again
git push origin main
```

### Error: "patch does not apply" on git apply
**Cause**: Working tree state differs from patch expectations (common with version.json).

**Recovery**:
```bash
# Reset and apply with --reject
git reset --hard HEAD
git apply fixN.patch --reject

# Remove rejected hunks (usually just version.json)
rm -f *.rej

# Regenerate version.json (it gets auto-updated anyway)
python3 scripts/update_version_json.py

# Commit as usual
git add -A
git commit -m "fixN: ..."
```

### Error: "flutter analyze" shows errors/warnings
**Cause**: Patch code has issues or dependencies missing.

**Recovery**:
```bash
# 1. Check if new dependency is needed
grep "import.*package" lib/backend/*.dart | grep -v "^//"

# 2. Fetch dependencies
flutter pub get

# 3. Run analysis again
flutter analyze --no-fatal-infos

# If still failing: Check fix*.md for special notes (e.g., "STOP if analysis shows X")
```

---

## Automation Script

For Claude Code and Cowork environments, use this script to automate the entire workflow:

**File**: `scripts/apply_fix.sh` (source at CLAUDE-FIX-AUTOMATION.sh)

```bash
./scripts/apply_fix.sh fix310
```

This handles all 10 steps automatically, with error checking and credential validation.

---

## Credential Management Security Notes

- `.github-token` is a GitHub Personal Access Token (PAT)
- It has repo-level read/write access only
- It's stored in the repo root (not in version control — see .gitignore)
- `~/.git-credentials` is auto-created and chmod'd 600 (owner read/write only)
- Tokens expire; if a push fails with "Invalid credentials", regenerate in GitHub Settings

---

## Quick Reference: Standard Workflow Command Sequence

```bash
# 1. Setup
cd ~/git/free4me-iptv
git checkout main && git fetch origin && git reset --hard origin/main

# 2. Apply & verify
git apply fixN.patch --reject
rm -f *.rej
flutter pub get
flutter analyze --no-fatal-infos

# 3. Commit & push
git add -A
git commit -m "fixN: description (VERSION)"
git push origin main

# 4. Tag & release
VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)
git tag -f "v${VERSION}" HEAD
git push -f origin "refs/tags/v${VERSION}"

# 5. Organize
mkdir -p runbooks
mv fixN.md fixN.patch runbooks/
git add -A && git commit -m "fixN: move fix files to runbooks/" && git push origin main

# 6. Verify (wait 30s for GitHub Actions)
git fetch origin --tags
git log -1 "v${VERSION}" --oneline
```

---

## Key Rules (Never Break These)

1. **Always use `main` branch** — Never checkout tag branches
2. **Always verify patch applies cleanly** — version.json --reject is OK, others are NOT
3. **Always check flutter analyze** — No errors/warnings (2 INFOs tolerated)
4. **Always commit before pushing** — Verify `git status` is clean
5. **Always use `-f` flag on tag push** — Prevents race condition stale commits
6. **Always organize fix files AFTER release** — Separate commit for housekeeping
7. **Always check .github-token exists** — First line of troubleshooting

---

## Testing This Runbook

To validate this runbook works:

1. Apply a fix following steps 1-9
2. Verify step 10 (release on GitHub)
3. Document any deviations and update this file

Last validated: 2026-06-08 (fix310)

