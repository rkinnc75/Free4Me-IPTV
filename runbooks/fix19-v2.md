# fix19.md (v2) — Critical Re-evaluation + Codebase Scan

> **This supersedes the previous fix19.** Opus re-evaluation found two
> incorrect fixes in v1 that would have introduced new bugs, and several
> additional issues from a static scan.

---

## Status of v1 fixes after re-evaluation

| # | Issue | v1 Verdict | v2 Action |
|---|---|---|---|
| 1 | Seek not suppressed in cell | ✓ Correct | Keep as-is |
| 2 | No auto-retry for tcp errors | ⚠ Missing retry counter | Add counter (3 max) |
| 3 | Double dispose root cause | ✗ WRONG diagnosis | Remove the `if (!exiting)` guard — it would leak the engine on every normal exit |
| 4 | `_disposed` flag in MpvEngine | ✓ Correct | Keep — this alone resolves the symptom |
| 5 | "nulls" in log | ✓ Correct | Keep |
| 6 | Skip first buffering=false | ⚠ Risky | Change approach — filter duplicates |
| 7 | DeviceMemory never logs | ✓ Correct symptom, wrong cause | Fix log init ordering |
| 8 | Settings: loaded missing | Same as 7 | Same fix |
| 9 | EnginePicker bypassed | ✓ Correct | Keep with ExoPlayer fallback |
| 10 | Overlay previewMode=false | ✓ Correct | Keep — highest impact |

Plus **5 new findings** from the static scan (Issues 11–15).

---

## Issue 1 — Seek suppression in MultiViewCell ✓ keep v1 fix

No change from v1.

---

## Issue 2 — Auto-retry needs a counter (revised)

### Problem with v1 fix

The proposed transient error classification triggers a 3-second retry
on every `errorStream` event matching the transient pattern. With no
counter, a permanently broken stream that always emits `ETIMEDOUT` will
retry **forever**. Each retry creates a new engine, more network load,
more battery drain.

### Revised fix — `lib/multi_view_cell.dart`

Add a per-cell retry counter that resets on stable playback:

```dart
int _transientRetries = 0;
static const int _maxTransientRetries = 3;
DateTime? _lastErrorAt;

// In _startEngine, reset counter when starting a new channel:
Future<void> _startEngine(Channel ch) async {
  // ... existing setup ...
  _transientRetries = 0;
  _lastErrorAt = null;
  // ... rest ...
}

// In the buffering listener, reset counter after stable playback:
engine.bufferingStream.listen((buffering) {
  if (!buffering &&
      _lastErrorAt != null &&
      DateTime.now().difference(_lastErrorAt!).inSeconds > 15) {
    // 15 s of stable playback after an error — reset counter
    _transientRetries = 0;
    _lastErrorAt = null;
  }
  // ... existing buffering log ...
});

// In the error listener:
engine.errorStream.listen((err) {
  // 1. Seek probe — always suppress (Issue 1 fix)
  if (err.contains('Cannot seek in this stream') ||
      err.contains('force-seekable=yes')) {
    if (AppLog.enabled) {
      AppLog.info('MultiViewCell: suppressed seek probe'
        ' cell=${widget.cellIndex} channel="${ch.name}"');
    }
    return;
  }

  // 2. Transient network errors — retry up to N times
  final isTransient = err.contains('0xffffff92') ||
      err.contains('ffurl_read') ||
      err.contains('Failed to recognize file format') ||
      err.contains('Connection timed out') ||
      err.contains('Connection reset');

  _lastErrorAt = DateTime.now();

  AppLog.warn(
    'MultiViewCell: engine error'
    ' [${isTransient ? "transient" : "permanent"}]'
    ' cell=${widget.cellIndex}'
    ' channel="${ch.name}"'
    ' retries=$_transientRetries/$_maxTransientRetries'
    ' error="$err"',
  );

  if (!mounted || generation != _openGeneration) return;

  if (isTransient && _transientRetries < _maxTransientRetries) {
    _transientRetries++;
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && generation == _openGeneration) {
        AppLog.info(
          'MultiViewCell: retry ${_transientRetries}/${_maxTransientRetries}'
          ' cell=${widget.cellIndex} channel="${ch.name}"',
        );
        _disposeEngine();
        _startEngine(ch);
      }
    });
  } else {
    setState(() { _error = true; _loading = false; });
  }
});
```

---

## Issue 3/4 — Double dispose (revised)

### Why v1 Issue 3 fix was WRONG

The proposed `if (!exiting) _engine.dispose()` guard in `Player.dispose()`
would prevent the engine from being disposed on every normal exit, because
`onExit()` sets `exiting = true` then calls `Navigator.pop()` which triggers
Flutter to call `dispose()`. The guard would then skip the disposal —
leaking the entire engine, its native mpv instance, its texture, and its
~192 MB buffer on every channel close.

### Correct root cause

The triple dispose in the log is **delayed Flutter widget disposal of
already-replaced widgets**. When `_swap()` pops the old Player and pushes
a new one, the old widget's `dispose()` doesn't run immediately — Flutter
defers it. 8+ minutes later when the next exit happens, those orphaned
disposals all fire in sequence. The `OverlayController`'s `stale engine,
ignored` log confirms this — those calls reference engines that have
already been replaced.

This is actually **benign for memory** as long as `MpvEngine.dispose()`
is idempotent. The only fix needed is Issue 4.

### Revised fix — `_disposed` flag only

```dart
// In MpvEngine:
bool _disposed = false;

@override
Future<void> dispose() async {
  if (_disposed) {
    if (AppLog.enabled) {
      AppLog.info(
        'MpvEngine: dispose() called twice — ignoring'
        ' channel="${channel.name}"',
      );
    }
    return;
  }
  _disposed = true;
  AppLog.info(
    'MpvEngine: dispose()'
    ' channel="${channel.name}"'
    ' previewMode=$previewMode',
  );
  for (final s in _subs) await s.cancel();
  await _bufferingCtrl.close();
  await _completedCtrl.close();
  await _errorCtrl.close();
  await _positionCtrl.close();
  await _player.dispose();
}
```

**Do NOT add the `if (!exiting)` guard to `Player.dispose()`** — that was
the v1 mistake.

---

## Issue 5 — "nulls" log fix ✓ keep v1 fix

No change.

---

## Issue 6 — Buffering false on init (revised)

### Why v1 fix was risky

`!buffering && !_seenFirstBuffering` skips the FIRST buffering=false event
unconditionally. If the engine takes a brief moment to start buffering and
emits `false → true → false`, the v1 fix would swallow the initial `false`
correctly. But if the first real event is genuinely `false` (stream
already cached, e.g. on rapid channel switching), it would be silently
dropped and the cell would appear stuck loading.

### Revised fix — log only state changes

A safer approach: track the last buffering state and only log on actual
transitions, not synthetic re-emissions:

```dart
bool? _lastBufferingState;

engine.bufferingStream.listen((buffering) {
  if (buffering == _lastBufferingState) return; // skip duplicates
  _lastBufferingState = buffering;
  if (AppLog.enabled) {
    AppLog.info(
      'MultiViewCell: buffering=$buffering'
      ' cell=${widget.cellIndex}'
      ' channel="${ch.name}"',
    );
  }
});
```

This is a log-noise fix only — it doesn't change functional behaviour.

---

## Issue 7/8 — DeviceMemory and Settings not logging (revised)

### Real root cause

`main.dart` line 46 calls `AppLog.setEnabled(settings.debugLogging)` AFTER
`DeviceMemory.init()` (line 34) and `SettingsService.getSettings()` (line 38)
have already run. So when those subsystems log their initialisation,
`AppLog.enabled` is `false` and the messages are silently dropped (the
gate at app_logger.dart:46 returns early).

### Fix — `lib/main.dart`, reorder startup

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await Workmanager().initialize(callbackDispatcher);

  // 1. Load settings FIRST so we know if debug logging is enabled.
  //    Pass null DeviceMemory defaults; they'll be re-evaluated below.
  final settings = await SettingsService.getSettings();

  // 2. Enable logging BEFORE any subsystem that wants to log.
  await AppLog.setEnabled(settings.debugLogging);

  // 3. Now initialise DeviceMemory — its log line will appear.
  await DeviceMemory.init();

  // 4. Re-read settings to pick up RAM-aware defaults that
  //    DeviceMemory.init() may have established. (Cheap, cached.)
  final settingsWithRam = await SettingsService.getSettings();

  // 5. Log the loaded settings now that AppLog is on.
  AppLog.info(
    'Settings: loaded'
    ' bufferSizeMB=${settingsWithRam.bufferSizeMB}'
    ' liveDemuxerMaxMB=${settingsWithRam.liveDemuxerMaxMB}'
    ' miniDemuxerMaxMB=${settingsWithRam.miniDemuxerMaxMB}'
    ' multiViewLayout=${settingsWithRam.multiViewLayout.name}',
  );

  // 6. Remaining startup work.
  final remainingResults = await Future.wait([
    Sql.hasSources(),
    Utils.hasTouchScreen(),
    DeviceDetector.isTV(),
  ]);
  final hasSources = remainingResults[0] as bool;
  final hasTouchScreen = remainingResults[1] as bool;
  final isTV = remainingResults[2] as bool;

  final packageInfo = await PackageInfo.fromPlatform();
  AppLog.info(
    'App started — version=${packageInfo.version}'
    ' build=${packageInfo.buildNumber}',
  );

  unawaited(EpgService.scheduleBackgroundRefresh());
  runApp(MyApp(...));
}
```

---

## Issue 9 — EnginePicker bypassed in cells ✓ keep v1 fix

No change.

---

## Issue 10 — Overlay previewMode=false ✓ keep v1 fix

One-line fix. Highest impact. This is the single most important change
in this whole runbook — it directly fixes the bandwidth contention root
cause that drives most of the tcp ETIMEDOUT errors.

---

## NEW Issue 11 — MultiViewCell stream subscriptions never tracked

### Finding

`MultiViewCell._startEngine()` calls `engine.errorStream.listen()`,
`engine.completedStream.listen()`, and `engine.bufferingStream.listen()`
but never stores the returned `StreamSubscription` objects. They can
never be cancelled.

```dart
// Current (lines 134, 146, 163 of multi_view_cell.dart):
engine.errorStream.listen((err) { ... });        // ← subscription lost
engine.completedStream.listen((done) { ... });   // ← subscription lost
engine.bufferingStream.listen((buffering) { ... }); // ← subscription lost
```

When `engine.dispose()` is called the underlying controllers close, so
the listeners DO go away — but only via stream closure, not via explicit
cancellation. If `dispose()` is ever skipped (e.g. exception during
teardown), the subscriptions leak and continue to fire callbacks that
reference a disposed widget.

### Fix

```dart
// Add as state field:
final List<StreamSubscription<dynamic>> _engineSubs = [];

// In _startEngine, store each subscription:
_engineSubs.add(engine.errorStream.listen((err) { ... }));
_engineSubs.add(engine.completedStream.listen((done) { ... }));
_engineSubs.add(engine.bufferingStream.listen((buffering) { ... }));

// In _disposeEngine, cancel them first:
void _disposeEngine() {
  _openGeneration++;
  for (final s in _engineSubs) {
    unawaited(s.cancel());
  }
  _engineSubs.clear();
  final e = _engine;
  _engine = null;
  if (e != null) unawaited(e.dispose());
}
```

This mirrors the pattern already used in `MpvEngine` (line 50: `final
List<StreamSubscription<dynamic>> _subs = []`) and `player.dart`
(`_engineSubs`).

---

## NEW Issue 12 — Silent catch swallows all errors in 4 files

### Findings from static scan

Four files use `catch (_) { }` which silently swallows ALL errors,
including programming errors:

- `lib/backend/xtream.dart`
- `lib/backend/stream_scanner.dart`
- `lib/backend/catchup_url.dart`
- `lib/player/pip_controller.dart`
- `lib/player/cast_controller.dart`

### Fix — log silently caught errors

```dart
// Replace patterns like:
} catch (_) {}

// With:
} catch (e) {
  if (AppLog.enabled) {
    AppLog.warn('Subsystem: silent error in operation — $e');
  }
}
```

This change is non-functional but means hidden errors become visible in
debug logs. Use case-by-case judgment on which message to log; for
`stream_scanner._probe()`, for example, an error legitimately means
"stream failed validation" and is the expected outcome — but it's still
useful to know what error caused the fail.

---

## NEW Issue 13 — `setState` after `await` without `mounted` check

### Findings from static scan

- `lib/player.dart` — one location
- `lib/views/epg_channel_mapping.dart` — two locations

After `await`, the widget may have been disposed. Calling `setState`
on a disposed widget throws `setState() called after dispose()` in
debug mode and is a no-op (potential memory issue) in release.

### Fix — add `if (!mounted) return` after every `await` in
StatefulWidget methods that subsequently call `setState`:

```dart
// Pattern:
await someFuture();
if (!mounted) return;
setState(() { ... });
```

Specific locations to audit — grep for `await ` followed by `setState`
in player.dart and views/epg_channel_mapping.dart.

---

## NEW Issue 14 — `MpvEngine` has 4 `listen()` but only 1 `cancel()` site

### Finding

`MpvEngine` lines 60–63 add 4 subscriptions to `_subs`. Line 125–126
cancels them. The static scan flagged this as 4 vs 1 because the cancel
is inside a loop — false positive. **Not a real bug.**

But the same scan caught the MultiViewCell leak (Issue 11) which IS real.
Keep this here for transparency that the scan was checked.

---

## NEW Issue 15 — `unawaited()` used heavily without error handling

### Finding

`multi_view_cell.dart` uses `unawaited(engine.dispose())` 4 times. If
`engine.dispose()` throws (rare but possible — e.g. native crash), the
exception is silently discarded.

### Fix — wrap critical unawaited calls

```dart
// Wrap with .catchError to at least log:
unawaited(engine.dispose().catchError((e) {
  AppLog.warn('MultiViewCell: dispose error — $e');
}));
```

Low priority. Cosmetic / observability improvement.

---

## Recommended apply order

Apply in this order — high-impact first, cheapest first within tiers:

**Tier 1 — Eliminates root cause of most observed issues:**
1. Issue 10 — `previewMode: true` in overlay (one line, fixes bandwidth contention)
2. Issue 1 — Seek suppression in cell (small, fixes restart loop)
3. Issue 4 — `_disposed` flag in MpvEngine (prevents native crashes)

**Tier 2 — Quality of life:**
4. Issue 2 — Transient retry with counter
5. Issue 9 — EnginePicker in cells
6. Issue 11 — Track and cancel cell subscriptions

**Tier 3 — Logging & observability:**
7. Issue 7/8 — Reorder main.dart startup
8. Issue 5 — "nulls" fix
9. Issue 6 — Distinct buffering log
10. Issue 12 — Replace silent catches
11. Issue 13 — Add mounted checks
12. Issue 15 — Wrap unawaited dispose

---

## What did NOT make it into v2

- Original Issue 3's `if (!exiting)` guard — **rejected** as it would leak
  the engine on every normal exit. The `_disposed` flag in MpvEngine
  (Issue 4) is the correct and only fix needed for the dispose symptom.
- Original Issue 6's "skip first buffering" — **revised** to distinct-state
  filter, which is safer and equivalent for log noise reduction.

## Model

Opus (re-evaluation of v1, static analysis, root cause correction)
