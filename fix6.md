# fix6.md — Double _applyMpvOptions Causing Seek Error on Reconnect

## Problem

Fix5 correctly set `demuxer-max-back-bytes = 0` in both live branches of
`_applyMpvOptions()`, but the `"Cannot seek in this stream."` error persists.

The root cause is that `_applyMpvOptions()` is called **twice** on every
`open()` call during a reconnect:

1. `player.dart` calls `mpv.reapplyOptions()` → `_applyMpvOptions()` ✓
2. `mpv_engine.dart open()` calls `_applyMpvOptions()` again ✗

The second call sets mpv properties on an **already-live stream** (the
previous reconnect attempt is still active when options are re-applied).
Setting `demuxer-max-back-bytes` (or any buffer property) on a live mpv
instance triggers an internal demuxer reset, which attempts a seek on the
active MPEG-TS stream. The server rejects it → `"Cannot seek in this stream."`
fires as a player error → `onDisconnect()` triggers → reconnect loop.

Fix5's `demuxer-max-back-bytes = 0` is correct. The problem is *when* it
is applied, not *what* it is set to.

## File to edit

`lib/player/mpv_engine.dart`

## Change — remove _applyMpvOptions from open()

Find:

```dart
@override
Future<void> open({
  required String url,
  Duration? startPosition,
  Map<String, String>? headers,
}) async {
  await _applyMpvOptions(url: url);
  await _player.open(
    mk.Media(
      url,
      start: startPosition,
      httpHeaders: headers,
    ),
  );
  if (fullscreenOnOpen) await _videoKey.currentState?.enterFullscreen();
}
```

Replace with:

```dart
@override
Future<void> open({
  required String url,
  Duration? startPosition,
  Map<String, String>? headers,
}) async {
  // Options are applied by the caller via reapplyOptions() before every
  // open() call. Setting mpv properties here would apply them to the
  // still-active previous stream, triggering a demuxer reset and seek
  // error on non-seekable MPEG-TS livestreams.
  await _player.open(
    mk.Media(
      url,
      start: startPosition,
      httpHeaders: headers,
    ),
  );
  if (fullscreenOnOpen) await _videoKey.currentState?.enterFullscreen();
}
```

## Verify caller coverage

Confirm that every call site that calls `open()` also calls `reapplyOptions()`
first. Currently in `player.dart`:

- `_startPlayback()` — calls `mpv.reapplyOptions()` ✓ (line ~258)
- `_onCastTap()` resume after stop — calls `_engine.open()` directly ✗

Add `reapplyOptions()` to the cast resume path:

```dart
// In _onCastTap(), before the resume open():
if (_engine case final MpvEngine mpv) {
  await mpv.reapplyOptions(url: url);
}
await _engine.open(url: url, startPosition: resumePosition);
```

## Why fix5 alone wasn't enough

Fix5 set the right value. Fix6 ensures it's set at the right time — before
`_player.open()` is called on a fresh stream, not mid-flight on a live one.

## Relationship to other fixes

- fix2 (startup grace): still worth keeping as a safety net
- fix5 (demuxer-max-back-bytes=0): keep — correct value, now applied correctly
- fix6: the actual resolution of the seek error loop

## Model

Sonnet 4.6 (single call-site removal, confirmed by code trace)
