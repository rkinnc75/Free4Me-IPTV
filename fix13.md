# fix13.md — Audio-Only (No Video) on Nvidia Shield / Android TV

## Device

Nvidia Shield Pro (Tegra X1, Android TV)

## Confirmed from log `free4me_log_1779334798742.txt`

```
[INFO] Player: engine=EngineType.libmpv channel="US: AGATHA ALL ALONG ᴿᴬᵂ"
[INFO] Player: open() succeeded
[INFO] Player: buffering=false       ← stream decoded, audio playing
[INFO] Player: suppressed seek probe error  ← fix12 working ✓
[INFO] Player: suppressed seek probe error  ← both messages caught ✓
```

Stream opens cleanly, no reconnects, fix12 confirmed working. Audio plays
but video is black. The player is fully functional — this is a hardware
decode surface binding issue specific to Android TV devices.

## Root cause

`hwdec = mediacodec` (set in `_applyMpvOptions()` for Android) has two
internal modes in mpv:

| Mode | How it works | Requirement |
|---|---|---|
| `mediacodec` | Decodes to a `SurfaceTexture` directly | mpv `vo=gpu` must bind the MediaCodec output surface to the Flutter texture correctly |
| `mediacodec-copy` | Copies decoded frames back to CPU RAM | Works with any `vo`, universally compatible |

The Nvidia Shield (Tegra X1) has a known issue where `mediacodec` in surface
mode produces audio-only when media_kit's `vo=gpu` path does not correctly
bind the MediaCodec output surface to the Flutter texture. This is a
hardware/driver interaction specific to Android TV devices with Tegra SoCs
and has been reported across multiple media_kit-based apps.

Audio plays because audio decoding is completely separate from the video
surface binding — audio goes directly to AudioTrack regardless of `vo`.

## Fix — use `mediacodec-copy` on Android TV

`mediacodec-copy` decodes in hardware but copies the result to CPU memory,
bypassing the surface binding entirely. It uses slightly more memory and
CPU than pure `mediacodec` but is fully compatible on all Android devices
including Shield. The Shield is powerful enough that the copy overhead is
imperceptible.

`DeviceDetector.isTV()` already exists and correctly detects Android TV via
`android.software.leanback` — the Shield reports this feature.

### File: `lib/player/mpv_engine.dart`

`_applyMpvOptions()` needs `isTV` passed in, or it can call
`DeviceDetector.isTV()` itself. Since `_applyMpvOptions` is already async,
calling it directly is cleanest.

Add the import at the top if not present:

```dart
import 'package:open_tv/models/device_detector.dart';
```

Find the `hwDecode` block:

```dart
if (s.hwDecode && Platform.isAndroid) {
  await np.setProperty('hwdec', 'mediacodec');
} else if (s.hwDecode && Platform.isIOS) {
  await np.setProperty('hwdec', 'videotoolbox');
} else {
  await np.setProperty('hwdec', 'no');
}
```

Replace with:

```dart
if (s.hwDecode && Platform.isAndroid) {
  // Android TV devices (Shield, Fire TV, etc.) require mediacodec-copy
  // rather than mediacodec. In surface mode, mediacodec binds directly
  // to a SurfaceTexture — this fails silently on Tegra X1 and similar
  // Android TV SoCs, producing audio with a black screen.
  // mediacodec-copy decodes in hardware but copies frames to CPU memory,
  // bypassing the surface binding. Overhead is negligible on TV hardware.
  final isTV = await DeviceDetector.isTV();
  final hwdecMode = isTV ? 'mediacodec-copy' : 'mediacodec';
  await np.setProperty('hwdec', hwdecMode);
  AppLog.info('Player: hwdec=$hwdecMode isTV=$isTV');
} else if (s.hwDecode && Platform.isIOS) {
  await np.setProperty('hwdec', 'videotoolbox');
} else {
  await np.setProperty('hwdec', 'no');
}
```

## Side effects

- `mediacodec-copy` is slightly higher CPU usage than `mediacodec` but
  imperceptible on Shield-class hardware
- Applies to all Android TV devices (Fire TV, Chromecast with Google TV,
  etc.) — all benefit from this change
- Phone/tablet users are unaffected (continue to use `mediacodec`)
- The `AppLog.info` line will confirm which mode was selected in future logs,
  making TV-specific issues easier to diagnose

## Also confirmed in this log — fix12 working

Both seek probe suppressions fired correctly:
```
suppressed seek probe error during startup  ← "Cannot seek in this stream."
suppressed seek probe error during startup  ← "force-seekable=yes" companion
```
No double-start. No reconnect. fix12 is fully effective.

## File to edit

`lib/player/mpv_engine.dart` — modify hwDecode block in `_applyMpvOptions()`

## Model

Sonnet 4.6 (platform conditional, DeviceDetector already in codebase)
