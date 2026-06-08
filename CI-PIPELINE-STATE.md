# CI Pipeline — Current State (read before authoring a fix)

**Audience:** the fix-authoring AI (phone/device side) that writes `fixN.md` specs and patches.
**Purpose:** describe how the release pipeline behaves *now*, so fix recipes don't re-instruct steps
that are already automated — or flag intentional behavior as errors.
**Last updated:** 2026-06-08 (after fix312 + fix312 follow-ups; validated by fix313).

---

## TL;DR — what changed and what NOT to tell the build machine to do

1. **`version.json` is now published LATE, by CI, after the APK upload.**
   `release.yml` builds the APK → uploads it to the release → verifies it returns HTTP 200
   (retried up to 6×) → **only then** regenerates `version.json`, commits it to `main`, and
   moves the tag onto that commit. This closes the old "updater sees new version but APK 404s"
   window (fix312).
   - ❌ **Do NOT** put `python3 scripts/update_version_json.py` + commit *before* tagging in the
     `## Release — EXECUTE` recipe. CI owns version.json now. Pre-publishing reopens the 404 window.
   - ❌ **Do NOT** treat `main/version.json` lagging `pubspec.yaml` *during a release* as a bug.
     That lag is intentional and expected until the build finishes.

2. **A stale `version.json` during the release no longer turns "Analyze main" red.**
   `analyze.yml`'s "Verify version.json is up to date" step is now gated behind the
   `APK_BEFORE_VERSIONJSON` toggle and is **skipped** while publish-late is active (the current
   default). So the "Analyze main" check stays green on the fix commit during the build window.
   - ❌ **Do NOT** add a "commit version.json so Analyze passes" step to fix recipes. Not needed.

3. **The toggle lives in BOTH workflow files.**
   `APK_BEFORE_VERSIONJSON: 'true'` is set in **`.github/workflows/release.yml`** *and*
   **`.github/workflows/analyze.yml`** (GitHub Actions env does not cross workflow files).
   To roll back to the old eager-publish ordering, set it to `'false'` in **both** files.

4. **`scripts/apply_fix.sh` reads the release commit message from the `## Release — EXECUTE`
   section** (scoped via awk), not the first `git commit -m` in the file.
   - ✅ Keep putting the canonical commit message on the `git commit -m "..."` line inside that
     section. `git commit` lines that appear *inside the embedded patch* are now ignored
     (previously they were picked up by mistake — e.g. a CI step's `${GH_TAG}: CI sync...`).

---

## What the fix author SHOULD still do (unchanged)

- Bump `version: X.Y.Z+N` in `pubspec.yaml`.
- Add the matching `'X.Y.Z':` entry to `lib/whats_new_modal.dart`.
- Keep the embedded patch in a ```diff fence inside `fixN.md` (the build machine extracts it).
- Keep a `## Release — EXECUTE` section whose `git commit -m "..."` line is the real release message.
- For fixes that **modify a workflow file**, validate YAML before release
  (`ruby -ryaml -e "YAML.load_file('.github/workflows/release.yml')"`; default `python3` lacks PyYAML).

---

## Release gating — "does Release only run after a successful Analyze?"

Short answer: **not as a hard CI gate, and the workarounds did not change that.**

- `release.yml` (trigger: tag push `v*`) and `analyze.yml` (trigger: push to `main`) are
  **separate workflows**. GitHub Actions cannot make one workflow's run depend on another's result.
- Inside `release.yml`, `build-and-release` has `needs: analyze`, but that internal `analyze` job
  (display name "flutter analyze (gate)") **does not actually run `flutter analyze`** — it does
  `flutter pub get` plus a version.json self-heal step (skipped under publish-late). The real
  `flutter analyze` runs **only in `analyze.yml`**.
- The two workflows share one concurrency group (`free4me-ci-${{ github.sha }}`, `cancel-in-progress: false`),
  so for a combined commit+tag push (same SHA) they **queue instead of overlapping** — but queueing
  does not guarantee Analyze runs *first*.
- So "Analyze before Release" is a **procedural convention** (push main, watch the ~2-min Analyze
  pass, then push the tag) plus concurrency serialization — not an enforced dependency.

If a true hard gate is wanted (Release blocked unless `flutter analyze` passed), that is a separate
change — e.g. add a real `flutter analyze` step to `release.yml`'s gate job, or have `release.yml`
invoke analyze as a reusable workflow. It has not been done.
