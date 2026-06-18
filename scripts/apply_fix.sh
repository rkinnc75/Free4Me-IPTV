#!/usr/bin/env bash
# =============================================================================
# apply_fix.sh — Automated fix application workflow (fix300+)
#
# Usage:
#   ./scripts/apply_fix.sh fix310
#   ./scripts/apply_fix.sh fix311 --no-push  (dry-run: apply only, no push/release)
#
# What it does (10 steps):
#   1. Setup environment & verify credentials
#   2. Read fix specification from fixN.md
#   3. Apply patch (with --reject for version.json)
#   4. Handle new dependencies (flutter pub get)
#   5. Verify with flutter analyze
#   6. Commit to main
#   7. Push main branch
#   8. Create & push tag
#   9. Organize fix files to /runbooks
#   10. Verify release on GitHub
#
# Requirements:
#   - Bash 4.0+
#   - git
#   - flutter (for step 5)
#   - .github-token in repo root
#
# Compatible with:
#   - Claude Cowork (file tools + bash)
#   - Claude Code (CLI automation)
#   - macOS local machine (with credentials set up)
#
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Configuration & Setup
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
DRY_RUN=0

# Parse arguments
if [[ $# -lt 1 ]]; then
  cat >&2 <<'EOF'
Usage: ./scripts/apply_fix.sh fixN [--no-push]

Arguments:
  fixN        Fix number (e.g., fix310)
  --no-push   Apply only; skip push/release (default: false)

Examples:
  ./scripts/apply_fix.sh fix310
  ./scripts/apply_fix.sh fix310 --no-push
EOF
  exit 1
fi

FIX_NAME="$1"
if [[ "${2:-}" == "--no-push" ]]; then
  DRY_RUN=1
fi

cd "$REPO_DIR"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_step() { echo -e "${BLUE}[STEP $1]${NC} $2"; }
log_ok() { echo -e "${GREEN}✓${NC} $1"; }
log_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# Step 0: Verify Prerequisites
# ─────────────────────────────────────────────────────────────────────────────

log_step "0" "Verifying prerequisites"

# Check .github-token exists (CRITICAL)
if [[ ! -f ".github-token" ]]; then
  log_error ".github-token not found in repo root"
  echo "This file contains GitHub API credentials and is required for automation." >&2
  exit 1
fi
log_ok ".github-token found"

# Check fix spec exists
if [[ ! -f "${FIX_NAME}.md" ]]; then
  log_error "${FIX_NAME}.md not found in repo root"
  exit 1
fi

# Auto-generate ${FIX_NAME}.patch from the embedded ```diff block in
# ${FIX_NAME}.md if the .patch file is missing. Treats the .md as the
# source of truth — prevents the "I forgot to extract the patch"
# failure mode and recovers when `git clean -fd` (or any selective
# rm) wipes only the .patch. If the .md has no embedded diff block,
# fall through to a clear error.
if [[ ! -f "${FIX_NAME}.patch" ]]; then
  log_warn "${FIX_NAME}.patch not found; extracting from ${FIX_NAME}.md"
  awk '/^```diff$/{f=1;next}/^```$/{if(f)exit}f' "${FIX_NAME}.md" > "${FIX_NAME}.patch"
  if [[ ! -s "${FIX_NAME}.patch" ]] \
      || ! head -1 "${FIX_NAME}.patch" | grep -q "^diff --git "; then
    log_error "${FIX_NAME}.md has no embedded \`\`\`diff block (or it is malformed); cannot extract patch"
    rm -f "${FIX_NAME}.patch"
    exit 1
  fi
  log_ok "Extracted $(wc -l <"${FIX_NAME}.patch") lines into ${FIX_NAME}.patch"
fi
log_ok "Fix specification and patch found"

# Verify git is configured for HTTPS (not SSH)
GIT_REMOTE=$(git remote get-url origin 2>/dev/null || true)
if [[ "$GIT_REMOTE" == git@* ]]; then
  log_warn "Git remote uses SSH; switching to HTTPS"
  git remote set-url origin "https://github.com/rkinnc75/Free4Me-IPTV.git"
fi
log_ok "Git remote configured"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Setup Credentials
# ─────────────────────────────────────────────────────────────────────────────

log_step "1" "Setting up credentials"

# Read token from .github-token
TOKEN=$(cat .github-token | tr -d '\n')
if [[ -z "$TOKEN" ]]; then
  log_error ".github-token is empty"
  exit 1
fi

# Configure git credential helper
git config --global credential.helper store 2>/dev/null || true

# Create ~/.git-credentials
CRED_FILE="$HOME/.git-credentials"
echo "https://rkinnc75:${TOKEN}@github.com" > "$CRED_FILE"
chmod 600 "$CRED_FILE"

# Pipeline hardening (2026-06): a sandbox reset between turns can wipe the
# global git identity. Without it, Step 7's commit and Step 9's annotated tag
# fail mid-run — leaving a staged-but-uncommitted tree that breaks the re-run.
# Set it explicitly every run (the rkinnc75 mirror) so a reset can't break the
# commit.
git config --global user.name "rkinnc75"
git config --global user.email "45132022+rkinnc75@users.noreply.github.com"
log_ok "Git credentials and identity configured"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Prepare Environment
# ─────────────────────────────────────────────────────────────────────────────

log_step "2" "Preparing environment"

# Pipeline hardening (2026-06): a prior aborted run (e.g. a mid-run failure
# after `git add -A`) can leave ${FIX_NAME}.md, its patch, and applied new
# files STAGED in the index. `git reset --hard origin/main` then DELETES the
# staged runbook (it is "new" relative to origin), so the re-run fails at Step 3
# trying to read it; leftover applied files also make Step 4's `git apply` fail
# with "already exists". Preserve the runbook across the reset and clean the
# tree so a re-run always starts from a pristine origin/main with the runbook
# intact. (.github-token is gitignored, so `git clean -fd` does NOT remove it.)
_RUNBOOK_STASH=$(mktemp -d)
cp -f "${FIX_NAME}.md" "$_RUNBOOK_STASH/" 2>/dev/null || true
cp -f "${FIX_NAME}.patch" "$_RUNBOOK_STASH/" 2>/dev/null || true
git checkout main 2>/dev/null || git checkout -B main origin/main
git fetch origin
git reset --hard origin/main
git clean -fd
cp -f "$_RUNBOOK_STASH/${FIX_NAME}.md" . 2>/dev/null || true
cp -f "$_RUNBOOK_STASH/${FIX_NAME}.patch" . 2>/dev/null || true
rm -rf "$_RUNBOOK_STASH"
log_ok "Environment reset to origin/main (runbook preserved, tree cleaned)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Read Fix Specification
# ─────────────────────────────────────────────────────────────────────────────

log_step "3" "Reading fix specification"

echo ""
head -20 "${FIX_NAME}.md"
echo ""

# Check for warnings
if grep -q "BUILD MACHINE\|⚠️\|WARNING" "${FIX_NAME}.md"; then
  log_warn "This fix has special requirements — review above"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Apply Patch
# ─────────────────────────────────────────────────────────────────────────────

log_step "4" "Applying patch"

if git apply "${FIX_NAME}.patch" 2>/dev/null; then
  log_ok "Patch applied cleanly"
else
  # Try with --reject for version.json conflicts
  git apply "${FIX_NAME}.patch" --reject 2>/dev/null || true

  if [[ -f "version.json.rej" ]]; then
    log_warn "version.json patch conflict (expected and harmless)"
    rm -f version.json.rej
    log_ok "Removed rejected hunk; version.json will be regenerated"
  else
    # Real conflict, not just version.json
    log_error "Patch apply failed with unresolved conflicts"
    git diff --name-only --diff-filter=U
    exit 1
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Handle Dependencies & Verify Build
# ─────────────────────────────────────────────────────────────────────────────

log_step "5" "Verifying build (flutter analyze, dependencies)"

# Check if new dependency was added
if grep -q "# fix[0-9]\+:" pubspec.yaml; then
  log_warn "New dependency detected; fetching packages"
  flutter pub get
else
  log_ok "No new dependencies detected"
fi

# Run flutter analyze. The actual gate since fix369 is 0 errors, 0
# warnings, with output containing "No issues found!". Older script
# logic only grep'd for "error" lines and printed a misleading
# "2 tolerated INFOs accepted" success message — replaced 2026-06-16
# to make the gate actually check the success string.
#
# `|| true` is REQUIRED: under `set -e`, a non-zero exit from the
# command substitution (which happens on any error or warning) aborts
# the script at this assignment — before the diagnostic below can run,
# leaving a silent `exit 1` with no analyzer output. The "No issues
# found" check is the real gate and covers every failure mode (errors,
# warnings, and INFOs alike), so the captured exit code is redundant.
ANALYZE_OUTPUT=$(flutter analyze --no-fatal-infos 2>&1) || true
if ! grep -q "No issues found" <<<"$ANALYZE_OUTPUT"; then
  log_error "flutter analyze gate failed (expected 'No issues found!' in output)"
  echo "$ANALYZE_OUTPUT" | head -30
  exit 1
fi
log_ok "flutter analyze: No issues found!"

# Pipeline hardening (2026-06): gate on the test suite too, not just analyze.
# A patch can be analyze-clean yet break a test (or break a guard a test
# enforces — the EXPLAIN/tested==emitted tests exist for exactly this). The
# suite uses markTestSkipped when libsqlite3 is absent, so it still prints
# "All tests passed!" in a minimal environment — the gate stays portable
# across providers/sandboxes.
log_step "5b" "Verifying test suite (flutter test)"
TEST_OUTPUT=$(flutter test 2>&1) || true
if ! grep -q "All tests passed!" <<<"$TEST_OUTPUT"; then
  log_error "flutter test gate failed (expected 'All tests passed!' in output)"
  echo "$TEST_OUTPUT" | tail -30
  exit 1
fi
log_ok "flutter test: All tests passed!"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Verify Version & Changelog
# ─────────────────────────────────────────────────────────────────────────────

log_step "6" "Verifying version and changelog"

# Extract version
VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)
if [[ -z "$VERSION" ]]; then
  log_error "Could not extract version from pubspec.yaml"
  exit 1
fi
log_ok "Version: $VERSION"

# Extract build number
BUILD=$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f2)
log_ok "Build number: $BUILD"

# Pipeline hardening (2026-06): build numbers must increase monotonically.
# origin/main has NOT been pushed to yet, so it still holds the pre-fix
# version. If the patched build number is <= origin's, a parallel agent
# shipped first or the runbook is stale — abort rather than commit a
# duplicate/regressing build. (Replaces the implicit assumption that the
# author's target is always exactly origin+1; here we only require strictly
# greater, which is all Android/monotonic tagging needs.)
ORIGIN_BUILD=$(git show origin/main:pubspec.yaml 2>/dev/null | grep '^version:' | awk '{print $2}' | cut -d+ -f2)
if [[ "$BUILD" =~ ^[0-9]+$ && "$ORIGIN_BUILD" =~ ^[0-9]+$ ]]; then
  if [[ "$BUILD" -le "$ORIGIN_BUILD" ]]; then
    log_error "Build $BUILD is not greater than origin/main build $ORIGIN_BUILD"
    echo "A parallel ship occurred or the runbook is stale. Re-fetch origin/main, rebase the runbook's version, and retry." >&2
    exit 1
  fi
  log_ok "Build monotonic: $BUILD > origin/main ($ORIGIN_BUILD)"
else
  log_warn "Skipping build-monotonicity check (unparseable: new='$BUILD' origin='$ORIGIN_BUILD')"
fi

# Check changelog entry
if grep -q "'${VERSION}':" lib/whats_new_modal.dart; then
  log_ok "Changelog entry found for v${VERSION}"
else
  log_error "Changelog entry missing for v${VERSION}"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Commit to Main
# ─────────────────────────────────────────────────────────────────────────────

log_step "7" "Committing to main"

git add -A
# Generic fallback if the fix doc has no Release section.
COMMIT_MSG="${FIX_NAME}: release ${VERSION}"

# Prefer the commit message from the fix doc's "## Release — EXECUTE" section.
# IMPORTANT: scope the search to that section. The embedded patch (section A)
# can itself contain `git commit -m` lines (e.g. a CI step), so a naive
# `grep ... | head -1` over the whole file grabs the wrong message.
if grep -q "^## Release — EXECUTE" "${FIX_NAME}.md"; then
  EXTRACTED=$(awk '/^## Release — EXECUTE/{f=1} f && /git commit -m/{print; exit}' "${FIX_NAME}.md" \
    | sed 's/.*git commit -m "//' | sed 's/"$//')
  # Reject empty matches or unexpanded shell templates (e.g. ${GH_TAG}),
  # which indicate the line came from inside a patch, not the release recipe.
  if [[ -n "$EXTRACTED" && "$EXTRACTED" != *'${'* ]]; then
    COMMIT_MSG="$EXTRACTED"
  else
    log_warn "Could not extract a clean commit message from ${FIX_NAME}.md; using fallback"
  fi
fi

git commit -m "$COMMIT_MSG"
log_ok "Committed: $(git log -1 --format='%h %s')"

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: Push Main & Create Tag
# ─────────────────────────────────────────────────────────────────────────────

if [[ $DRY_RUN -eq 1 ]]; then
  log_warn "DRY RUN MODE: Skipping push and release"
  echo ""
  echo "To complete the release, run:"
  echo "  git push origin main"
  echo "  git tag -a v${VERSION} -m 'Release v${VERSION}' HEAD   # only if the tag does not already exist on origin"
  echo "  git push origin refs/tags/v${VERSION}"
  exit 0
fi

log_step "8" "Pushing main branch"

if git push origin main; then
  log_ok "Pushed main to GitHub"
else
  log_error "Push failed; check credentials"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 9: Create & Push Tag
# ─────────────────────────────────────────────────────────────────────────────

log_step "9" "Creating and pushing tag"

TAG="v${VERSION}"
# Pipeline hardening (2026-06): tags are immutable. The previous version
# force-pushed (`git tag -f` / `push -f`), which would silently CLOBBER another
# agent's release tag at the same version. Instead: if the tag already exists
# on origin at a DIFFERENT commit, abort (a parallel agent shipped this
# version); if it already points at our HEAD, no-op (idempotent re-run); only
# create+push when it is absent. No force anywhere.
REMOTE_TAG_LINE=$(git ls-remote --tags origin "refs/tags/${TAG}" 2>/dev/null || true)
if [[ -n "$REMOTE_TAG_LINE" ]]; then
  LOCAL_SHA=$(git rev-parse HEAD)
  # Dereference an annotated tag to the commit it wraps for a fair compare.
  REMOTE_COMMIT=$(git ls-remote origin "refs/tags/${TAG}^{}" 2>/dev/null | awk '{print $1}')
  [[ -z "$REMOTE_COMMIT" ]] && REMOTE_COMMIT=$(awk '{print $1}' <<<"$REMOTE_TAG_LINE")
  if [[ "$REMOTE_COMMIT" != "$LOCAL_SHA" ]]; then
    log_error "Tag ${TAG} already exists on origin at ${REMOTE_COMMIT} (≠ local HEAD ${LOCAL_SHA})"
    echo "Another agent already shipped this version. Aborting to preserve tag immutability." >&2
    exit 1
  fi
  log_warn "Tag ${TAG} already on origin at this commit; skipping tag push (idempotent)"
else
  git tag -a "$TAG" -m "Release ${TAG}" HEAD
  git push origin "refs/tags/$TAG"
  log_ok "Tagged v${VERSION} and pushed to GitHub"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 10: Organize Fix Files
# ─────────────────────────────────────────────────────────────────────────────

log_step "10" "Organizing fix files to /runbooks"

mkdir -p runbooks
mv "${FIX_NAME}.md" "${FIX_NAME}.patch" runbooks/
git add -A
git commit -m "${FIX_NAME}: move fix files to runbooks/"
git push origin main
log_ok "Fix files organized and committed"

# ─────────────────────────────────────────────────────────────────────────────
# Step 11: Verify Release
# ─────────────────────────────────────────────────────────────────────────────

log_step "11" "Verifying release on GitHub"

git fetch origin tag "$TAG"
COMMIT=$(git log -1 "$TAG" --format='%h')
log_ok "Tag $TAG verified on GitHub at commit $COMMIT"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                  ✓ FIX RELEASE COMPLETE                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Release: v${VERSION}"
echo "Tag:     ${TAG}"
echo "Commit:  ${COMMIT}"
echo ""
echo "GitHub Actions will build the APK in ~5 minutes."
echo "Release will appear at:"
echo "  https://github.com/rkinnc75/Free4Me-IPTV/releases/tag/${TAG}"
echo ""
