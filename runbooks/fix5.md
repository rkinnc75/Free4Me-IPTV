# fix5.md — Livestream Seek Error Causing Immediate Reconnect

## Problem

On most livestream opens, video plays for ~3 seconds then reconnects with:

```
reason="player error: Cannot seek in this stream."
```

mpv allocates a backward (rewind) buffer (`demuxer-max-back-bytes = 32MiB`)
and attempts a seek to verify the buffer range. MPEG-TS livestreams are not
seekable, so the server rejects it. mpv surfaces this as a player error,
`onDisconnect()` fires, and the stream reconnects. The second open is stable
because mpv no longer attempts the probe seek once it knows the stream state.

This is the root cause of the 1–2 second reconnect-on-open reported in the
original investigation. Fix2 (startup grace period) would mask this symptom
but not eliminate it — this fix addresses the actual cause.

## File to edit

`lib/player/mpv_engine.dart`

## Change — disable back buffer for all livestream branches

In `_applyMpvOptions()`, find the live stream section:

```dart
// Live + normal latency
await np.setProperty('cache-secs', '${s.liveCacheSecs}');
await np.setProperty('demuxer-max-bytes', '${s.liveDemuxerMaxMB}MiB');
await np.setProperty('demuxer-max-back-bytes', '32MiB');
```

Replace with:

```dart
await np.setProperty('cache-secs', '${s.liveCacheSecs}');
await np.setProperty('demuxer-max-bytes', '${s.liveDemuxerMaxMB}MiB');
await np.setProperty('demuxer-max-back-bytes', '0');
```

And in the live + low latency branch, add explicitly:

```dart
await np.setProperty('profile', 'low-latency');
await np.setProperty('demuxer-max-back-bytes', '0'); // ← add this
```

Leave VOD untouched — `demuxer-max-back-bytes = 64MiB` is correct for
seekable content.

## Confirmed via log

```
[12:49:45] open() succeeded — engine=libmpv url="...461837.ts"
[12:49:48] buffering=false                          ← video rendering
[12:49:48] reconnect — reason="player error: Cannot seek in this stream."
[12:49:49] open() succeeded                         ← stable on second open
```

## Relationship to fix2

Fix2 (startup grace period) is still worth keeping — it guards against other
false positive disconnect triggers during startup. But with fix5 applied,
the seek error will not occur at all, so fix2 becomes a safety net rather
than a primary workaround.

## Model

Sonnet 4.6 (single property change, confirmed by log)
