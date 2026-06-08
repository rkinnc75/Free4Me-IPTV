# Fix Automation Documentation

**Purpose**: Complete guide to the fix300+ release workflow  
**Audience**: Claude (Cowork, Claude Code), developers  
**Status**: Active (updated after fix310)  
**Last Updated**: 2026-06-08  

---

## 🚀 Quick Start

### For Claude (Cowork or Claude Code)

```bash
./scripts/apply_fix.sh fix311
```

That's it. The script handles all 11 steps automatically.

### For Manual Release

See `FIX-RELEASE-RUNBOOK.md` for step-by-step instructions.

---

## 📚 Documentation Map

| Document | Who Should Read | Purpose |
|----------|-----------------|---------|
| **THIS FILE** | Everyone | Overview and navigation |
| `FIX-RELEASE-RUNBOOK.md` | Everyone | Complete, detailed process (11 steps) |
| `CLAUDE-COWORK-FIX-GUIDE.md` | Claude in Cowork | How to automate in Cowork mode |
| `CLAUDE-CODE-FIX-GUIDE.md` | Claude in Claude Code | How to automate in CLI |
| `scripts/apply_fix.sh` | Automation runners | The actual automation script |
| `CREDENTIALS-AND-SECRETS.md` | Token managers | How to manage `.github-token` |

---

## 📋 What You'll Learn

### From FIX-RELEASE-RUNBOOK.md
- ✓ Complete 11-step workflow
- ✓ How to apply patches
- ✓ How to verify builds
- ✓ How to push commits and tags
- ✓ How to troubleshoot errors
- ✓ Emergency recovery procedures

### From CLAUDE-COWORK-FIX-GUIDE.md
- ✓ Running automation in Cowork mode
- ✓ Cowork-specific workflows
- ✓ Reading and verifying fixes before release
- ✓ Troubleshooting Cowork limitations
- ✓ Integration patterns

### From CLAUDE-CODE-FIX-GUIDE.md
- ✓ Running automation in Claude Code (CLI)
- ✓ One-time setup
- ✓ Per-fix checklist
- ✓ Dry-run testing
- ✓ CI/CD integration
- ✓ Scheduled releases

### From CREDENTIALS-AND-SECRETS.md
- ✓ Understanding `.github-token`
- ✓ Security best practices
- ✓ Token lifecycle and rotation
- ✓ Troubleshooting token issues
- ✓ Emergency token revocation

---

## 🔑 Key Concepts

### The Workflow
```
Read fix spec
    ↓
Apply patch
    ↓
Verify (flutter analyze)
    ↓
Commit to main
    ↓
Push main
    ↓
Create & push tag
    ↓
Organize files to /runbooks
    ↓
GitHub Actions builds APK
    ↓
Release appears on GitHub
```

### Critical Files

**Credentials**:
- `.github-token` — GitHub API token (required for automation)

**Code**:
- `scripts/apply_fix.sh` — Automation script
- `fix*.md` — Fix specification
- `fix*.patch` — Patch file
- `pubspec.yaml` — Version number
- `lib/whats_new_modal.dart` — Changelog

**Configuration**:
- `.git-credentials` — Git credential cache (auto-created)
- `.gitignore` — Excludes secrets from version control

---

## ⚡ The Automation Script

### What `scripts/apply_fix.sh` Does

```bash
./scripts/apply_fix.sh fix311          # Full release
./scripts/apply_fix.sh fix311 --no-push # Test only (no push)
```

**Steps it handles**:
1. Verify prerequisites (credentials, fix files)
2. Setup git credentials
3. Prepare environment (fetch, reset)
4. Apply patch (with --reject for version.json)
5. Fetch dependencies (flutter pub get)
6. Verify build (flutter analyze)
7. Commit to main
8. Push main branch
9. Create & push tag
10. Organize fix files
11. Verify on GitHub

**Why it exists**: To prevent the mistakes that happened during fix310 (missing credentials, not searching for them, asking for help instead of automating).

---

## ⚠️ Critical Success Factors

**Don't Skip These**:

1. **Check `.github-token` exists** immediately
   - If missing, fix cannot be released
   - Location: repo root

2. **Verify git is in HTTPS mode** (not SSH)
   - SSH requires keys; HTTPS uses token
   - Script handles this automatically

3. **Always run `flutter analyze`** before committing
   - Catches errors early
   - 2 tolerated INFOs from settings_view.dart are OK

4. **Never push without a commit**
   - Empty pushes can confuse the system
   - Script always commits before pushing

5. **Always verify on GitHub** after release
   - Wait 5 minutes for GitHub Actions
   - Check release URL: `https://github.com/rkinnc75/Free4Me-IPTV/releases/tag/vX.Y.Z`

---

## 🔐 Credential Security

**The single most important thing**:
- `.github-token` must exist in repo root
- It's NOT committed to git (in .gitignore)
- The script reads it and uses it internally
- It's never exposed in logs or output
- It's the ONLY credential you need for automation

**If the token is missing**:
1. The script will fail immediately
2. You must restore it from your password manager
3. See `CREDENTIALS-AND-SECRETS.md` for details

---

## 🐛 When Things Go Wrong

### "Script failed" Errors

1. **Read the error message** — It includes the step number
2. **Look up that step** in `FIX-RELEASE-RUNBOOK.md`
3. **Check "Error Recovery"** section for solutions
4. **Never push without verifying first** — Use `--no-push` flag

### Common Issues

| Issue | Solution |
|-------|----------|
| Credentials missing | See CREDENTIALS-AND-SECRETS.md |
| Patch won't apply | Use `git apply --reject`, remove `.rej` files |
| Flutter errors | Run `flutter pub get`, then analyze again |
| Push fails | Check credential setup, test with git config |
| Tag not on GitHub | Run `git fetch origin --tags` |

---

## 📖 How to Use This Documentation

### If you're Claude running a fix release:
1. Start with `CLAUDE-COWORK-FIX-GUIDE.md` (Cowork) OR `CLAUDE-CODE-FIX-GUIDE.md` (CLI)
2. Run `./scripts/apply_fix.sh fix###`
3. If it fails, refer to `FIX-RELEASE-RUNBOOK.md` Error Recovery section

### If you're setting up automation:
1. Read `FIX-RELEASE-RUNBOOK.md` to understand the workflow
2. Setup credentials using `CREDENTIALS-AND-SECRETS.md`
3. Test with `./scripts/apply_fix.sh fix### --no-push`

### If you're debugging:
1. Check the error message and step number
2. Look in `FIX-RELEASE-RUNBOOK.md` under that step
3. See "Error Recovery" section
4. If still stuck, review `CREDENTIALS-AND-SECRETS.md` (most issues are auth-related)

---

## ✅ Verification Checklist

After running a fix release, verify:

- [ ] Commits in `git log` (2 commits: code + file organization)
- [ ] Tag created: `git tag -l v1.26.*` shows new version
- [ ] Fix files moved: `/runbooks/fix*.md` exists
- [ ] GitHub release page loads: Check URL `https://github.com/rkinnc75/Free4Me-IPTV/releases/tag/vX.Y.Z`
- [ ] APK asset appears (wait 5 minutes for GitHub Actions)

---

## 📚 File Structure

```
/Users/rich.kalsky/git/free4me-iptv/
├── FIX-AUTOMATION-README.md          ← You are here
├── FIX-RELEASE-RUNBOOK.md            ← Complete workflow docs
├── CLAUDE-COWORK-FIX-GUIDE.md        ← Cowork-specific guide
├── CLAUDE-CODE-FIX-GUIDE.md          ← Claude Code guide
├── CREDENTIALS-AND-SECRETS.md        ← Token management
├── .github-token                     ← GitHub API token (secret!)
├── scripts/
│   └── apply_fix.sh                  ← Automation script
├── runbooks/                         ← Organized fix files
│   ├── fix310.md
│   ├── fix310.patch
│   └── ...
├── lib/
│   └── whats_new_modal.dart          ← Changelog
├── pubspec.yaml                      ← Version number
└── CLAUDE-WORKFLOW.md                ← Developer workflow
```

---

## 🎯 Success Indicators

You'll know the automation is working when:

1. ✓ Script runs without errors
2. ✓ Commits appear in `git log`
3. ✓ Tag appears on GitHub (in 30 seconds)
4. ✓ Release page shows release (within 5 minutes)
5. ✓ APK asset appears (within 5-10 minutes as Actions complete)

---

## 🔄 Next Steps After This Fix

For the next fix (fix311, fix312, etc.):

```bash
# Same command, different fix number
./scripts/apply_fix.sh fix311
./scripts/apply_fix.sh fix312
./scripts/apply_fix.sh fix313
# ... and so on
```

Each fix follows the **exact same workflow**.

---

## 📝 Changes Log

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-06-08 | Initial version; consolidates fix310 lessons learned |

---

## ❓ Questions?

- **About the script?** → Read `CLAUDE-CODE-FIX-GUIDE.md`
- **About Cowork integration?** → Read `CLAUDE-COWORK-FIX-GUIDE.md`
- **About credentials?** → Read `CREDENTIALS-AND-SECRETS.md`
- **About the full process?** → Read `FIX-RELEASE-RUNBOOK.md`
- **Still stuck?** → Check the error in `FIX-RELEASE-RUNBOOK.md` under "Error Recovery"

---

## 🚦 One More Thing

**Remember**: The `fix310` release initially failed because the automation didn't immediately check for `.github-token`. 

**These docs prevent that from happening again.**

The entire fix300+ workflow is now documented, automated, and tested. The next time you release a fix, you should be able to run a single command and walk away:

```bash
./scripts/apply_fix.sh fix311
# ✓ Done. Check GitHub in 5 minutes.
```

