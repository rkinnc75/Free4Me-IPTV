# fix7.md — Infinite Reconnect Loop on Permanently Unavailable Streams

## Problem

When a stream is permanently unavailable (geo-blocked, offline, expired
token), the player reconnects infinitely with no error shown to the user
and no way to stop it except closing the app.

Confirmed from log `free4me_log_1779306449140.txt`:
`(t) MLB: New York Yankees` reconnected every ~1 second for 6+ minutes
with `reason="player error: Failed to open ...666508.ts"` — never stopping.

## Root Cause

The failure completely bypasses the `_maxOpenFailures` guard. Here's why:

### The two reconnect paths

**Path A — `_startPlayback` catch block** (what `_maxOpenFailures` guards):
```
open() throws exception → catch → _consecutiveOpenFailures++ → check limit
```

**Path B — `errorStream` listener** (what actually fires for "Failed to open"):
```
open() returns OK (mpv accepted the command)
→ _consecutiveOpenFailures = 0   ← RESET
→ mpv async: "Failed to open" fires on errorStream
→ onDisconnect() → _isReconnecting = true → 1s delay → _startPlayback()
→ open() returns OK again → _consecutiveOpenFailures = 0 again
→ repeat forever
```

`open()` returning means mpv *accepted the URL command*, NOT that the
stream is playable. The actual network connection is attempted asynchronously.
When that async connection fails, mpv fires an error event — which goes to
`errorStream`, not to the `catch` block. So `_consecutiveOpenFailures` is
reset to 0 on every cycle and `_maxOpenFailures = 6` is never reached.

### Why `_isReconnecting` doesn't stop it

`onDisconnect()` sets `_isReconnecting = true` at entry and `false` at exit.
Since `_startPlayback()` returns before the next async error fires, by the
time the next `errorStream` event arrives `_isReconnecting` is already `false`
again, so `onDisconnect()` is called again. The guard only prevents concurrent
reconnects, not repeated sequential ones.

## Fix — two-part

### Part A: Separate reconnect counter in onDisconnect()

Add a reconnect counter that increments on every `onDisconnect()` call and
is only reset on confirmed stable playback. This counter is checked alongside
`_maxOpenFailures`:

```dart
// Add alongside existing bookkeeping:
int _totalReconnectAttempts = 0;
static const int _maxReconnectAttempts = 6;
```

In `onDisconnect()`:

```dart
void onDisconnect({String reason = 'unknown'}) async {
  if (!mounted || exiting || _isReconnecting) return;
  if (widget.channel.mediaType != MediaType.livestream) return;

  _totalReconnectAttempts++;
  AppLog.warn(
    'Player: reconnect attempt $_totalReconnectAttempts/$_maxReconnectAttempts'
    ' — reason="$reason" channel="${widget.channel.name}"',
  );

  if (_totalReconnectAttempts >= _maxReconnectAttempts) {
    AppLog.warn('Player: max reconnects reached — giving up on "${widget.channel.name}"');
    if (mounted) {
      setState(() => _bufferingState =
          'Stream unavailable — ${Error.friendlyMessage(reason)}');
    }
    return;
  }

  _isReconnecting = true;
  // ... rest unchanged ...
}
```

Reset on confirmed stable playback — add to `_onBufferingChanged`:

```dart
void _onBufferingChanged(bool buffering) {
  if (!mounted || exiting) return;
  AppLog.info('Player: buffering=$buffering channel="${widget.channel.name}"');
  if (!buffering) {
    // Stream is actually playing — reset reconnect counter
    _totalReconnectAttempts = 0;
    _bufferingWatchdog?.cancel();
    _bufferingWatchdog = null;
    if (mounted) setState(() => _bufferingState = null);
  } else {
    // ... existing buffering=true logic unchanged ...
  }
}
```

### Part B: Error classification (distinguish transient vs permanent)

`"Failed to open"` is a permanent failure (stream unreachable). It should
use a shorter retry limit and faster backoff than transient errors like
`"Cannot seek"` or network drops. Add classification to the `errorStream`
listener:

```dart
_engine.errorStream.listen((err) {
  debugPrint('player error: $err');
  final isPermanent = err.contains('Failed to open') ||
      err.contains('404') ||
      err.contains('403') ||
      err.contains('Connection refused');
  AppLog.warn(
    'Player: engine error [${isPermanent ? "permanent" : "transient"}]'
    ' — "$err" channel="${widget.channel.name}"',
  );
  // Permanent failures count toward the reconnect limit immediately
  if (isPermanent) _totalReconnectAttempts++;
  onDisconnect(reason: 'player error: $err');
}),
```

## Additional logging required (to confirm fix is working)

Add to `onDisconnect()` before the guard check:

```dart
AppLog.info(
  'Player: onDisconnect state — reconnects=$_totalReconnectAttempts'
  ' openFailures=$_consecutiveOpenFailures'
  ' isReconnecting=$_isReconnecting'
  ' startupGrace=$_startupGrace'
  ' channel="${widget.channel.name}"',
);
```

This will confirm in the next log whether:
- The counter is actually incrementing
- The guard is being reached
- `_startupGrace` is interfering (if grace is still true when the error fires,
  the error may be suppressed — check `completedStream` guard uses `!_startupGrace`
  but `errorStream` does NOT — which is correct)

## What the fixed log should look like

```
[WARN] Player: reconnect attempt 1/6 — reason="player error: Failed to open..."
[WARN] Player: reconnect attempt 2/6 — reason="player error: Failed to open..."
...
[WARN] Player: reconnect attempt 6/6 — reason="player error: Failed to open..."
[WARN] Player: max reconnects reached — giving up on "(t) MLB: New York Yankees"
```
Then a static "Stream unavailable" message on screen — no more looping.

## Files to edit

- `lib/player.dart` — all changes above

## Relationship to other fixes

- fix2 (startup grace): grace suppresses `completedStream` but NOT `errorStream`
  — correct, errors should always propagate
- fix5/fix6 (seek error): unrelated path, both fixes still needed
- fix7: independent of fix5/fix6, addresses the separate infinite loop issue

## Model

Sonnet 4.6 (state management, no architectural changes)
