# fix30.md — Multi-view setting persistence + opt-out for channel auto-restore

> Two requests:
>
> 1. **"The multi-view setting value is either not saved or not
>    imported correctly. It doesn't remember it upon import."**
>
>    Diagnosis: the user imported `free4me-backup__2_.json`. Inspection
>    of the file shows `schemaVersion: 2`, exported from app version
>    `1.15.8`. The keys `multiViewLayout`, `multiViewCells1x2`, and
>    `multiViewCells2x2` are not in the file at all — they were added
>    in fix28 (schema v3). On import, `_settingsFromMap` correctly
>    falls back to the constructor default `MultiViewLayout.none` for
>    missing fields.
>
>    **No code fix is needed for the import bug — there isn't one.**
>    The persistence code in `SettingsService.updateSettings` writes
>    `multiViewLayout`, the export in `_settingsToMap` writes it, the
>    import in `_settingsFromMap` reads it. The v2 backup file simply
>    doesn't contain it.
>
>    To make sure this doesn't recur (i.e. to catch a real future
>    persistence bug if one appears), this runbook adds diagnostic
>    log lines around the save/load/export/import boundary for the
>    three multi-view settings fields. Cheap, off by default,
>    informative when on.
>
> 2. **"Currently when multi-view is opened it has the last channels
>    start automatically. Add a setting: on = as is, off = show with
>    all cells ready to add a channel."**
>
>    Straightforward: one new boolean Settings field
>    (`multiViewAutoRestoreChannels`, default `true` to preserve
>    current behaviour), one new toggle in the Settings UI under the
>    existing multi-view layout tile, and one branch in
>    `MultiViewScreen._restoreChannels()` that skips the restore when
>    the setting is off.

---

# Part 30.1 — Diagnostic logging on multi-view setting persistence

> Cheap insurance against a future real persistence bug. All lines
> gated on `AppLog.enabled`.

## File: `lib/backend/settings_service.dart`

### Existing log line at line 180-189 already covers loading

The current load log includes `multiViewLayout=${settings.multiViewLayout.name}`.
Extend it to also cover the cell-assignment strings so we can see them
round-trip:

**Current code (lines 180-189):**

```dart
AppLog.info(
  'Settings: loaded'
  ' bufferSizeMB=${settings.bufferSizeMB}'
  ' liveDemuxerMaxMB=${settings.liveDemuxerMaxMB}'
  ' miniDemuxerMaxMB=${settings.miniDemuxerMaxMB}'
  ' stableThresholdSecs=${settings.stableThresholdSecs}'
  ' startupGraceMs=${settings.startupGraceMs}'
  ' streamCompletedDelayMs=${settings.streamCompletedDelayMs}'
  ' multiViewLayout=${settings.multiViewLayout.name}',
);
```

**Replace with:**

```dart
AppLog.info(
  'Settings: loaded'
  ' bufferSizeMB=${settings.bufferSizeMB}'
  ' liveDemuxerMaxMB=${settings.liveDemuxerMaxMB}'
  ' miniDemuxerMaxMB=${settings.miniDemuxerMaxMB}'
  ' stableThresholdSecs=${settings.stableThresholdSecs}'
  ' startupGraceMs=${settings.startupGraceMs}'
  ' streamCompletedDelayMs=${settings.streamCompletedDelayMs}'
  ' multiViewLayout=${settings.multiViewLayout.name}'
  ' multiViewCells1x2="${settings.multiViewCells1x2}"'
  ' multiViewCells2x2="${settings.multiViewCells2x2}"',
);
```

### Add log line on save

**Current code (line 239):**

```dart
await Sql.updateSettings(settingsMap);
_cached = settings; // keep the in-memory copy in sync
AppLog.info('Settings: saved');
```

**Replace with:**

```dart
await Sql.updateSettings(settingsMap);
_cached = settings; // keep the in-memory copy in sync
AppLog.info(
  'Settings: saved'
  ' multiViewLayout=${settings.multiViewLayout.name}'
  ' multiViewCells1x2="${settings.multiViewCells1x2}"'
  ' multiViewCells2x2="${settings.multiViewCells2x2}"',
);
```

## File: `lib/backend/settings_io.dart`

### Log on export

In `exportToFile`, after the existing settings/sources retrieval and
before the JSON encode (around line 25, just before `final
sourcesPayload = ...`), add:

```dart
AppLog.info(
  'SettingsIo.export: schema=$_schemaVersion'
  ' sources=${sources.length}'
  ' multiViewLayout=${settings.multiViewLayout.name}'
  ' multiViewCells1x2="${settings.multiViewCells1x2}"'
  ' multiViewCells2x2="${settings.multiViewCells2x2}"',
);
```

### Log on import (key tell — what's in the file)

In `importFromFile`, immediately after `_settingsFromMap` runs and
before `SettingsService.updateSettings(settings)` (around line 170),
add:

**Current code (lines 165-171):**

```dart
try {
  if (payload['settings'] != null) {
    final settings = _settingsFromMap(
      payload['settings'] as Map<String, dynamic>,
    );
    await SettingsService.updateSettings(settings);
  }
```

**Replace with:**

```dart
try {
  if (payload['settings'] != null) {
    final rawSettings = payload['settings'] as Map<String, dynamic>;
    final settings = _settingsFromMap(rawSettings);

    // fix30 diagnostic — log what arrived in the payload alongside
    // what _settingsFromMap produced. If a v2 backup is imported,
    // the three multi-view fields will be absent from rawSettings
    // and the resulting settings will hold constructor defaults
    // (none / "," / ",,,"). That's expected and not a bug — the
    // old backup simply doesn't carry that data.
    AppLog.info(
      'SettingsIo.import: schemaVersion=${payload['schemaVersion']}'
      ' appVersion=${payload['appVersion']}'
      ' payload-has-multiViewLayout=${rawSettings.containsKey('multiViewLayout')}'
      ' payload-multiViewLayout=${rawSettings['multiViewLayout']}'
      ' parsed-multiViewLayout=${settings.multiViewLayout.name}'
      ' parsed-cells1x2="${settings.multiViewCells1x2}"'
      ' parsed-cells2x2="${settings.multiViewCells2x2}"',
    );

    await SettingsService.updateSettings(settings);
  }
```

### How to read these logs

After running an import, look for the three lines in sequence:

1. `SettingsIo.import: ...payload-has-multiViewLayout=true/false`
   — tells you whether the backup carried the field.
2. `Settings: saved multiViewLayout=...`
   — what got written to SQLite.
3. `Settings: loaded multiViewLayout=...`
   — what came back on the next launch.

If (1) says `true` but (2) or (3) says `none`, there's a real bug.
If (1) says `false`, the backup is too old. Tell the user to make a
fresh backup on the current build.

---

# Part 30.2 — Add "Auto-restore channels in multi-view" setting

## File: `lib/models/settings.dart`

### Add the field

Insert in the multi-view section, after `multiViewCells2x2` declaration
(after line 101):

```dart
/// Persisted channel IDs for the 2×2 layout (4 cells).
String multiViewCells2x2;

/// When `true`, opening the multi-view screen restores the channels
/// from the last session for the current layout. When `false`, the
/// screen opens with all cells empty (ready for the user to assign).
///
/// Default `true` to preserve historical behaviour. Channel IDs are
/// still persisted regardless — flipping this back to `true` will
/// restore the channels that were active before the toggle.
bool multiViewAutoRestoreChannels;
```

### Add the constructor default

After line 135 (`this.multiViewCells2x2 = ',,,',`) add:

```dart
this.multiViewCells2x2 = ',,,',
this.multiViewAutoRestoreChannels = true,
```

## File: `lib/backend/settings_service.dart`

### Add the property key

Next to the other multi-view keys (after line 54):

```dart
const multiViewCells2x2Prop = "multiViewCells2x2";
const multiViewAutoRestoreChannelsProp = "multiViewAutoRestoreChannels";
```

### Read the value in `_readFromDb`

In `_readFromDb`, near the other multi-view reads (after line 115):

```dart
var mvLayout = settingsMap[multiViewLayoutProp];
var mvCells1x2 = settingsMap[multiViewCells1x2Prop];
var mvCells2x2 = settingsMap[multiViewCells2x2Prop];
var mvAutoRestore = settingsMap[multiViewAutoRestoreChannelsProp];
```

And later in the same method, near where the other mv fields are
applied (after line 163):

```dart
if (mvCells1x2 != null) settings.multiViewCells1x2 = mvCells1x2;
if (mvCells2x2 != null) settings.multiViewCells2x2 = mvCells2x2;
if (mvAutoRestore != null) {
  settings.multiViewAutoRestoreChannels = int.parse(mvAutoRestore) == 1;
}
```

### Write the value in `updateSettings`

Near the other mv writes (after line 231):

```dart
settingsMap[multiViewLayoutProp] = settings.multiViewLayout.toJson();
settingsMap[multiViewCells1x2Prop] = settings.multiViewCells1x2;
settingsMap[multiViewCells2x2Prop] = settings.multiViewCells2x2;
settingsMap[multiViewAutoRestoreChannelsProp] =
    (settings.multiViewAutoRestoreChannels ? 1 : 0).toString();
```

## File: `lib/backend/settings_io.dart`

### Export

In `_settingsToMap` (after the existing `multiViewCells2x2` line, around
298):

```dart
'multiViewCells2x2': s.multiViewCells2x2,
'multiViewAutoRestoreChannels': s.multiViewAutoRestoreChannels,
```

### Import

In `_settingsFromMap`'s v3 overlay block (after the existing
`multiViewCells2x2` block, around line 352):

```dart
if (m['multiViewCells2x2'] is String) {
  s.multiViewCells2x2 = m['multiViewCells2x2'];
}
if (m['multiViewAutoRestoreChannels'] is bool) {
  s.multiViewAutoRestoreChannels = m['multiViewAutoRestoreChannels'];
}
```

> **Schema version note.** This field is additive on schema v3 — no
> bump needed. Older v3 backups missing this key fall back to the
> constructor default `true`, which matches existing behaviour, so
> they look identical to v3 backups that explicitly carry `true`.
> If you want strict schema discipline, bump to v4. I'd skip it —
> a v3-without-the-field is harmless.

## File: `lib/multi_view_screen.dart`

### Skip restore when the setting is off

**Current code (lines 115-138):**

```dart
Future<void> _restoreChannels() async {
  final raw = widget.layout == MultiViewLayout.oneByTwo
      ? widget.settings.multiViewCells1x2
      : widget.settings.multiViewCells2x2;

  AppLog.info(
    'MultiViewScreen: restoring channels'
    ' layout=${widget.layout.name}'
    ' raw="$raw"',
  );

  final parts = raw.split(',');
  final toFetch = <int, int>{}; // cellIndex → channelId

  for (var i = 0; i < _cellCount && i < parts.length; i++) {
    final id = int.tryParse(parts[i]);
    if (id != null) toFetch[i] = id;
  }

  if (toFetch.isEmpty) {
    AppLog.info('MultiViewScreen: no persisted channels to restore');
    if (mounted) setState(() => _restored = true);
    return;
  }
```

**Replace with:**

```dart
Future<void> _restoreChannels() async {
  // Honour the auto-restore opt-out (fix30). When off, open with all
  // cells empty. The persisted channel IDs in
  // multiViewCells1x2 / multiViewCells2x2 are NOT cleared — flipping
  // the setting back on will restore them on the next entry.
  if (!widget.settings.multiViewAutoRestoreChannels) {
    AppLog.info(
      'MultiViewScreen: auto-restore disabled — opening with empty cells'
      ' layout=${widget.layout.name}',
    );
    if (mounted) setState(() => _restored = true);
    return;
  }

  final raw = widget.layout == MultiViewLayout.oneByTwo
      ? widget.settings.multiViewCells1x2
      : widget.settings.multiViewCells2x2;

  AppLog.info(
    'MultiViewScreen: restoring channels'
    ' layout=${widget.layout.name}'
    ' raw="$raw"',
  );

  final parts = raw.split(',');
  final toFetch = <int, int>{}; // cellIndex → channelId

  for (var i = 0; i < _cellCount && i < parts.length; i++) {
    final id = int.tryParse(parts[i]);
    if (id != null) toFetch[i] = id;
  }

  if (toFetch.isEmpty) {
    AppLog.info('MultiViewScreen: no persisted channels to restore');
    if (mounted) setState(() => _restored = true);
    return;
  }
```

> **Design note: keep persisting picks even when auto-restore is off.**
> `_setChannel` and `_persistChannels` continue to write the latest
> picks into `multiViewCells1x2` / `multiViewCells2x2` regardless of
> the auto-restore setting. This is intentional. The setting governs
> behaviour on *open* only; it doesn't wipe the user's picks. Flipping
> the toggle back on instantly restores whatever the cells held at
> the most recent close.
>
> If the user wants a "clear all cells now" affordance, that's a
> separate feature — a button on the multi-view screen that calls
> `_clearAllCells()`. Out of scope here unless requested.

## File: `lib/settings_view.dart`

### Add a Switch tile under the multi-view layout tile

The multi-view section currently consists of a single `_multiViewTile`
(lines 964-998) that shows the layout picker. Add an auto-restore
toggle below it.

Find the call site of `_multiViewTile` in the build tree (somewhere
in the main `build` Scaffold body — search for `_multiViewTile(settings)`).
Right after that ListTile, insert another:

```dart
_multiViewTile(settings),
SwitchListTile(
  title: Row(
    children: [
      const Expanded(child: Text('Restore last channels on open')),
      const SizedBox(width: 4),
      _helpIcon(
        title: 'Auto-restore channels',
        body: 'When ON, opening multi-view brings back the channels '
            'you had loaded the last time you used the current '
            'layout — exactly as you left them.\n\n'
            'When OFF, multi-view opens with all cells empty; tap '
            'each "+" to pick a channel.\n\n'
            'Your last picks are remembered in either case — turning '
            'this back ON restores them on the next open.',
      ),
    ],
  ),
  value: settings.multiViewAutoRestoreChannels,
  onChanged: settings.multiViewLayout == MultiViewLayout.none
      ? null  // greyed out when multi-view is off; nothing to restore
      : (v) {
          setState(() => settings.multiViewAutoRestoreChannels = v);
          updateSettings();
        },
),
```

Disabling the switch when `multiViewLayout == none` keeps the UI
honest: the setting has no effect until multi-view is enabled.

## File: `lib/settings_view.dart` — Settings.optimisedFor too

The optimise-for-device factory (fix22) writes a fully-specified
Settings instance. Add the new field there so optimise doesn't quietly
revert it.

In `Settings.optimisedFor` (the factory in `lib/models/settings.dart`,
not settings_view), in the body after the existing
`forcedEngine = EngineType.auto;` line, add:

```dart
s.forcedEngine = EngineType.auto;
s.multiViewAutoRestoreChannels = true;  // safe default
```

`Settings.defaults()` already returns `Settings()` which carries the
constructor default `true`, so no change needed there.

---

## Test plan

### Part 30.1 — diagnostic logging

1. Apply Part 30.1 and rebuild.
2. Enable debug logging in Settings.
3. **Test fresh export → fresh import round-trip:**
   - Set multi-view layout to 1×2 in Settings.
   - Open multi-view, pick two channels, exit.
   - Export a backup.
   - In the saved JSON, verify `"schemaVersion": 3` and the
     presence of `multiViewLayout`, `multiViewCells1x2`,
     `multiViewCells2x2` keys.
   - Uninstall + reinstall + import the new backup.
   - In the log, find:
     ```
     SettingsIo.export: schema=3 sources=2
       multiViewLayout=oneByTwo
       multiViewCells1x2="ID1,ID2"
       multiViewCells2x2=",,,"
     ```
     ```
     SettingsIo.import: schemaVersion=3 appVersion=1.16.x
       payload-has-multiViewLayout=true
       payload-multiViewLayout=oneByTwo
       parsed-multiViewLayout=oneByTwo
       parsed-cells1x2="ID1,ID2"
       parsed-cells2x2=",,,"
     ```
     ```
     Settings: saved multiViewLayout=oneByTwo
       multiViewCells1x2="ID1,ID2" ...
     ```
   - Open the multi-view button on Home — should be visible.
   - Open multi-view — should restore the two channels (this is
     the existing behaviour, governed by the new toggle in
     Part 30.2 below).

4. **Test old v2 backup import (regression sanity check):**
   - Import the user's existing `free4me-backup__2_.json`
     (v2, from 1.15.8).
   - In the log, find:
     ```
     SettingsIo.import: schemaVersion=2 appVersion=1.15.8
       payload-has-multiViewLayout=false
       payload-multiViewLayout=null
       parsed-multiViewLayout=none
       parsed-cells1x2=","
       parsed-cells2x2=",,,"
     ```
   - This is correct. The v2 file doesn't carry the data; the
     defaults are used. Tell the user "your old backup predates
     multi-view export support; make a fresh backup on the
     current build to round-trip it."

### Part 30.2 — auto-restore toggle

1. Apply Part 30.2.
2. With multi-view layout = 1×2 and two channels assigned:
3. **Toggle ON (default):**
   - Exit multi-view, re-open. Both channels restored. (Existing
     behaviour confirmed.)
4. **Toggle OFF:**
   - Go to Settings → flip "Restore last channels on open" off.
   - Exit settings, open multi-view.
   - **Expected:** both cells open empty with "+" buttons.
   - In the log: `MultiViewScreen: auto-restore disabled —
     opening with empty cells layout=oneByTwo`.
5. **Round-trip with toggle off:**
   - Pick two new channels in the cells. Exit. Re-open.
   - **Expected:** still empty (the setting is OFF, so even fresh
     picks don't auto-restore on the next open).
   - But the picks ARE still being persisted — verify by flipping
     the setting back ON and re-opening. Channels should reappear.
6. **Greyed-out check:**
   - Set multi-view layout to "Off" in Settings.
   - **Expected:** the "Restore last channels on open" switch is
     greyed out (not toggleable). There's nothing to restore when
     multi-view itself is disabled.
7. **Export/import round-trip:**
   - Set toggle OFF, export, fresh install, import.
   - On next launch, verify toggle is OFF in Settings.
8. **Optimise-for-device regression:**
   - Settings → Reset → Optimise for this device → Apply.
   - Verify toggle reverts to ON (the documented "safe default").

---

## Notes for the implementer

- **No SQL schema changes.** The new boolean field uses the existing
  `settings` key-value store via `multiViewAutoRestoreChannelsProp`.
- **No schema-version bump.** Older v3 backups without the key get
  the constructor default `true` on import, which matches existing
  behaviour. v4 would be overkill for one additive boolean.
- **Total file diff:**
  - `lib/models/settings.dart`: +6 lines
  - `lib/backend/settings_service.dart`: +12 lines (3 new for
    diagnostics, 9 for the new field)
  - `lib/backend/settings_io.dart`: +16 lines (export + import log,
    new field in maps)
  - `lib/multi_view_screen.dart`: +10 lines (opt-out branch)
  - `lib/settings_view.dart`: +25 lines (Switch tile)
- **Diagnostic log lines are gated on `AppLog.enabled`** — no
  overhead in release builds without debug logging enabled.
- **The user's existing backup file (`free4me-backup__2_.json`)
  cannot be made to carry multi-view data after the fact.** It was
  written by 1.15.8 which didn't know about the fields. Once the
  user makes a fresh backup on 1.16.x, the round-trip works.
