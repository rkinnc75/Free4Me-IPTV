#!/usr/bin/env python3
"""
pre_commit_check.py — Fast static checks for Free4Me-IPTV Dart code.

Catches the specific errors that have repeatedly broken CI builds:
  1. @override on mpv-only methods NOT in the PlayerEngine interface
  2. Apostrophes inside single-quoted Dart strings in whats_new_modal.dart
  3. Duplicate version keys in whats_new_modal.dart _changelog map
  4. version.json out of sync with pubspec.yaml
  5. Targeted import checks: types that have actually caused missing-import
     CI breaks in this project (MediaType, AppLog in new files, etc.)

Exits 0 if clean, 1 if issues found.
"""

from __future__ import annotations
import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
LIB  = REPO / "lib"

# ── Methods that ARE in the PlayerEngine interface ────────────────────────────
# Only these may carry @override in mpv_engine.dart. Everything else is mpv-only.
PLAYER_ENGINE_INTERFACE: set[str] = {
    "buildVideoView", "open", "dispose",
    "bufferingStream", "completedStream", "errorStream", "positionStream",
    "position", "supportsTrackSelection", "subtitleTracks", "audioTracks",
    "setSubtitleTrack", "setAudioTrack", "setVolume",
    "handlesOwnFullscreen", "enterFullscreen", "exitFullscreen", "isFullscreen",
}

# ── Targeted import rules: (type, required_import_fragment, files_to_check) ──
# Only the combinations that have actually broken CI in this project.
# file_glob: glob relative to lib/ — use None to check ALL dart files.
IMPORT_RULES: list[tuple[str, str, str | None]] = [
    # MediaType broke multi_view_screen.dart (fix144)
    ("MediaType",   "models/media_type.dart",   "multi_view_screen.dart"),
    # MediaType in any player file
    ("MediaType",   "models/media_type.dart",   "player/*.dart"),
    # autofocus is not a param on ExpansionTile (fix122) — detected differently, skip
]

issues: list[str] = []


def check_override_on_mpv_only() -> None:
    """Flag @override on methods NOT in the PlayerEngine interface in mpv_engine.dart."""
    mpv = LIB / "player" / "mpv_engine.dart"
    if not mpv.exists():
        return
    src = mpv.read_text(encoding="utf-8")
    lines = src.splitlines()
    for i, line in enumerate(lines):
        if line.strip() != "@override":
            continue
        # Scan forward past doc-comments to find the method declaration
        for j in range(i + 1, min(i + 8, len(lines))):
            next_line = lines[j].strip()
            if not next_line or next_line.startswith("//") or next_line.startswith("///"):
                continue
            m = re.search(
                r"(?:Future<[^>]*>|Stream<[^>]*>|bool|void|int\??|String\??|"
                r"Widget|Duration|List<[^>]*>)\s+(?:get\s+)?(\w+)",
                next_line
            )
            if m:
                method = m.group(1)
                if method not in PLAYER_ENGINE_INTERFACE:
                    issues.append(
                        f"STRAY @override: lib/player/mpv_engine.dart line {i+1}: "
                        f"'{method}' is not in PlayerEngine interface — remove @override"
                    )
            break


def check_changelog_apostrophes() -> None:
    """Flag unescaped apostrophes inside single-quoted Dart strings in whats_new_modal.dart.

    Pattern: a single-quoted string token that visibly contains 's or n't
    (the string parser would have split it, so the raw source has the apostrophe
    adjacent to a word boundary mid-string).
    """
    modal = LIB / "whats_new_modal.dart"
    if not modal.exists():
        return
    src = modal.read_text(encoding="utf-8")
    in_changelog = False
    for i, line in enumerate(src.splitlines(), 1):
        if "_changelog" in line:
            in_changelog = True
        if not in_changelog:
            continue
        # Look for patterns like: 'blah blah word's more' or 'can't'
        # These have an apostrophe that terminates the Dart string unexpectedly.
        # Heuristic: single-quoted token ends right before a possessive/contraction.
        if re.search(r"'\s*[A-Za-z]+\s*'s\b", line) or \
           re.search(r"'\s*[A-Za-z]+n\s*'t\b", line):
            issues.append(
                f"APOSTROPHE: lib/whats_new_modal.dart line {i}: "
                f"unescaped apostrophe in single-quoted Dart string. "
                f"Reword to avoid (e.g. \"widget's\" → \"widget\", "
                f"\"doesn't\" → \"does not\")."
            )


def check_changelog_duplicate_keys() -> None:
    """Flag duplicate version keys in the _changelog map."""
    modal = LIB / "whats_new_modal.dart"
    if not modal.exists():
        return
    src = modal.read_text(encoding="utf-8")
    keys = re.findall(r"'(\d+\.\d+(?:\.\d+)?)':\s*\[", src)
    seen: set[str] = set()
    for k in keys:
        if k in seen:
            issues.append(
                f"DUPLICATE KEY: lib/whats_new_modal.dart has two entries "
                f"for version '{k}' — remove the duplicate"
            )
        seen.add(k)


def check_version_json_sync() -> None:
    """Verify version.json 'latest' matches pubspec.yaml version string."""
    pubspec = (REPO / "pubspec.yaml").read_text(encoding="utf-8")
    m = re.search(r"^version:\s*(\d+\.\d+\.\d+)", pubspec, re.MULTILINE)
    if not m:
        issues.append("Cannot parse version from pubspec.yaml")
        return
    pubspec_ver = m.group(1)

    vf = REPO / "version.json"
    if not vf.exists():
        issues.append("version.json missing — run: python3 scripts/update_version_json.py")
        return
    try:
        json_ver = json.loads(vf.read_text(encoding="utf-8")).get("latest", "")
    except Exception as e:
        issues.append(f"version.json malformed: {e}")
        return

    if pubspec_ver != json_ver:
        issues.append(
            f"VERSION MISMATCH: pubspec.yaml={pubspec_ver} but "
            f"version.json={json_ver} — run: python3 scripts/update_version_json.py"
        )


def check_targeted_imports() -> None:
    """Check targeted import rules — only patterns that have actually broken CI."""
    for type_name, import_fragment, file_glob in IMPORT_RULES:
        if file_glob is None:
            candidates = list(LIB.rglob("*.dart"))
        else:
            candidates = list(LIB.glob(file_glob))

        for dart_file in candidates:
            src = dart_file.read_text(encoding="utf-8")
            # Strip line and block comments before scanning for type usage
            src_clean = re.sub(r"//[^\n]*", "", src)
            src_clean = re.sub(r"/\*.*?\*/", "", src_clean, flags=re.DOTALL)
            # Strip string literals to avoid false positives from type names in strings
            src_clean = re.sub(r"'[^']*'", "''", src_clean)
            src_clean = re.sub(r'"[^"]*"', '""', src_clean)

            if not re.search(rf"\b{re.escape(type_name)}\b", src_clean):
                continue  # type not used in this file

            imports = re.findall(r"import\s+'([^']+)'", src)
            if not any(import_fragment in imp for imp in imports):
                rel = dart_file.relative_to(REPO)
                issues.append(
                    f"MISSING IMPORT: {rel} uses '{type_name}' "
                    f"but doesn't import '.../{import_fragment}'"
                )


def check_autofocus_on_expansion_tile() -> None:
    """Flag autofocus: true on ExpansionTile (fix122 regression check)."""
    for dart_file in LIB.rglob("*.dart"):
        src = dart_file.read_text(encoding="utf-8")
        lines = src.splitlines()
        for i, line in enumerate(lines):
            if "autofocus: true" not in line:
                continue
            # Look backwards for the enclosing widget name
            for j in range(i - 1, max(i - 10, -1), -1):
                prev = lines[j].strip()
                if prev.startswith("//") or prev.startswith("///") or not prev:
                    continue
                if "ExpansionTile(" in prev or "ExpansionTile(" in lines[j]:
                    issues.append(
                        f"INVALID PARAM: {dart_file.relative_to(REPO)} line {i+1}: "
                        f"'autofocus' is not a valid ExpansionTile parameter"
                    )
                break


def main() -> int:
    print("pre_commit_check: running...")
    check_override_on_mpv_only()
    check_changelog_apostrophes()
    check_changelog_duplicate_keys()
    check_version_json_sync()
    check_targeted_imports()
    check_autofocus_on_expansion_tile()

    if issues:
        print(f"\n❌  {len(issues)} issue(s) found:\n")
        for iss in issues:
            print(f"  • {iss}")
        print()
        return 1

    print("✅  All checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
