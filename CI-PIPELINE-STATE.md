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

## Release gating — Release is HARD-GATED on `flutter analyze`

**`release.yml`'s `analyze` job now actually runs `flutter analyze --no-fatal-infos`**, and
`build-and-release` has `needs: analyze`. So if static analysis fails on the tagged commit, the
APK build and the entire release are **skipped** — a true hard gate, self-contained within
`release.yml` (it does not depend on the separate `analyze.yml` workflow).

- Previously the `analyze` job (display name "flutter analyze (gate)") only ran `flutter pub get`
  plus a version.json self-heal step and **never actually analyzed** — the real check lived only in
  `analyze.yml`, which (being a separate workflow on a different trigger) could not gate Release.
  That step has now been added, so the job lives up to its name.
- `analyze.yml` (trigger: push to `main`) still exists as the fast ~2-min feedback check before you
  push a tag. It and `release.yml` share a concurrency group (`free4me-ci-${{ github.sha }}`,
  `cancel-in-progress: false`) so they queue rather than overlap for the same SHA.
- The 2 tolerated `settings_view.dart` INFOs pass (`--no-fatal-infos`); warnings/errors fail the gate.
