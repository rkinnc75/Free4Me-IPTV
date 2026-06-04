# fix288 — RECOVER main: all of main/tag/release for "1.26.10" are 1.26.2 code

> ## ⚠️ BUILD MACHINE — DIAGNOSIS-GATED RECOVERY. Do Part A (read-only) and PASTE OUTPUT before doing Part B or C.
> Confirmed from the three uploaded zips (main download, v1.26.10 tag download, 1.26.10 release asset): ALL THREE contain 1.26.2+262 code — migration top 20, no is_divider, no groups.enabled, changelog tops at 1.26.2, version.json=1.26.2. The remote `main` is genuinely rolled back. fix254–fix282 are not on it. We must recover before any further work.

## What we know
- Last KNOWN-GOOD complete code = the **1.26.9 build** (version 1.26.9+282, migration 23, category enable/disable, dividers, CI self-heal). 1.26.8 also good. These exist as zips off-repo if git refs are unrecoverable.
- The rolled-back main still has the OLD version.json tripwire guard (not the fix282 self-heal), i.e. main never received the later commits.

---

# PART A — READ-ONLY: find if the good commits still exist in git. CHANGE NOTHING.
```bash
cd /path/to/Free4Me-IPTV
git fetch origin --prune --tags
echo "=== origin/main tip + version ==="
git log --oneline -5 origin/main
git show origin/main:pubspec.yaml | grep '^version:'
echo "=== do the good commits exist ANYWHERE in the object store? ==="
git log --all --oneline -S "SqliteMigration(23" -- lib/backend/db_factory.dart | head
git log --all --oneline -S "groupEnabled" -- lib/backend/sql.dart | head
echo "=== tags that might point at good code ==="
for t in v1.26.9 v1.26.8 v1.26.7 v1.26.6; do
  printf "%s -> " "$t"; git rev-parse "$t" 2>/dev/null || echo "MISSING"
  git show "$t:lib/backend/db_factory.dart" 2>/dev/null | grep -oE "SqliteMigration\([0-9]+" | grep -oE "[0-9]+" | sort -n | tail -1
done
echo "=== reflog (recent HEAD positions, may hold the good commit) ==="
git reflog --date=iso | head -30
```
**PASTE ALL OF THIS BACK.** Then do Part B if any command found migration-23 / groupEnabled commits or a good tag; otherwise do Part C.

---

# PART B — RECOVER FROM GIT (preferred, if Part A found the good commits)
Use the SHA that Part A showed for migration-23 / the v1.26.9 tag. Replace GOOD_SHA below.
```bash
cd /path/to/Free4Me-IPTV
git fetch origin --tags
GOOD_SHA=<paste the SHA from Part A — e.g. the v1.26.9 commit or the migration-23 commit>

# sanity: confirm that SHA really has the good code BEFORE touching main
git show ${GOOD_SHA}:pubspec.yaml | grep '^version:'                 # expect 1.26.9+282 (or 1.26.8+280)
git show ${GOOD_SHA}:lib/backend/db_factory.dart | grep -oE "SqliteMigration\([0-9]+" | grep -oE "[0-9]+" | sort -n | tail -1   # expect 23
git show ${GOOD_SHA}:lib/backend/sql.dart | grep -c groupEnabled      # expect >0

# make a safety branch of current (rolled-back) main first
git branch backup/rolledback-main origin/main

# restore main to the good commit
git checkout -B main ${GOOD_SHA}
git push --force-with-lease origin main
echo "main restored to ${GOOD_SHA}"
```

---

# PART C — RECOVER FROM THE 1.26.9 ZIP (only if Part A found NOTHING in git)
If the good commits are truly gone from the object store, rebuild main's tree from the known-good 1.26.9 source the user has. The user will provide `Free4Me-IPTV-1_26_9.zip`.
```bash
cd /path/to/Free4Me-IPTV
git fetch origin
git branch backup/rolledback-main origin/main          # safety
git checkout -B main origin/main

# wipe tracked files and replace with the 1.26.9 tree (preserve .git)
# (unzip the provided 1.26.9 zip to /tmp/good first)
rsync -a --delete --exclude='.git' /tmp/good/Free4Me-IPTV-1.26.9/ ./
git add -A
git commit -m "Restore main to 1.26.9 code (recover from rollback to 1.26.2)"
git push --force-with-lease origin main
```

---

# PART D — after recovery, VERIFY main is correct (run regardless of B or C)
```bash
cd /path/to/Free4Me-IPTV
git fetch origin && git checkout main && git reset --hard origin/main
grep '^version:' pubspec.yaml                                          # 1.26.9+282 (B) or as committed (C)
grep -oE "SqliteMigration\([0-9]+" lib/backend/db_factory.dart | grep -oE "[0-9]+" | sort -n | tail -1   # 23
grep -c is_divider lib/backend/sql.dart                                # >0
grep -c groupEnabled lib/backend/sql.dart                              # >0
grep -oE "'1\.26\.[0-9]+':" lib/whats_new_modal.dart | head -1         # '1.26.9':
```
All must match. Paste the output.

## DO NOT
- Do NOT cut any new release until main is recovered and verified (Part D passes).
- Do NOT delete `backup/rolledback-main` until recovery is confirmed good.
- Use `--force-with-lease` (not plain `-f`) so you can't clobber a concurrent change.

## After recovery
Once Part D confirms main = 1.26.9 code, I will (1) investigate WHY main rolled back so it can't happen again, and (2) write the two UI bug fixes (in-memory search ignoring disabled categories; picker duplicate Favourites sections) against the recovered, correct code.
