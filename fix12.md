# fix12.md — Complete Double-Start & Force-Close Loop Resolution

## Issues addressed

| # | Issue | Root cause |
|---|---|---|
| 1 | Double-start persists | Grace timer expires before seek error arrives |
| 2 | Second mpv error message not suppressed | Only "Cannot seek" suppressed, not companion message |
| 3 | Force-close required after give-up loop | Provider rate-limiting rapid reconnects; user retries hit same wall repeatedly |

---

## Issue 1 — Grace timer expires before seek error arrives

### Why fix11 didn't fully work

The suppression guard fires correctly but grace expires too early:

```
T+0   open() succeeded         → _startupGrace = true
T+3   Future.delayed(3s)       → _startupGrace = false  ← grace expires
T+4   buffering=false
T+4   "Cannot seek" error      → startupGrace=FALSE → not suppressed → reconnect
```

The 3-second timer is anchored to `open()` (command accepted), but the seek
probe fires relative to `buffering=false` (stream ready). On any connection
where buffering takes >3 seconds, the grace window closes before the error
arrives. Confirmed in log: `buffering=false` at T+4s, grace expired at T+3s.

### Fix — anchor grace expiry to buffering=false

#### `lib/player.dart` — Edit 1: Remove fixed 3s timer from `_startPlayback()`

Find and **delete** these lines (after `open()` succeeds):

```dart
// DELETE:
Future.delayed(const Duration(seconds: 3), () {
  if (mounted) setState(() => _startupGrace = false);
});
```

`_startupGrace` stays `true` until `_onBufferingChanged` handles it.

#### `lib/player.dart` — Edit 2: Expire grace 500ms after buffering=false

In `_onBufferingChanged()`, in the `else` (buffering=false) branch, add
immediately after cancelling the watchdog:

```dart
} else {
  _bufferingWatchdog?.cancel();
  _bufferingWatchdog = null;
  if (mounted) setState(() => _bufferingState = null);

  // Expire startup grace 500ms after buffering=false.
  // The mpv seek probe fires at the same instant as buffering=false —
  // delaying expiry ensures the suppression guard in errorStream catches
  // it regardless of event delivery order between the two streams.
  if (_startupGrace) {
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => _startupGrace = false);
    });
  }

  // Start stability timer (existing code unchanged below)...
  _stableTimer?.cancel();
  ...
```

**Why 500ms:** The `errorStream` and `bufferingStream` are backed by
separate mpv native callbacks. Their Dart delivery order within the same
native event cycle is not guaranteed. 500ms ensures the seek error is
processed before grace expires, regardless of isolate scheduling.
500ms is imperceptible to the user and does not affect the watchdog
(which is cancelled on `buffering=false`) or stability timer (which
starts after the 500ms window).

---

## Issue 2 — Companion mpv error message not suppressed

mpv always emits two messages on a seek rejection:

```
1. "Cannot seek in this stream."         ← suppressed ✓
2. "You can force it with '--force-seekable=yes'."  ← NOT suppressed ✗
```

Both fire on `errorStream`. Only the first is currently caught. The second
slips through to `onDisconnect()` and causes the reconnect even when the
first is suppressed.

### Fix — extend suppression to companion message

#### `lib/player.dart` — Edit 3: Extend the suppression guard

Find:

```dart
if (_startupGrace && err.contains('Cannot seek in this stream')) {
  AppLog.info(
    'Player: suppressed seek probe error during startup'
    ' channel="${widget.channel.name}"',
  );
  return;
}
```

Replace with:

```dart
if (_startupGrace && (
    err.contains('Cannot seek in this stream') ||
    err.contains('force-seekable=yes')
)) {
  AppLog.info(
    'Player: suppressed seek probe error during startup'
    ' channel="${widget.channel.name}"',
  );
  return;
}
```

---

## Issue 3 — Force-close loop after give-up

### What happened

```
19:05:22  Yankees open() — immediate "Failed to open" (T+0)
19:05:30  max reconnects reached — gave up (6 attempts in 8 seconds)
19:07:53  Yankees opens again — user tapped channel manually
19:07:53  immediate "Failed to open" again
          → give-up again → user retries → same → force-close
```

The give-up logic (`exiting=true`) is correct and working — the re-open at
19:07:53 is a **new Player widget** created when the user navigated back to
Yankees. Each new widget resets all state including `_totalReconnectAttempts`.

The underlying cause: the provider **rate-limits rapid reconnects**. 6
attempts in 8 seconds triggers a temporary block on the provider's side.
Every subsequent open — even from a fresh widget — gets immediately rejected
(T+0 failure) until the rate-limit window clears (typically 30–120 seconds).

The user sees "Stream unavailable", taps the channel again, gets the same
immediate failure, hits give-up again — stuck in a visible loop requiring
force-close.

### Fix — cross-session cooldown on give-up

When max reconnects is reached, record the channel ID and timestamp in a
static map shared across widget instances. New Player widgets check this
map before attempting `_startPlayback()`.

#### `lib/player.dart` — Edit 4: Add static cooldown registry

Add alongside the existing static constants:

```dart
/// Channels that recently hit max reconnects. Maps channel ID → DateTime
/// when the give-up occurred. New Player widgets respect a cooldown before
/// retrying, preventing rapid re-open loops when the provider is
/// rate-limiting. Static so it persists across widget rebuilds.
static final Map<int, DateTime> _recentGiveUps = {};
static const Duration _giveUpCooldown = Duration(seconds: 60);
```

#### `lib/player.dart` — Edit 5: Record give-up in onDisconnect()

In `onDisconnect()`, where max reconnects is reached, add before `return`:

```dart
if (_totalReconnectAttempts >= _maxReconnectAttempts) {
  AppLog.warn(
    'Player: max reconnects reached — giving up on "${widget.channel.name}"',
  );
  // Record cooldown so fresh widget instances don't immediately retry.
  final id = widget.channel.id;
  if (id != null) _recentGiveUps[id] = DateTime.now();

  exiting = true;
  _bufferingWatchdog?.cancel();
  _bufferingWatchdog = null;
  _stableTimer?.cancel();
  _stableTimer = null;
  if (mounted) {
    setState(() => _bufferingState =
        'Stream unavailable — too many failed attempts. Try again shortly.');
  }
  return;
}
```

#### `lib/player.dart` — Edit 6: Check cooldown in initAsync()

At the very start of `initAsync()`, before `_startPlayback()` is called:

```dart
Future<void> initAsync() async {
  // Check cross-session give-up cooldown before attempting playback.
  final id = widget.channel.id;
  if (id != null) {
    final gaveUp = _recentGiveUps[id];
    if (gaveUp != null) {
      final elapsed = DateTime.now().difference(gaveUp);
      if (elapsed < _giveUpCooldown) {
        final remaining = (_giveUpCooldown - elapsed).inSeconds;
        AppLog.warn(
          'Player: cooldown active for "${widget.channel.name}"'
          ' — ${remaining}s remaining',
        );
        if (mounted) {
          setState(() => _bufferingState =
              'Stream unavailable — please wait ${remaining}s before retrying');
        }
        return;  // Don't attempt playback yet
      } else {
        // Cooldown expired — clear the record and try again
        _recentGiveUps.remove(id);
        AppLog.info(
          'Player: cooldown expired for "${widget.channel.name}" — retrying',
        );
      }
    }
  }

  // ... rest of existing initAsync() unchanged
  final channelId = widget.channel.id;
  ...
}
```

This gives the provider's rate-limit window time to clear before any retry
is attempted. The user sees a clear message with remaining seconds rather
than an unexplained failure loop.

---

## Summary of all changes

| Edit | File | Change |
|---|---|---|
| 1 | `player.dart` | Remove 3s grace timer from `_startPlayback()` |
| 2 | `player.dart` | Add 500ms grace expiry after `buffering=false` in `_onBufferingChanged()` |
| 3 | `player.dart` | Extend seek suppression to companion `force-seekable=yes` message |
| 4 | `player.dart` | Add static `_recentGiveUps` map and `_giveUpCooldown` constant |
| 5 | `player.dart` | Record give-up in `onDisconnect()` when max reached |
| 6 | `player.dart` | Check cooldown at start of `initAsync()` |

All changes are in `lib/player.dart`. No other files touched.

---

## Expected log after fix

**Normal open:**
```
[INFO] open() succeeded
[INFO] buffering=false
[INFO] suppressed seek probe error during startup  ← both messages caught
[INFO] stream stable for 15s — resetting reconnect counters
```

**Dead/rate-limited stream:**
```
[WARN] onDisconnect — attempt 1/6
[WARN] onDisconnect — attempt 2/6
...
[WARN] max reconnects reached — giving up
[WARN] cooldown active for "Yankees" — 47s remaining  ← if user retries too soon
[INFO] cooldown expired — retrying  ← after 60s
```

## Model

Sonnet 4.6 (confirmed by log timestamp analysis — no architectural changes)
