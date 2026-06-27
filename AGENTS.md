# AGENTS.md — Free4Me-IPTV

**👉 Read [`ONBOARDING.md`](ONBOARDING.md) first.** It is the canonical entry point for a
coder + builder session (current state, build/ship process, key files, gotchas, reference map).
This file only exists because tools auto-load it — it routes you to ONBOARDING and lists the
non-negotiable guardrails below.

`GROUND_ZERO.md` is the separate phone-coder (read-only mobile) handoff.

## Non-negotiable guardrails

- **Commit convention:** `fixNNN: <imperative subject>` (or `deps:` / `vX.Y.Z:`). **No Jira/`PO-` key** — any doc claiming one is stale Pinogy-template bleed-over. **No AI co-author trailers.**
- **Do not rename** Dart package `open_tv` or Android ID `me.free4me.iptv`.
- **Do not change the release signing identity** (alias `free4me-iptv`) — it forces every user to reinstall.
- **Do not remove the `dependency_overrides` block** in `pubspec.yaml` — it wires the custom LGPL-max libmpv (see `docs/CUSTOM_LIBMPV.md`).
- **Credentials — `rkinnc75` ONLY.** For any `github.com/rkinnc75/Free4Me-IPTV` operation, authenticate **only** with the `rkinnc75` PAT in `.github-token` (inline HTTPS URL). **NEVER use the `rkalsky` `gh` account — it has no write access to this repo (403).** Do not rely on plain `git push`: the `gh` credential helper resolves to `rkalsky`, so always push via the explicit PAT URL.
- **Only a `vX.Y.Z` tag push triggers a build** (`.github/workflows/release.yml`). Commits to `main` alone do not.
- **Player engine is media_kit/libmpv only** — ExoPlayer was removed (fix350).
- SQL in Dart strings is invisible to `flutter analyze` — never blindly rewrite it; run the app for DB changes.

See `ONBOARDING.md` §4–§5 for the full release procedure and gotchas.
