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
export PATH="$PATH:~/tools/flutter/bin"

# fix31 preflight — Mac builds MUST sign with the project's release keystore.
# If key.properties is missing, the build would silently fall back to the
# debug keystore (per android/app/build.gradle) and ship an APK that no
# existing user can install over the top. Better to fail before the build.
if [[ ! -f "$REPO_DIR/android/key.properties" ]]; then
  cat >&2 <<'WARN'

ERROR: android/key.properties is missing. Without it, this build would
       be signed with the debug keystore and existing users would have
       to uninstall before updating.

       Restore your local copy from the .release-keystore-secrets backup
       (or from your password manager). The file should contain:

           storeFile=release.keystore
           storePassword=<RELEASE_KEYSTORE_PASSWORD>
           keyAlias=<RELEASE_KEY_ALIAS>
           keyPassword=<RELEASE_KEY_PASSWORD>

       And android/app/release.keystore must exist alongside it.
       See CLAUDE-WORKFLOW.md (fix31 section).

WARN
  exit 1
fi
if [[ ! -f "$REPO_DIR/android/app/release.keystore" ]]; then
  echo "ERROR: android/app/release.keystore is missing." >&2
  echo "       Decode RELEASE_KEYSTORE_B64 into it. See CLAUDE-WORKFLOW.md." >&2
  exit 1
fi

flutter build apk --release --target-platform android-arm64

APK_SRC="$REPO_DIR/build/app/outputs/flutter-apk/app-release.apk"
APK_DOWNLOADS="$HOME/Downloads/$APK_NAME"

cp "$APK_SRC" "$APK_DOWNLOADS"
echo " APK copied to ~/Downloads/$APK_NAME"

# ── 3a. Auto-generate a What's New entry from commits if one is missing ──────
# fix242: the in-app What's New dialog and version.json both read the
# _changelog map in lib/whats_new_modal.dart. If a release is cut without a
# hand-written entry, the dialog falls back to a generic placeholder. This
# generates an entry from the commit subjects since the previous tag (a no-op
# if a hand-written entry already exists), so every release gets a real
# automated summary. The previous tag is the most recent v* tag reachable.
PREV_TAG=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
echo "── changelog ──────────────────────────────────────────────────────────"
python3 scripts/gen_changelog.py "$VERSION" "$PREV_TAG"

# ── 3b. Update version.json (fetched by the in-app update checker) ───────────
python3 - <<PYEOF
import json, pathlib, re

repo  = pathlib.Path("$REPO_DIR")
ver   = "$VERSION"
tag   = "$TAG"

# ── Extract changelog for this version from whats_new_modal.dart ─────────────
dart = (repo / "lib/whats_new_modal.dart").read_text()

def extract_notes(text, version):
    marker = f"  '{version}': ["
    idx = text.find(marker)
    if idx == -1:
        return f"Version {version}"
    start = text.index('[', idx) + 1
    end   = text.find('\n  ],', start)
    if end == -1:
        return f"Version {version}"
    block = text[start:end]

    bullets, cur = [], []
    for line in block.split('\n'):
        m = re.search(r"'((?:[^'\\\\]|\\\\.)*)'", line)
        if not m:
            continue
        content = (m.group(1)
                    .replace('\\\\n', '\n')
                    .replace("\\\\'", "'")
                    .replace('\\\\\\\\', '\\\\'))
        # 4-space indent = new list element; 8-space = continuation
        if re.match(r'^    [^ ]', line):
            if cur:
                bullets.append(''.join(cur))
            cur = [content]
        else:
            cur.append(content)
    if cur:
        bullets.append(''.join(cur))
    return '\n'.join(f'• {b.strip()}' for b in bullets) if bullets else f"Version {version}"

notes = extract_notes(dart, ver)

vf   = repo / "version.json"
data = json.loads(vf.read_text()) if vf.exists() else {}
data["latest"]      = ver
data["releaseUrl"]  = f"https://github.com/rkinnc75/Free4Me-IPTV/releases/tag/{tag}"
data["releaseNotes"] = notes
vf.write_text(json.dumps(data, indent=2) + "\n")
print(f"  releaseNotes for {ver}:\n{notes}")
PYEOF
echo " version.json updated to $VERSION"

# ── 4. Git commit & push ──────────────────────────────────────────────────────
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

# fix280: HARD GUARD — version.json on HEAD must match the generator, else the
# tag would point at a commit with stale version.json (the recurring CI failure).
python3 scripts/update_version_json.py
if ! git diff --quiet version.json; then
  git add version.json
  git commit -m "${TAG}: sync version.json"
fi
python3 scripts/update_version_json.py
if ! git diff --quiet version.json; then
  echo "ERROR: version.json does not match generator after commit — aborting before tag." >&2
  git --no-pager diff version.json >&2
  exit 1
fi

echo " Pushing to GitHub"
git push origin main

# fix280: create the tag LOCALLY on the exact commit that contains version.json,
# then push it. This pins the tag to the right commit instead of letting the
# GitHub release API create it at the server's branch HEAD (which raced to the
# PREVIOUS commit and caused every "version.json on the tagged commit is stale"
# failure: 1.26.2, 1.26.4, 1.26.5, 1.26.7).
RELEASE_SHA="$(git rev-parse HEAD)"
git tag -f "${TAG}" "${RELEASE_SHA}"
git push -f origin "refs/tags/${TAG}"
echo " Tagged ${TAG} at ${RELEASE_SHA} (commit with current version.json)"

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
  # fix280: target_commitish pins the release/tag to the exact commit that has
  # the current version.json, so it can never resolve to a stale commit.
  JSON_PAYLOAD=$(python3 - <<PYEOF
import json
print(json.dumps({
  "tag_name": "${TAG}",
  "target_commitish": "${RELEASE_SHA}",
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
