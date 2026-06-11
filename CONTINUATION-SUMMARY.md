# Continuation Summary — free4me-iptv fix releases + Google Drive task

**Created:** 2026-06-11 · **For:** a new session that has the Google Drive tool enabled.

---

## 1. Immediate task (the reason for the new session)
Read the user's **Google Drive `Claude_Automation` directory**.

The previous session could not: **no Google Drive connector** was configured, and Drive was **not synced locally** (only Dropbox under `~/Library/CloudStorage`; no `Claude_Automation` folder anywhere under `~`). The new session should have the Drive tool enabled — **search / list / read** the `Claude_Automation` directory and report its contents, then await the user's direction on what to do with them.

---

## 2. Project context
- **Repo:** `~/git/free4me-iptv` — Flutter IPTV app for Android / Android TV (fork of open-tv).
- **Remote:** `https://github.com/rkinnc75/Free4Me-IPTV` (HTTPS; token in `.github-token`, gitignored).
- **Work pattern:** the user drops `fixNNN.md` files in the repo root. Each is a release spec containing an embedded ```diff``` patch, a version bump, a changelog entry, and an "EXECUTE EXACTLY" block. I apply + release them one at a time on `main` (fix290 main-only flow; never check out a tag).

## 3. Per-fix release procedure
1. Extract patch: `awk '/^```diff$/{f=1;next}/^```$/{if(f)exit}f' fixNNN.md > fixNNN.patch`
2. `git apply --check fixNNN.patch` (verify it applies cleanly).
3. Run with flutter on PATH:
   `export PATH="/Users/rich.kalsky/tools/flutter/bin:$PATH"; bash scripts/apply_fix.sh fixNNN`
   The script does: reset to origin/main → apply patch → `flutter analyze` → commit → push main → create+push tag `vX.Y.Z` → move fix files to `runbooks/` → push.
4. Report the release URL: `https://github.com/rkinnc75/Free4Me-IPTV/releases/tag/vX.Y.Z`.

## 4. Standing preferences (also in project memory)
Memory dir: `~/.claude/projects/-Users-rich-kalsky-git-free4me-iptv/memory/` (see `MEMORY.md` index).
- **Output style:** ≤150 words, bullets/code over prose, skip setup explanations. ("explain more" = give depth.)
- **Don't poll CI** for standard Dart-only fixes — report from `apply_fix.sh` output and stop. The pipeline is proven.
- **EXCEPTION — verify the CI build** when a release touches: native code / `AndroidManifest.xml` / a new pub dependency, the CI workflows (`.github/workflows/*`), `apply_fix.sh`, or version.json logic. For native fixes, also do a local `flutter build apk --debug` pre-flight (ANDROID SDK at `~/Library/Android/sdk`) before pushing.
- **Sequential + settle-wait for multiple fixes:** release one, wait for its CI run (esp. the post-APK version.json step) to finish before the next — avoids the back-to-back "too fast" race.

## 5. apply_fix.sh gotchas (resolved, but watch for them)
- `git add -A` once swept a **live PAT** (`CREDENTIALS-AND-SECRETS.md`) into a commit → now gitignored. Never bypass GitHub push protection.
- Commit-message extraction now reads the `## Release — EXECUTE` section (fixed). Verify the commit subject anyway.
- `apply_fix.sh` does **not** run `flutter test` locally — the CI gate does (18 tests as of fix325).
- For a **two-fix batch where the 2nd skips a version** (e.g. 329→.45 / 330→.46, or 333/334), the 2nd patch's pubspec/changelog hunks go stale after the 1st lands → rebase the `.patch`: change `-version:` base + the changelog anchor entry, and drop stale body-context lines. (Sequential same-step pairs like 339/340 need no rebase.)

## 6. CI pipeline state (see repo-root `CI-PIPELINE-STATE.md` — the doc the phone-side fix-authoring AI reads)
- **version.json published LATE** by `release.yml` after the APK uploads (fix312). Don't pre-publish it.
- `analyze.yml`'s version.json check is gated behind `APK_BEFORE_VERSIONJSON` (both workflow files carry the toggle; rollback = set `'false'` in both).
- **Release is hard-gated on `flutter analyze` + `flutter test`** inside `release.yml`.
- `analyze.yml` has `paths-ignore` so the runbooks-move commit doesn't trigger a redundant Analyze run.
- Post-APK version.json step has a `git stash` + push-retry/rebase loop to survive the dirty-tree and simultaneous-release races.

## 7. Current state (end of this session)
- **Last released: fix342 → v1.26.58+342** (commit `d384618`, tag `v1.26.58`).
- All fix files through fix342 are released and moved to `runbooks/`. **No pending `fixNNN.md` in the repo root.**
- Recent run of releases this session: fix311 → fix342 (v1.26.27 → v1.26.58), all green.

## 8. Open / non-blocking follow-ups
- The live PAT in `.github-token` is still **un-rotated** (user chose to leave it). Rotating it (revoke + regenerate, update `.github-token`) remains advisable but is the user's call.
- fix334 (ExoPlayer first-frame nudge) and fix337 (Shield 2×2 texture race) are **on-device-only verifiable** — not yet confirmed on real hardware.
