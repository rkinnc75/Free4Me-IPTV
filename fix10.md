# fix10.md — stableThresholdSecs Persistence + Version Logging

## Verified status in 1.11.10

| Fix | Status |
|---|---|
| fix9 (force-seekable=no) | ✓ Applied — line 221 mpv_engine.dart |
| fix8 issue 2 (remove pre-increment) | ✓ Applied — comment confirms removal |
| fix8 issue 3 (exiting=true on give-up) | ✓ Applied — line 279 player.dart |

---

## Issue 1 — stableThresholdSecs never persisted to SQLite

`stableThresholdSecs` exists in the `Settings` model, is exported/imported
correctly via the JSON backup, but is **never written to or read from the
SQLite database**. Every app restart silently resets it to the hardcoded
default of `30` regardless of what the user set.

The backup JSON shows `stableThresholdSecs: 15` — this value only survives
while in memory. A restore from backup imports it correctly, but the next
app restart drops it to 30.

All 23 other settings fields persist correctly.

## Fix — `lib/backend/settings_service.dart`

### Step 1 — Add constant (alongside the other prop constants):

```dart
const stableThresholdSecsProp = "stableThresholdSecs";
```

### Step 2 — Add read in `_readFromDb()` (alongside other int reads):

```dart
var stable = settingsMap[stableThresholdSecsProp];
if (stable != null) settings.stableThresholdSecs = int.parse(stable);
```

### Step 3 — Add write in `updateSettings()` (alongside other int writes):

```dart
settingsMap[stableThresholdSecsProp] = settings.stableThresholdSecs.toString();
```

---

## Issue 2 — Version number missing from log

`main.dart` line 41 logs `'App started'` with no version. Every log file
is missing the build version, making it impossible to confirm which version
produced a given log without asking.

## Fix — `lib/main.dart`

Replace:

```dart
AppLog.info('App started');
```

With:

```dart
final packageInfo = await PackageInfo.fromPlatform();
AppLog.info('App started — version=${packageInfo.version} build=${packageInfo.buildNumber}');
```

`PackageInfo` is already imported via `package_info_plus` (used in
`settings_service.dart` and `settings_io.dart`), so no new dependency needed.

If `main.dart` doesn't already import it, add:

```dart
import 'package:package_info_plus/package_info_plus.dart';
```

### Expected log output after fix:

```
[INFO] App started — version=1.11.11 build=42
[INFO] EPG: scheduling background refresh — interval=48h refreshHour=4
```

This makes every exported log self-identifying — no more ambiguity about
which build is being tested.

---

## Files to edit

- `lib/backend/settings_service.dart` — 3 additions for stableThresholdSecs
- `lib/main.dart` — version string in App started log line

## Model

Sonnet 4.6 (mechanical additions, no logic changes)
