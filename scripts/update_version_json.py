#!/usr/bin/env python3
"""Update version.json from pubspec.yaml + lib/whats_new_modal.dart.

This is the standalone version of the inline Python heredoc in
`scripts/build_and_release.sh` (Section b2 of BUILD-ENV.md). Keeping it
as a separate file lets both the local release script and the GitHub
Actions workflow share one implementation.

Behavior:
  * Reads VERSION from `pubspec.yaml` (the `version: X.Y.Z+N` line,
    strips the `+N` build-number suffix).
  * Reads the bullet list for that VERSION from
    `lib/whats_new_modal.dart` (the `const _changelog` map).
  * Writes `version.json` at repo root with:
        latest        = VERSION
        releaseUrl    = github.com/.../releases/tag/vVERSION
        releaseNotes  = bulleted text (UTF-8 • prefix per line)
    Existing keys in version.json (e.g. minSupportedAndroidApi,
    criticalUpdate) are preserved.

Idempotent. Run with no arguments. Exits non-zero if pubspec.yaml is
malformed; treats a missing changelog entry as soft (writes
"Version VERSION" as the notes).

Usage:
  python3 scripts/update_version_json.py
"""

from __future__ import annotations

import json
import pathlib
import re
import sys

REPO_DIR = pathlib.Path(__file__).resolve().parent.parent
GITHUB_REPO = "rkinnc75/Free4Me-IPTV"


def read_version() -> str:
    pubspec = (REPO_DIR / "pubspec.yaml").read_text(encoding="utf-8")
    m = re.search(
        r"^version:\s*(?P<v>\d+\.\d+\.\d+)(?:\+\d+)?\s*$",
        pubspec,
        flags=re.MULTILINE,
    )
    if not m:
        sys.exit(
            "ERROR: could not parse `version: X.Y.Z+N` from pubspec.yaml"
        )
    return m.group("v")


def extract_notes(dart_text: str, version: str) -> str:
    """Pull the per-version bullet list out of the const _changelog map.

    The map literal in lib/whats_new_modal.dart has the shape:

        const _changelog = <String, List<String>>{
          '1.15.8': [
            'Fix: First bullet text. '
                'Continuation line concatenated by Dart.',
            'Fix: Second bullet.',
          ],
          '1.15.7': [
            ...
          ],
        };

    A "new bullet" line starts at column 4 with a quoted string; a
    continuation line is indented at column 8. The single-quoted string
    literals may contain \\n, \\', and \\\\ escapes — we decode them.
    """
    marker = f"  '{version}': ["
    idx = dart_text.find(marker)
    if idx == -1:
        return f"Version {version}"
    start = dart_text.index("[", idx) + 1
    end = dart_text.find("\n  ],", start)
    if end == -1:
        return f"Version {version}"
    block = dart_text[start:end]

    bullets: list[str] = []
    cur: list[str] = []
    for line in block.split("\n"):
        m = re.search(r"'((?:[^'\\]|\\.)*)'", line)
        if not m:
            continue
        content = (
            m.group(1)
            .replace("\\n", "\n")
            .replace("\\'", "'")
            .replace("\\\\", "\\")
        )
        # 4-space indent = new bullet; 8-space indent = continuation.
        if re.match(r"^    [^ ]", line):
            if cur:
                bullets.append("".join(cur))
            cur = [content]
        else:
            cur.append(content)
    if cur:
        bullets.append("".join(cur))
    if not bullets:
        return f"Version {version}"
    return "\n".join(f"• {b.strip()}" for b in bullets)


def main() -> None:
    version = read_version()
    tag = f"v{version}"
    dart_text = (REPO_DIR / "lib/whats_new_modal.dart").read_text(
        encoding="utf-8"
    )
    notes = extract_notes(dart_text, version)

    vf = REPO_DIR / "version.json"
    data: dict = (
        json.loads(vf.read_text(encoding="utf-8")) if vf.exists() else {}
    )
    data["latest"] = version
    data["releaseUrl"] = (
        f"https://github.com/{GITHUB_REPO}/releases/tag/{tag}"
    )
    # fix310: direct APK download URL for the in-app auto-updater. Asset name
    # matches release.yml: Free4Me-IPTV-${VERSION}-arm64.apk
    data["apkUrl"] = (
        f"https://github.com/{GITHUB_REPO}/releases/download/{tag}/"
        f"Free4Me-IPTV-{version}-arm64.apk"
    )
    data["releaseNotes"] = notes

    # Match the formatting the local `scripts/build_and_release.sh` Python
    # heredoc produces (default `json.dumps` settings — i.e.
    # ensure_ascii=True). Keeps the file byte-identical between local and
    # CI builds so git history doesn't churn on encoding differences.
    vf.write_text(
        json.dumps(data, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"version.json updated to {version}")
    print(f"  releaseUrl   : {data['releaseUrl']}")
    print(f"  releaseNotes :")
    for line in notes.splitlines():
        print(f"    {line}")


if __name__ == "__main__":
    main()
