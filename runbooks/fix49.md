# fix49.md — Make `flutter analyze` a hard CI gate; phone-Claude release procedure

> **Session type:** Mac/Cowork (odd number)
> **Shipped in:** v1.17.6
>
> Two things in one runbook:
> 1. A one-line CI change that makes `flutter analyze` block the release
>    if it finds errors (currently advisory-only — the build continues
>    even on analyzer failures).
> 2. The complete step-by-step release procedure for phone Claude sessions,
>    which is now fully safe once fix49.1 is in place.

---

## Why this matters

Phone Claude cannot run `flutter analyze` — the Flutter SDK lives only
on the host Mac (`/Users/builder/tools/flutter/bin`), not in the
sandbox. Before fix49, analyzer errors in a phone-authored commit would
slip through undetected and ship in an APK.

With fix49.1 applied, if a phone-originated commit has a type error or
missing import, CI fails at the analyze step, no APK is produced, no
GitHub release is created. Phone Claude then pushes a corrective commit,
re-tags, and CI retries cleanly.

---

## Fix 49.1 — Hard-gate `flutter analyze` in `.github/workflows/release.yml`

**File:** `.github/workflows/release.yml`

**Current step (lines ~175–184):**

```yaml
- name: flutter analyze (advisory)
  run: |
    set +e
    flutter analyze --no-fatal-infos
    rc=$?
    if [[ $rc -ne 0 ]]; then
      echo "::warning::flutter analyze reported issues (advisory only)."
    fi
    exit 0
```

**Replace with:**

```yaml
- name: flutter analyze
  run: flutter analyze --no-fatal-infos
```

That is the entire change. Removing `set +e` / `exit 0` means the step
fails when the analyzer reports issues, which blocks all downstream steps
(keystore restore → build → release creation). No bad APK ships.

`--no-fatal-infos` keeps info-level hints (style suggestions) as
non-fatal, consistent with the current advisory behaviour. Only warnings
and errors block the build.

---

## Fix 49.2 — Complete phone Claude release procedure

Phone Claude sessions use **even** fix numbers (fix46, fix48, fix50…).
Release version numbers are **fully sequential** — do not skip versions
(1.17.5 → 1.17.6 → 1.17.7; never 1.17.5 → 1.17.7).

### Pre-release checklist (phone Claude runs these first)

```
1. Read AGENTS.md — confirms current version, key files, rules.
2. Read the relevant fixXX.md files to implement.
3. Verify each runbook claim against current code before editing.
   For any runbook with ≥3 items: present per-item analysis in chat,
   WAIT for user sign-off before mass-editing.
```

### Step-by-step release sequence

#### 1. Determine the parent commit

```bash
PAT=$(cat /sessions/.../mnt/free4me-iptv/.github-token | tr -d '\n')
git ls-remote "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" HEAD
```

Copy the full 40-char SHA — this is `PARENT_SHA`.

The local `git log` in the sandbox is stale (it shows commits only up
to the last time the repo was freshly cloned). Always use `ls-remote`
to get the true HEAD from GitHub before committing.

#### 2. Make all code changes

Use the Read / Edit / Write file tools. Do NOT use `git add` yet.
Make all edits through the file tools; the GIT_INDEX_FILE step below
picks them up from the working tree.

#### 3. Bump `pubspec.yaml`

```
version: X.Y.Z+N   →   version: X.Y.(Z+1)+(N+1)
```

Example: `1.17.5+78` → `1.17.6+79`

#### 4. Add changelog entry to `lib/whats_new_modal.dart`

Insert a new key at the **top** of `_changelog` (newest first):

```dart
'X.Y.Z+1': [
  'Fix: short description of the user-visible change.',
  'Fix: another change if applicable.',
],
```

#### 5. Update `AGENTS.md`

Change the "Latest release" table row:

```
| Latest release | **vX.Y.(Z+1)+(N+1)** (...) |
```

#### 6. Regenerate `version.json`

```bash
cd /sessions/.../mnt/free4me-iptv
python3 scripts/update_version_json.py
```

Verify the output shows the new version and the correct release notes
pulled from `whats_new_modal.dart`.

#### 7. Commit via GIT_INDEX_FILE workaround

The bindfs sandbox disallows `unlink` on `.git/index` and
`.git/objects/tmp_*`. Use a temp index to avoid this:

```bash
cd /sessions/.../mnt/free4me-iptv
IDX=$(mktemp)
export GIT_INDEX_FILE=$IDX

# Seed the index from the parent commit on GitHub (not the stale local HEAD)
git read-tree PARENT_SHA 2>/dev/null

# Stage exactly the files that changed
git add \
  AGENTS.md \
  lib/whats_new_modal.dart \
  pubspec.yaml \
  version.json \
  fixXX.md \
  [any other changed files]  2>/dev/null

# Create the tree object
TREE=$(git write-tree 2>/dev/null)
echo "Tree: $TREE"

# Create the commit object
COMMIT=$(git commit-tree $TREE \
  -p PARENT_SHA \
  -m "PO-XXXXX Verb Subject" \
  2>/dev/null)
echo "Commit: $COMMIT"
```

**Commit message convention:** `PO-XXXXX Verb Subject` — imperative,
≤72 chars. Use a real Jira key if available; `PO-NNNNN` as placeholder
is acceptable for maintenance commits.

#### 8. Verify the diff before pushing

```bash
git diff PARENT_SHA $COMMIT --stat
```

Confirm: only the files you intended to change appear, with plausible
insertion/deletion counts. If anything unexpected appears, stop and
investigate before pushing.

#### 9. Push the commit to `main`

```bash
PAT=$(cat .github-token | tr -d '\n')
git push "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" \
  ${COMMIT}:refs/heads/main
```

Expected output: `b80763a..965b4bf  ... -> main`

#### 10. Push the release tag (triggers CI)

```bash
git tag vX.Y.Z+1 $COMMIT 2>/dev/null
git push "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" \
  refs/tags/vX.Y.Z+1
```

Expected output: `* [new tag]  vX.Y.Z+1 -> vX.Y.Z+1`

CI now runs: analyze → build → GitHub release creation.

#### 11. Monitor CI

Check https://github.com/rkinnc75/Free4Me-IPTV/actions

- **Green:** APK is available at
  https://github.com/rkinnc75/Free4Me-IPTV/releases — done.
- **Red at `flutter analyze`:** the code change has a Dart error.
  Fix it (read the CI log for the exact error), edit the file,
  recommit using a new `IDX=$(mktemp)`, and push a new commit to
  `main`. Then delete the bad tag and push a corrected one:

  ```bash
  # Delete the bad tag remotely
  git push "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" \
    :refs/tags/vX.Y.Z+1

  # Re-tag the fixed commit and push
  NEW_COMMIT=<sha of corrective commit>
  git tag -f vX.Y.Z+1 $NEW_COMMIT 2>/dev/null
  git push "https://${PAT}@github.com/rkinnc75/Free4Me-IPTV.git" \
    refs/tags/vX.Y.Z+1
  ```

- **Red elsewhere (build/signing):** unrelated to the code change —
  check BUILD-ENV.md and CLAUDE-WORKFLOW.md; likely a toolchain or
  secrets issue.

---

## Constraints that always apply in phone sessions

| Constraint | Detail |
|---|---|
| `flutter analyze` | Cannot run locally — CI is the gate. Trust static type inspection. |
| `pub.dev` | Blocked in sandbox — do not attempt `flutter pub get` via bash; it times out. The CI runner has internet access and runs `flutter pub get` itself. |
| `api.github.com` | Blocked — use PAT-in-URL for all GitHub operations. |
| `git log` / `git status` | Show stale local state. Use `git ls-remote` for current HEAD. |
| `unlink` on `.git` objects | bindfs blocks it — always use `GIT_INDEX_FILE=$(mktemp)` pattern. |
| Fix file numbering | Phone sessions: even (fix50, fix52…). Mac sessions: odd (fix51, fix53…). Release versions: fully sequential, no skipping. |

---

## Sandbox path mapping

The sandbox uses different paths than the file tools. Translate as needed:

| File tool path | Bash path |
|---|---|
| `/Users/builder/git/free4me-iptv/` | `/sessions/loving-stoic-bell/mnt/free4me-iptv/` |
| `/Users/builder/Library/Application Support/Claude/.../outputs` | `/sessions/loving-stoic-bell/mnt/outputs/` |

The session name (`loving-stoic-bell`) may differ between Cowork
sessions. Run `ls /sessions/` to find the current name if paths fail.

---

## Apply order for fix49

1. **Fix 49.1** — edit `.github/workflows/release.yml` (one line
   change: remove the advisory wrapper around `flutter analyze`).
2. Commit, bump to next version, changelog entry, push, tag.
3. CI validates the change works (analyze step should pass; build
   should succeed).

---

## Notes for the implementer

- **This runbook is safe to follow from a phone Claude session** once
  fix49.1 is shipped. The procedure in fix49.2 is self-contained.
- **No schema changes, no new dependencies, no new Dart files.**
- The `--no-fatal-infos` flag is deliberate — info-level style
  suggestions (unused variable hints, prefer-const etc.) should not
  block releases. Only actual warnings and errors do.
