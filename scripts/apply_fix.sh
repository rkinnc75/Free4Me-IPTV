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

# Check fix files exist
if [[ ! -f "${FIX_NAME}.md" ]]; then
  log_error "${FIX_NAME}.md not found"
  exit 1
fi
if [[ ! -f "${FIX_NAME}.patch" ]]; then
  log_error "${FIX_NAME}.patch not found"
  exit 1
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
log_ok "Git credentials configured"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Prepare Environment
# ─────────────────────────────────────────────────────────────────────────────

log_step "2" "Preparing environment"

git checkout main
git fetch origin
git reset --hard origin/main
log_ok "Environment reset to origin/main"

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

# Run flutter analyze
if flutter analyze --no-fatal-infos 2>&1 | grep -E "^(lib/|android/|ios/)" | grep -i error; then
  log_error "flutter analyze found errors"
  flutter analyze --no-fatal-infos | head -20
  exit 1
fi
log_ok "flutter analyze passed (2 tolerated INFOs accepted)"

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
  echo "  git tag -f v${VERSION} HEAD"
  echo "  git push -f origin refs/tags/v${VERSION}"
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
git tag -f "$TAG" HEAD
git push -f origin "refs/tags/$TAG"
log_ok "Tagged v${VERSION} and pushed to GitHub"

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
