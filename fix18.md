# fix18.md — Comprehensive Logging Across All Subsystems

## Why this fix exists

The 1×2 multi-view session (14:18:51–14:23:55 in log `free4me_log_1779474763987.txt`)
produced **zero diagnostic events** for 5 minutes of active playback. The entire
multi-view playback path bypasses `player.dart` where all logging lives.
`MultiViewCell`, `ExoEngine`, `OverlayPlayerController`, `EnginePicker`,
`MpvEngine` (beyond hwdec), M3U/Xtream backends, settings service, and SQL
all have no logging — or insufficient logging — making remote diagnosis
impossible.

This fix adds `AppLog` calls everywhere a developer or user would need to
understand what the app is doing. Every log line follows the pattern:
`Subsystem: event — key=value key=value`

---

## 1. `lib/multi_view_cell.dart`

This is the highest priority — it produced zero log output for a full session.

```dart
import 'package:open_tv/backend/app_logger.dart';

// ── _startEngine() ─────────────────────────────────────────────────────────

Future<void> _startEngine(Channel ch) async {
  final generation = ++_openGeneration;
  AppLog.info(
    'MultiViewCell: starting engine'
    ' cell=$_cellIndex'            // add an index field (see below)
    ' channel="${ch.name}"'
    ' url="${ch.url}"'
    ' previewMode=true'
    ' generation=$generation',
  );
  if (mounted) setState(() { _loading = true; _error = false; });

  final engine = MpvEngine(
    channel: ch,
    settings: widget.settings,
    fullscreenOnOpen: false,
    previewMode: true,
  );

  await engine.setVolume(widget.isFocused ? 1.0 : 0.0);

  // Subscribe to errorStream and completedStream so failures are visible
  // in logs AND the cell shows an error state / retries automatically.
  // (Core fix — see fix18 Issue 3)
  engine.errorStream.listen((err) {
    AppLog.warn(
      'MultiViewCell: engine error'
      ' cell=$_cellIndex'
      ' channel="${ch.name}"'
      ' error="$err"',
    );
    if (mounted && generation == _openGeneration) {
      setState(() { _error = true; _loading = false; });
    }
  });

  engine.completedStream.listen((done) {
    if (!done) return;
    AppLog.info(
      'MultiViewCell: stream completed'
      ' cell=$_cellIndex'
      ' channel="${ch.name}"'
      ' — retrying in 2s',
    );
    // Single silent retry after 2s (matches streamCompletedDelayMs default)
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && generation == _openGeneration && !_error) {
        _disposeEngine();
        _startEngine(ch);
      }
    });
  });

  engine.bufferingStream.listen((buffering) {
    AppLog.info(
      'MultiViewCell: buffering=$buffering'
      ' cell=$_cellIndex'
      ' channel="${ch.name}"',
    );
  });

  try {
    await engine.open(url: ch.url ?? '');
  } catch (err) {
    AppLog.warn(
      'MultiViewCell: open() threw'
      ' cell=$_cellIndex'
      ' channel="${ch.name}"'
      ' error=$err',
    );
    if (!mounted || generation != _openGeneration) {
      unawaited(engine.dispose());
      return;
    }
    setState(() { _error = true; _loading = false; });
    unawaited(engine.dispose());
    return;
  }

  if (!mounted || generation != _openGeneration) {
    AppLog.info(
      'MultiViewCell: open() stale — discarding'
      ' cell=$_cellIndex generation=$generation',
    );
    unawaited(engine.dispose());
    return;
  }

  AppLog.info(
    'MultiViewCell: open() succeeded'
    ' cell=$_cellIndex'
    ' channel="${ch.name}"',
  );
  setState(() {
    _engine = engine;
    _loading = false;
  });
}

// ── _disposeEngine() ────────────────────────────────────────────────────────

void _disposeEngine() {
  AppLog.info(
    'MultiViewCell: disposing engine'
    ' cell=$_cellIndex'
    ' channel="${widget.channel?.name ?? 'empty'}"',
  );
  _openGeneration++;
  final e = _engine;
  _engine = null;
  if (e != null) unawaited(e.dispose());
}

// ── _setFocus / volume change ───────────────────────────────────────────────

// In didUpdateWidget, when isFocused changes:
if (widget.isFocused != old.isFocused) {
  AppLog.info(
    'MultiViewCell: focus changed → ${widget.isFocused ? "FOCUSED" : "muted"}'
    ' cell=$_cellIndex'
    ' channel="${widget.channel?.name ?? 'empty'}"',
  );
  _engine?.setVolume(widget.isFocused ? 1.0 : 0.0);
}

// ── _promoteToFullScreen() ──────────────────────────────────────────────────

Future<void> _promoteToFullScreen() async {
  final ch = widget.channel;
  if (ch == null) return;
  AppLog.info(
    'MultiViewCell: promoting to full-screen'
    ' cell=$_cellIndex'
    ' channel="${ch.name}"',
  );
  Player.clearCooldown(ch.id);
  await Navigator.of(context).push(...);
}

// ── Add _cellIndex field ────────────────────────────────────────────────────
// Pass index from MultiViewScreen so logs identify which cell:
// MultiViewCell(key: ..., cellIndex: i, ...)
// In _MultiViewCellState: int get _cellIndex => /* store from widget */
```

---

## 2. `lib/multi_view_screen.dart`

```dart
// ── _restoreChannels() ──────────────────────────────────────────────────────
AppLog.info(
  'MultiViewScreen: restoring channels'
  ' layout=${widget.layout.name}'
  ' raw="$raw"',
);
// After restore:
AppLog.info(
  'MultiViewScreen: restored ${_channels.where((c) => c != null).length}'
  '/${_cellCount} cells',
);

// ── _setChannel() ───────────────────────────────────────────────────────────
AppLog.info(
  'MultiViewScreen: cell $index assigned'
  ' channel="${channel.name}"',
);

// ── _setFocus() ─────────────────────────────────────────────────────────────
AppLog.info(
  'MultiViewScreen: focus → cell $index'
  ' (was $_focusedCell)',
);

// ── _closeCell() ────────────────────────────────────────────────────────────
AppLog.info(
  'MultiViewScreen: cell $index closed'
  ' was="${_channels[index]?.name ?? 'empty'}"',
);

// ── dispose() ───────────────────────────────────────────────────────────────
@override
void dispose() {
  AppLog.info('MultiViewScreen: disposing — layout=${widget.layout.name}');
  _interruptionSub?.cancel();
  _audioSession?.setActive(false).ignore();
  super.dispose();
}
```

---

## 3. `lib/player/exo_engine.dart`

Currently has zero logging. ExoEngine errors and state changes are invisible.

```dart
import 'package:open_tv/backend/app_logger.dart';

// ── open() ──────────────────────────────────────────────────────────────────
@override
Future<void> open({
  required String url,
  Duration? startPosition,
  Map<String, String>? headers,
}) async {
  AppLog.info('ExoEngine: open() url="$url"');
  await _controller?.dispose();
  // ... existing init ...
  AppLog.info(
    'ExoEngine: initialised'
    ' duration=${_controller!.value.duration.inSeconds}s'
    ' size=${_controller!.value.size}',
  );
}

// ── dispose() ───────────────────────────────────────────────────────────────
@override
Future<void> dispose() async {
  AppLog.info('ExoEngine: dispose()');
  // ... existing ...
}

// ── _onValueChanged() ───────────────────────────────────────────────────────
void _onValueChanged() {
  final v = _controller?.value;
  if (v == null) return;

  if (v.hasError) {
    AppLog.warn('ExoEngine: error — "${v.errorDescription}"');
    _errorCtrl.add(v.errorDescription ?? 'ExoPlayer error');
  }

  if (!v.isPlaying && v.isInitialized &&
      v.duration > Duration.zero && v.position >= v.duration) {
    AppLog.info('ExoEngine: stream completed');
    _completedCtrl.add(true);
  }

  if (v.isBuffering != _wasBuffering) {
    AppLog.info('ExoEngine: buffering=${v.isBuffering}');
    _wasBuffering = v.isBuffering;
    _bufferingCtrl.add(v.isBuffering);
  }
}
```

---

## 4. `lib/player/overlay_player_controller.dart`

```dart
import 'package:open_tv/backend/app_logger.dart';

// ── registerMain() ──────────────────────────────────────────────────────────
void registerMain(Channel ch, Settings s, Source? src, PlayerEngine engine) {
  AppLog.info('OverlayController: registerMain channel="${ch.name}"');
  // ... existing ...
}

// ── unregisterMain() ────────────────────────────────────────────────────────
void unregisterMain([PlayerEngine? engine]) {
  if (engine != null && _mainEngine != engine) {
    AppLog.info('OverlayController: unregisterMain — stale engine, ignored');
    return;
  }
  AppLog.info('OverlayController: unregisterMain');
  // ... existing ...
}

// ── startOverlay() ──────────────────────────────────────────────────────────
Future<void> startOverlay(Channel ch, Settings s, Source? src) async {
  AppLog.info('OverlayController: startOverlay channel="${ch.name}"');
  // ... existing ...
  await engine.open(url: url);
  AppLog.info('OverlayController: overlay open() succeeded channel="${ch.name}"');
}

// ── stopOverlay() ───────────────────────────────────────────────────────────
Future<void> stopOverlay() async {
  AppLog.info(
    'OverlayController: stopOverlay'
    ' channel="${_channel?.name ?? 'none'}"',
  );
  // ... existing ...
}

// ── consumeOverlay() ────────────────────────────────────────────────────────
Future<({Channel ch, Settings s, Source? src})?> consumeOverlay() async {
  AppLog.info(
    'OverlayController: consumeOverlay'
    ' channel="${_channel?.name ?? 'none'}"',
  );
  // ... existing ...
}

// ── muteMain() ──────────────────────────────────────────────────────────────
Future<void> muteMain() async {
  AppLog.info('OverlayController: muteMain');
  await _mainEngine?.setVolume(0.0);
}
```

---

## 5. `lib/player/engine_picker.dart`

```dart
import 'package:open_tv/backend/app_logger.dart';

static EngineType pick({...}) {
  final chanOverride = channel.engineOverride;
  if (chanOverride != null && chanOverride != EngineType.auto) {
    AppLog.info(
      'EnginePicker: channel-override → ${chanOverride.name}'
      ' channel="${channel.name}"',
    );
    return chanOverride;
  }

  if (settings.forcedEngine != EngineType.auto) {
    AppLog.info(
      'EnginePicker: global-override → ${settings.forcedEngine.name}'
      ' channel="${channel.name}"',
    );
    return settings.forcedEngine;
  }

  final srcDefault = source?.defaultEngine;
  if (srcDefault != null && srcDefault != EngineType.auto) {
    AppLog.info(
      'EnginePicker: source-default → ${srcDefault.name}'
      ' channel="${channel.name}"',
    );
    return srcDefault;
  }

  final u = (url ?? channel.url ?? '').toLowerCase();
  final byUrl = (u.contains('.m3u8') || u.contains('.mpd') || u.endsWith('.mp4'))
      ? EngineType.exoplayer
      : EngineType.libmpv;
  AppLog.info(
    'EnginePicker: url-heuristic → ${byUrl.name}'
    ' channel="${channel.name}"'
    ' url="$u"',
  );
  return byUrl;
}
```

---

## 6. `lib/player/mpv_engine.dart`

Add to `open()` and `dispose()`:

```dart
// In open():
AppLog.info(
  'MpvEngine: open()'
  ' url="$url"'
  ' previewMode=$previewMode'
  ' startPosition=${startPosition?.inSeconds}s',
);

// After _player.open():
AppLog.info(
  'MpvEngine: open() command sent'
  ' channel="${channel.name}"',
);

// In dispose():
AppLog.info(
  'MpvEngine: dispose()'
  ' channel="${channel.name}"'
  ' previewMode=$previewMode',
);

// In _applyMpvOptions() — log the final resolved values:
AppLog.info(
  'MpvEngine: options applied'
  ' channel="${channel.name}"'
  ' forceSeekable=no'
  ' demuxerMB=${previewMode ? s.miniDemuxerMaxMB : s.liveDemuxerMaxMB}'
  ' bufferSizeMB=${previewMode ? s.bufferSizeMB ~/ 2 : s.bufferSizeMB}'
  ' lowLatency=${s.lowLatency}'
  ' hwdec=${previewMode ? "no" : (Platform.isAndroid ? "mediacodec[-copy]" : "...")}',
);
```

---

## 7. `lib/backend/m3u.dart` and `lib/backend/xtream.dart`

```dart
// In M3U download/parse:
AppLog.info('M3U: downloading source="${source.name}" url="$url"');
// After parse:
AppLog.info(
  'M3U: parsed source="${source.name}"'
  ' channels=$channelCount'
  ' duration=${stopwatch.elapsed.inSeconds}s',
);
AppLog.warn('M3U: download failed source="${source.name}" error=$e');

// In Xtream:
AppLog.info('Xtream: fetching source="${source.name}" url="$url"');
AppLog.info(
  'Xtream: fetched source="${source.name}"'
  ' live=$liveCount movies=$movieCount series=$seriesCount',
);
AppLog.warn('Xtream: fetch failed source="${source.name}" error=$e');
```

---

## 8. `lib/backend/settings_service.dart`

```dart
// After loading settings from DB:
AppLog.info(
  'Settings: loaded'
  ' bufferSizeMB=${s.bufferSizeMB}'
  ' liveDemuxerMaxMB=${s.liveDemuxerMaxMB}'
  ' miniDemuxerMaxMB=${s.miniDemuxerMaxMB}'
  ' stableThresholdSecs=${s.stableThresholdSecs}'
  ' startupGraceMs=${s.startupGraceMs}'
  ' streamCompletedDelayMs=${s.streamCompletedDelayMs}'
  ' multiViewLayout=${s.multiViewLayout.name}',
);

// After saving settings:
AppLog.info('Settings: saved');
```

---

## 9. `lib/channel_tile.dart`

```dart
// In _maybePrewarm():
AppLog.info(
  'ChannelTile: prewarming channel="${widget.channel.name}"',
);

// In play() — so we know what triggered a channel open:
AppLog.info(
  'ChannelTile: play channel="${widget.channel.name}"'
  ' prewarmed=${ChannelTile.prewarmedUrl(widget.channel.id) != null}',
);
```

---

## 10. `lib/player/pip_controller.dart`

```dart
// On PIP mode change:
AppLog.info('PipController: pipMode=$inPip');

// On enter/exit:
AppLog.info('PipController: entering PIP');
AppLog.info('PipController: exiting PIP');
```

---

## 11. `lib/memory.dart` (DeviceMemory)

```dart
// After detecting RAM:
AppLog.info(
  'DeviceMemory: totalMb=$totalMb'
  ' defaultLiveDemuxer=${defaultLiveDemuxerMb}MB'
  ' defaultMiniDemuxer=${defaultMiniDemuxerMb}MB'
  ' defaultBufferSize=${defaultBufferSizeMb}MB'
  ' maxLiveDemuxer=${maxLiveDemuxerMb}MB'
  ' maxMiniDemuxer=${maxMiniDemuxerMb}MB',
);
```

---

## What the log will look like after this fix

For a 1×2 multi-view session opening Yankees + WBTV:

```
[INFO] DeviceMemory: totalMb=3936 defaultLiveDemuxer=150MB ...
[INFO] Settings: loaded bufferSizeMB=128 liveDemuxerMaxMB=150 ...
[INFO] MultiViewScreen: restoring channels layout=oneByTwo raw="461837,461838"
[INFO] MultiViewScreen: restored 2/2 cells
[INFO] EnginePicker: url-heuristic → libmpv channel="(t) MLB: New York Yankees"
[INFO] MpvEngine: options applied channel="Yankees" demuxerMB=24 bufferSizeMB=64 ...
[INFO] MultiViewCell: starting engine cell=0 channel="Yankees" generation=1
[INFO] MpvEngine: open() url="https://..." previewMode=true
[INFO] MultiViewCell: open() succeeded cell=0 channel="Yankees"
[INFO] MultiViewCell: buffering=true cell=0 channel="Yankees"
[INFO] MultiViewCell: buffering=false cell=0 channel="Yankees"
[INFO] MultiViewCell: starting engine cell=1 channel="WBTV" generation=1
[INFO] MultiViewCell: open() succeeded cell=1 channel="WBTV"
[INFO] MultiViewCell: focus changed → FOCUSED cell=0 channel="Yankees"
[WARN] MultiViewCell: engine error cell=1 channel="WBTV" error="Cannot seek..."
[INFO] MultiViewCell: stream completed cell=0 channel="Yankees" — retrying in 2s
```

Every state transition is visible. Remote diagnosis of any stoppage is
immediate — the cell index, channel name, generation counter, and error
message all appear in the log.

---

## Files to edit

| File | Log calls added |
|---|---|
| `lib/multi_view_cell.dart` | engine start/open/error/completed/buffering/focus/dispose/promote |
| `lib/multi_view_screen.dart` | restore/assign/focus/close/dispose |
| `lib/player/exo_engine.dart` | open/dispose/error/buffering/completed |
| `lib/player/overlay_player_controller.dart` | registerMain/unregister/start/stop/consume/mute |
| `lib/player/engine_picker.dart` | all four resolution paths |
| `lib/player/mpv_engine.dart` | open/dispose/options-applied |
| `lib/backend/m3u.dart` | download start/done/fail |
| `lib/backend/xtream.dart` | fetch start/done/fail |
| `lib/backend/settings_service.dart` | load/save |
| `lib/channel_tile.dart` | prewarm/play |
| `lib/player/pip_controller.dart` | mode-change/enter/exit |
| `lib/memory.dart` | RAM detection result |

## Model

Sonnet 4.6 (mechanical log insertion — no logic changes in any file)

---

## ⚠ All logging is gated by the debug logging setting

`AppLog.info()` and `AppLog.warn()` are **already no-ops** when debug logging
is disabled — the gate is inside `AppLog` at line 46 of `app_logger.dart`:
`if (!_enabled && level != LogLevel.error) return;`

Only `AppLog.error()` always writes regardless of the setting.

No additional `if (AppLog.enabled)` guards are needed for correctness.
However, for **high-frequency calls** (buffering events, position polling)
that fire many times per second, wrap with `if (AppLog.enabled)` at the
call site to avoid the string interpolation cost when logging is off:

```dart
// High-frequency — wrap to avoid string interpolation overhead:
if (AppLog.enabled) {
  AppLog.info('MultiViewCell: buffering=$buffering cell=$_cellIndex ...');
}
if (AppLog.enabled) {
  AppLog.info('ExoEngine: buffering=${v.isBuffering}');
}

// Low-frequency — no wrap needed, gate inside AppLog handles it:
AppLog.info('MultiViewCell: open() succeeded cell=$_cellIndex ...');
AppLog.warn('MultiViewCell: engine error cell=$_cellIndex ...');
```

Calls that should always use `if (AppLog.enabled)` guard:
- `MultiViewCell.bufferingStream.listen` callback
- `ExoEngine._onValueChanged()` buffering change
- `MpvEngine` position/buffering stream callbacks
- Any `Timer.periodic` callback
