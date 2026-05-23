# Agent Handoff — Free4Me-IPTV @ v1.15.7

**Date written:** 2026-05-23
**Last shipped:** `v1.15.7+66` (commit `d500acc`)
**Last fix doc fully processed:** `fix22.md` (with retrospective patch in v1.15.7)
**Read this before:** picking up any new `fixXX.md`, releasing, or modifying multi-view / settings / player code.

> Pair this with [`AGENTS.md`](AGENTS.md) (canonical session guide; note: its top-of-file "Latest release" line is **stale** — refer to git tags) and [`DEVELOPMENT-HANDBOOK.md`](DEVELOPMENT-HANDBOOK.md). This file captures everything that happened between v1.14.x and v1.15.7 plus the *process* the user expects from here on.

---

## 1. Process directive (most important — drives all future work)

The user's standing instruction, given verbatim during the v1.15.6 → v1.15.7 transition:

> *"For each of these fixes, you should be doing your own analysis to confirm its findings and then implementing the best option."*

**Translation:** Treat every `fixXX.md` document as a hypothesis, not a spec. The previous agent (me) was caught transcribing too literally. The required workflow is:

1. **Verify each diagnostic claim against current code** before accepting. Line numbers and behaviour drift fast across versions.
2. **Stress-test the proposed fix** for false positives, regressions, and overlap with existing code paths (transient retry vs `completedStream`, error-listener vs error-listener-via-state-stream, etc.).
3. **Look for cleaner alternatives already in the codebase.** Example: `MultiViewLayout.label` already exists in `lib/models/multi_view_layout.dart`; do not re-implement.
4. **Reconcile internal inconsistencies in the doc itself.** Fix22 had a clear table-vs-code mismatch about Optimise scope that was missed; `fix19-v2.md` itself rejected the original `fix19.md`'s `if (!exiting)` guard. That kind of self-correction is the bar.
5. **Match rigor to evidence quality.** Log-backed diagnoses (fix20, fix21) deserve direct application after sanity-check. Unbacked feature requests (fix22) deserve a design pass with the user.
6. **Push back when wrong.** The user wants debate, not stenography.

If a fix doc has bullets or numbered items (e.g. fix20.1, fix20.2…), produce a per-item analysis note in chat *before* mass-editing.

---

## 2. Repo at-a-glance

| Item | Value |
|---|---|
| Working tree | `/Users/builder/git/free4me-iptv` |
| Branch | `main` |
| Latest tag | `v1.15.7` |
| Latest commit | `d500acc v1.15.7: release build` |
| Dart package | `open_tv` (do **not** rename) |
| Android pkg | `me.free4me.iptv` |
| Flutter SDK | `/Users/builder/tools/flutter/bin` |
| Java for builds | `/Applications/Android Studio.app/Contents/jbr/Contents/Home` |
| Release script | `scripts/build_and_release.sh` (auto-bumps tag, builds APK, GH release) |
| Releases | https://github.com/rkinnc75/Free4Me-IPTV/releases |

`flutter analyze` baseline at handoff time: **1 pre-existing issue** (`page_results` non-camelCase in `lib/channel_picker_screen.dart:68`). All other code is clean. The release script does **not** require zero issues — it ships even with the existing info-level warning.

---

## 3. Where the fix docs live

All `fix*.md` and `fix*-v2.md` files live at **repo root** (next to `AGENTS.md`). Existing ones:

```
fix1..fix17, fix18, fix19-v2, fix20, fix21, fix22
multi-view-plan.md          ← original multi-view phase plan (P1..P7)
updated-help-messages.md    ← copy strings for help dialogs
```

There is **no `docs/` directory.** The workspace rule `feature-documentation.mdc` mentions `docs/` but this repo predates that convention; documentation lives at root or in `AGENTS.md` / `DEVELOPMENT-HANDBOOK.md`. New comprehensive docs should follow that root convention unless the user explicitly asks for a `docs/` folder.

`free4me_log_*.txt` at root are log dumps the user pasted from the device while debugging. They are not committed inputs to fixes; treat as throwaway evidence.

---

## 4. Release runbook (cheat sheet)

```bash
# Once per terminal session
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export PATH="/Users/builder/tools/flutter/bin:$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="$HOME/Library/Android/sdk"

cd /Users/builder/git/free4me-iptv
flutter pub get                        # only after dependency changes
flutter analyze --no-fatal-infos       # sanity check
bash scripts/build_and_release.sh      # bumps tag, builds, pushes, GH release
```

**Pre-release checklist:**

1. Bump `version: X.Y.Z+N` in `pubspec.yaml`. The `+N` build number must increment too.
2. Add a top-of-map changelog entry in `lib/whats_new_modal.dart` (newest key first).
3. `flutter analyze` — be aware of pre-existing info issues; don't introduce new ones.
4. `bash scripts/build_and_release.sh` — handles git tag, GH release, APK upload.

**Commit message rule** (workspace rule `git_commits.mdc`): every subject must start with a Jira key (e.g. `PO-XXXXX Verb Subject`). The build script defaults to `vX.Y.Z: release build` which technically violates this — it has been the convention since v1.13.x and the user has accepted it. **Do not** retroactively rewrite history; for *user-driven* commits outside the release script, use the Jira convention.

---

## 5. v1.15.0 → v1.15.7 ledger

This block is the source of truth for what each recent fix doc actually shipped.

### v1.15.0 — `fix17.md` part 1 (RAM-aware buffering, retry plumbing)
- Introduced `lib/backend/device_memory.dart` (reads `/proc/meminfo` on Android).
- `Settings` defaults now derive from device RAM (clamped). Sliders show the auto-pick.
- Engine error → reconnect path stabilised (suppress benign seek probe errors).

### v1.15.1 — `fix17` rolled forward
- Multi-view audio focus via `audio_session` (P5 from `multi-view-plan.md`).
- Ensured `ChannelPickerScreen` shows green-validated check + colored text consistent with `ChannelTile`.

### v1.15.2 — `fix17` polish
- `MultiViewCell._buildInfoBar()` — gradient bottom strip with channel name + reused `NowNextStrip` widget (P6).

### v1.15.3 — UX
- Multi-view channel picker now sorts: favorites → green-validated → alphabetical.
- Picker fetches *all* pages (not just 36) before sorting, then renders sectioned headers.
- Star icon on favorites in picker.

### v1.15.4 — `fix18.md` (Comprehensive logging)
- `Subsystem: event — key=value` log lines added across:
  - `multi_view_cell.dart` (cellIndex, open/error/buffering/dispose/promote/focus)
  - `multi_view_screen.dart` (restoration, assignment, focus, dispose)
  - `player/exo_engine.dart`, `player/mpv_engine.dart` (open/dispose/options/completed/error/buffering)
  - `player/overlay_player_controller.dart` (register/unregister/start/stop/consume/mute)
  - `player/engine_picker.dart` (which of 4 selection paths fired)
  - `player/pip_controller.dart`, `player/cast_controller.dart`
  - `backend/m3u.dart`, `backend/xtream.dart`, `backend/settings_service.dart`
  - `channel_tile.dart` (prewarm, playback)
- High-frequency events gated with `if (AppLog.enabled)` to avoid IO during normal play.
- `DeviceMemory.init()` log now reports default + max for live/mini demuxers and buffer.

### v1.15.5 — `fix19-v2.md` (Stability + leak fixes — major)
The v2 of the doc explicitly **rejected** v1's proposed `if (!exiting)` guard and re-diagnosed. Shipped:
- **Overlay PiP uses `previewMode: true`** (mini-buffer, software decode) to avoid contending with main player.
- **`MpvEngine.dispose()` is idempotent** via `_disposed` flag (logs duplicate calls).
- `MultiViewCell` rewritten:
  - Engine creation now flows through `EnginePicker.pick()` (per-channel/source/global override is honored).
  - All engine event subscriptions tracked in `List<StreamSubscription> _engineSubs` and explicitly cancelled in `_disposeEngine()`.
  - `engine.dispose()` wrapped in `.catchError()` with warn log.
  - Transient retry counter (`_transientRetries` / `_maxTransientRetries=3` at v1.15.5; raised to 5 in v1.15.6), `_lastErrorAt` resets the counter after 15 s of stable playback.
  - `_lastBufferingState` filters duplicate buffering log lines.
- Replaced silent `catch (_)` blocks with `catch (e)` + `AppLog.warn` in:
  - `backend/xtream.dart`, `backend/stream_scanner.dart`, `backend/catchup_url.dart`
  - `player/pip_controller.dart`, `player/cast_controller.dart`
- `mounted` checks added before `setState` after `await` in:
  - `lib/player.dart` (Cast resume path)
  - `lib/views/epg_channel_mapping.dart` (`_load`, `_applyMapping`, `_clearMapping`)
- `lib/main.dart` startup re-ordered: load early settings → enable `AppLog` → `DeviceMemory.init` → reload settings (RAM-aware defaults applied on first run).
- `MpvEngine.open()` log shows `<live>` instead of `nulls` when `startPosition == null`.

### v1.15.6 — `fix20.md` + `fix21.md` + `fix22.md` (Multi-view parity + Reset UI)
- **fix20.1**: Multi-view cells now fetch `ChannelHttpHeaders` via `Sql.getChannelHeaders(id)` and call `MpvEngine.reapplyOptions(url, ignoreSsl)` then `engine.open(url, headers)` — bringing them to parity with the full-screen player. Helper `_ignoreSslFromHeaders` parses `String?` ignoreSSL (`'1'`/`'true'`).
- **fix20.2 / fix21.2**: Permanent error path now disposes the engine; `if (_error) return;` guards against duplicate permanent errors recreating state.
- **fix20.3**: 500 ms debounce on transient retry counter via `_lastTransientIncrementAt` to prevent a single error burst from consuming multiple retries. (Note: kept separate from `_lastErrorAt` — different semantics.)
- **fix20.4**: `_disposeEngine()` resets `_lastTransientIncrementAt = null`.
- **fix20.5**: `completedStream` retry now uses `widget.settings.streamCompletedDelayMs` (was hardcoded 2 s).
- **fix21.1**: `_isTransientError` expanded to include: `0xffffff99` (ECONNRESET), `Failed to open`, `Error decoding audio`, `Error decoding video`, `Could not open codec`, `End of file`, `HTTP error 5`, `Server returned 5`. Bounded by retry budget (max ~15 s) so no infinite retry on truly broken codecs.
- **fix21.3**: `_maxTransientRetries` raised from 3 → 5. Pairs with the 15-s stable-reset window.
- **fix22.1**: `Settings.defaults()` and `Settings.optimisedFor({isTV, layout})` factories in `lib/models/settings.dart`. Optimise calculates fields from `DeviceMemory.totalMb`, isTV, and the multi-view layout's cell count.
- **fix22.2**: New "Reset" section in `settings_view.dart` with two tiles: *Reset settings to defaults* and *Optimise for this device*. Confirmation dialog + snackbar reminder about restart-needed for buffer changes.

### v1.15.7 — Retrospective patch on v1.15.6 (this current handoff)

User asked for critical analysis. Found two issues:

1. **`Settings.optimisedFor` was clobbering personal preferences.** Fix22's table said Optimise should leave `defaultView`, `refreshOnStart`, `forceTVMode`, `showLivestreams/Movies/Series`, and the 5 EPG fields alone. Fix22's *code* did clobber them (since `Settings()` resets everything and `_confirmAndResetSettings` only preserved 4 session fields). Internal table-vs-code inconsistency I followed mechanically.
   - **Fix:** `_confirmAndResetSettings` now takes `bool preserveLibraryPreferences = false`. Optimise tile passes `true`. Reset tile passes `false` (full reset, unchanged behavior).
2. **Duplicate label helper.** `MultiViewLayout` already had a `.label` getter; I had implemented `_layoutLabel()` in `settings_view.dart` from the doc. Replaced.

**v1.15.7 changelog wording** (already in `lib/whats_new_modal.dart`):
> Fix: "Optimise for this device" no longer resets your library view, show/hide preferences, force-TV-mode, or EPG settings — those are personal preferences with no relationship to device tuning. Only buffer, cache, timing, and decoder fields change now. "Reset to defaults" still resets everything (except sources, debug-logging, and multi-view session state).

---

## 6. Critical patterns the codebase relies on

These are non-obvious invariants. Breaking them silently regresses things.

### Multi-view cell lifecycle (`lib/multi_view_cell.dart`)
- **Generation token** `_openGeneration++` on every dispose; every async path checks `generation != _openGeneration` after each `await` to bail out of stale open sequences.
- **`_engineSubs`** must hold every `StreamSubscription` — `errorStream`, `completedStream`, `bufferingStream` (and any future stream). `_disposeEngine()` cancels all of them.
- **`_disposeEngine()` is the only place** that nulls `_engine`. Every callsite that wants a clean reopen must call `_disposeEngine()` first.
- **HTTP headers + reapplyOptions parity with `lib/player.dart`** — when changing one, change both. Multi-view used to silently lack both, and that was the root cause for fix20.
- **`previewMode: true`** for multi-view cells (mini-buffer, software decode). Same applies to `OverlayPlayerController` (PiP). Do not try to "improve" a cell by removing `previewMode` — it's load-bearing for thermals on TV hardware and HW decoder pool contention.
- **Error classification:**
  - Transient list lives in `_isTransientError(err)`. Adding to it costs at most `_maxTransientRetries × stableThreshold` of latency before giving up; never infinite.
  - 500 ms debounce on `_lastTransientIncrementAt` prevents error bursts from consuming the budget.
  - 15 s stable playback resets `_transientRetries` to 0 (via `_lastErrorAt` check in `bufferingStream` listener).
  - Permanent-error path **must** call `_disposeEngine()` and **must** guard with `if (_error) return;`.
- **Seek probes** during cell startup emit error-stream events that should be ignored. `_isSeekProbeError(err)` filters them.

### MPV engine (`lib/player/mpv_engine.dart`)
- `dispose()` is idempotent (`_disposed` flag). Don't add code that assumes a single dispose call.
- `reapplyOptions(url, ignoreSsl)` mutates runtime tunables based on URL category (live vs VOD heuristic). Must be called *after* construction and *before* `open()` for non-default settings to take effect.
- Logging convention: `MpvEngine: open() url=… previewMode=… startPosition=…`. Use `<live>` literal for `null` start positions.

### Engine selection (`lib/player/engine_picker.dart`)
- Four-tier resolution: channel-override → global-override → source-default → URL-heuristic. Each path emits a log line indicating which fired.
- Multi-view cells **must** call `EnginePicker.pick()` (added in v1.15.5). Don't hardcode `MpvEngine`.

### Settings persistence (`lib/backend/settings_service.dart`, `lib/models/settings.dart`)
- `SettingsService._cached` is a process-lifetime cache. `getSettings()` returns it; `reload()` re-reads disk.
- Every tunable field has a default in the constructor. RAM-aware fields (`liveDemuxerMaxMB`, `miniDemuxerMaxMB`, `bufferSizeMB`) compute their *defaults* via `DeviceMemory`; user override in DB wins.
- `Settings.defaults()` returns a fresh `Settings()` (constructor defaults).
- `Settings.optimisedFor({isTV, layout})` computes device-tuning fields. Personal preferences (defaultView, refreshOnStart, forceTVMode, show*, EPG fields) **must be preserved by callers** — `Settings.optimisedFor` does not preserve them itself; the convention since v1.15.7 is that `_confirmAndResetSettings` does the preservation when called with `preserveLibraryPreferences: true`.

### Logging (`lib/backend/app_logger.dart`)
- `AppLog.info`, `.warn`, `.error` all check `AppLog.enabled`. Wrap *call sites* with `if (AppLog.enabled) {…}` only when the message construction itself is expensive (string interpolation with method calls). Most logs do not need this guard.
- Convention: `Subsystem: event — key=value key2=value2`. Subsystems used so far: `MpvEngine`, `ExoEngine`, `MultiViewCell`, `MultiViewScreen`, `OverlayPlayerController`, `EnginePicker`, `PipController`, `CastController`, `M3U`, `Xtream`, `StreamScanner`, `Settings`, `DeviceMemory`, `ChannelTile`, `EpgService`.

### Mounted checks
- Every async path that ends in `setState` must guard with `if (!mounted) return;` after each `await`. Recently audited: `lib/player.dart` (Cast resume), `lib/views/epg_channel_mapping.dart`. Continue this discipline.

---

## 7. Open questions / probable next-fix candidates

Things I noticed but did not change. Surface to the user before touching:

1. **`channel_picker_screen.dart:68` `page_results` lint** — pre-existing info-level warning. Likely a single-rename change, but the codebase has tolerated it through several releases. Ask before fixing.
2. **"End of file" classified as transient** — added in fix21.1. Risk: it overlaps with `completedStream` which already triggers retry via the completed handler. Guarded by generation token so not a real bug, but means a single end-of-stream may produce two retry attempts (one fires, second sees stale generation and aborts). Watch logs in production.
3. **`Could not open codec` is transient** — could trigger 5 retries against a stream the device genuinely can't decode. Bounded at ~15 s. Consider device-keyed cooldown if logs show this is wasteful.
4. **`MpvEngine.reapplyOptions` only takes `url` + `ignoreSsl`** — doesn't take headers. The full-screen player applies headers separately at `engine.open(url, headers)`. Cell mirrors this pattern. If headers ever need to influence demuxer/HTTP options pre-open, both call paths need updating together.
5. **Snackbar text "Restart for buffer-size changes"** is shown after both Reset and Optimise even when buffer didn't change. Minor — false positive. Could detect actual diff.
6. **`lib/whats_new_modal.dart` `_changelog` map is append-only.** It's getting long. No request to trim, but if a future version >1.16 wants a changelog overhaul, that's the file.
7. **`AGENTS.md` "Latest release" line is stale at v1.14.0+56.** Did not auto-update through v1.15.x. Update if user requests, otherwise leave (doesn't break anything, and the user has been getting current state from the chat / git tags).

---

## 8. Recently-edited files (state at handoff)

| File | Last meaningful change | Notes |
|---|---|---|
| `lib/multi_view_cell.dart` | v1.15.6 — fix20/21 multi-fix | Headers, reapplyOptions, debounce, expanded transient classifier, retries 3→5 |
| `lib/models/settings.dart` | v1.15.6 — fix22.1 | `Settings.defaults()`, `Settings.optimisedFor()` |
| `lib/settings_view.dart` | v1.15.7 — retrospective | `preserveLibraryPreferences` param; uses `MultiViewLayout.label` |
| `lib/whats_new_modal.dart` | v1.15.7 | New `1.15.7` entry at top of `_changelog` |
| `pubspec.yaml` | v1.15.7 | `version: 1.15.7+66` |
| `lib/player/mpv_engine.dart` | v1.15.5 | Idempotent dispose, `<live>` log |
| `lib/player/overlay_player_controller.dart` | v1.15.5 | `previewMode: true` for overlay |
| `lib/main.dart` | v1.15.5 | Reordered startup; removed `as bool` casts |
| `lib/backend/xtream.dart` / `stream_scanner.dart` / `catchup_url.dart` | v1.15.5 | `catch(_)` → `catch(e)` + log |
| `lib/player/pip_controller.dart` / `cast_controller.dart` | v1.15.5 | Same |
| `lib/views/epg_channel_mapping.dart` | v1.15.5 | `mounted` guards |
| `lib/player.dart` | v1.15.5 | `mounted` guard in Cast resume |

---

## 9. How to pick up this work

**If a new `fixXX.md` lands at repo root:**

1. Read it once end-to-end without editing.
2. Open the files it references and verify each diagnostic claim *as it stands today*. Note any line-number drift, behavior the doc misses, or dependencies on patterns that have changed since.
3. Produce an analysis bullet list in chat. For each item: `claim → verification result → recommended action (apply / modify / reject)`. **Wait for the user** if the doc has `≥3` items or any rejection.
4. Implement only what survives review. Group by file when possible to minimize diff churn.
5. `flutter analyze --no-fatal-infos`. Fix any *new* warnings; tolerate the pre-existing `page_results` info.
6. Bump `pubspec.yaml` version (last digit of `version` and `+N` build).
7. Add a top-of-map entry to `lib/whats_new_modal.dart`. Be specific — the user reads these.
8. `bash scripts/build_and_release.sh`. Confirm GH release URL in output.
9. Reply with: short summary + release URL + any items deferred.

**If the user asks to revisit shipped work** (as happened from v1.15.6 → v1.15.7):

1. Don't revert blindly — read the current state of the touched files, recall the fix doc's stated intent, and identify the *specific* place where the implementation diverged from intent.
2. Patch forward in a new version, not via amend. v1.15.7 was the right pattern.
3. Keep the `whats_new_modal.dart` entry honest about it being a follow-up to a prior version's behavior.

---

## 10. Files/paths a continuing agent will reference often

```
fix*.md                          ← fix docs (root)
multi-view-plan.md               ← original phase plan (P1..P7, mostly done)
free4me_log_*.txt                ← user-pasted device logs (evidence, not inputs)
AGENTS.md                        ← canonical session guide (note stale "Latest release")
DEVELOPMENT-HANDBOOK.md          ← original feature plan & copy strings
AGENT-HANDOFF-v1.15.7.md         ← THIS FILE
scripts/build_and_release.sh     ← release pipeline
pubspec.yaml                     ← version source of truth
lib/whats_new_modal.dart         ← user-facing changelog (top of `_changelog`)
lib/multi_view_cell.dart         ← most-edited file in v1.15.x
lib/player/mpv_engine.dart       ← engine state machine (idempotent dispose; reapplyOptions)
lib/player/engine_picker.dart    ← 4-tier engine selection
lib/models/settings.dart         ← Settings + defaults() + optimisedFor()
lib/settings_view.dart           ← UI for settings, including new Reset section
lib/backend/device_memory.dart   ← /proc/meminfo reader; defines RAM-aware defaults
lib/backend/app_logger.dart      ← AppLog API and Subsystem convention
```

---

## 11. Things to **not** change without asking

- Dart package name `open_tv`.
- Android package id `me.free4me.iptv`.
- Upstream Fredolx credit / donation links.
- Default EPG window (1 day past, 7 days forward) — user has explicitly tuned this.
- Debug signing.
- Buffer slider ranges in `settings_view.dart`.
- The `_changelog` map ordering (newest first).
- Existing `previewMode: true` on overlay/multi-view callsites.
- `_maxTransientRetries = 5` and the 15-s stable-reset window — these are paired.

---

## 12. Conversation lineage

This handoff caps a long thread that began with `fix17.md` review and ran through:
- v1.15.0 → fix17 (RAM-aware buffering)
- v1.15.1 → audio-focus (multi-view P5)
- v1.15.2 → EPG strip (multi-view P6)
- v1.15.3 → channel picker sort
- v1.15.4 → fix18 (logging)
- v1.15.5 → fix19-v2 (stability/leaks)
- v1.15.6 → fix20+21+22 (parity + reset UI)
- v1.15.7 → retrospective on v1.15.6 (Optimise scope, label dedupe)

The same thread is in:
`/Users/builder/.cursor/projects/Users-builder-git/agent-transcripts/f9d7672e-6f10-4f54-986f-e3d8ea221227/f9d7672e-6f10-4f54-986f-e3d8ea221227.jsonl`

Use grep on filenames or "fix2" / "fix1" to navigate; do not read linearly.

---

*End of handoff.*
