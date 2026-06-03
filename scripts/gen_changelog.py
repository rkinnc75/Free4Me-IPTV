#!/usr/bin/env python3
"""fix242: auto-generate a _changelog entry from git commits when one is missing.

Called by build_and_release.sh BEFORE version.json extraction. If
lib/whats_new_modal.dart already has an entry for the release version, does
nothing (hand-written entries win). Otherwise it builds a bulleted summary from
the commit subjects since the previous tag and injects it at the top of the
_changelog map, so the in-app What's New dialog, version.json, and the GitHub
release notes all show a real summary instead of a placeholder.
"""
import re, subprocess, sys

def commit_subjects(prev_tag):
    rng = f"{prev_tag}..HEAD" if prev_tag else "HEAD"
    out = subprocess.run(["git", "log", rng, "--pretty=format:%s"],
                         capture_output=True, text=True).stdout
    return [l.strip() for l in out.splitlines() if l.strip()]

def clean(subjects):
    """Turn commit subjects into user-facing bullets. Drops noise; dedupes."""
    bullets, seen = [], set()
    for s in subjects:
        # drop release/chore/merge noise
        if re.match(r'^(v?\d+\.\d+\.\d+|merge|chore|refactor: move fix|.*: release build)', s, re.I):
            continue
        # strip a leading "fixNNN: " or "fix: " prefix
        s = re.sub(r'^fix\w*:\s*', '', s, flags=re.I).strip()
        if not s:
            continue
        s = s[0].upper() + s[1:]
        key = s.lower()
        if key in seen:
            continue
        seen.add(key)
        bullets.append(s)
    return bullets

def dart_escape(s):
    return s.replace('\\', r'\\').replace("'", r"\'")

def main():
    version = sys.argv[1]
    prev_tag = sys.argv[2] if len(sys.argv) > 2 else ""
    path = "lib/whats_new_modal.dart"
    text = open(path).read()
    if f"  '{version}': [" in text:
        print(f"changelog: entry for {version} already present — leaving as-is")
        return
    bullets = clean(commit_subjects(prev_tag))
    if not bullets:
        bullets = [f"Maintenance and stability improvements."]
    # cap to a sensible number for the dialog
    bullets = bullets[:8]
    entry_lines = [f"  '{version}': ["]
    for b in bullets:
        entry_lines.append(f"    '{dart_escape(b)}',")
    entry_lines.append("  ],")
    entry = "\n".join(entry_lines) + "\n"
    # insert right after the map opener
    m = re.search(r"(const _changelog = <String, List<String>>\{\n|_changelog = <String, List<String>>\{\n|_changelog = \{\n)", text)
    if not m:
        print("changelog: ERROR could not find _changelog map opener", file=sys.stderr)
        sys.exit(1)
    text = text[:m.end()] + entry + text[m.end():]
    open(path, "w").write(text)
    print(f"changelog: auto-generated {len(bullets)}-bullet entry for {version} from commits since {prev_tag or 'start'}")

if __name__ == "__main__":
    main()
