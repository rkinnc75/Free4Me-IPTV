# Claude Cowork Fix Release Guide

**For**: Claude Cowork users automating fix releases in Cowork mode  
**Version**: 1.0  
**Last Updated**: 2026-06-08  

## Overview

In Cowork mode, you can automate the entire fix release workflow using Claude's file tools and bash integration. This guide shows how.

---

## The Three-Phase Workflow

### Phase 1: Preparation (In Cowork)
- Read fix specification files
- Verify fix files exist
- Check prerequisites

### Phase 2: Automation (Cowork bash + scripts)
- Apply patch
- Verify build
- Commit and push

### Phase 3: Verification (Manual on GitHub)
- Check release appears on GitHub
- Verify APK asset is uploaded

---

## Step-by-Step in Cowork

### 1. Check Workspace Access

In Cowork, you should have the repo folder mounted. Verify:

```
User message: "Can you access the repo?"

Claude should check:
- Read /Users/rich.kalsky/git/free4me-iptv/README.md
- Verify .github-token file exists
- Confirm scripts/ directory is present
```

### 2. Read the Fix Specification

```
User message: "Review fix311.md for me"

Claude should:
- Read the fix311.md file
- Look for ⚠️ warnings
- Check for special requirements (new dependencies, migrations, etc.)
- Summarize findings
```

### 3. Run the Automated Release

```
User message: "Apply and release fix311"

Claude should run (in bash):
cd /Users/rich.kalsky/git/free4me-iptv
./scripts/apply_fix.sh fix311
```

### 4. Verify Success

```
User message: "Verify the release completed"

Claude should:
- Check git log for new commits
- Verify tag was created
- Confirm fix files are in /runbooks/
- Show the completion banner
```

### 5. Check GitHub

Manual step (user):
- Visit https://github.com/rkinnc75/Free4Me-IPTV/releases
- Look for v1.26.X tag
- Wait 5 minutes for GitHub Actions to build APK

---

## Common Cowork Workflows

### Scenario 1: Single Fix Release

```
User: "Apply and release fix311 from the fix spec provided"

Claude Cowork:
1. Read(fix311.md) → Understand changes
2. Read(.github-token) → Verify credentials exist
3. Bash: apply_fix.sh fix311 → Run automation
4. Read(git log) → Verify commits
5. Report success and GitHub Actions status
```

### Scenario 2: Reviewing Before Release

```
User: "Check if fix311 is ready to release"

Claude Cowork:
1. Read(fix311.md) → Check specification
2. Bash: git apply --no-index fix311.patch → Verify patch format
3. Report findings: ready or needs fixing
```

### Scenario 3: Multiple Fixes Sequentially

```
User: "Release fixes 311, 312, and 313"

Claude Cowork:
1. apply_fix.sh fix311
2. apply_fix.sh fix312
3. apply_fix.sh fix313
4. Report all three releases completed
```

### Scenario 4: Dry-Run Before Real Release

```
User: "Test fix311 without releasing"

Claude Cowork:
1. Bash: apply_fix.sh fix311 --no-push
2. Report: patch applied, tests passed, ready to release
```

---

## Key Files in Cowork Context

| File | How to Use in Cowork |
|------|---------------------|
| `FIX-RELEASE-RUNBOOK.md` | Reference guide; read to understand each step |
| `CLAUDE-CODE-FIX-GUIDE.md` | Quick reference for CLI usage |
| `scripts/apply_fix.sh` | Run via Cowork bash tool |
| `fix*.md` | Read to understand the fix before applying |
| `fix*.patch` | Automatically applied by script |
| `.github-token` | Read to verify credentials; used by script |

---

## Critical Security Notes for Cowork

### Credential Handling

The `.github-token` file is:
- ✓ Required for the automation to work
- ✓ Safe to read in Cowork (file system access only)
- ✓ Used internally by git commands (not exposed)
- ⚠️ **NEVER** commit to version control
- ⚠️ **NEVER** print to console unnecessarily

### Best Practices in Cowork

```bash
# ✓ Good: Script handles credentials internally
./scripts/apply_fix.sh fix311

# ✓ Good: Reading to verify it exists
test -f .github-token && echo "Credentials found"

# ✗ Bad: Exposing the token
cat .github-token
TOKEN=$(cat .github-token); echo $TOKEN  # <- NEVER DO THIS

# ✓ Good: Script configures git safely
# (happens internally in apply_fix.sh)
```

---

## Cowork Integration Patterns

### Pattern 1: Direct Command

```
User: "release fix311"

Claude: 
cd /Users/rich.kalsky/git/free4me-iptv && ./scripts/apply_fix.sh fix311
```

### Pattern 2: Read → Decide → Execute

```
User: "I have fix312 ready. Is it good to release?"

Claude:
1. Read(fix312.md) → Analyze
2. Respond with findings
3. If user confirms: Execute release script
```

### Pattern 3: Batch Releases

```
User: "Check what fixes are pending and release them"

Claude:
1. Bash: ls -1 fix*.md | wc -l  → Count pending
2. For each fix: apply_fix.sh fix###
3. Report summary of releases
```

### Pattern 4: Troubleshooting in Cowork

```
User: "Release failed. What went wrong?"

Claude:
1. Read git log → Check last commit
2. Bash: git status → Show state
3. Read FIX-RELEASE-RUNBOOK.md Error Recovery section
4. Guide through recovery steps
```

---

## Cowork + Claude Code Consistency

Both Cowork and Claude Code use the **same**:
- ✓ `FIX-RELEASE-RUNBOOK.md` (reference)
- ✓ `scripts/apply_fix.sh` (automation)
- ✓ `.github-token` (credentials)
- ✓ Git workflow (fix300+ main-only procedure)

The only difference is the **execution environment**:
- **Cowork**: Browser-based Cowork app with file & bash tools
- **Claude Code**: CLI with direct shell access

Both follow the same runbook.

---

## Handling Cowork Limitations

### If Bash Fails to Connect

```bash
# Cowork sometimes needs fresh workspace startup
# Retry the bash command after a moment
./scripts/apply_fix.sh fix311
```

### If File Read Returns Empty

```bash
# Use Read tool with explicit absolute path
# NOT: Read("fix311.md")
# YES: Read("/Users/rich.kalsky/git/free4me-iptv/fix311.md")
```

### If Git Command Hangs

```bash
# Add timeout to prevent hanging in Cowork
timeout 30 git push origin main

# Or check git status to debug
git status
git log -1
```

---

## Quick Decision Tree in Cowork

```
User provides a fix release request:
│
├─ Is fix*.md file provided?
│  ├─ NO: Ask user to provide
│  └─ YES: Continue
│
├─ Does .github-token exist?
│  ├─ NO: Stop and explain credentials
│  └─ YES: Continue
│
├─ Are there special requirements in fix*.md?
│  ├─ YES: Alert user and ask to proceed
│  └─ NO: Continue
│
├─ Run: ./scripts/apply_fix.sh fix###
│
├─ Did it succeed?
│  ├─ YES: Report success, GitHub release URL, expected timeline
│  └─ NO: Read error message, check FIX-RELEASE-RUNBOOK.md recovery, guide user
```

---

## Cowork Memory: What to Remember

As Claude in Cowork, you should remember:

1. **The .github-token file exists** at `/Users/rich.kalsky/git/free4me-iptv/.github-token`
2. **The automation script is at** `scripts/apply_fix.sh`
3. **Use the script for releases**, not manual commands
4. **The runbook is the source of truth** for the process
5. **Verify on GitHub** after release (wait 5 min for Actions)

---

## Testing This Guide

To validate this works in Cowork:

1. Load Cowork with the free4me-iptv folder
2. Run a test release: `./scripts/apply_fix.sh fix310 --no-push`
3. Verify the script works and outputs expected steps
4. Document any deviations

Last tested: 2026-06-08 (fix310 successful release)

---

## Support in Cowork

If you get stuck in a Cowork session:

1. **Check the error message** — it includes the step number
2. **Read FIX-RELEASE-RUNBOOK.md** — Error Recovery section
3. **Use `git status` and `git log`** — See the actual state
4. **Never push without verifying** — Use `--no-push` for testing
5. **Ask the user to verify credentials** — If push fails with "No such device"

