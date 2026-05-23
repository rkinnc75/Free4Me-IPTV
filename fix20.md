# fix20.md — Multi-view cells skip `reapplyOptions()` and channel headers

> **Diagnosis from `free4me_log_1779486563310.txt`.** With 4 provider
> connections allocated, 2 multi-view streams should be well within budget,
> yet both cells degraded into a retry → permanent-error → orphaned-engine
> spiral within ~3 minutes. Root cause is not server-side capping — it is
> that `MultiViewCell._startEngine()` opens an `MpvEngine` **without ever
> calling `reapplyOptions()`** and **without supplying channel HTTP headers**.
> The full-screen `Player` does both. The cell falls back to mpv defaults
> for every network and buffer setting the rest of the app carefully tunes.

---

## Evidence

### 1. The log pattern is not "provider cap"

If the provider were capping the account, opens would fail at the TCP/HTTP
layer immediately. Instead the log shows healthy opens followed by
**progressive degradation**:

```
17:42:14  cell 0 OK, cell 1 OK                    ← clean opens
17:42:17  cell 0 stable (no buffering)
17:42:26  cell 0 ETIMEDOUT (0xffffff92) after 12s ← server quietly closed read
17:42:29  cell 1 "stream completed" after 15s     ← server EOF'd the .ts
17:43:41  cell 1 ETIMEDOUT after ~34s
17:43:49  cell 1 "Failed to open" → PERMANENT     ← retry hit a bad edge
17:44:15  cell 0 "stream completed" after ~58s
17:44:33  cell 1 ETIMEDOUT after ~16s
17:45:22  cell 1 "stream completed" after ~46s
17:45:32  cell 0 "stream completed"
17:45:43  cell 1 ECONNRESET (0xffffff99) x2       ← server actively reset
17:45:54  cell 0 "Failed to open" → PERMANENT
17:45:59  cell 1 "Could not open codec" → PERMANENT
```

All three error classes (`ETIMEDOUT`, `ECONNRESET`, `Could not open codec`)
are network-condition failures, not auth/quota failures. The single
StreamScanner pre-run (17:41:18–17:42:12) probed channels on the same
host successfully — including a UA of `Lavf/61.7.100` — meaning the account
itself was healthy at that moment.

### 2. The full-screen player applies mpv options; cells do not

**`lib/player.dart:450-455`** — every full-screen open goes through:

```dart
if (_engine case final MpvEngine mpv) {
  await mpv.reapplyOptions(
    url: playbackUrl,
    ignoreSsl: _isIgnoreSsl(headers),
  );
}
```

This call configures (via `_applyMpvOptions`):

- `cache` = yes
- `network-timeout` = 30
- `hwdec` = `no` (preview) / `mediacodec`-`copy` / `mediacodec` / `videotoolbox`
- `force-seekable` = no (livestreams)
- `cache-secs` = `settings.liveCacheSecs` (user set to **45**)
- `demuxer-max-bytes` = `liveDemuxerMaxMB` MiB (preview: `miniDemuxerMaxMB`)
- `demuxer-max-back-bytes` = 0 (livestreams)
- `hls-bitrate` (for .m3u8)
- `tls-verify` (when ignoreSsl)

**`lib/multi_view_cell.dart:188-195, 291-292`** — the cell builds the
engine and goes straight to `open()`:

```dart
PlayerEngine engine = pickedType == EngineType.exoplayer
    ? ExoEngine()
    : MpvEngine(
        channel: ch,
        settings: widget.settings,
        fullscreenOnOpen: false,
        previewMode: true,
      );

// ...subscriptions...

try {
  await engine.open(url: ch.url ?? '');
}
```

No `reapplyOptions()`. The `previewMode=true` flag halves the
`PlayerConfiguration.bufferSize` (a libmpv input cache size set at
construction time) but **never reaches `_applyMpvOptions`**, so every
runtime tuning the rest of the app applies is silently dropped on the
floor. The cell runs with mpv's stock defaults for:

| Property | App default | mpv default (when option skipped) |
|---|---|---|
| `network-timeout` | 30 | depends — some libmpv builds use 60 |
| `cache-secs` | 45 | 10 |
| `demuxer-max-bytes` | 48 MiB (preview live) | 150 MiB |
| `demuxer-max-back-bytes` | 0 (live) | varies |
| `force-seekable` | `no` via property *and* via `Media.extras` | only `Media.extras` is applied |
| `hwdec` | `no` (preview) | platform default — on Android this is **mediacodec**, which fights the full-screen player for the surface pool when the user later promotes a cell |
| `cache` | yes | yes (default), but never explicitly enabled |

`Media.extras = {'force-seekable': 'no'}` is still set in
`MpvEngine.open()` (line 103) so the seek probe is suppressed — that's
why no `"Cannot seek"` errors appear in this log. Everything else is
running on whatever defaults libmpv ships.

### 3. The cell never passes channel HTTP headers

**`lib/player.dart:427`** — full-screen reconnect path:

```dart
final headers = await Sql.getChannelHeaders(id);
await _startPlayback(null, headers: headers);
```

**`lib/multi_view_cell.dart:292`** — cell open:

```dart
await engine.open(url: ch.url ?? '');
```

No `Sql.getChannelHeaders()` lookup. M3U sources commonly encode
`http-user-agent=...`, `http-referrer=...`, `http-origin=...` directives,
and the M3U parser persists them per channel. Without these, the cell
hits the provider with mpv's generic UA. Some provider edges (and most
cloud WAFs) treat unrecognised UAs more aggressively — shorter
keepalives, faster idle disconnects, more aggressive connection cycling
on the load balancer. This matches the observed degradation pattern
exactly.

### 4. Permanent-error path leaks the engine

**`lib/multi_view_cell.dart:248-249`** — when retries are exhausted or the
error is non-transient:

```dart
// 3. Permanent or retries exhausted — surface the error UI.
setState(() { _error = true; _loading = false; });
```

The cell flips to the error UI but **does not call `_disposeEngine()`**.
The engine keeps running, keeps its TCP connection open, keeps emitting
`buffering`, `seek probe`, and even `stream completed` events into the
subscriptions. Evidence is in the log at lines 192–203 of the log file:

```
17:45:54 engine error [permanent] cell=0  ← error state set
17:45:59 engine error [permanent] cell=1
17:45:59 buffering=false cell=1            ← engine still alive
17:45:59 suppressed seek probe cell=1
17:45:59 buffering=true cell=1
17:45:59 stream completed cell=1 — retrying in 2s    ← retry scheduled but blocked
17:45:59 buffering=false cell=1
17:45:59 suppressed seek probe cell=1 (×4)
```

The retry is blocked by the `!_error` guard in the `completedStream`
listener, but everything else — the open TCP socket, the seek probes,
buffering oscillation — continues. Each leaked engine holds one of the
user's 4 provider connections until the user manually intervenes
(`17:48:36`, ~3 minutes later).

### 5. ECONNRESET retry shows duplicate-burst handling

Log lines 168–169:

```
17:45:43 engine error [transient] cell=1 retries=0/3 error="…0xffffff99"
17:45:43 engine error [transient] cell=1 retries=1/3 error="…0xffffff99"
```

Two `0xffffff99` (ECONNRESET) errors in the same second incremented the
retry counter twice. mpv emits the connection error followed by a
secondary read-failure error in the same event tick; both pass the
transient check. With `_maxTransientRetries=3`, a single TCP reset
burns 2 of the 3 retries. This is technically correct but wastes
budget — a 500ms debounce on the increment would handle it cleanly.

---

## Why this combination produces the observed cascade

1. Cell opens with mpv defaults — `cache-secs=10`, no `network-timeout`,
   default UA.
2. Provider's edge sees an unfamiliar UA and a client that draws data
   slowly (small cache → small read bursts) → edge cycles the connection
   after 30–60 s.
3. mpv reports `completed` or `ETIMEDOUT`.
4. Cell retries — usually succeeds, sometimes hits a bad edge → "Failed
   to open" → marked permanent.
5. Permanent-error path sets `_error=true` but **does not dispose the
   engine** → orphaned connection holds one of the 4 slots indefinitely.
6. The same happens on the second cell. Over ~3 minutes, both cells end
   up in permanent-error UI with two orphaned engines still consuming
   provider connections in the background — making subsequent manual
   retries (`17:48:36`, `17:49:02`) also fail with "Failed to open"
   because the user has effectively been using 2× or 3× the connections
   they think they are.

So the user's instinct is right: **the provider isn't capping them**. The
client is mis-using their connection budget by leaking engines on
permanent errors, and is provoking unnecessary disconnects by running
each cell with the wrong network defaults.

---

## Fixes

### Fix 20.1 — Apply mpv options in MultiViewCell (PRIMARY)

**File:** `lib/multi_view_cell.dart`

**Current code (lines 188-198):**

```dart
PlayerEngine engine = pickedType == EngineType.exoplayer
    ? ExoEngine()
    : MpvEngine(
        channel: ch,
        settings: widget.settings,
        fullscreenOnOpen: false,
        previewMode: true,
      );

// Volume first so the first audio packet plays at the correct level.
await engine.setVolume(widget.isFocused ? 1.0 : 0.0);
```

**Replace with:**

```dart
PlayerEngine engine = pickedType == EngineType.exoplayer
    ? ExoEngine()
    : MpvEngine(
        channel: ch,
        settings: widget.settings,
        fullscreenOnOpen: false,
        previewMode: true,
      );

// Apply mpv runtime options BEFORE open(), matching what the full-screen
// Player does at lib/player.dart:450. Without this the cell runs on mpv
// defaults (cache-secs=10, no network-timeout, default UA) instead of the
// app-tuned values (liveCacheSecs=45, network-timeout=30, miniDemuxerMaxMB
// for buffer, etc.). See fix20.md for evidence.
if (engine is MpvEngine) {
  // Per-channel headers, mainly so the M3U-declared User-Agent reaches
  // the provider. Some edges treat unfamiliar UAs aggressively (shorter
  // keepalive, faster idle disconnect) which produces the
  // stream-completed → retry → permanent-error cascade we see in logs.
  final chHeaders = await Sql.getChannelHeaders(ch.id);
  await engine.reapplyOptions(
    url: ch.url ?? '',
    ignoreSsl: chHeaders?.ignoreSSL == true,
  );
}

// Volume after options, before open(). First audio packet then plays at
// the correct level with the correct mpv config in place.
await engine.setVolume(widget.isFocused ? 1.0 : 0.0);
```

Add the required imports at the top of the file (next to the existing
imports):

```dart
import 'package:open_tv/backend/sql.dart';
```

Then update the `engine.open(...)` call at line 292 to pass HTTP headers:

**Current code (line 292):**

```dart
try {
  await engine.open(url: ch.url ?? '');
```

**Replace with:**

```dart
// Look up channel headers once and reuse for both reapplyOptions and open.
// Hoist this above reapplyOptions so we only hit SQLite once per cell open.
//
// IMPORTANT — implementer: refactor so chHeaders is fetched ONCE before the
// reapplyOptions block above, stored in a local, then reused here. The
// snippet above shows the fetch inline for clarity; the final structure
// should be:
//
//   final chHeaders = await Sql.getChannelHeaders(ch.id);
//   if (engine is MpvEngine) {
//     await engine.reapplyOptions(
//       url: ch.url ?? '',
//       ignoreSsl: chHeaders?.ignoreSSL == true,
//     );
//   }
//   await engine.setVolume(widget.isFocused ? 1.0 : 0.0);
//   // ...subscriptions...
//   final httpHeaders = chHeaders != null ? {
//     if (chHeaders.referrer != null)  'Referer':    chHeaders.referrer!,
//     if (chHeaders.httpOrigin != null) 'Origin':     chHeaders.httpOrigin!,
//     if (chHeaders.userAgent != null) 'User-Agent': chHeaders.userAgent!,
//   } : null;
//   try {
//     await engine.open(url: ch.url ?? '', headers: httpHeaders);

try {
  final httpHeaders = chHeaders != null
      ? {
          if (chHeaders.referrer != null)  'Referer':    chHeaders.referrer!,
          if (chHeaders.httpOrigin != null) 'Origin':     chHeaders.httpOrigin!,
          if (chHeaders.userAgent != null) 'User-Agent': chHeaders.userAgent!,
        }
      : null;
  await engine.open(url: ch.url ?? '', headers: httpHeaders);
```

This mirrors `lib/player.dart:442-462` exactly.

Add an import for `ChannelHttpHeaders` too if not already present:

```dart
import 'package:open_tv/models/channel_http_headers.dart';
```

### Fix 20.2 — Dispose the engine on permanent error (CRITICAL — leak)

**File:** `lib/multi_view_cell.dart`

**Current code (lines 246-250):**

```dart
      // 3. Permanent or retries exhausted — surface the error UI.
      setState(() { _error = true; _loading = false; });
    }));
```

**Replace with:**

```dart
      // 3. Permanent or retries exhausted — surface the error UI AND
      //    dispose the engine. Without disposal, the failed engine keeps
      //    its TCP connection open and continues emitting buffering,
      //    seek-probe, and completed events into the subscriptions until
      //    the user manually intervenes (sometimes minutes later). With
      //    a 4-connection provider account, two leaked cells can consume
      //    half the budget invisibly, making subsequent manual retries
      //    fail with "Failed to open" for what looks like no reason.
      setState(() { _error = true; _loading = false; });
      _disposeEngine();
    }));
```

`_disposeEngine()` increments `_openGeneration`, cancels subscriptions,
and calls `engine.dispose()` — exactly what is needed. The error-cell
UI built by `_buildErrorCell()` does not need `_engine` (it shows a
broken-image icon and a Retry button) so disposing here is safe. The
Retry button already calls `_disposeEngine()` then `_startEngine(ch)`,
so the user-facing recovery path is unchanged.

### Fix 20.3 — Debounce duplicate transient errors

**File:** `lib/multi_view_cell.dart`

mpv emits ECONNRESET twice in the same event tick (log lines 168-169),
burning two retries from a single network event. Add a 500 ms debounce
on the transient counter.

**Add a field next to the existing retry-tracking fields (around line 80):**

```dart
DateTime? _lastErrorAt;
DateTime? _lastTransientIncrementAt;   // NEW
```

**Modify the transient branch in the errorStream listener
(current lines 230-246):**

```dart
      // 2. Transient — retry up to N times with a short delay.
      if (transient && _transientRetries < _maxTransientRetries) {
        // mpv can emit two transient errors in the same event tick
        // (e.g. ECONNRESET + the subsequent read failure). Debounce so a
        // single network event doesn't burn two retries from our budget.
        final now = DateTime.now();
        if (_lastTransientIncrementAt != null &&
            now.difference(_lastTransientIncrementAt!).inMilliseconds < 500) {
          return; // already counted this burst
        }
        _lastTransientIncrementAt = now;
        _transientRetries++;
        final attempt = _transientRetries;
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && generation == _openGeneration) {
            AppLog.info(
              'MultiViewCell: retry $attempt/$_maxTransientRetries'
              ' cell=${widget.cellIndex}'
              ' channel="${ch.name}"',
            );
            _disposeEngine();
            _startEngine(ch);
          }
        });
        return;
      }
```

Also reset `_lastTransientIncrementAt = null;` in `_startEngine` next to
the existing `_lastErrorAt = null;` (line 166).

### Fix 20.4 — Reset `_lastBufferingState` and `_lastTransientIncrementAt` on dispose

**File:** `lib/multi_view_cell.dart`

`_disposeEngine` already resets `_lastBufferingState` (line 129). For
symmetry and to guarantee a fresh retry budget after dispose, also reset
`_lastTransientIncrementAt`:

**Current code (lines 122-141):**

```dart
  void _disposeEngine() {
    AppLog.info(
      'MultiViewCell: disposing engine'
      ' cell=${widget.cellIndex}'
      ' channel="${widget.channel?.name ?? 'empty'}"',
    );
    _openGeneration++;
    for (final s in _engineSubs) {
      unawaited(s.cancel());
    }
    _engineSubs.clear();
    final e = _engine;
    _engine = null;
    _lastBufferingState = null;
    if (e != null) {
      // ...
    }
  }
```

**Add one line after `_lastBufferingState = null;`:**

```dart
    _lastBufferingState = null;
    _lastTransientIncrementAt = null;   // NEW
```

### Fix 20.5 — Use settings.streamCompletedDelayMs in cell (consistency)

**File:** `lib/multi_view_cell.dart`

The comment at line 260 says the 2 s delay "matches streamCompletedDelayMs
default" but the value is hardcoded. The full-screen player reads the
setting (`lib/player.dart:250`). The cell should too — otherwise users
who lower the slider for the main player will see no effect in multi-view.

**Current code (lines 252-267):**

```dart
    _engineSubs.add(engine.completedStream.listen((done) {
      if (!done) return;
      AppLog.info(
        'MultiViewCell: stream completed'
        ' cell=${widget.cellIndex}'
        ' channel="${ch.name}"'
        ' — retrying in 2s',
      );
      // Single silent retry after 2 s (matches streamCompletedDelayMs default).
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && generation == _openGeneration && !_error) {
          _disposeEngine();
          _startEngine(ch);
        }
      });
    }));
```

**Replace with:**

```dart
    _engineSubs.add(engine.completedStream.listen((done) {
      if (!done) return;
      final delayMs = widget.settings.streamCompletedDelayMs;
      AppLog.info(
        'MultiViewCell: stream completed'
        ' cell=${widget.cellIndex}'
        ' channel="${ch.name}"'
        ' — retrying in ${delayMs}ms',
      );
      // Single silent retry — honours the user's streamCompletedDelayMs
      // setting (same as full-screen Player at lib/player.dart:250).
      Future.delayed(Duration(milliseconds: delayMs), () {
        if (mounted && generation == _openGeneration && !_error) {
          _disposeEngine();
          _startEngine(ch);
        }
      });
    }));
```

---

## Expected behaviour after fix

For the same scenario as the log:

1. Both cells open with `cache-secs=45`, `network-timeout=30`,
   `demuxer-max-bytes=48MiB`, `hwdec=no` (software decode), and the
   provider-declared User-Agent.
2. Server-initiated EOFs ("stream completed") still happen because the
   provider's edge cycles connections — that's not in our control. But
   the larger cache and explicit network-timeout reduce the rate of
   spurious `ETIMEDOUT` and improve retry success.
3. When a retry does hit a bad edge and "Failed to open" fires, the
   cell disposes the engine immediately — no leaked TCP connection, no
   stealth consumption of the 4-connection budget.
4. ECONNRESET bursts consume one retry slot, not two.
5. The retry delay honours the user's `streamCompletedDelayMs` slider.

Net effect: with 4 provider connections, both cells should sustain
indefinitely under normal network conditions. Even when individual
reconnects fail, the cell recovers cleanly without zombie engines
poisoning the connection pool.

---

## Test plan

1. Apply all five fixes, rebuild.
2. Enable debug logging.
3. Open 1×2 multi-view with the same two channels from the log
   (Yankees + WSOC).
4. Let it run 5+ minutes. **Expected:** no `engine error [permanent]`
   events; at most occasional `stream completed` followed by clean
   retry; no `Failed to open` cascades.
5. Inspect log for one line per cell open:
   `MpvEngine: options applied channel="..." previewMode=true demuxerMB=48 ...`
   — confirms `reapplyOptions` is running on cell startup.
6. Force a permanent error: edit the channel URL to a bogus host,
   reopen. **Expected:** cell shows the error UI, log shows
   `MultiViewCell: disposing engine` **immediately** after the
   permanent-error log line, and no further events from that cell.
7. Stress test: open 2×2 on a device that supports it. Confirm no more
   than 4 active TCP connections to the provider during a 10-minute
   session (check via `adb shell ss -tn | grep media4u | wc -l` or
   equivalent).

---

## Why this wasn't caught earlier

Multi-view shipped recently (1.15.x). The full-screen path and the
multi-view cell path were developed against the same `MpvEngine` but
the multi-view cell took the shortcut of skipping the
`reapplyOptions()` step because the cell is "just a small preview".
That assumption is fine for the buffer-size halving but doesn't hold
for network-layer settings — those matter exactly the same regardless
of pixel count.

The leaked-engine-on-permanent-error issue is masked in single-stream
testing because the user only has one stream open, sees the error,
taps Retry, the engine is disposed at that point, and the symptom is
gone. It only becomes a connection-budget problem in multi-view where
multiple cells can leak simultaneously and the user may not retry them
individually for several minutes.
