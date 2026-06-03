# fix2.md — Startup Grace Period (Reconnect on Open)

## Problem

On most stream opens, the player plays for 1–2 seconds then reconnects.
During startup, mpv emits a brief `buffering = true` event while filling its
initial buffer, and ExoPlayer can briefly report a false `completed` event
before the stream settles. Either fires `onDisconnect()` within the first
1–2 seconds, causing an immediate reconnect loop.

Root causes (in priority order):
1. `completedStream` false-positive on ExoPlayer — `duration > Duration.zero`
   fires briefly during HLS init before the player settles on zero for a
   livestream.
2. `bufferingWatchdogSecs` (default 12s) starts immediately on open, before
   the stream has had time to stabilize.

## File to edit

`lib/player.dart`

## Step 1 — Add grace period state variable

In the `_PlayerState` class, alongside the existing `_isReconnecting` field:

```dart
bool _startupGrace = false;
```

## Step 2 — Set grace period around open()

In `_startPlayback()`, wrap the `_engine.open()` call:

```dart
_startupGrace = true;
await _engine.open(
  url: playbackUrl,
  startPosition: startPosition,
  headers: httpHeaders,
).timeout(...);
_consecutiveOpenFailures = 0;

// Hold grace for 3s after open() returns so the stream can stabilize.
Future.delayed(const Duration(seconds: 3), () {
  if (mounted) setState(() => _startupGrace = false);
});
```

## Step 3 — Guard _onBufferingChanged

```dart
void _onBufferingChanged(bool buffering) {
  if (!mounted || exiting || _startupGrace) return; // ← add _startupGrace
  // ... rest of existing logic unchanged ...
}
```

## Step 4 — Guard completedStream listener

In `initAsync()` where subscriptions are set up:

```dart
_engine.completedStream.listen((completed) {
  if (completed && !_startupGrace) onDisconnect(reason: 'stream completed');
}),
```

## Rationale

3 seconds is enough for any real stream to emit `buffering = false` after
the initial buffer fill. It's short enough not to mask genuine early errors.
The watchdog and completed guards are reset atomically via `_startupGrace`
so there's no race between reconnect paths.

## Notes

- `_startupGrace` must be reset to `false` on every `_startPlayback()` call
  entry (not just success) so a failed open doesn't leave grace permanently on.
  Add `_startupGrace = false;` at the top of `_startPlayback()` for safety.
- This does NOT affect VOD — `onDisconnect()` already guards on
  `MediaType.livestream`, so the grace period on VOD is a no-op.

## Model

Sonnet 4.6 (straightforward state guard, no architectural changes)
