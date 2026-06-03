# fix11.md — Double-Start Persists Despite force-seekable=no (Property Reset)

## Why fix9 didn't work

`force-seekable=no` is set correctly in `reapplyOptions()` before `open()`.
However, `mk.Player` is a `late final` — it is created once in `initState()`
and reused for every reconnect. When `_player.open()` is called, mpv
internally reinitializes the demuxer for the new stream and **resets
stream-level runtime properties to their defaults**, including
`force-seekable` back to `auto`. The property is wiped before the stream
probe happens, so the seek attempt still occurs.

`setProperty()` sets a runtime property on the current stream context.
`_player.open()` discards that context. The fix must travel WITH the open
command, not precede it.

## Root cause summary

```
reapplyOptions() → setProperty('force-seekable', 'no')  ← set on old context
_player.open()   → mpv resets stream-level properties   ← wipes force-seekable
mpv probes seekability → server rejects → "Cannot seek" → reconnect
```

---

## Fix A — Pass force-seekable via Media extras (primary fix)

media_kit `^1.1.0`+ supports an `extras` parameter on `Media` that passes
mpv options directly into the open command. These survive the demuxer reset
because they are applied as part of the open call itself, not separately.

### File: `lib/player/mpv_engine.dart`

In the `open()` method, change `mk.Media(...)` to include extras for
livestreams:

```dart
@override
Future<void> open({
  required String url,
  Duration? startPosition,
  Map<String, String>? headers,
}) async {
  // force-seekable=no passed via extras so it survives mpv's internal
  // demuxer reset on open(). Setting it via setProperty() beforehand is
  // insufficient — mpv resets stream-level properties when initializing
  // a new stream, wiping the value before the seekability probe runs.
  final extras = channel.mediaType == MediaType.livestream
      ? {'force-seekable': 'no'}
      : null;

  await _player.open(
    mk.Media(
      url,
      start: startPosition,
      httpHeaders: headers,
      extras: extras,
    ),
  );
  if (fullscreenOnOpen) await _videoKey.currentState?.enterFullscreen();
}
```

The `force-seekable=no` line in `_applyMpvOptions()` (added in fix9) should
be **kept** as a belt-and-suspenders guard for the initial open, but the
`extras` approach is the reliable path for reconnects.

---

## Fix B — Suppress seek error during startupGrace (guaranteed fallback)

If `extras` does not suppress the probe (e.g. media_kit's extras
implementation passes them after demuxer init rather than before), add this
guard in `player.dart` as a fallback. The stream plays fine after the seek
rejection — the reconnect is the only harmful effect.

### File: `lib/player.dart`

In the `errorStream` listener inside `initAsync()`:

```dart
_engine.errorStream.listen((err) {
  debugPrint('player error: $err');

  // Suppress the mpv seekability probe error during startup.
  // mpv probes seekability on every open() and MPEG-TS livestreams reject
  // it with "Cannot seek in this stream." The stream plays fine after this;
  // only the reconnect it triggers is harmful. fix9 (force-seekable=no) and
  // fix11A (extras) attempt to prevent the probe. This guard ensures the
  // reconnect never fires even if the probe slips through.
  if (_startupGrace && err.contains('Cannot seek in this stream')) {
    AppLog.info(
      'Player: suppressed seek probe error during startup'
      ' channel="${widget.channel.name}"',
    );
    return;
  }

  final isPermanent = err.contains('Failed to open') ||
      err.contains('404') ||
      err.contains('403') ||
      err.contains('Connection refused');
  AppLog.warn(
    'Player: engine error [${isPermanent ? "permanent" : "transient"}]'
    ' — "$err" channel="${widget.channel.name}"',
  );
  onDisconnect(reason: 'player error: $err');
}),
```

---

## Implementation order

Apply **both** Fix A and Fix B together. Fix A is the correct architectural
solution. Fix B is a zero-cost safety net that guarantees the double-start
cannot occur even if Fix A has any edge case (first open, cold start, etc.).

Together they form two independent layers of defence:
- Fix A: prevents the probe from firing at all
- Fix B: prevents the reconnect even if the probe fires

---

## Expected log after fix

```
[INFO] Player: open() succeeded — engine=EngineType.libmpv url="...ts"
[INFO] Player: buffering=false channel="..."
[INFO] Player: stream stable for 15s — resetting reconnect counters
```

No seek error. No reconnect. Single clean open on every channel.

---

## Also remove force-seekable from _applyMpvOptions?

No — keep it. `reapplyOptions()` is called before `open()` so on a fresh
player instance (first open, no prior stream) it may still help. It does no
harm and provides a third layer on cold starts.

## Files to edit

- `lib/player/mpv_engine.dart` — add `extras` to `mk.Media(...)` in `open()`
- `lib/player.dart` — add seek error suppression guard in `errorStream` listener

## Model

Sonnet 4.6 (targeted error suppression + API parameter, no architectural changes)
