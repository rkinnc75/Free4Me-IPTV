# Shield black-screen findings

**Date:** 2026-06-17
**Build on device:** Free4Me-IPTV 1.34.21+393 (pre-fix394)
**Device:** NVIDIA Shield Android TV (Tegra X1, 2945 MB RAM, foster_e_hdd)
**Engine:** libmpv via `media_kit` 1.2.6 (`mk.NativePlayer`)

## TL;DR

The Shield's black screen on full-screen playback (audio alive, video pipeline stalled) is caused by **fix164's code-vs-comment drift** at `lib/player/mpv_engine.dart:561-570`. The comment says "low-RAM TV boxes (onn 4K Plus, 2GB / Mali-G310)" but the code uses `isTV`, which fires for any Android TV device regardless of RAM. The Shield (2945 MB, isTV=true, isLowRamDevice=false) gets `hwdec=no` (software decode) — the wrong path for Tegra. Pre-fix164, the Shield got `mediacodec-copy` and that worked. fix164 overcorrected.

## What the log shows

- Build: `1.34.21+393` (pre-fix394)
- 20:45:43 — user opens "US: EPIX DRIVE IN" full-screen, 90-min DVR enabled
- 20:45:44 — engine created, DVR set up (5.4 GB cache-on-disk), options applied
- 20:45:45 — open() succeeds, `buffering=false` (audio alive), then `buffering=true` (waiting for first video frame)
- 20:45:45 — `Player: ROTATE init → landscape` — surface tears down
- 20:45:45 — `SURFACE[rotate-landscape] textureId=null rect=null` (surface unbound)
- 20:45:46 — startup grace expires (logged twice — a duplicate-emit bug, separate)
- 20:45:47 — `texture attached latency=1346ms` (surface rebinds)
- 20:45:47 — `SURFACE[mid-playback+2s] textureId=0 rect=1920x1080` (surface live)
- 20:45:47 — `buffering=false` (audio alive again)
- **20:45:47 → 20:45:59: 12 seconds of silence** — no `Player: position=N` lines, no video/audio params
- 20:45:59 — user exits

**Smoking gun:** 12 seconds of silence. A playing livestream fires periodic `Player: position=N` lines. Their absence means the playhead is not advancing. Audio is alive (`buffering=false` at 20:45:47), but the video frame queue is empty. The user sees audio but no video (a black screen). After 12 s of waiting, presses exit.

## The bug: fix164's code-vs-comment drift

### The code (1.34.21+393, `lib/player/mpv_engine.dart:561-570`)

```dart
} else if (s.hwDecode && Platform.isAndroid) {
  // Phone: mediacodec surface mode (hardware, zero-copy).
  // TV: software decode. fix164 — on low-RAM TV boxes (onn 4K Plus,
  // 2GB / Mali-G310) the mediacodec-copy GPU→CPU readback falls behind
  // the audio clock causing A/V desync. Software decode (hwdec=no)
  // keeps A/V in sync and cannot hit the surface-mode black-screen
  // failure (fix108). Preview/multi-view cells keep mediacodec-copy.
  final isTV = await DeviceDetector.isTV();
  final hwdecMode = isTV ? 'no' : 'mediacodec';
  await np.setProperty('hwdec', hwdecMode);
  AppLog.info('Player: hwdec=$hwdecMode isTV=$isTV (fix164)');
}
```

**Comment:** "low-RAM TV boxes (onn 4K Plus, 2GB / Mali-G310)."
**Code:** `isTV` — fires for any Android TV device, regardless of RAM.

### The git history confirms the drift

Pre-fix164 routing (worked on Shield):
```dart
final isTV = await DeviceDetector.isTV();
final hwdecMode = isTV ? 'mediacodec-copy' : 'mediacodec';
```
Pre-fix164 comment: "Android TV devices (Shield, Fire TV, Onn 4K, etc.) require mediacodec-copy rather than mediacodec surface mode. In surface mode, mediacodec binds directly to a SurfaceTexture — this fails silently on Tegra X1 and similar Android TV SoCs."

fix164 changed `'mediacodec-copy'` to `'no'` for `isTV` — but the intent (per the runbook and the new comment) was only for low-RAM TV (the onn 4K Plus 2GB). The code uses `isTV` instead of `isLowRamDevice`, breaking the Shield.

### The fix164 runbook itself documents the intent

From `fix164.md` (commit 8675130):
- Evidence: `free4me_log_1780155704975.txt` (onn 4K Plus, isTV=true)
- `DeviceMemory: totalMb=1925` — 2GB
- "the `mediacodec-copy` readback path is memory-bandwidth bound here; software decode keeps the clocks in sync, which matches the user's 'Hardware Decoder Off is much better.'"
- "fix108 deliberately moved TV to `mediacodec-copy` because surface-mode `mediacodec` binds to a SurfaceTexture and silently produces audio-only black screen on Tegra-class Android TV SoCs. So we must NOT switch TV to plain `mediacodec` — that re-introduces the fix108 black-screen failure."

The runbook itself says: don't switch TV to `mediacodec` (would re-introduce fix108's black screen on Tegra). But it didn't anticipate that `isTV=true` covers non-low-RAM TV too, where `mediacodec-copy` is the *correct* path.

## Why the Shield stalls specifically

With `hwdec=no` on Shield (Tegra X1, 2945 MB):
1. **GPU is idle** — software decode doesn't use Maxwell GPU. 4× Cortex-A57 doing H.264.
2. **Disk I/O contention** — `cache-on-disk=yes` writing 5.4 GB to internal storage for 90-min DVR saturates the storage bus.
3. **Surface rebind** — 1.3 s gap at 20:45:45–47 when the layout rotation tears down the SurfaceTexture. Software-decoded frames go through the OpenGL upload path; if the GL context changes during rotation, the upload is lost.
4. **No position advance** — decoder pipeline is starving. mpv reports `buffering=false` (audio alive) but the video frame queue is empty. 12 s of silence in the log.

With `hwdec=mediacodec-copy` (pre-fix164, what works on Shield):
- Hardware decode via Tegra's H.264 decoder, frames copied to CPU memory.
- Bypasses the SurfaceTexture binding issue (fix108's original concern).
- 4× A57 + idle GPU + 5.4 GB disk write = plenty of headroom.

## The proper fix (3 lines)

```dart
final isTV = await DeviceDetector.isTV();
final isLowRam = await DeviceDetector.isLowRamDevice();
final hwdecMode = isLowRam
    ? 'no'              // fix164: low-RAM TV → software (desync fix)
    : isTV
        ? 'mediacodec-copy'  // pre-fix164: non-low-RAM TV → hardware copy (Tegra works)
        : 'mediacodec';      // phone: hardware surface
await np.setProperty('hwdec', hwdecMode);
AppLog.info('Player: hwdec=$hwdecMode isTV=$isTV isLowRam=$isLowRam');
```

### Routing after fix

| Device | isLowRam | isTV | hwdec | Source |
|---|---|---|---|---|
| onn 4K Plus (1925 MB) | true | true | `no` | fix164 path preserved |
| **Shield (2945 MB, Tegra)** | **false** | **true** | **`mediacodec-copy`** | **pre-fix164 path restored** |
| Phone Pixel (8 GB) | false | false | `mediacodec` | unchanged |
| Phone low-RAM OPPO (2 GB) | true | false | `no` | safe fallback |
| iOS | — | — | `videotoolbox` | unchanged |

This is fix395.

## Why the `Player: hwdec=...` log line is missing from the export

The export bracketing is suspicious:
- `20:45:44 MpvEngine: DVR enabled — window=90min ...`
- `20:45:44 MpvEngine: options applied ...`

Between these two is where `Player: hwdec=$hwdecMode isTV=$isTV (fix164)` should fire (one of ~10 `AppLog.info` calls in `_applyMpvOptions` between them). The two bracketing lines are present; the middle is missing.

**Most likely:** the export was truncated between the two lines, not filtered. The `Player:` prefix is otherwise preserved throughout the log (CREATED engine, buffering, open() succeeded, watchdog armed, ROTATE, startup grace, onExit, dispose). Re-exporting on a fresh play and grepping for `hwdec` should confirm the line fires.

## Supporting evidence

- `git show 8675130^:lib/player/mpv_engine.dart` — pre-fix164 routing, Shield got `mediacodec-copy`.
- `git show 8675130 -- fix164.md` — fix164 runbook explicitly mentions onn 4K Plus 2GB / Mali-G310 as the target device.
- `lib/models/device_detector.dart:9-25` — `isTV()` checks `android.software.leanback` system feature (any Android TV device, not low-RAM).
- `lib/models/device_detector.dart:124-133` — `isLowRamDevice()` checks `DeviceMemory.totalMb < 2300` (RAM-only).
- `lib/models/device_detector.dart:89-105` — `isTegra()` matches 'tegra'/'shield'/'nvidia' in device info.

## Shipping checklist for fix395

1. Fresh clone: `rm -rf /workspace/f4m && git clone --depth 1 https://github.com/rkinnc75/Free4Me-IPTV.git /workspace/f4m`
2. Next build: `1.34.23+395` (every fix gets a new minor; burn-versions convention)
3. Edit `lib/player/mpv_engine.dart:567-570` — replace `final isTV = ...` + `final hwdecMode = isTV ? 'no' : 'mediacodec'` with the 3-line proper fix above
4. Add regression-guard test: `test/shield_hwdec_routing_test.dart` — pure function or const that asserts the routing logic per the table above (mock `isTV`/`isLowRamDevice`)
5. `lib/whats_new_modal.dart` — 1.34.23 entry
6. `pubspec.yaml` — `1.34.22+394` → `1.34.23+395`
7. Gates: pub get / analyze / test (expect 127/127 with +1 new test)
8. Chain-verify on second fresh clone
9. Single-file runbook at `/workspace/fix395.md` with `## Release — EXECUTE` header, embedded patch byte-identical to `git diff HEAD`

## Backlog: same pattern, settings layer

Per the fix390 review's settings auto-detect roadmap:
- `Settings.hwDecode` should auto-set on first run: `!isLowRamDevice()` (or `!isTV` for non-low-RAM TV, with explicit opt-in for Shield-class devices). Same USER-VISIBLE-MATCHES-ACTUAL pattern as fix390.
- Settings.optimisedFor timing/buffer fields (liveCacheSecs, openTimeoutSecs, etc.) — auto-applied on first run.
- This is fix396 or later, after fix395 ships.

## Out of scope

- 90-min DVR write I/O on Shield — orthogonal; user can disable DVR if disk I/O is the bottleneck. Not addressed by fix395.
- 1.3 s surface rebind during layout rotation — separate issue; might be a fix396 if reproducible on other devices.
- `Player: startup grace expired (after 500ms)` logged twice — duplicate-emit bug, separate fix.

## Files referenced

- `lib/player/mpv_engine.dart:561-570` (the buggy branch)
- `lib/models/device_detector.dart:9-25, 89-105, 124-133` (isTV, isTegra, isLowRamDevice)
- `lib/backend/app_logger.dart:60-87` (log function, no filter)
- `lib/player.dart:641, 813` (reapplyOptions call sites)
- `fix164.md` (runbook documenting the original intent)
- `git log` commit `8675130` (fix164 landing)
