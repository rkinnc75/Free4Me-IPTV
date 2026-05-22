# fix17.md — Mini-Player Buffer Settings, Stream Completed Delay, Seek Always-Suppress, Concurrent Open Guard

## Issues confirmed in log `free4me_log_1779370833745.txt` (1.14.2)

| # | Issue | Status |
|---|---|---|
| 1 | Bandwidth contention between mini + full-screen | Root cause of all buffering |
| 2 | `"Cannot seek"` on reconnect (grace=false) causes reconnect | Not suppressed outside grace |
| 3 | `"stream completed"` false-positive on TCP dropout | No delay before reconnect |
| 4 | Double-increment counter (2→4 jump) | Still present |
| 5 | Concurrent `open()` calls on same channel | `_isReconnecting` race condition |
| 6 | Mini-player buffer hardcoded to 16MB, not user-configurable | Hardcoded in previewMode |

---

## Issue 1 + 6 — Mini-Player Buffer Settings (User-Configurable, Memory-Aware)

### Problem

The overlay (mini-player) uses `previewMode: true` → hardcoded `16MB demuxer`
and `32MB bufferSize`. These values are too low for smooth playback and too
high for very low-RAM devices. They should be:

- **User-configurable** via a slider
- **Capped at 75% of available device RAM** (divided by number of streams)
- **Defaulted intelligently** based on detected RAM

### Memory detection — no new dependency required

Android exposes total RAM via `/proc/meminfo`. Parse it at app start and store
in a static field:

#### New file: `lib/backend/device_memory.dart`

```dart
import 'dart:io';
import 'package:open_tv/backend/app_logger.dart';

/// Detects device RAM and computes recommended buffer limits.
/// Uses /proc/meminfo on Android; falls back to conservative defaults elsewhere.
class DeviceMemory {
  DeviceMemory._();

  /// Total physical RAM in MB. 0 = unknown.
  static int totalMb = 0;

  /// Initialise once at app startup. Safe to call multiple times.
  static Future<void> init() async {
    if (totalMb > 0) return;
    try {
      if (Platform.isAndroid) {
        final lines = await File('/proc/meminfo').readAsLines();
        for (final line in lines) {
          if (line.startsWith('MemTotal:')) {
            // "MemTotal:       3936144 kB"
            final kb = int.tryParse(
              line.replaceAll(RegExp(r'[^0-9]'), ''),
            );
            if (kb != null) totalMb = kb ~/ 1024;
            break;
          }
        }
      }
    } catch (e) {
      AppLog.warn('DeviceMemory: could not read /proc/meminfo — $e');
    }
    if (totalMb == 0) totalMb = 2048; // safe fallback: assume 2GB
    AppLog.info('DeviceMemory: totalMb=$totalMb');
  }

  /// Maximum recommended live demuxer MB for full-screen (75% RAM ÷ 1 stream).
  /// Capped at 512MB regardless of device RAM.
  static int get maxLiveDemuxerMb =>
      ((totalMb * 0.75) / 1).round().clamp(32, 512);

  /// Maximum recommended live demuxer MB for mini-player (75% RAM ÷ 2 streams).
  /// Capped at 256MB.
  static int get maxMiniDemuxerMb =>
      ((totalMb * 0.75) / 2).round().clamp(16, 256);

  /// Maximum recommended bufferSize MB (75% RAM ÷ 2 streams).
  static int get maxBufferSizeMb =>
      ((totalMb * 0.75) / 2).round().clamp(16, 256);

  /// Default live demuxer MB for full-screen based on detected RAM.
  static int get defaultLiveDemuxerMb => switch (totalMb) {
        < 2048 => 64,
        < 3072 => 100,
        < 5120 => 150,
        _      => 200,
      };

  /// Default mini-player (preview) live demuxer MB based on detected RAM.
  static int get defaultMiniDemuxerMb => switch (totalMb) {
        < 2048 => 16,
        < 3072 => 24,
        < 5120 => 32,
        _      => 48,
      };

  /// Default bufferSize MB per stream based on detected RAM.
  static int get defaultBufferSizeMb => switch (totalMb) {
        < 2048 => 32,
        < 3072 => 64,
        < 5120 => 128,
        _      => 192,
      };
}
```

#### `lib/main.dart` — initialise at startup

```dart
// Before runApp():
await DeviceMemory.init();
AppLog.info('App started — version=${packageInfo.version} build=${packageInfo.buildNumber}');
```

### New settings fields

#### `lib/models/settings.dart` — add fields

```dart
/// libmpv forward demuxer cache (MB) for mini-player / overlay streams.
/// Independently tunable from full-screen liveDemuxerMaxMB.
/// Default set from DeviceMemory.defaultMiniDemuxerMb at first run.
int miniDemuxerMaxMB;

/// libmpv bufferSize (MB) per player instance.
/// Applies to both full-screen and mini-player.
int bufferSizeMB;

// In constructor:
this.miniDemuxerMaxMB = 32,   // overridden at first run from DeviceMemory
this.bufferSizeMB = 128,      // overridden at first run from DeviceMemory
```

#### First-run defaults from detected RAM

In `SettingsService._readFromDb()`, if a setting is missing from DB
(first run or upgrade), substitute the device-appropriate default:

```dart
// After reading miniDemuxerMaxMB:
if (settingsMap[miniDemuxerMaxMBProp] == null) {
  settings.miniDemuxerMaxMB = DeviceMemory.defaultMiniDemuxerMb;
}
if (settingsMap[bufferSizeMBProp] == null) {
  settings.bufferSizeMB = DeviceMemory.defaultBufferSizeMb;
}
```

#### `lib/backend/settings_service.dart` — persist both

```dart
const miniDemuxerMaxMBProp = "miniDemuxerMaxMB";
const bufferSizeMBProp = "bufferSizeMB";

// In _readFromDb():
var mini = settingsMap[miniDemuxerMaxMBProp];
if (mini != null) settings.miniDemuxerMaxMB = int.parse(mini);

var buf = settingsMap[bufferSizeMBProp];
if (buf != null) settings.bufferSizeMB = int.parse(buf);

// In updateSettings():
settingsMap[miniDemuxerMaxMBProp] = settings.miniDemuxerMaxMB.toString();
settingsMap[bufferSizeMBProp] = settings.bufferSizeMB.toString();
```

### Wire up to MpvEngine

#### `lib/player/mpv_engine.dart`

Replace the hardcoded `32 * 1024 * 1024` bufferSize:

```dart
late final mk.Player _player = mk.Player(
  configuration: mk.PlayerConfiguration(
    // bufferSizeMB from settings; halved in previewMode (mini-player).
    bufferSize: previewMode
        ? (settings.bufferSizeMB ~/ 2) * 1024 * 1024
        : settings.bufferSizeMB * 1024 * 1024,
    logLevel: mk.MPVLogLevel.warn,
  ),
);
```

Replace hardcoded demuxer values in `_applyMpvOptions()`:

```dart
// Live streams:
final liveMB = previewMode ? s.miniDemuxerMaxMB : s.liveDemuxerMaxMB;
await np.setProperty('demuxer-max-bytes', '${liveMB}MiB');

// VOD:
final vodMB = previewMode
    ? (s.miniDemuxerMaxMB * 2)  // VOD preview gets double live preview
    : s.vodDemuxerMaxMB;
await np.setProperty('demuxer-max-bytes', '${vodMB}MiB');
```

### Pass settings to overlay

#### `lib/player/overlay_player_controller.dart`

`startOverlay()` already receives `Settings s` — just add `previewMode: true`:

```dart
final engine = MpvEngine(
  channel: ch,
  settings: s,
  fullscreenOnOpen: false,
  previewMode: true,    // ← already present but buffer values now from settings
);
```

### Settings UI sliders

#### `lib/settings_view.dart` — add to Buffering section

```dart
// After liveDemuxerMaxMB slider:
_bufferSlider(
  label: 'Mini-player demuxer cache (MB)',
  value: settings.miniDemuxerMaxMB.toDouble(),
  min: 8,
  max: DeviceMemory.maxMiniDemuxerMb.toDouble(),
  divisions: ((DeviceMemory.maxMiniDemuxerMb - 8) / 8).round(),
  help: (
    title: 'Mini-Player Demuxer Cache',
    body: 'Forward read buffer for the mini-player / overlay stream. '
        'Lower values reduce RAM usage when two streams play simultaneously. '
        'Max is 75% of your device\'s RAM divided by 2 streams. '
        'Default: ${DeviceMemory.defaultMiniDemuxerMb}MB '
        '(auto-detected from ${DeviceMemory.totalMb}MB RAM).',
  ),
  onChanged: (v) {
    setState(() => settings.miniDemuxerMaxMB = v.round());
    updateSettings();
  },
),

_bufferSlider(
  label: 'Player buffer size (MB)',
  value: settings.bufferSizeMB.toDouble(),
  min: 16,
  max: DeviceMemory.maxBufferSizeMb.toDouble(),
  divisions: ((DeviceMemory.maxBufferSizeMb - 16) / 16).round(),
  help: (
    title: 'Player Buffer Size',
    body: 'Internal libmpv read-ahead buffer per player instance. '
        'Increasing this helps on high-bitrate streams but uses more RAM. '
        'Mini-player uses half this value automatically. '
        'Max is 75% of your device\'s RAM divided by 2 streams. '
        'Default: ${DeviceMemory.defaultBufferSizeMb}MB '
        '(auto-detected from ${DeviceMemory.totalMb}MB RAM).',
  ),
  onChanged: (v) {
    setState(() => settings.bufferSizeMB = v.round());
    updateSettings();
  },
),
```

---

## Issue 2 — "Cannot seek" should NEVER trigger onDisconnect

### Problem

`"Cannot seek in this stream."` fires when `startupGrace=false` (reconnect
attempt 2+) and slips through to `onDisconnect()`. This error is NEVER
actionable — mpv always probes seekability, MPEG-TS always rejects it, the
stream plays fine regardless. Suppressing it only during `startupGrace` is
insufficient.

### Fix — always suppress both seek messages

#### `lib/player.dart` — errorStream listener

Change the suppression from grace-conditional to unconditional:

```dart
// Before:
if (_startupGrace &&
    (err.contains('Cannot seek in this stream') ||
     err.contains('force-seekable=yes'))) {
  AppLog.info('Player: suppressed seek probe error during startup ...');
  return;
}

// After:
if (err.contains('Cannot seek in this stream') ||
    err.contains('force-seekable=yes')) {
  // mpv always probes seekability on open. MPEG-TS livestreams always
  // reject it. The stream plays fine regardless — this error is purely
  // informational and should never trigger a reconnect at any point.
  AppLog.info(
    'Player: suppressed seek probe error'
    ' channel="${widget.channel.name}"',
  );
  return;
}
```

---

## Issue 3 — "stream completed" false-positive: add reconnect delay setting

### Problem

libmpv fires `"stream completed"` when the provider briefly closes the TCP
connection (load balancer rotation, segment boundary). The reconnect fires
immediately — if the provider re-establishes within 1-2 seconds, the
reconnect was unnecessary.

### Fix — configurable delay before stream-completed reconnect

#### `lib/models/settings.dart` — add field

```dart
/// Milliseconds to wait before reconnecting after a "stream completed"
/// event. Gives the provider time to re-establish the TCP connection.
/// 0 = reconnect immediately. Default: 2000ms. Range: 0–10000ms.
int streamCompletedDelayMs;

// In constructor:
this.streamCompletedDelayMs = 2000,
```

#### `lib/backend/settings_service.dart` — persist it

```dart
const streamCompletedDelayMsProp = "streamCompletedDelayMs";

// In _readFromDb():
var scd = settingsMap[streamCompletedDelayMsProp];
if (scd != null) settings.streamCompletedDelayMs = int.parse(scd);

// In updateSettings():
settingsMap[streamCompletedDelayMsProp] = settings.streamCompletedDelayMs.toString();
```

#### `lib/player.dart` — apply delay in completedStream listener

```dart
_engineSubs.add(_engine.completedStream.listen((completed) {
  if (!completed || _startupGrace) return;
  final delayMs = widget.settings.streamCompletedDelayMs;
  if (delayMs > 0) {
    Future.delayed(Duration(milliseconds: delayMs), () {
      if (mounted && !exiting && !_isReconnecting) {
        onDisconnect(reason: 'stream completed');
      }
    });
  } else {
    onDisconnect(reason: 'stream completed');
  }
}));
```

#### `lib/settings_view.dart` — add slider

```dart
_bufferSlider(
  label: 'Stream-ended reconnect delay (ms)',
  value: settings.streamCompletedDelayMs.toDouble(),
  min: 0,
  max: 10000,
  divisions: 20,  // 500ms steps
  help: (
    title: 'Stream-Ended Reconnect Delay',
    body: 'How long to wait before reconnecting when the stream signals '
        'it has ended. IPTV providers sometimes briefly close the TCP '
        'connection at segment boundaries or during load balancer '
        'rotation — a short delay lets them re-establish without '
        'triggering a full reconnect. '
        '0 = reconnect immediately. Default: 2000ms (2 seconds).',
  ),
  onChanged: (v) {
    setState(() => settings.streamCompletedDelayMs = v.round());
    updateSettings();
  },
),
```

---

## Issue 4 — Double-increment counter (2→4 jump)

Confirmed still present in 1.14.2 log at 09:40:05. The pre-increment line
in `errorStream` listener that was supposedly removed in fix8 is still
causing the jump. Verify it is truly absent:

```dart
// CONFIRM this line does NOT exist anywhere in player.dart errorStream listener:
if (isPermanent) _totalReconnectAttempts++;   // ← MUST NOT EXIST
```

If it does exist, delete it. `onDisconnect()` is the sole incrementer.

---

## Issue 5 — Concurrent open() calls (_isReconnecting race)

At 09:39:37, TWO simultaneous `open()` calls fire for WBTV. Both `onDisconnect`
calls see `_isReconnecting=false` before either sets it to `true` (same
event loop tick).

### Fix — set `_isReconnecting` synchronously at entry

```dart
void onDisconnect({String reason = 'unknown'}) async {
  if (!mounted || exiting || _isReconnecting) return;

  // Set synchronously BEFORE any await — prevents a second onDisconnect
  // call in the same event loop tick from passing the guard above.
  _isReconnecting = true;   // ← MOVE THIS to immediately after the guard

  _totalReconnectAttempts++;
  AppLog.warn('Player: onDisconnect — attempt ...');
  // ... rest of method
  // Remove the later _isReconnecting = true that was after the delay
}
```

Currently `_isReconnecting = true` is set AFTER the delay and some other
logic. Moving it to immediately after the guard (before any `await`) makes
the flag atomic within the Dart event loop.

---

## Summary of all changes

| Issue | File(s) | Change |
|---|---|---|
| Memory-aware buffer defaults | `lib/backend/device_memory.dart` (new) | Reads /proc/meminfo, computes defaults |
| | `lib/main.dart` | Call `DeviceMemory.init()` at startup |
| | `lib/models/settings.dart` | Add `miniDemuxerMaxMB`, `bufferSizeMB` |
| | `lib/backend/settings_service.dart` | Persist both (3 additions each) |
| | `lib/player/mpv_engine.dart` | Use `settings.bufferSizeMB`, `settings.miniDemuxerMaxMB` |
| | `lib/settings_view.dart` | Add 2 sliders with RAM-aware max |
| Seek never reconnects | `lib/player.dart` | Remove `_startupGrace` condition from seek suppression |
| Stream-completed delay | `lib/models/settings.dart` | Add `streamCompletedDelayMs` (default 2000) |
| | `lib/backend/settings_service.dart` | Persist it |
| | `lib/player.dart` | Apply delay in completedStream listener |
| | `lib/settings_view.dart` | Add slider (0–10000ms, 500ms steps) |
| Double-increment | `lib/player.dart` | Verify pre-increment line is absent |
| Concurrent open() | `lib/player.dart` | Move `_isReconnecting = true` before first await |

## RAM tier reference

| Device RAM | bufferSizeMB default | liveDemuxerMaxMB default | miniDemuxerMaxMB default |
|---|---|---|---|
| < 2GB | 32 MB | 64 MB | 16 MB |
| 2–3GB (Onn 4K) | 64 MB | 100 MB | 24 MB |
| 3–6GB (Shield) | 128 MB | 150 MB | 32 MB |
| > 6GB | 192 MB | 200 MB | 48 MB |

Slider max = 75% of device RAM ÷ 2 (two concurrent streams), capped at 512MB.

## Model

Sonnet 4.6 (settings additions, guard fixes)
`DeviceMemory` class: Sonnet 4.6 (file I/O, no architectural decisions)

---

## ⚠ Implementation note — RAM-aware help text

Three settings have help messages that reference `DeviceMemory.totalMb` and
`DeviceMemory.defaultXxxMb` at runtime:

- `miniDemuxerMaxMB`
- `bufferSizeMB`
- `liveDemuxerMaxMB` (updating existing help text)

These help bodies **cannot be `const`** — they must be computed inside the
`build()` method of `_SettingsState` after `DeviceMemory.init()` has run.
The slider `max:` values for all three are also runtime-computed from
`DeviceMemory.maxMiniDemuxerMb`, `DeviceMemory.maxBufferSizeMb`, and
`DeviceMemory.maxLiveDemuxerMb`.

The existing `_helpLiveDemuxerMB` is currently a top-level `const`. It must
be converted to an inline `help:` expression inside the `_bufferSlider` call
(same pattern as the Stable Threshold and Startup Grace inline messages)
so it can access `DeviceMemory` values.

See `updated-help-messages.md` for the full text of all three revised bodies.

---

## ⚠ Help text — use updated-help-messages.md, not the abbreviated versions above

The slider code blocks in this file show abbreviated `help:` bodies for
brevity. When implementing, **replace all `help:` bodies in `settings_view.dart`
with the full versions from `updated-help-messages.md`**. This applies to:

**New settings (full text in updated-help-messages.md):**
- `miniDemuxerMaxMB` slider — "Mini-Player Demuxer Buffer (MB)"
- `bufferSizeMB` slider — "Player Buffer Size (MB)"
- `streamCompletedDelayMs` slider — "Stream-Ended Reconnect Delay (ms)"

**Existing settings whose help text is also updated in updated-help-messages.md:**
- `liveDemuxerMaxMB` — convert from `const _helpLiveDemuxerMB` to inline,
  use full revised body (adds RAM cap note and mini-player contention context)
- `bufferingWatchdogSecs` — use full revised body (adds dual-stream warning)
- `stableThresholdSecs` — use full revised body (adds give-up diagnosis tip)
- `startupGraceMs` — use full revised body (notes seek suppression is now unconditional)
- All other existing settings — use revised bodies from updated-help-messages.md

The two files are a matched pair and must both be passed to the implementer.
