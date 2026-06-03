# fix3.md — Player-Level Logging

## Problem

The app logger (`AppLog`) is only wired to EPG, update checker, and backend
operations. The player layer uses `debugPrint()` only, which goes to Android
logcat but never appears in the in-app log file. Reconnect reasons,
buffering events, and playback errors are invisible in exported logs,
making remote diagnosis impossible.

## Files to edit

- `lib/player.dart`

## Step 1 — Add AppLog import

```dart
import 'package:open_tv/backend/app_logger.dart';
```

## Step 2 — Log buffering events in _onBufferingChanged()

```dart
void _onBufferingChanged(bool buffering) {
  if (!mounted || exiting) return;
  AppLog.info('Player: buffering=$buffering channel="${widget.channel.name}"');
  if (buffering) {
  // ... rest of existing logic ...
```

## Step 3 — Log reconnect trigger in onDisconnect()

```dart
void onDisconnect({String reason = 'unknown'}) async {
  if (!mounted || exiting || _isReconnecting) return;
  if (widget.channel.mediaType != MediaType.livestream) return;
  AppLog.warn('Player: reconnect triggered — reason="$reason" channel="${widget.channel.name}"');
  // ... rest of existing logic ...
```

## Step 4 — Log playback open and failure in _startPlayback()

On successful open:

```dart
_consecutiveOpenFailures = 0;
AppLog.info('Player: open() succeeded — engine=$_engineType url="$playbackUrl"');
```

On failure inside the catch block:

```dart
AppLog.warn(
  'Player: open() failed ($_consecutiveOpenFailures/$_maxOpenFailures) — $e'
  ' — channel="${widget.channel.name}"',
);
```

## Step 5 — Log engine selection in initState()

```dart
_engineType = _pickEngine();
AppLog.info('Player: engine selected — $_engineType channel="${widget.channel.name}"');
_engine = _createEngine(_engineType);
```

## What you'll see in logs after this fix

```
[INFO] Player: engine selected — exoplayer channel="CNN HD"
[INFO] Player: open() succeeded — engine=exoplayer url="https://..."
[INFO] Player: buffering=true channel="CNN HD"
[WARN] Player: reconnect triggered — reason="stream completed" channel="CNN HD"
[INFO] Player: buffering=false channel="CNN HD"
```

This will confirm whether fix2 (startup grace period) is working and
identify any channels that reconnect repeatedly after the grace window.

## Bonus — also log the EPG over-refresh (visible in current logs)

In `epg_service.dart`, the EPG is refreshing 3× in 90 minutes despite a
24-hour interval. Add logging around the WorkManager schedule decision to
confirm whether `scheduleBackgroundRefresh()` is being called on every app
start and overwriting the interval.

```dart
// In EpgService.scheduleBackgroundRefresh():
AppLog.info('EPG: scheduling background refresh — '
    'autoRefresh=${settings.epgAutoRefresh} '
    'interval=${settings.epgRefreshHours}h');
```

## Model

Sonnet 4.6 (mechanical log insertion, no logic changes)
