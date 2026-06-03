# fix9.md — Persistent "Cannot Seek" Error: mpv Seekability Probe

## Status of previous fixes in 1.11.9

| Fix | Status | Notes |
|---|---|---|
| fix1 (hwdec platform guard) | ✓ Applied | Platform.isAndroid/isIOS in place |
| fix5 (demuxer-max-back-bytes=0) | ✓ Applied | Both live branches set to 0 |
| fix6 (remove _applyMpvOptions from open()) | ✓ Applied | Comment in code confirms it |
| fix7 (reconnect counter + stable timer) | ✓ Applied | stableThresholdSecs=15 in settings |
| fix8 issue 2 (double increment) | ✗ NOT applied | Counter still jumps by 2 |
| fix8 issue 3 (exiting on give-up) | ✗ NOT applied | Re-open after give-up still occurs |

---

## Problem — "Cannot seek in this stream." still fires on every channel open

Despite fix5 (`demuxer-max-back-bytes=0`) and fix6 (no mid-stream property
setting), every channel still double-starts with this sequence:

```
17:32:00  open() succeeded
17:32:03  buffering=false          ← stream is playing
17:32:03  engine error — "Cannot seek in this stream."
17:32:03  onDisconnect attempt 1/6 ... startupGrace=true
17:32:03  engine error — "You can force it with '--force-seekable=yes'."
```

The seek error fires **at the same millisecond as `buffering=false`** —
meaning it's part of mpv's initial stream probing, not a property-setting
side effect. Every channel shows exactly 3 seconds between `open()` and the
error, which is the network latency to the provider, not a code timer.

## Root Cause

mpv probes seekability of every new stream by attempting a seek as part of
its demuxer initialization. On MPEG-TS livestreams, the server rejects this
seek (livestreams are not seekable), and mpv surfaces it as a player error.
mpv even tells you the fix in the second error message:

```
"You can force it with '--force-seekable=yes'."
```

The inverse — `force-seekable=no` — tells mpv **not to probe** seekability
at all. The stream is declared non-seekable upfront and no seek attempt is
made. fix5's `demuxer-max-back-bytes=0` reduces back-buffer allocation but
does NOT suppress the seekability probe. These are independent mpv behaviors.

## Fix — add `force-seekable=no` for livestreams

In `lib/player/mpv_engine.dart`, inside `_applyMpvOptions()`, in the
`channel.mediaType == MediaType.livestream` block:

```dart
if (channel.mediaType == MediaType.livestream) {
  // Declare stream non-seekable upfront. Without this, mpv probes
  // seekability by attempting a seek on first open — MPEG-TS livestreams
  // reject it, which surfaces as "Cannot seek in this stream." causing
  // an unnecessary reconnect on every channel open.
  await np.setProperty('force-seekable', 'no');   // ← ADD THIS

  if (s.lowLatency) {
    await np.setProperty('profile', 'low-latency');
    await np.setProperty('demuxer-max-back-bytes', '0');
  } else {
    await np.setProperty('cache-secs', s.liveCacheSecs.toString());
    await np.setProperty('demuxer-max-bytes', '${s.liveDemuxerMaxMB}MiB');
    await np.setProperty('demuxer-max-back-bytes', '0');
  }
} else {
  // VOD: seekable, leave force-seekable at default (auto)
  await np.setProperty('cache-secs', s.vodCacheSecs.toString());
  await np.setProperty('demuxer-max-bytes', '${s.vodDemuxerMaxMB}MiB');
  await np.setProperty('demuxer-max-back-bytes', '64MiB');
}
```

`force-seekable=no` is safe for VOD because it's only set in the livestream
branch. VOD channels get mpv's default auto-detection which correctly
identifies them as seekable.

---

## Fix8 issues still pending

### Issue 2 — double increment (still present in 1.11.9)

The `errorStream` listener in `player.dart` still has:

```dart
if (isPermanent) _totalReconnectAttempts++;  // ← fires first
onDisconnect(reason: 'player error: $err');   // ← increments again
```

Counter still jumps 2→4→6 per permanent failure. The pre-increment line must
be removed. `onDisconnect()` is the single source of truth.

### Issue 3 — re-open after give-up (still present in 1.11.9)

`onDisconnect()` on max-reached path still returns without setting
`exiting = true`:

```dart
if (_totalReconnectAttempts >= _maxReconnectAttempts) {
  AppLog.warn('Player: max reconnects reached...');
  exiting = true;          // ← MISSING
  _bufferingWatchdog?.cancel();  // ← MISSING
  _stableTimer?.cancel();        // ← MISSING
  if (mounted) {
    setState(() => _bufferingState = '...');
  }
  return;
}
```

---

## Settings observations (from free4me-backup-np.json)

- `liveCacheSecs: 45` — raised from default 20, appropriate for this provider
- `stableThresholdSecs: 15` — correct, prevents premature counter reset
- **Two sources pointing to identical URL** (`tv.media4u.top/player_api.php`)
  with no username/password. Both `Aniel3000` and `Media4u` are the same
  endpoint. This causes every channel to appear twice in search/listings and
  doubles EPG matching work. Consider disabling one source or merging them
  if the intent is a single provider.

---

## Expected result after fix9

```
17:32:00  open() succeeded
17:32:03  buffering=false          ← stream playing, NO seek error
17:32:18  stream stable for 15s — resetting reconnect counters
```

The double-start disappears entirely. Every channel opens cleanly on the
first attempt.

## File to edit

`lib/player/mpv_engine.dart` — add `force-seekable=no` in livestream branch
`lib/player.dart` — fix8 issues 2 and 3 (remove pre-increment, add exiting=true)

## Model

Sonnet 4.6 (single property addition confirmed by mpv documentation and
error message self-reporting)
