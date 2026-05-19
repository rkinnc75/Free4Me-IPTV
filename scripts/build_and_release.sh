#!/usr/bin/env bash
# =============================================================================
# build_and_release.sh  build, commit, push, and publish a GitHub Release
#
# Usage:
#   ./scripts/build_and_release.sh
#
# What it does:
#   1. Reads version from pubspec.yaml
#   2. Builds the release APK
#   3. Copies it to ~/Downloads/Free4Me-IPTV-{version}-arm64.apk
#   4. Commits pubspec.yaml (version bump must already be done)
#   5. Pushes to github.com:rkinnc75/Free4Me-IPTV (using ~/.ssh/id_rsa)
#   6. Creates a GitHub Release tagged v{version}
#   7. Uploads the APK as a release asset
#
# Prerequisites:
#    GitHub token stored in macOS Keychain:
#       security add-internet-password -s api.github.com -a rkinnc75 -w <token>
#    SSH key ~/.ssh/id_rsa added to ssh-agent (or passphrase in
#       ~/.ssh/id_rsa.passphrase)
# =============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

#  1. Read version 
VERSION=$(grep '^version:' pubspec.yaml | head -1 | awk '{print $2}' | cut -d+ -f1)
if [[ -z "$VERSION" ]]; then
  echo "ERROR: could not read version from pubspec.yaml" >&2
  exit 1
fi
echo " Version: $VERSION"
APK_NAME="Free4Me-IPTV-${VERSION}-arm64.apk"
TAG="v${VERSION}"

#  2. Load SSH key (non-interactive) 
PASSPHRASE_FILE="$HOME/.ssh/id_rsa.passphrase"
if ! ssh-add -l &>/dev/null; then
  echo " Loading SSH key"
  if [[ -f "$PASSPHRASE_FILE" ]]; then
    SSH_ASKPASS=/bin/cat DISPLAY=dummy ssh-add "$HOME/.ssh/id_rsa" \
      < "$PASSPHRASE_FILE" 2>/dev/null
  else
    ssh-add "$HOME/.ssh/id_rsa"
  fi
fi

#  3. Build release APK 
echo " Building release APK"
flutter build apk --release

APK_SRC="$REPO_DIR/build/app/outputs/flutter-apk/app-release.apk"
APK_DOWNLOADS="$HOME/Downloads/$APK_NAME"

cp "$APK_SRC" "$APK_DOWNLOADS"
echo " APK copied to ~/Downloads/$APK_NAME"

#  4. Git commit & push 
# Make sure the remote is set
if ! git remote get-url origin &>/dev/null; then
  git remote add origin git@github.com:rkinnc75/Free4Me-IPTV.git
fi

# Stage everything modified (version bump in pubspec.yaml, changelog, etc.)
# APKs are in .gitignore so they won't be staged.
git add -A
if ! git diff --cached --quiet; then
  git commit -m "${TAG}: release build"
fi

echo " Pushing to GitHub"
git push origin main

#  5. Read GitHub token from keychain 
GITHUB_TOKEN=$(security find-internet-password -s "api.github.com" -a "rkinnc75" -w 2>/dev/null)
if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "ERROR: GitHub token not found in keychain." >&2
  echo "Run: security add-internet-password -s api.github.com -a rkinnc75 -w <token>" >&2
  exit 1
fi

#  6. Check if release already exists 
EXISTING=$(curl -sf \
  -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/rkinnc75/Free4Me-IPTV/releases/tags/$TAG" \
  2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

if [[ -n "$EXISTING" ]]; then
  echo " Release $TAG already exists (id=$EXISTING)  skipping creation"
  RELEASE_ID="$EXISTING"
else
  #  7. Create the GitHub release 
  echo " Creating GitHub release $TAG"

  # Build release notes from the What's New changelog in whats_new_modal.dart
  # Pull the entry matching this version's major.minor prefix
  MAJOR_MINOR=$(echo "$VERSION" | cut -d. -f1-2)

  RELEASE_BODY="## Free4Me-IPTV ${TAG}

Install \`${APK_NAME}\` by sideloading on your Android TV device.

See [DEVELOPMENT-HANDBOOK.md](https://github.com/rkinnc75/Free4Me-IPTV/blob/main/DEVELOPMENT-HANDBOOK.md) for the full feature roadmap and changelog."

  # Build JSON payload safely  avoid shell quoting nightmares
  JSON_PAYLOAD=$(python3 - <<PYEOF
import json
print(json.dumps({
  "tag_name": "${TAG}",
  "name": "${TAG}",
  "body": """${RELEASE_BODY}""",
  "draft": False,
  "prerelease": False
}))
PYEOF
)

  RESPONSE=$(curl -sf -X POST \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.github.com/repos/rkinnc75/Free4Me-IPTV/releases" \
    -d "$JSON_PAYLOAD")

  RELEASE_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  echo " Release created (id=$RELEASE_ID)"
fi

#  8. Upload APK asset 
# Delete any existing asset with the same name (idempotent re-runs)
EXISTING_ASSET_ID=$(curl -sf \
  -H "Authorization: token $GITHUB_TOKEN" \
  "https://api.github.com/repos/rkinnc75/Free4Me-IPTV/releases/${RELEASE_ID}/assets" \
  | python3 -c "
import sys, json
assets = json.load(sys.stdin)
match = [a['id'] for a in assets if a['name'] == '${APK_NAME}']
print(match[0] if match else '')
" 2>/dev/null || true)

if [[ -n "$EXISTING_ASSET_ID" ]]; then
  echo " Removing existing asset (id=$EXISTING_ASSET_ID)"
  curl -sf -X DELETE \
    -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/rkinnc75/Free4Me-IPTV/releases/assets/${EXISTING_ASSET_ID}" || true
fi

echo " Uploading $APK_NAME"
UPLOAD_RESPONSE=$(curl -sf -X POST \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Content-Type: application/vnd.android.package-archive" \
  --data-binary @"$APK_DOWNLOADS" \
  "https://uploads.github.com/repos/rkinnc75/Free4Me-IPTV/releases/${RELEASE_ID}/assets?name=${APK_NAME}")

ASSET_URL=$(echo "$UPLOAD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['browser_download_url'])")
echo ""
echo " Done! Release live at:"
echo "  https://github.com/rkinnc75/Free4Me-IPTV/releases/tag/${TAG}"
echo ""
echo " APK download URL:"
echo "  $ASSET_URL"
