# Claude Code Fix Release Guide

**For**: Claude Code CLI users (developers running automated fix releases)  
**Version**: 1.0  
**Last Updated**: 2026-06-08  

## Quick Start

```bash
# In Claude Code or your terminal
cd ~/git/free4me-iptv
./scripts/apply_fix.sh fix311
```

The script handles the complete 11-step release workflow automatically.

---

## Before You Start

### One-Time Setup (per machine)

```bash
# 1. Ensure .github-token exists in repo root
cd ~/git/free4me-iptv
test -f .github-token && echo "✓ Credentials found" || echo "✗ Missing!"

# 2. Verify git is in HTTPS mode (not SSH)
git remote -v
# Should show: https://github.com/rkinnc75/Free4Me-IPTV.git
# NOT: git@github.com:rkinnc75/Free4Me-IPTV.git
```

### Per-Fix Checklist

- [ ] Read `fixN.md` for special requirements
- [ ] Verify `fixN.patch` and `fixN.md` exist in repo root
- [ ] Check pubspec.yaml for version bump
- [ ] Confirm lib/whats_new_modal.dart has changelog entry

---

## Running a Fix Release

### Option A: Full Automated Release (Recommended)

```bash
./scripts/apply_fix.sh fix311
```

**What it does**:
1. ✓ Verifies credentials & prerequisites
2. ✓ Applies patch (handles version.json conflicts)
3. ✓ Runs `flutter analyze` for verification
4. ✓ Commits code changes to main
5. ✓ Pushes main to GitHub
6. ✓ Creates and pushes tag v1.26.X
7. ✓ Organizes fix files to `/runbooks`
8. ✓ Verifies release on GitHub

**Output**: You'll see progress for each step. On success:
```
╔════════════════════════════════════════════════════════════════╗
║                  ✓ FIX RELEASE COMPLETE                        ║
╚════════════════════════════════════════════════════════════════╝

Release: v1.26.26
Tag:     v1.26.26
Commit:  abc1234d

GitHub Actions will build the APK in ~5 minutes.
```

### Option B: Dry-Run (Test Only, No Push)

```bash
./scripts/apply_fix.sh fix311 --no-push
```

**What it does**: Applies and verifies the fix, but stops before pushing. Useful for testing if a fix applies cleanly before releasing.

### Option C: Manual Step-by-Step (Advanced)

If the automated script fails, follow the steps in `FIX-RELEASE-RUNBOOK.md` manually. Each step is self-contained:

```bash
# Step by step
git checkout main && git fetch origin && git reset --hard origin/main
git apply fix311.patch --reject
flutter pub get
flutter analyze --no-fatal-infos
git add -A && git commit -m "fix311: description (VERSION)"
git push origin main
VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)
git tag -f "v${VERSION}" HEAD && git push -f origin "refs/tags/v${VERSION}"
mkdir -p runbooks && mv fix311.* runbooks/ && git add -A && git commit -m "fix311: move to runbooks/" && git push origin main
```

---

## Troubleshooting

### "No such device or address" on git push

```bash
# Reconfigure credentials
TOKEN=$(cat .github-token | tr -d '\n')
git config --global credential.helper store
echo "https://rkinnc75:${TOKEN}@github.com" > ~/.git-credentials
chmod 600 ~/.git-credentials

# Retry
git push origin main
```

### "patch does not apply"

```bash
git reset --hard HEAD
git apply fixN.patch --reject
rm -f *.rej
# Continue; version.json conflicts are expected
```

### "flutter analyze" shows errors

```bash
# Check if new dependency was added
grep "# fix[0-9]\+:" pubspec.yaml

# If yes, fetch it
flutter pub get

# Re-run analysis
flutter analyze --no-fatal-infos
```

### ".github-token not found"

```bash
# Token file should be in repo root
ls -la .github-token

# If missing, restore from:
# 1. Your password manager
# 2. The .release-keystore-secrets backup
# 3. Ask team lead
```

---

## Integration with Claude Code

### Using Claude Code to Apply Fixes

In a Claude Code session, you can invoke the automation directly:

```
User: "Apply and release fix311"

Claude Code:
$ cd ~/git/free4me-iptv && ./scripts/apply_fix.sh fix311
```

### Using Claude Code to Debug

If the script fails, you can troubleshoot step-by-step:

```
User: "Why did the patch fail to apply?"

Claude Code:
$ git apply fix311.patch --reject 2>&1 | head -50
```

### Combining with Claude Analysis

Ask Claude to analyze the fix before releasing:

```
User: "Review fix311.md for any gotchas"

Claude Code:
$ cat fix311.md
```

---

## Workflow Integration

### Daily Release Cycle

```bash
# Morning: Check for pending fixes
ls -la fix*.md

# Apply and release each fix
./scripts/apply_fix.sh fix311
./scripts/apply_fix.sh fix312
./scripts/apply_fix.sh fix313

# Verify all released
git log --oneline -10
```

### Scheduled Releases (with cron)

```bash
# Add to crontab for automated daily release
0 9 * * * cd ~/git/free4me-iptv && [ -f fix*.md ] && ./scripts/apply_fix.sh fix$(ls -1 fix*.md | head -1 | sed 's/fix\([0-9]*\).md/\1/')
```

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `scripts/apply_fix.sh` | Main automation script (this is your entry point) |
| `FIX-RELEASE-RUNBOOK.md` | Complete manual documentation |
| `CLAUDE-WORKFLOW.md` | Developer workflow (in repo) |
| `.github-token` | GitHub API credentials (in repo root) |
| `fix*.md` | Fix specification (created by developer) |
| `fix*.patch` | Patch file (created by developer) |

---

## Success Indicators

After running `./scripts/apply_fix.sh fix311`, you should see:

- ✓ No errors or failures
- ✓ Commits show in `git log`
- ✓ Tag created: `git tag -l v1.26.*`
- ✓ Fix files in `/runbooks`: `ls runbooks/fix*.md`
- ✓ Release on GitHub: Check https://github.com/rkinnc75/Free4Me-IPTV/releases

---

## Advanced: Custom Fixes

If you need to customize the automation:

1. Edit `scripts/apply_fix.sh` - shell script, fully documented
2. Add your custom steps in the appropriate section
3. Test with `--no-push` first
4. Document any changes in this guide

---

## Support & Questions

- **Script errors?** Check the step number in the error message and see "Troubleshooting" above
- **Patch issues?** Run `git apply fixN.patch --reject` and review the rejected hunks
- **Credentials lost?** See "Troubleshooting" > ".github-token not found"
- **Other issues?** Refer to `FIX-RELEASE-RUNBOOK.md` for detailed documentation

---

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-06-08 | Initial version; documents fix300+ workflow after fix310 release |

