# fix290 — ROOT CAUSE FIX: releases operated on tags/detached HEAD, never advanced main

> ## ⚠️ BUILD MACHINE — EXECUTE EXACTLY. This is the fix for the disease behind BOTH the version.json failures AND the rollback.
> Main was recovered to 92982c8 (1.26.10+284). This runbook prevents recurrence. Apply Part A (process change you MUST follow), commit Part B (a guard that makes the failure impossible), push. No app code.

## ROOT CAUSE (proven by reflog)
- `origin/main` sat frozen at `d80858b` (1.26.2-era) from 08:48 until the 19:32 recovery push. There is NO `update by push` to origin/main for ANY of fix266–fix284.
- The local reflog shows those commits were made, AND shows repeated `checkout: moving from main to v1.26.4` / `to v1.26.5` (detached-HEAD tag checkouts).
- Conclusion: the release process committed version.json on a **detached HEAD at the tag**, pushed only the **tag**, and **never pushed the commits onto `main`**. So main never advanced, every tag pointed at an orphaned commit, and CI (which checks out the tag) saw a tree whose version.json was never the current one.
- This is the SAME bug as every "version.json on the tagged commit is stale" failure AND the "rollback to 1.26.2." One cause, both symptoms.

## The rule that fixes it
**A release is just: commit to `main` → push `main` → tag the pushed commit on `main` → push the tag.** Never `git checkout <tag>`, never commit on a detached HEAD, never push a tag whose commit is not an ancestor of `origin/main`.

`scripts/build_and_release.sh` already does this correctly (push main, then tag HEAD). The failures came from cutting releases by some OTHER path (tag-checkout automation / manual). So:

# PART A — the ONLY allowed release procedure (use this verbatim every time)
```bash
cd /path/to/Free4Me-IPTV
git checkout main
git fetch origin
git reset --hard origin/main          # start from the real main, NEVER from a tag
# (apply the runbook's code edits; bump pubspec; write changelog)
flutter analyze --no-fatal-infos       # clean
grep '^version:' pubspec.yaml          # confirm the new version
./scripts/build_and_release.sh         # this pushes main, THEN tags the pushed commit
```
NEVER do any of these to cut a release:
- `git checkout v1.26.X` / `git checkout <sha>` then commit (detached HEAD — commits get orphaned)
- push a tag without having pushed `main` first
- create the tag in the GitHub UI / API on an arbitrary commit

# PART B — install a guard so a detached/non-main release CANNOT happen
Add a pre-push hook that REJECTS pushing a tag whose commit is not on `origin/main`, and rejects pushing from a detached HEAD. This makes the failure mechanically impossible regardless of who runs what.

Create `.githooks/pre-push`:
```bash
#!/usr/bin/env bash
# fix290: prevent the orphaned-tag / detached-HEAD release bug.
# Reject (a) pushing from a detached HEAD, and (b) pushing any tag whose
# commit is not an ancestor of origin/main.
set -euo pipefail
remote="$1"
git fetch -q "$remote" main || true
while read -r local_ref local_sha remote_ref remote_sha; do
  # tag push?
  if [[ "$remote_ref" == refs/tags/* ]]; then
    if ! git merge-base --is-ancestor "$local_sha" "$remote/main" 2>/dev/null \
       && ! git merge-base --is-ancestor "$local_sha" origin/main 2>/dev/null; then
      echo "PRE-PUSH BLOCK: tag ${remote_ref#refs/tags/} points at $local_sha which is NOT on origin/main." >&2
      echo "Push main first, then tag the commit that is on main. (fix290)" >&2
      exit 1
    fi
  fi
done
exit 0
```
Then enable it:
```bash
chmod +x .githooks/pre-push
git config core.hooksPath .githooks
git add .githooks/pre-push
git commit -m "fix290: pre-push hook blocks orphaned-tag / detached-HEAD releases (root-cause guard)"
git push origin main
```
> The hook lives in the repo (`.githooks/`) and is activated by `core.hooksPath`. On the Mac, run the `git config core.hooksPath .githooks` once so it's active locally. (Hooks are per-clone; if CI ever pushes tags, add the same check as a CI step — see Part C.)

# PART C — (optional but recommended) branch protection
On GitHub: Settings → Branches → add a rule for `main`:
- Require that pushes advance the branch (disallow force pushes by anyone except admins).
This prevents main from ever being force-moved backward again. Tags are unaffected.

## After this
Main = 1.26.10+284 (recovered). With Part A as the only release path and Part B blocking orphaned tags, neither the version.json staleness nor the rollback can recur: every tag will be on a main commit whose version.json the script already regenerated and committed.

## Next (separate runbooks, against the recovered code)
1. The two UI bugs: in-memory search ignoring disabled categories; channel picker duplicate Favourites sections.
