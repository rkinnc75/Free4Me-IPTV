# CLAUDE-WORKFLOW.md — How Claude ships Free4Me-IPTV

## 🔴 Core Rule: Every fix or group of fixes must be tagged and released

This ensures each change is immutable, trackable, and incrementally available to users.
No code changes go in without a corresponding version bump and GitHub release.

---

This doc captures the workflow used to take a code change from idea to a
published GitHub release, with specific attention to **which steps require
which environment**. Read alongside [`AGENTS.md`](AGENTS.md) (canonical
session guide) and [`BUILD-ENV.md`](BUILD-ENV.md) (host-Mac build
environment that CI mirrors).

Last updated: 2026-06-04.

---

## 1. The three modes you can engage Claude in

| Mode | Reach | Use it for |
|---|---|---|
| **Cowork (desktop Claude app on Mac)** | Full read + edit + commit + push, plus tag pushes that trigger CI | Doing actual releases. The only mode that can write to the repo. |
| **Claude mobile app** | Read-only over GitHub HTTPS | Reviewing code, drafting plans, fact-checking docs, sanity-checking release notes — but nothing that changes the repo. |
| **Cursor on Mac** | Full local Flutter build + `scripts/build_and_release.sh` | Hands-on Mac releases when you want a local APK or when GitHub Actions is unavailable. |

What works where:

| Capability | Cowork | Mobile | Cursor (Mac) |
|---|---|---|---|
| Read repo files | ✓ | ✓ (via GitHub) | ✓ |
| Edit repo files | ✓ | ✗ | ✓ |
| Run `flutter` locally | ✗ (egress blocked) | ✗ | ✓ |
| `git commit` + `git push` | ✓ (via PAT) | ✗ | ✓ |
| Tag + trigger CI | ✓ | ✗ | ✓ |
| Re-run failed CI job | ✓ (browser) | ✓ (browser) | ✓ (browser) |
| Read CI status | ✓ (web scrape) | ✓ (web) | ✓ (web) |
| Read api.github.com | ✗ (allowlist) | ✓ | ✓ |

**The phone is for analysis, not action.** Ask Claude on mobile to read
code, summarize, critique, plan. When you decide an action is needed,
switch to the desktop Cowork app and Claude will execute it.

---

## 2. The release pipeline

Two paths produce the same artifact:

### 2a. Automated (GitHub Actions, default for AI-driven releases)

```
edit files in Cowork  →  bump pubspec.yaml  →  update changelog
                                                        ↓
                                       run scripts/update_version_json.py
                                                        ↓
                       commit (GIT_INDEX_FILE workaround in the sandbox)
                                                        ↓
                                   git push origin main  (HTTPS + PAT)
                                                        ↓
                                  git push origin vX.Y.Z (HTTPS + PAT)
                                                        ↓
                               GitHub Actions: .github/workflows/release.yml
                                                        ↓
                       Flutter 3.44.0 + Java 21 Temurin + Android SDK 36
                                                        ↓
                                   flutter build apk --release
                                                        ↓
                                gh release create + APK upload
                                                        ↓
                              https://github.com/rkinnc75/Free4Me-IPTV/releases
```

Cold run takes ~6–10 min on a fresh GitHub-hosted runner (Flutter SDK
download + Android SDK install dominate). Warm runs once
`subosito/flutter-action` and `android-actions/setup-android` caches hit
are ~3–5 min.

### 2b. Local Mac (hands-on, still supported)

`bash scripts/build_and_release.sh` runs the same pipeline on your Mac:

  - reads the GitHub PAT from macOS Keychain
  - uses `~/.ssh/id_rsa` for SSH push
  - copies the APK to `~/Downloads/`
  - creates the GH release via the REST API directly

Use this when you want the APK on disk, when GitHub Actions is down, or
when you don't want the Cowork sandbox in the loop.

---

## 3. The runbook (Claude or human) — fix290: COMMIT ON MAIN, NEVER ON TAGS

**⚠️ fix290 blocks releases that operate on tags/detached HEADs. Use this procedure verbatim:**

To ship `vX.Y.Z` from Cowork:

1. **Start from `main`** (fix290: never from a tag):
   ```bash
   git checkout main
   git fetch origin
   git reset --hard origin/main
   ```

2. **Edit code** as needed.
3. **Bump `pubspec.yaml`**: `version: X.Y.Z+N` where `N` increments by 1.
4. **Add a changelog entry** at the TOP of `_changelog` in
   `lib/whats_new_modal.dart`:

   ```dart
   'X.Y.Z': [
     'Concise user-facing bullet describing the change.',
     'Second bullet if needed.',
   ],
   ```

5. **Regenerate `version.json`**:
   ```bash
   python3 scripts/update_version_json.py
   ```

6. **Commit** all of the above on `main`. Release-build commits use the
   `vX.Y.Z: release build` convention (exempt from the usual Jira-key
   rule per `AGENT-HANDOFF-v1.15.7.md` §4).
7. **Push `main`** (commits to origin/main, not tags yet).
8. **Tag the pushed commit** on `main`:
   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```
   This is what fires CI. The pre-push hook (fix290) blocks pushing tags
   not on main — mechanical guard against orphaned commits.
9. **Watch** the run:
   https://github.com/rkinnc75/Free4Me-IPTV/actions/workflows/release.yml

The workflow has two safety checks before it builds:

  - **Tag/pubspec match**: the pushed tag must equal
    `v$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)`.
  - **`version.json` freshness**: re-running
    `scripts/update_version_json.py` in CI must produce no diff against
    the committed file.

If either fails, CI aborts with `::error::` annotations and no release
is created.

---

## 4. Cowork sandbox constraints

What Claude can and can't do from the sandbox:

| Surface | Status | Workaround |
|---|---|---|
| Flutter / Dart SDK | Not installed | Builds run in GH Actions |
| Android SDK / NDK / Java | Not installed | Same |
| `apt`, `sudo` | No root | Use existing toolchain only |
| `api.github.com` | Blocked by egress allowlist | Use `gh` in CI; sandbox uses git over HTTPS to `github.com:443` |
| `raw.githubusercontent.com` | Blocked | Read via bindfs mount |
| `storage.googleapis.com`, `pub.dev`, `dl.google.com`, `services.gradle.org`, `repo.maven.apache.org` | Blocked | All resolution happens in CI |
| `github.com` (web + git HTTPS) | ✓ Reachable | `git push`, CI status web scrapes |
| Workspace file create / overwrite | ✓ Allowed | `Edit` / `Write` tools |
| Workspace file delete | ✗ (bindfs disallows unlink) | Leftover empty files cleaned manually from the Mac |
| `.git/*.lock` cleanup | ✗ | Use `GIT_INDEX_FILE=/tmp/...` to bypass the local index lock entirely |
| `$HOME` persistence | Cleared between sessions | Persistent state (e.g., `.github-token`) lives in the repo |

### The two non-obvious workarounds Claude uses

**`GIT_INDEX_FILE` for commits.** The bindfs mount blocks `unlink(2)` on
`.git/index.lock`, so `git add` fails with "Another git process seems to
be running". Claude routes the index to `/tmp` instead, sidestepping the
lock:

```bash
export GIT_INDEX_FILE=/tmp/whatever.idx
git read-tree HEAD
git add -- path/to/file
TREE=$(git write-tree)
COMMIT=$(git commit-tree "$TREE" -p "$(git rev-parse HEAD)" -m "msg")
git push <url-with-pat> "${COMMIT}:refs/heads/main"
```

The commit object lands in `.git/objects/` (which allows new file
creation), the index is in `/tmp` (not in the bindfs mount), and the
push goes over HTTPS using the PAT in `.github-token`.

**HTTPS push with PAT-in-URL.** The configured remote is SSH
(`git@github.com:rkinnc75/Free4Me-IPTV.git`), which the sandbox can't use
(no key). Claude pushes via an inline HTTPS URL instead:

```bash
PAT=$(cat .github-token)
git push "https://x-access-token:${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" "$COMMIT:refs/heads/main"
```

The configured SSH remote is left untouched so the local Mac flow
continues to work unchanged.

---

## 5. Bootstrap state (what's currently set up)

Don't re-do these unless they break.

1. **`.github/workflows/release.yml`** — the CI workflow. Toolchain
   pinned to match `BUILD-ENV.md`.
2. **`scripts/update_version_json.py`** — standalone extraction of the
   inline Python from `scripts/build_and_release.sh`. Idempotent.
3. **Repo secrets `RELEASE_KEYSTORE_*`** (4 secrets, fix31 / v1.17.0+):
   - `RELEASE_KEYSTORE_B64` — base64 of `android/app/release.keystore`.
   - `RELEASE_KEYSTORE_PASSWORD` — keystore password.
   - `RELEASE_KEY_ALIAS` — `free4me-iptv`.
   - `RELEASE_KEY_PASSWORD` — same as `RELEASE_KEYSTORE_PASSWORD` (PKCS12).

   CI's "Restore release keystore" step reconstructs both the keystore
   file and `android/key.properties` from these. Without them the
   workflow **fails fast** rather than silently signing with debug.
   See `fix31.md` for the full story; through v1.16.3 we used a single
   `DEBUG_KEYSTORE_B64` secret which proved too brittle.
4. **Repo setting**: Settings → Actions → General → **Workflow
   permissions = "Read and write permissions"**. Required for
   `gh release create` and asset upload.
5. **`.github-token`** at repo root (gitignored) — fine-grained PAT
   scoped to `rkinnc75/Free4Me-IPTV` with `Contents: read/write` and
   `Workflows: read/write`. Used by Cowork to push.
6. **`engineering` plugin installed** in Cowork — currently the only
   marketplace plugin advertising a GitHub MCP. Not strictly required
   for the workflow (Claude pushes via the PAT regardless), but
   installed for skill access.

If any of these are lost, §7 has the recovery steps.

---

## 6. Failure modes and recovery

### CI workflow fails mid-run
- Open the failed run: https://github.com/rkinnc75/Free4Me-IPTV/actions
- Click **"Re-run failed jobs"** (top right).
- Most transient failures (network blip, runner provisioning) clear up on retry.
- If the failure is structural, fix the workflow → commit → push → tag a new version (re-tagging the same version requires deleting the existing tag and release first).

### Workflow ran, no release created
- Most likely: repo-level Workflow permissions reverted to read-only.
- Fix: re-set to "Read and write permissions" in Settings → Actions → General.

### Tag pushed, workflow didn't trigger
- The workflow file at the tagged commit must contain the `push: tags: ['v*']` trigger. If you tagged a commit from before `.github/workflows/release.yml` was added, the workflow won't be present.
- Fix: bump version one more time on a current commit and tag that.

### `pubspec.yaml` / tag mismatch
- CI fails loudly in the "Verify tag matches pubspec.yaml" step.
- Fix: `git push origin --delete vX.Y.Z`, fix `pubspec.yaml`, retag.

### `version.json` stale at the tagged commit
- CI fails in "Verify version.json is up to date" with a diff in the log.
- Fix: `python3 scripts/update_version_json.py`, commit, retag.

### `RELEASE_KEYSTORE_*` secret missing
- CI fails fast in the "Restore release keystore" step with a clear
  `::error::` line — it deliberately refuses to fall back to a debug
  signing config because that would re-introduce the v1.16.x update
  break.
- Fix: regenerate the missing secret from the `.release-keystore-secrets`
  backup file on the Mac (§7b) and re-run the workflow.

### Existing user can't install v1.17.0 over v1.16.x
- Expected. v1.17.0 is the keystore migration; one final uninstall is
  required. After v1.17.0 the fingerprint is stable forever.

### PAT expired
- `git push` from Cowork returns `403` or `401`.
- Fix: rotate the PAT (§7a).

### Pre-push hook blocks tag push (fix290)
- Local push fails with `PRE-PUSH BLOCK: tag ... is NOT on origin/main`.
- Cause: attempting to push a tag whose commit is not on the main branch.
- **This is the guard working as designed.** It prevents orphaned tags.
- Fix: ensure you're on `main`, committed, pushed `main`, then tag and push the tag.
  See §3 (the runbook) for the correct procedure.

---

## 6a. The fix290 guard (prevents orphaned-tag releases)

The `.githooks/pre-push` hook blocks two dangerous patterns:

1. **Pushing a tag not on `origin/main`** — prevents orphaned commits
2. **Committing and pushing from a detached HEAD** — prevents commits that don't advance main

The hook is active once you run (one time on your Mac):
```bash
git config core.hooksPath .githooks
```

If you see `PRE-PUSH BLOCK`, it means your tag's commit is not an ancestor of
`origin/main`. Fix: always follow §3's runbook (commit on main, push main, tag
the pushed commit).

---

## 7. Bootstrap recovery

### 7a. Recreate the PAT

1. https://github.com/settings/personal-access-tokens/new
2. Token name: `Free4Me-IPTV automated release`
3. Resource owner: `rkinnc75`
4. Repository access: Only select repositories → `Free4Me-IPTV`
5. Repository permissions:
   - `Contents`: **Read and write**
   - `Workflows`: **Read and write**
   - `Metadata`: Read (mandatory)
6. Generate, copy the `github_pat_...` value
7. On the Mac:
   ```bash
   echo 'github_pat_XXX' > ~/git/free4me-iptv/.github-token
   chmod 600 ~/git/free4me-iptv/.github-token
   ```
8. Next Cowork session: Claude reads `.github-token` and uses it on push.

### 7b. Recreate the `RELEASE_KEYSTORE_*` secrets

The canonical source of truth is `.release-keystore-secrets` at the
repo root on the Mac (gitignored, `chmod 600`). It contains all four
values already formatted as `KEY=VALUE` lines.

```bash
cat ~/git/free4me-iptv/.release-keystore-secrets
```

Then https://github.com/rkinnc75/Free4Me-IPTV/settings/secrets/actions →
for each line, **New repository secret** → name = the key → paste the
value → Save. The four names are exactly:

- `RELEASE_KEYSTORE_B64`
- `RELEASE_KEYSTORE_PASSWORD`
- `RELEASE_KEY_ALIAS`
- `RELEASE_KEY_PASSWORD`

If `.release-keystore-secrets` is also lost: the same data lives in
your offline backup (password manager / encrypted USB). If that's
gone too, see fix31.md §"Recovery if the keystore is lost".

### 7c. Confirm repo Actions permissions

https://github.com/rkinnc75/Free4Me-IPTV/settings/actions →
**Workflow permissions** = "Read and write permissions" → Save.

### 7d. Confirm workflow file is on `main`

`.github/workflows/release.yml` should exist on the `main` branch.

---

## 8. Mobile-mode usage examples

Things to ask Claude on your phone:

- "What's in the latest release notes for v1.16.0?" — Claude reads
  `lib/whats_new_modal.dart` or the GH release page.
- "Review my proposed change to `lib/multi_view_cell.dart`..." —
  Claude reads the file, reasons about it, critiques.
- "Plan v1.16.1 — what should change?" — Claude reads recent issues,
  fix docs, and proposes scope.
- "Sanity-check my release notes draft for v1.16.1." — Claude critiques.
- "Is the CI workflow's Flutter version still current?" — Claude checks
  against recent Flutter stable releases.
- "What does the `_isTransientError` function in
  `lib/multi_view_cell.dart` do, and is the EOF handling correct?" —
  Claude reads, explains, evaluates.

Things you'll get told to do on Cowork instead:

- "Implement that plan" → "Open Cowork on your Mac; I'll do the actual
  edits + commit + push from there."
- "Bump the version and ship" → same.
- "Edit `pubspec.yaml`" → same.
- "Add this changelog entry" → same.

The phone is for **deciding**; the desktop is for **doing**.

---

## 9. File reference

| File | Purpose |
|---|---|
| `pubspec.yaml` | Version source of truth (`version: X.Y.Z+N`). |
| `lib/whats_new_modal.dart` | User-facing per-version changelog. Top of the `_changelog` map. |
| `version.json` | In-app update checker payload. Regenerated from the above two. |
| `.github/workflows/release.yml` | CI workflow. |
| `scripts/update_version_json.py` | Standalone changelog → `version.json` extractor. Callable from local + CI. |
| `scripts/build_and_release.sh` | Local Mac release script (Cursor's path; unchanged). |
| `.github-token` | Local PAT for sandbox-to-GitHub push. **Gitignored.** Never commit. |
| `BUILD-ENV.md` | Documents the local Mac build environment that CI mirrors. |
| `AGENTS.md` | Canonical session guide for AI agents. Updated when state changes. |
| `AGENT-HANDOFF-v1.15.7.md` | Historical handoff with codebase patterns + invariants. |
| `CLAUDE-WORKFLOW.md` | This file. |

---

*End of Claude workflow doc.*
