# fix1.md — hwdec Platform Guard

## Problem

`MpvEngine._applyMpvOptions()` unconditionally sets `hwdec = mediacodec` when
`settings.hwDecode` is enabled. `mediacodec` is Android-specific and will
silently fail or error on iOS, macOS, Linux, and Windows.

## File to edit

`lib/player/mpv_engine.dart`

## Step 1 — Add import

Add `dart:io` to the imports if not already present:

```dart
import 'dart:io';
```

## Step 2 — Replace the hwdec block

Find:

```dart
if (s.hwDecode) {
  await np.setProperty('hwdec', 'mediacodec');
} else {
  await np.setProperty('hwdec', 'no');
}
```

Replace with:

```dart
if (s.hwDecode && Platform.isAndroid) {
  await np.setProperty('hwdec', 'mediacodec');
} else if (s.hwDecode && Platform.isIOS) {
  await np.setProperty('hwdec', 'videotoolbox');
} else {
  await np.setProperty('hwdec', 'no');
}
```

## Step 3 — (Optional) Expose toggle on iOS

If the `hwDecode` settings toggle in `settings_view.dart` is currently gated
behind an Android-only check, extend the condition to include iOS so the
setting is visible and functional on both platforms.

## Rationale

| Platform | Value | Reason |
|---|---|---|
| Android | `mediacodec` | Correct Android HW decoder |
| iOS | `videotoolbox` | Correct Apple HW decoder |
| Desktop / other | `no` | Safe fallback; mpv software decode |

`Platform.isAndroid` is already the platform-detection pattern used in
`utils.dart`, `settings_io.dart`, and `device_detector.dart` — no new
dependencies introduced.

## Model

Sonnet 4.6 (standard pattern work, no architectural traps)
