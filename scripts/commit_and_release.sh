#!/usr/bin/env bash
# commit_and_release.sh — Bindfs-safe commit + push for Free4Me-IPTV.
#
# Usage (from the VM):
#   bash /sessions/.../mnt/free4me-iptv/scripts/commit_and_release.sh \
#       "fix144: description (vX.Y.Z+NNN)" \
#       vX.Y.Z \
#       [--force-tag] \
#       file1 file2 ...
#
# Arguments:
#   $1          commit message (quoted)
#   $2          tag name (e.g. v1.22.12)
#   --force-tag (optional) force-push if tag already exists on remote
#   remaining   files to stage
#
# What it does:
#   1. Runs pre_commit_check.py — aborts if issues found
#   2. Bindfs commit (TMPIDX workaround)
#   3. Writes tag ref
#   4. Syncs real .git/index (BEFORE push — avoids the index.lock dance)
#   5. Pushes main branch
#   6. Pushes tag (force if --force-tag)

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# ── Parse arguments ──────────────────────────────────────────────────────────
COMMIT_MSG="${1:?commit message required}"
TAG="${2:?tag required}"
shift 2

FORCE_TAG=0
FILES=()
for arg in "$@"; do
    if [[ "$arg" == "--force-tag" ]]; then
        FORCE_TAG=1
    else
        FILES+=("$arg")
    fi
done

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "ERROR: no files specified to stage"
    exit 1
fi

# ── Step 1: pre-commit checks ────────────────────────────────────────────────
echo "── pre_commit_check ────────────────────────────────────────────────────"
python3 scripts/pre_commit_check.py || {
    echo ""
    echo "ERROR: pre-commit checks failed — fix issues before committing."
    exit 1
}

# ── Step 2: bindfs commit ────────────────────────────────────────────────────
echo "── bindfs commit ───────────────────────────────────────────────────────"
TMPIDX=$(mktemp)
GIT_INDEX_FILE="$TMPIDX" git read-tree HEAD
GIT_INDEX_FILE="$TMPIDX" git add "${FILES[@]}"
TREE=$(GIT_INDEX_FILE="$TMPIDX" git write-tree)
PARENT=$(git rev-parse HEAD)
COMMIT=$(GIT_INDEX_FILE="$TMPIDX" git commit-tree "$TREE" -p "$PARENT" -m "$COMMIT_MSG")
echo "Commit: $COMMIT"
printf '%s\n' "$COMMIT" > .git/refs/heads/main
rm "$TMPIDX"

# ── Step 3: write tag ref ────────────────────────────────────────────────────
printf '%s\n' "$COMMIT" > ".git/refs/tags/$TAG"
echo "Tag:    $TAG → $COMMIT"

# ── Step 4: sync index BEFORE push (avoids index.lock from push) ─────────────
echo "── syncing index ───────────────────────────────────────────────────────"
git read-tree HEAD 2>/dev/null && echo "index synced" || \
    echo "WARNING: index.lock present — rm .git/index.lock from Mac Terminal then re-run"

# ── Step 5: push main ────────────────────────────────────────────────────────
echo "── push main ───────────────────────────────────────────────────────────"
PAT=$(cat .github-token)
git push "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" main

# ── Step 6: push tag ─────────────────────────────────────────────────────────
echo "── push tag ────────────────────────────────────────────────────────────"
if [[ "$FORCE_TAG" == "1" ]]; then
    git push --force "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" "refs/tags/$TAG"
else
    git push "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" "refs/tags/$TAG"
fi

echo ""
echo "✅  Done — $TAG pushed. CI build triggered."
