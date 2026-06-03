# fix8.md — Three Issues: Seek Error Root Cause, Double Increment, and Re-open After Give-up

## Summary of issues confirmed in log `free4me_log_1779314111059.txt`

---

## Issue 1 — "Cannot seek in this stream." is still firing (fix6 not yet applied)

Every channel open still produces:
```
buffering=false
engine error [transient] — "Cannot seek in this stream."
onDisconnect — attempt 1/6 ... startupGrace=true
engine error [transient] — "You can force it with '--force-seekable=yes'."
```
This is the same double-start seen since the beginning. **fix6 has not been
applied yet** — `_applyMpvOptions` is still being called inside `open()`,
setting `demuxer-max-back-bytes` on a live stream and triggering the seek.

Note: mpv always emits TWO errors for a seek failure:
1. `"Cannot seek in this stream."`
2. `"You can force it with '--force-seekable=yes'."`

Both fire on `errorStream`. Only the first triggers `onDisconnect` (because
`_isReconnecting` is set to true after the first). The second is logged but
silently swallowed. This is correct behavior — no fix needed for the second
error message specifically.

**Fix:** Apply fix6 (remove `_applyMpvOptions` from inside `open()`).

---

## Issue 2 — `_totalReconnectAttempts` increments by 2 per failure cycle

The counter jumps: `2→4→6` and `1→3→5→7` instead of `1→2→3`.

**Root cause:** When a `"Failed to open"` error fires, the `isPermanent`
pre-increment in fix7's Part B adds +1 to `_totalReconnectAttempts` BEFORE
`onDisconnect()` is called, then `onDisconnect()` increments it AGAIN.
Each failure cycle = +2.

This means the limit of 6 is effectively halved to 3 real retry attempts.
It also allows the counter to exceed 6 (seen: `attempt 7/6`) because the
guard check `>= _maxReconnectAttempts` happens after the second increment.

**Fix — remove the pre-increment from the errorStream listener:**

```dart
// In errorStream listener — REMOVE this line:
if (isPermanent) _totalReconnectAttempts++;   // ← DELETE

// onDisconnect() already increments — that's the single source of truth
onDisconnect(reason: 'player error: $err');
```

The counter should only ever be incremented in one place: inside
`onDisconnect()` at the top, before the guard check.

---

## Issue 3 — Channel re-opens after "max reconnects reached"

After `"max reconnects reached — giving up on WSOC"` at 17:36:02, the same
channel re-opens at 17:37:04 and loops to max again. Then at 17:37:33 it
opens a third time and finally plays. Same pattern for WSOC at 17:50:54.

**Root cause:** `_totalReconnectAttempts` is instance state on the player
widget. When the user navigates away and back to the channel (or the history
list re-opens it), a new player widget is created with a fresh
`_totalReconnectAttempts = 0`, so the give-up state is lost. The channel
just loops through all 6 attempts again from scratch.

This is actually **partially acceptable** — a channel that was temporarily
down may be back up when the user returns. The real problem is the channel
re-opening automatically without user action. Looking at the log:

- 17:36:02 → max reached, gave up
- 17:37:04 → channel re-opened (63 seconds later, automatically)

This is the **buffering watchdog** or a background reconnect timer
re-triggering `_startPlayback()` after the give-up. The `exiting` flag should
prevent this, but if the give-up path doesn't set `exiting = true` before
returning, the watchdog may still fire.

**Fix — set exiting on give-up:**

```dart
// In onDisconnect(), when max is reached:
if (_totalReconnectAttempts >= _maxReconnectAttempts) {
  AppLog.warn('Player: max reconnects reached — giving up on "${widget.channel.name}"');
  exiting = true;                          // ← ADD THIS
  _bufferingWatchdog?.cancel();            // ← ADD THIS
  _bufferingWatchdog = null;               // ← ADD THIS
  if (mounted) {
    setState(() => _errorMessage =
        'Stream unavailable after $_maxReconnectAttempts attempts');
  }
  return;
}
```

Setting `exiting = true` ensures the watchdog, errorStream, and
completedStream listeners all no-op from that point forward, preventing
the automatic re-open.

---

## Remaining issue NOT fixed here — seek error on startupGrace=false

Three seek errors fire with `startupGrace=false`:
- WBTV at 17:35:40 (grace already expired)
- WSOC at 17:37:36 (grace already expired)

These occur because fix6 hasn't been applied (seek error happens on first
open regardless of grace window). Once fix6 is applied, these should
disappear entirely since the root cause (mid-stream property setting) is
eliminated.

---

## Also noted in log — "Failed to recognize file format" (KSAZ)

KSAZ-TV at 17:33:45 played for **31 seconds** before failing with
`"Failed to recognize file format."` — classified as transient. This is
a different stream problem (the `.ts` stream may be serving garbage data
or the provider dropped the feed mid-stream). This is classified correctly
as transient and the channel eventually gives up after 3 real attempts.
No fix needed — this is provider-side.

---

## Files to edit

`lib/player.dart`

## Changes summary

| # | Location | Change |
|---|---|---|
| 1 | `mpv_engine.dart open()` | Apply fix6 — remove `_applyMpvOptions` call |
| 2 | `errorStream` listener | Remove `if (isPermanent) _totalReconnectAttempts++` |
| 3 | `onDisconnect()` give-up path | Add `exiting = true` and cancel watchdog |

## Model

Sonnet 4.6 (targeted state fixes, confirmed by log trace)
