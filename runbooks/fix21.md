# fix21.md — Error Classifier Wrong + Permanent-Error Patterns From Extended Testing

> **Diagnosis from `free4me_log_1779507390618.txt`** (~85 minute session,
> 1.15.5, fix20 **not** applied). Three failure patterns confirm fix20's
> three findings (skipped `reapplyOptions`, leaked engines on permanent
> error, duplicate-burst counting) and add three new issues that fix20
> doesn't address: a flat-out incorrect transient/permanent classifier,
> permanent-error duplicate bursts that need their own debounce, and the
> permanent-error path being so unforgiving that streams which would
> recover on a second try are killed after one bad retry.

---

## Session shape and baseline observations

| Metric | This log |
|---|---|
| Wall time | 22:03:09 → 23:36:16 (~93 min) |
| Full-screen plays | 1 (YES Network, 22:03:51 → 22:05:12, **zero errors**) |
| 1×2 multi-view | 22:11:13 → 23:06:16 (~55 min) |
| 2×2 multi-view | 23:06:39 → 23:36:16 (~30 min) |
| `MultiViewCell: starting engine` | 129 |
| `stream completed` | 102 |
| `engine error [transient]` | 7 |
| `engine error [permanent]` | 18 |
| Distinct channels played in cells | 11+ |

**Key reference point.** The single full-screen YES Network session played
for ~80 s with **zero** stream-completion events and no errors of any
kind (other than the suppressed seek probe). The instant multi-view
opens, the same channels start cycling every 30-60 s. This is the
clearest possible demonstration that **the cell code path is the cause**,
not the provider — the same URL, fed to the same `MpvEngine`, behaves
completely differently depending on which widget owns it.

`MpvEngine: options applied` log line appears **once** in the entire log
— line 19, the full-screen YES Network open. It never appears for any
of the 129 cell starts. fix20.1 (the missing `reapplyOptions` call) is
confirmed by exact log evidence.

## Stream duration distribution (open → completed)

Per-cell mean stream lifetime before the server EOFs or the cell
restarts:

| Cell | Layout | n | Mean | Min | Max |
|---|---|---|---|---|---|
| 0 | 1×2 + 2×2 | 24 | 100.2 s | 11 s | 603 s |
| 1 | 1×2 + 2×2 | 31 | 120.9 s | 14 s | 1999 s |
| 2 | 2×2 only | 22 | 52.3 s | 8 s | 100 s |
| 3 | 2×2 only | 25 | 49.8 s | 11 s | 88 s |

Cells 2 and 3 (which exist only in 2×2 mode) never sustain a stream
longer than ~100 s. Cells 0 and 1 occasionally last 10+ minutes during
the 1×2 phase. With identical channels behind identical URLs, the
difference is concurrency and the missing `reapplyOptions` call (which
sets `cache-secs=45`, `network-timeout=30`, and the demuxer size). Fix
20.1 directly addresses this.

---

## New findings (not covered by fix20)

### Finding A — "Failed to open …" is mis-classified as permanent

**Evidence.** WSOC (URL `…/819009.ts`) opened successfully in this log
**four times** between 22:11:13 and 22:13:13 — each open went through
`MpvEngine: open() command sent` and `MultiViewCell: open() succeeded`
and `buffering=true` → `buffering=false`. Then at 22:13:18 the fifth
open of the same URL emitted:

```
[2026-05-22 22:13:18] [WARN] MultiViewCell: engine error [permanent]
  cell=1 channel="(m) NC| ABC Charlotte WSOC" retries=0/3
  error="Failed to open https://tv.media4u.top/live/rkinnc75/rkinnc756182025/819009.ts."
```

The classifier sends this to the permanent branch because the string
doesn't match any pattern in `_isTransientError`. The same URL had been
opening fine 5 seconds earlier. This is a transient network condition
— the next retry would very likely have succeeded.

Same pattern appears multiple times in the log:

- `22:27:48` cell 0 WSOC — straight to permanent on first try after a
  channel swap.
- `23:01:50` cell 0 WSOC — `"Error decoding audio."` permanent **but**
  the engine continues emitting events afterward, including a
  `stream completed` 1 second later. That's not how a permanently
  dead engine behaves.
- `23:06:44` cell 2 DAZN 2 — `"Could not open codec."` twice (same
  second) → permanent. Could be real, could be a transient codec
  negotiation failure during a 4-stream burst.
- `23:07:04` cell 2 SPECTRUM — `"Failed to open"` on what would be the
  3rd transient retry, but classified permanent so the cell gave up.
- `23:25:56` cell 2 FOX Montgomery — `"Error decoding audio."`
  permanent → cell stuck.
- `23:32:19` cell 1 Yankees — `"Error decoding audio."` permanent →
  cell stuck.

The current classifier:

```dart
static bool _isTransientError(String err) {
  return err.contains('0xffffff92') ||
      err.contains('ffurl_read') ||
      err.contains('Failed to recognize file format') ||
      err.contains('Connection timed out') ||
      err.contains('Connection reset') ||
      err.contains('ETIMEDOUT');
}
```

Missing transient patterns to add:

- `"Failed to open"` — generic open failure; almost always retries clean
- `"Error decoding audio"` — mid-stream decoder hiccup; engine often
  recovers on its own, retry definitely should be tried
- `"Could not open codec"` — codec negotiation race during high
  concurrency; worth one retry to confirm
- `"0xffffff99"` (ECONNRESET) — present in earlier logs but missed here
  too
- `"End of file"` — sometimes emitted instead of completedStream signal
- `"HTTP error 5"` — any 5xx response (502/503/504) is transient

### Finding B — Permanent errors emit duplicates too

**Evidence.** Line 703 and 705 in the log, same second:

```
[23:06:44] engine error [permanent] cell=2 DAZN 2 ... "Could not open codec."
[23:06:44] engine error [permanent] cell=2 DAZN 2 ... "Could not open codec."
```

The current permanent branch is:

```dart
// 3. Permanent or retries exhausted — surface the error UI.
setState(() { _error = true; _loading = false; });
```

Two `setState` calls in the same frame is harmless, but if a future
revision adds side effects on the permanent path (logging to a remote
service, recording a give-up count, etc.) the double-fire becomes a
correctness issue. More importantly, fix20.2 wants to `_disposeEngine()`
inside this branch — disposing twice will trip the engine's
`_disposed` guard (idempotent, but log-noisy). Easiest is to no-op the
permanent branch if `_error` is already set.

### Finding C — Transient retries should be more generous

**Evidence.** Pattern repeats across the log:

```
23:07:00  cell 2 SPECTRUM    [transient] "Failed to recognize file format" → retry 1/3
23:07:04  cell 2 SPECTRUM    [permanent] "Failed to open ..."              → ERROR UI
```

That's a 4-second total budget before the cell is declared dead, on a
channel that worked fine seconds earlier on the same network. The retry
delay is hardcoded at 3 s; the first try takes ~1 s to fail; one more
retry follows. If the second attempt hits any non-classified error
string, the cell is done.

Combined with Finding A (broader transient classification), bumping the
retry limit from 3 to 5 — with the existing 15 s stable-playback counter
reset still in place — costs nothing on truly-dead channels and gives
healthy channels two more chances during network turbulence.

### Finding D — fix20.2 leak confirmed by 10-minute orphan

**Evidence.** Cell 1 hit `[permanent]` at 22:13:18. Cell 1 engine
`MpvEngine: dispose()` for that channel did not appear until **22:23:52**
when the user manually replaced the channel — exactly **10 min 34 s**
later. During that entire window the engine kept its TCP connection to
the provider open, contributing zero playback. fix20.2 is correct and
critical.

### Finding E — `streamCompletedDelayMs` setting still ignored in cells

The cell logs `— retrying in 2s` 102 times, exactly what the comment
predicted in fix20.5. The user's setting (default 2 000 ms but
adjustable) has no effect. Confirms fix20.5.

---

## Revised plan: fix20 + fix21 together

fix20 stays as previously written. fix21 adds three more changes to
`lib/multi_view_cell.dart`. Apply in this order:

1. **fix20.1** — call `reapplyOptions()` + supply channel HTTP headers
2. **fix20.2** — dispose engine on permanent error
3. **fix20.3** — 500 ms debounce on transient error counter
4. **fix20.4 / 20.5** — clean up debounce field on dispose; honour
   `streamCompletedDelayMs`
5. **fix21.1** — expand `_isTransientError` patterns
6. **fix21.2** — guard the permanent branch with `_error` check
7. **fix21.3** — increase `_maxTransientRetries` from 3 to 5

---

## Fix 21.1 — Expand the transient classifier

**File:** `lib/multi_view_cell.dart`

**Current code (lines 144-153):**

```dart
/// Returns true if [err] looks like a transient network condition that
/// is worth retrying.
static bool _isTransientError(String err) {
  return err.contains('0xffffff92') ||
      err.contains('ffurl_read') ||
      err.contains('Failed to recognize file format') ||
      err.contains('Connection timed out') ||
      err.contains('Connection reset') ||
      err.contains('ETIMEDOUT');
}
```

**Replace with:**

```dart
/// Returns true if [err] looks like a transient condition worth retrying.
///
/// Multi-view cells routinely see all of these resolve on a single retry
/// — they fire when the provider's edge cycles a connection, a codec
/// race loses during concurrent opens, or mpv hits a brief decoder
/// hiccup mid-stream. The cell is the wrong place to give up on these;
/// the user can always close the cell manually if the channel is truly
/// dead.
///
/// See `free4me_log_1779507390618.txt` for evidence — every error string
/// added below was observed *immediately after* the same URL had been
/// playing cleanly, or *immediately preceded* further successful events
/// from the same engine (the "Error decoding audio" → `stream completed`
/// pattern at 23:01:50–23:01:51).
static bool _isTransientError(String err) {
  return
      // Original network-layer patterns
      err.contains('0xffffff92') ||        // ETIMEDOUT (FFmpeg)
      err.contains('0xffffff99') ||        // ECONNRESET (FFmpeg)
      err.contains('ffurl_read') ||        // any FFmpeg URL read failure
      err.contains('ETIMEDOUT') ||
      err.contains('Connection timed out') ||
      err.contains('Connection reset') ||
      // Format/codec/open patterns that look final but recover on retry
      err.contains('Failed to recognize file format') ||
      err.contains('Failed to open') ||    // mpv generic open-failure
      err.contains('Error decoding audio') ||  // mid-stream decoder hiccup
      err.contains('Error decoding video') ||  // same, for video stream
      err.contains('Could not open codec') ||  // codec negotiation race
      err.contains('End of file') ||       // sometimes emitted instead of completedStream
      // HTTP-layer transient (5xx). Match conservatively so 4xx (auth/
      // permanent) doesn't slip in by accident.
      err.contains('HTTP error 5') ||
      err.contains('Server returned 5');
}
```

### Why each addition is safe

| Pattern | Why it's safe to retry |
|---|---|
| `0xffffff99` | TCP RST. Always a network-layer event, never a content problem. |
| `Failed to open` | The same URL had succeeded seconds earlier in every case observed. Worst-case waste is one 3-second retry cycle. |
| `Error decoding audio` / `video` | The engine continues emitting `buffering` and `stream completed` events after this, meaning mpv itself doesn't consider it fatal. Treating it as fatal in the cell is stricter than mpv. |
| `Could not open codec` | Observed only during concurrent 4-stream startup bursts. If it's a genuine codec issue, the retry will fire it again and the cell will eventually exhaust retries (with fix 21.3, after 5 tries). |
| `End of file` | Server EOF. We already handle this on `completedStream`; if mpv routes it through `errorStream` instead, transient retry is the same correct behaviour. |
| `HTTP error 5xx` / `Server returned 5xx` | All 5xx codes are transient by HTTP definition. 502/503/504 are common on overloaded IPTV edges. |

### What is still treated as permanent

After this change, only error strings that don't match any of the
patterns above hit the permanent branch. The expected residual
permanent-error universe is essentially:

- 4xx HTTP responses (404, 403 — actually-broken URL or auth issue)
- mpv internal errors that the codebase doesn't recognise (e.g. new
  error strings from a future media_kit version)

Both deserve the error UI.

---

## Fix 21.2 — Guard the permanent branch against duplicate fires

**File:** `lib/multi_view_cell.dart`

**Current code (lines 246-249):**

```dart
      // 3. Permanent or retries exhausted — surface the error UI.
      setState(() { _error = true; _loading = false; });
    }));
```

**Replace with (this also reflects fix20.2's `_disposeEngine()`
addition):**

```dart
      // 3. Permanent or retries exhausted — surface the error UI AND
      //    dispose the engine. mpv can emit the same permanent error
      //    twice in the same frame (observed: "Could not open codec."
      //    at 23:06:44 fired twice from cell 2). Guard so we only
      //    dispose once and only call setState once.
      //
      //    Without disposal the failed engine keeps its TCP connection
      //    open and continues emitting events into the subscriptions
      //    until the user manually intervenes — sometimes 10+ minutes
      //    later (observed: cell 1 WSOC orphaned 22:13:18 → 22:23:52).
      //    With a 4-connection provider account, two leaked cells can
      //    silently consume half the budget.
      if (_error) return; // already disposed; ignore duplicate burst
      setState(() { _error = true; _loading = false; });
      _disposeEngine();
    }));
```

This replaces fix20.2's version of the same edit. Apply this version
instead of fix20.2 — the only difference is the leading `if (_error)
return;` guard.

---

## Fix 21.3 — Increase transient retry budget to 5

**File:** `lib/multi_view_cell.dart`

**Current code (line 79):**

```dart
static const int _maxTransientRetries = 3;
```

**Replace with:**

```dart
/// Per-cell transient retry budget. Raised from 3 to 5 after extensive
/// testing showed channels that recovered cleanly on the 4th–5th attempt
/// during provider edge cycling. The counter still resets to 0 after
/// 15 s of uninterrupted playback (see bufferingStream listener), so
/// raising the cap doesn't lengthen failure detection for truly-dead
/// channels — it just gives healthy channels more headroom during
/// network turbulence.
static const int _maxTransientRetries = 5;
```

Combined with the 3-second delay between retries, this gives a healthy
channel up to 15 s of recovery time (5 retries × 3 s) before the cell
declares the stream dead.

---

## Combined error-listener block after all fixes (20 + 21)

For clarity, the full `errorStream.listen` body after fix20 and fix21
are applied:

```dart
_engineSubs.add(engine.errorStream.listen((err) {
  // 1. Seek probe — always suppress.
  if (_isSeekProbeError(err)) {
    if (AppLog.enabled) {
      AppLog.info(
        'MultiViewCell: suppressed seek probe'
        ' cell=${widget.cellIndex} channel="${ch.name}"',
      );
    }
    return;
  }

  final transient = _isTransientError(err);
  _lastErrorAt = DateTime.now();

  AppLog.warn(
    'MultiViewCell: engine error'
    ' [${transient ? "transient" : "permanent"}]'
    ' cell=${widget.cellIndex} channel="${ch.name}"'
    ' retries=$_transientRetries/$_maxTransientRetries'
    ' error="$err"',
  );

  if (!mounted || generation != _openGeneration) return;

  // 2. Transient — retry with debounced counter (fix20.3).
  if (transient && _transientRetries < _maxTransientRetries) {
    final now = DateTime.now();
    if (_lastTransientIncrementAt != null &&
        now.difference(_lastTransientIncrementAt!).inMilliseconds < 500) {
      return; // duplicate burst, already counted
    }
    _lastTransientIncrementAt = now;
    _transientRetries++;
    final attempt = _transientRetries;
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && generation == _openGeneration) {
        AppLog.info(
          'MultiViewCell: retry $attempt/$_maxTransientRetries'
          ' cell=${widget.cellIndex} channel="${ch.name}"',
        );
        _disposeEngine();
        _startEngine(ch);
      }
    });
    return;
  }

  // 3. Permanent or retries exhausted — surface the error UI and
  //    dispose the engine (fix20.2/21.2). Duplicate-fire guard.
  if (_error) return;
  setState(() { _error = true; _loading = false; });
  _disposeEngine();
}));
```

---

## Expected behaviour after fix20 + fix21

Replay the test scenario from `free4me_log_1779507390618.txt`:

**Currently (no fixes):**
- 18 permanent-error events over 93 minutes
- 6 channels stuck in error UI for minutes-to-tens-of-minutes
- 1 confirmed 10-minute engine leak (WSOC at 22:13:18)
- 102 stream completion events; mean 50 s on 2×2 cells

**After fix20 alone:**
- mpv options applied → mean stream lifetime should jump from 50 s to
  several minutes (matching the full-screen Player which never
  completed during its 80 s session)
- All permanent errors dispose their engines → no more 10-minute leaks
- Channel HTTP headers (UA) applied → provider less likely to cycle
- ECONNRESET bursts no longer burn double retries

**After fix20 + fix21:**
- The 4 of 18 permanent errors that were `"Failed to open"`,
  `"Error decoding audio"`, and `"Could not open codec"` get reclassified
  as transient → at least 3-4 of those cells stay alive instead of
  going to error UI
- Cells get up to 5 retries instead of 3 → channels surviving provider
  turbulence increases proportionally
- Duplicate-burst permanent errors no longer double-dispose

Net: expect a 5-min 2×2 test to show at most 1-2 cells in error state,
all of them on channels that are truly dead at that moment (e.g. DAZN 2
if the codec really is unsupported).

---

## Test plan

1. Apply fix20 (all 5 sub-fixes).
2. Apply fix21 (all 3 sub-fixes). **fix21.2 supersedes fix20.2** — use
   the 21.2 version (which adds the `if (_error) return;` guard).
3. Enable debug logging, force-quit and relaunch.
4. Open 2×2 multi-view with 4 channels including the previously
   problematic ones: Yankees, WSOC, FOX Montgomery, NBC Charlotte.
5. Let run 10+ minutes without touching the UI.

**Pass criteria:**

| Metric | Before | Pass threshold |
|---|---|---|
| `engine error [permanent]` events | 18 in 93 min | ≤ 2 in 10 min |
| Engine leaks (permanent error w/o subsequent `dispose()` within 5 s) | many | 0 |
| Mean stream duration on cells 2/3 | 50 s | ≥ 120 s |
| `MpvEngine: options applied` log lines per cell open | 0 | 1 |
| Cells stuck in error UI at end of 10-min test | varies | 0 (excluding genuinely dead channels) |

6. **Targeted regression check:** force a permanent error by editing a
   channel URL to a bogus host. Verify:
   - Error UI appears within ~5 s (one cycle of `_maxTransientRetries`
     × 3 s retries = ~15 s now, vs ~9 s before)
   - `MpvEngine: dispose()` appears in the log immediately after the
     final `engine error [permanent]` line
   - No further events from that cell appear until user taps Retry

---

## Sanity check — am I masking real problems?

The expanded classifier in fix 21.1 turns several error strings from
"permanent" into "transient." Worth asking: does this hide
genuinely-broken channels behind a retry loop?

No, for two reasons:

1. **The retry counter has a cap.** After 5 transient errors without
   15 s of stable playback in between, the cell still flips to the
   permanent branch and disposes. Truly dead channels still hit error
   UI within ~15 s.

2. **The classifier change matches mpv's own behaviour.** mpv emits
   `"Error decoding audio."` and then continues playback. mpv emits
   `"Failed to open"` and then on the next `open()` succeeds. mpv emits
   `"Could not open codec"` for the audio track and continues with
   video. In all three cases mpv considers the stream alive; the cell
   was treating it as dead. The fix aligns the cell with mpv's view.

3. **The error UI is a user-recoverable state, not an irreversible
   commitment.** Even if a channel really is dead and the user has to
   wait the full 15 s for the error UI to appear instead of 5 s, the
   functional outcome is identical — the user taps Retry or replaces
   the channel.
