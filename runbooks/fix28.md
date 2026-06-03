# fix28.md — Consolidated runbook: Setup import, full backup round-trip, multi-view history, promote-to-fullscreen collision

> Repo state: `Free4Me-IPTV-1.16.0` has fix20, fix21, fix22 applied
> (verified via code inspection: `MpvEngine.reapplyOptions` is called
> from `MultiViewCell._startEngine`, `_maxTransientRetries=5`,
> `_lastTransientIncrementAt` debounce field present,
> `Settings.optimisedFor` / `Settings.defaults` factories exist,
> Settings UI has the Reset section).
>
> This consolidated runbook supersedes the four pending runbooks
> fix24/25/26/27 and bundles them into a single coherent change set.
> Apply all four parts in the order shown — they share imports and
> some lines touch the same methods, so doing them together avoids
> rework.
>
> Skipped from this consolidation: **fix23** (signing-key
> diagnostics) is build-machine ops, not a code change.

---

## What's covered

| Part | Bug | Files touched |
|---|---|---|
| 28.1 | First-run Setup forces source-add before backup import is reachable | `lib/setup.dart` |
| 28.2 | Backup export drops favorites, last-watched, and 9 settings fields | `lib/backend/settings_io.dart`, `lib/backend/utils.dart` |
| 28.3 | Multi-view doesn't record watch history | `lib/multi_view_screen.dart`, `lib/multi_view_cell.dart` |
| 28.4 | Promoting a cell to full-screen fails because the cell engine collides with the new Player engine on the same `.ts` URL | `lib/multi_view_cell.dart` |

Total code change: ~150 lines across 4 files. No SQL schema changes.
No new dependencies.

---

# Part 28.1 — Add "Import settings backup" to the first-run Setup screen

**Why:** after a clean install (e.g. after the keystore reset in
fix23), the user lands on the Setup wizard with no way to import an
existing backup. They have to create a throwaway source, navigate to
Settings, import the backup (which replaces the throwaway), then
proceed. The fix adds an "Import settings backup" button on the
welcome page that bypasses the wizard entirely if a backup is
selected.

**File:** `lib/setup.dart`

### Step 1 — add the import

After line 9 (`import 'package:open_tv/backend/utils.dart';`), add:

```dart
import 'package:open_tv/backend/settings_io.dart';
```

### Step 2 — add `_importBackup` method

Insert this method on `_SetupState`, immediately after the existing
`navigateToHome()` method (after line 309):

```dart
  /// Import a backup file from the welcome screen. If the import
  /// produces at least one source, skip the rest of the wizard and
  /// jump straight to Home. Otherwise stay on the welcome screen so
  /// the user can fall back to adding a source manually.
  ///
  /// SettingsIo.importFromFile() handles the file picker, schema
  /// validation, the confirm dialog, and persistence. We just react
  /// to its outcome.
  Future<void> _importBackup() async {
    await SettingsIo.importFromFile(context);
    if (!mounted) return;

    // Only navigate forward if the import actually populated a source.
    // User may have cancelled the picker or the confirm dialog.
    final sources = await Sql.getSources();
    if (!mounted) return;
    if (sources.isNotEmpty) {
      navigateToHome();
    }
  }
```

### Step 3 — render the button on the welcome page

**Current code (lines 438-443):**

```dart
case Steps.welcome:
  return getPage(
    "Welcome to Free4Me-IPTV",
    "Let's set up your ${widget.showAppBar ? "new" : "first"} source",
    null,
  );
```

**Replace with:**

```dart
case Steps.welcome:
  return getPage(
    "Welcome to Free4Me-IPTV",
    "Let's set up your ${widget.showAppBar ? "new" : "first"} source",
    // Only show the import-backup affordance on first-run setup
    // (showAppBar=false). When Setup is opened from Settings →
    // Add Source, the user already has Settings → Backup &
    // Restore available; offering it here would be redundant.
    widget.showAppBar
        ? null
        : [
            const SizedBox(height: 32),
            Text(
              'Already have a backup file?',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.7),
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _isFinishing ? null : _importBackup,
              icon: const Icon(Icons.download_for_offline),
              label: const Text('Import settings backup'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
              ),
            ),
          ],
  );
```

---

# Part 28.2 — Complete the backup round-trip (favorites, last-watched, missing settings fields)

**Why:** the export payload currently includes only `settings` and
`sources`. It does not contain channel-level data (`favorite`,
`last_watched`), so favorites disappear on every restore. The
`_settingsToMap` / `_settingsFromMap` helpers are also missing 9
fields that exist in the current `Settings` class — these silently
revert to defaults on every import.

**Files:** `lib/backend/settings_io.dart`, `lib/backend/utils.dart`

### Step 1 — bump schema version

**`lib/backend/settings_io.dart` line 17:**

```dart
const int _schemaVersion = 2;
```

**Replace with:**

```dart
const int _schemaVersion = 3;
```

### Step 2 — add imports

After line 8 (`import 'package:open_tv/backend/sql.dart';`), add:

```dart
import 'package:open_tv/models/channel_preserve.dart';
import 'package:open_tv/models/multi_view_layout.dart';
```

After line 15 (`import 'package:path_provider/path_provider.dart';`),
add:

```dart
import 'package:open_tv/backend/utils.dart' show Utils;
```

(The `show Utils` keeps the import surface narrow.)

### Step 3 — extend `exportToFile` to include preserved channel data

**Current code (lines 22-46):**

```dart
static Future<void> exportToFile(
  BuildContext context, {
  bool includeCredentials = false,
}) async {
  final packageInfo = await PackageInfo.fromPlatform();
  final settings = await SettingsService.getSettings();
  final sources = await Sql.getSources();

  final payload = jsonEncode({
    'schemaVersion': _schemaVersion,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'appVersion': packageInfo.version,
    'settings': _settingsToMap(settings),
    'sources': sources.map((s) => _sourceToMap(s, includeCredentials)).toList(),
  });
```

**Replace with:**

```dart
static Future<void> exportToFile(
  BuildContext context, {
  bool includeCredentials = false,
}) async {
  final packageInfo = await PackageInfo.fromPlatform();
  final settings = await SettingsService.getSettings();
  final sources = await Sql.getSources();

  // For each source, capture the per-channel attributes worth
  // round-tripping (favorite flag + last-watched timestamp). Keyed
  // by channel name — restorePreserve matches on (name, source_id)
  // after a refresh repopulates the channel table.
  final sourcesPayload = <Map<String, dynamic>>[];
  for (final s in sources) {
    final base = _sourceToMap(s, includeCredentials);
    if (s.id != null) {
      final preserve = await Sql.getChannelsPreserve(s.id!);
      if (preserve.isNotEmpty) {
        base['preserve'] = preserve
            .map((p) => {
                  'name': p.name,
                  if (p.favorite != null) 'favorite': p.favorite,
                  if (p.lastWatched != null) 'lastWatched': p.lastWatched,
                })
            .toList();
      }
    }
    sourcesPayload.add(base);
  }

  final payload = jsonEncode({
    'schemaVersion': _schemaVersion,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'appVersion': packageInfo.version,
    'settings': _settingsToMap(settings),
    'sources': sourcesPayload,
  });
```

### Step 4 — add the pending-preserves staging field

Insert at the top of the `SettingsIo` class (after line 19's class
declaration):

```dart
class SettingsIo {
  /// Channel-attribute restores staged by importFromFile, keyed by
  /// source name. Consumed by applyPendingPreserves once channel
  /// rows are populated by the first source refresh.
  ///
  /// In-memory only — if the app is killed before refresh runs, the
  /// entries are lost (the backup file itself is still on disk so
  /// the user can re-import). Persisting to SQLite is possible but
  /// adds schema-migration work; not worth it for a rare edge case.
  static final Map<String, List<ChannelPreserve>> _pendingPreserves = {};
```

### Step 5 — capture preserve lists during `importFromFile`

**Current code (lines 132-148):**

```dart
if (payload['sources'] != null) {
  final rawSources = payload['sources'] as List<dynamic>;
  for (final raw in rawSources) {
    final map = raw as Map<String, dynamic>;
    final source = Source(
      name: map['name'] as String,
      url: map['url'] as String?,
      username: map['username'] as String?,
      password: map['password'] as String?,
      sourceType: SourceType.values[map['sourceType'] as int? ?? 0],
      enabled: map['enabled'] as bool? ?? true,
      epgUrl: map['epgUrl'] as String?,
      defaultEngine: EngineType.fromJson(map['defaultEngine'] as String?),
    );
    await Sql.commitWrite([Sql.getOrCreateSourceByName(source)]);
  }
}
```

**Replace with:**

```dart
if (payload['sources'] != null) {
  final rawSources = payload['sources'] as List<dynamic>;
  for (final raw in rawSources) {
    final map = raw as Map<String, dynamic>;
    final source = Source(
      name: map['name'] as String,
      url: map['url'] as String?,
      username: map['username'] as String?,
      password: map['password'] as String?,
      sourceType: SourceType.values[map['sourceType'] as int? ?? 0],
      enabled: map['enabled'] as bool? ?? true,
      epgUrl: map['epgUrl'] as String?,
      defaultEngine: EngineType.fromJson(map['defaultEngine'] as String?),
    );
    await Sql.commitWrite([Sql.getOrCreateSourceByName(source)]);

    // Stage favorites / last-watched for re-application after the
    // first refresh populates channels for this source. Keyed by
    // source name because IDs differ between export and import
    // databases; names are the only stable identifier across the
    // boundary.
    final preserveRaw = map['preserve'] as List<dynamic>?;
    if (preserveRaw != null && preserveRaw.isNotEmpty) {
      _pendingPreserves[source.name] = preserveRaw
          .map((p) {
            final m = p as Map<String, dynamic>;
            return ChannelPreserve(
              name: m['name'] as String,
              favorite: m['favorite'] as int?,
              lastWatched: m['lastWatched'] as int?,
            );
          })
          .toList();
    }
  }
}
```

### Step 6 — change the success snackbar and kick off refresh

**Current code (lines 150-154):**

```dart
if (context.mounted) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Backup imported successfully')),
  );
}
```

**Replace with:**

```dart
if (context.mounted) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text(
        'Backup imported. Refreshing channels in the background…',
      ),
      duration: Duration(seconds: 4),
    ),
  );
}

// Fire-and-forget: refresh all sources so channels populate and
// pending preserves get applied. User can navigate freely while
// this runs.
// ignore: unawaited_futures
Utils.refreshAllSources();
```

### Step 7 — add the public `applyPendingPreserves` method

Insert this static method right before the existing `_settingsToMap`
declaration (i.e. before line 167):

```dart
/// Apply any pending channel-attribute restores for [sourceName]
/// that were staged by a recent importFromFile call. Safe to call
/// repeatedly; the entry is consumed and cleared on first
/// successful match. No-op if nothing is pending.
///
/// Called from Utils.refreshSource after channels are populated.
static Future<void> applyPendingPreserves(String sourceName) async {
  final preserve = _pendingPreserves.remove(sourceName);
  if (preserve == null || preserve.isEmpty) return;

  final sources = await Sql.getSources();
  Source? source;
  for (final s in sources) {
    if (s.name == sourceName) {
      source = s;
      break;
    }
  }
  if (source == null || source.id == null) {
    // Source was deleted between import and refresh — drop the
    // staged preserves silently.
    return;
  }

  await Sql.commitWrite(
    [Sql.restorePreserve(preserve)],
    memory: {'sourceId': source.id!.toString()},
  );
}
```

### Step 8 — extend `_settingsToMap` with the missing fields

**Current code (lines 167-192):**

```dart
static Map<String, dynamic> _settingsToMap(Settings s) => {
      'defaultView': s.defaultView.index,
      'refreshOnStart': s.refreshOnStart,
      'showLivestreams': s.showLivestreams,
      'showMovies': s.showMovies,
      'showSeries': s.showSeries,
      'forceTVMode': s.forceTVMode,
      'lowLatency': s.lowLatency,
      'hwDecode': s.hwDecode,
      'preWarmOnFocus': s.preWarmOnFocus,
      'liveCacheSecs': s.liveCacheSecs,
      'liveDemuxerMaxMB': s.liveDemuxerMaxMB,
      'vodCacheSecs': s.vodCacheSecs,
      'vodDemuxerMaxMB': s.vodDemuxerMaxMB,
      'openTimeoutSecs': s.openTimeoutSecs,
      'bufferingWatchdogSecs': s.bufferingWatchdogSecs,
      'stableThresholdSecs': s.stableThresholdSecs,
      'forcedEngine': s.forcedEngine.toJson(),
      // EPG & debug (added schema v2)
      'debugLogging': s.debugLogging,
      'epgAutoRefresh': s.epgAutoRefresh,
      'epgRefreshHours': s.epgRefreshHours,
      'epgRefreshHour': s.epgRefreshHour,
      'epgPastDays': s.epgPastDays,
      'epgForecastDays': s.epgForecastDays,
    };
```

**Replace with:**

```dart
static Map<String, dynamic> _settingsToMap(Settings s) => {
      'defaultView': s.defaultView.index,
      'refreshOnStart': s.refreshOnStart,
      'showLivestreams': s.showLivestreams,
      'showMovies': s.showMovies,
      'showSeries': s.showSeries,
      'forceTVMode': s.forceTVMode,
      'lowLatency': s.lowLatency,
      'hwDecode': s.hwDecode,
      'preWarmOnFocus': s.preWarmOnFocus,
      'liveCacheSecs': s.liveCacheSecs,
      'liveDemuxerMaxMB': s.liveDemuxerMaxMB,
      'vodCacheSecs': s.vodCacheSecs,
      'vodDemuxerMaxMB': s.vodDemuxerMaxMB,
      'openTimeoutSecs': s.openTimeoutSecs,
      'bufferingWatchdogSecs': s.bufferingWatchdogSecs,
      'stableThresholdSecs': s.stableThresholdSecs,
      'forcedEngine': s.forcedEngine.toJson(),
      // EPG & debug (schema v2)
      'debugLogging': s.debugLogging,
      'epgAutoRefresh': s.epgAutoRefresh,
      'epgRefreshHours': s.epgRefreshHours,
      'epgRefreshHour': s.epgRefreshHour,
      'epgPastDays': s.epgPastDays,
      'epgForecastDays': s.epgForecastDays,
      // Schema v3 additions:
      'startupGraceMs': s.startupGraceMs,
      'miniDemuxerMaxMB': s.miniDemuxerMaxMB,
      'bufferSizeMB': s.bufferSizeMB,
      'streamCompletedDelayMs': s.streamCompletedDelayMs,
      'streamScanMaxCount': s.streamScanMaxCount,
      'streamScanTimeoutSecs': s.streamScanTimeoutSecs,
      'multiViewLayout': s.multiViewLayout.toJson(),
      'multiViewCells1x2': s.multiViewCells1x2,
      'multiViewCells2x2': s.multiViewCells2x2,
    };
```

### Step 9 — extend `_settingsFromMap` with the missing fields

**Current code (lines 194-220):**

```dart
static Settings _settingsFromMap(Map<String, dynamic> m) {
  return Settings(
    defaultView: ViewType.values[m['defaultView'] as int? ?? 0],
    refreshOnStart: m['refreshOnStart'] as bool? ?? false,
    showLivestreams: m['showLivestreams'] as bool? ?? true,
    showMovies: m['showMovies'] as bool? ?? true,
    showSeries: m['showSeries'] as bool? ?? true,
    forceTVMode: m['forceTVMode'] as bool? ?? false,
    lowLatency: m['lowLatency'] as bool? ?? false,
    hwDecode: m['hwDecode'] as bool? ?? true,
    preWarmOnFocus: m['preWarmOnFocus'] as bool? ?? true,
    liveCacheSecs: m['liveCacheSecs'] as int? ?? 20,
    liveDemuxerMaxMB: m['liveDemuxerMaxMB'] as int? ?? 150,
    vodCacheSecs: m['vodCacheSecs'] as int? ?? 60,
    vodDemuxerMaxMB: m['vodDemuxerMaxMB'] as int? ?? 256,
    openTimeoutSecs: m['openTimeoutSecs'] as int? ?? 15,
    bufferingWatchdogSecs: m['bufferingWatchdogSecs'] as int? ?? 12,
    stableThresholdSecs: m['stableThresholdSecs'] as int? ?? 30,
    forcedEngine: EngineType.fromJson(m['forcedEngine'] as String?),
    debugLogging: m['debugLogging'] as bool? ?? false,
    epgAutoRefresh: m['epgAutoRefresh'] as bool? ?? true,
    epgRefreshHours: m['epgRefreshHours'] as int? ?? 12,
    epgRefreshHour: m['epgRefreshHour'] as int? ?? 3,
    epgPastDays: m['epgPastDays'] as int? ?? 1,
    epgForecastDays: m['epgForecastDays'] as int? ?? 7,
  );
}
```

**Replace with:**

```dart
static Settings _settingsFromMap(Map<String, dynamic> m) {
  // Construct with v2 fields first, then overlay v3 additions.
  // Missing v3 fields silently fall back to constructor defaults,
  // which matches user expectation when restoring a v2 backup.
  final s = Settings(
    defaultView: ViewType.values[m['defaultView'] as int? ?? 0],
    refreshOnStart: m['refreshOnStart'] as bool? ?? false,
    showLivestreams: m['showLivestreams'] as bool? ?? true,
    showMovies: m['showMovies'] as bool? ?? true,
    showSeries: m['showSeries'] as bool? ?? true,
    forceTVMode: m['forceTVMode'] as bool? ?? false,
    lowLatency: m['lowLatency'] as bool? ?? false,
    hwDecode: m['hwDecode'] as bool? ?? true,
    preWarmOnFocus: m['preWarmOnFocus'] as bool? ?? true,
    liveCacheSecs: m['liveCacheSecs'] as int? ?? 20,
    liveDemuxerMaxMB: m['liveDemuxerMaxMB'] as int? ?? 150,
    vodCacheSecs: m['vodCacheSecs'] as int? ?? 60,
    vodDemuxerMaxMB: m['vodDemuxerMaxMB'] as int? ?? 256,
    openTimeoutSecs: m['openTimeoutSecs'] as int? ?? 15,
    bufferingWatchdogSecs: m['bufferingWatchdogSecs'] as int? ?? 12,
    stableThresholdSecs: m['stableThresholdSecs'] as int? ?? 30,
    forcedEngine: EngineType.fromJson(m['forcedEngine'] as String?),
    debugLogging: m['debugLogging'] as bool? ?? false,
    epgAutoRefresh: m['epgAutoRefresh'] as bool? ?? true,
    epgRefreshHours: m['epgRefreshHours'] as int? ?? 24,
    epgRefreshHour: m['epgRefreshHour'] as int? ?? 3,
    epgPastDays: m['epgPastDays'] as int? ?? 1,
    epgForecastDays: m['epgForecastDays'] as int? ?? 7,
  );

  // v3 overlay — only assign if present in the payload.
  if (m['startupGraceMs'] is int) s.startupGraceMs = m['startupGraceMs'];
  if (m['miniDemuxerMaxMB'] is int) s.miniDemuxerMaxMB = m['miniDemuxerMaxMB'];
  if (m['bufferSizeMB'] is int) s.bufferSizeMB = m['bufferSizeMB'];
  if (m['streamCompletedDelayMs'] is int) {
    s.streamCompletedDelayMs = m['streamCompletedDelayMs'];
  }
  if (m['streamScanMaxCount'] is int) {
    s.streamScanMaxCount = m['streamScanMaxCount'];
  }
  if (m['streamScanTimeoutSecs'] is int) {
    s.streamScanTimeoutSecs = m['streamScanTimeoutSecs'];
  }
  if (m['multiViewLayout'] is String) {
    s.multiViewLayout = MultiViewLayout.fromJson(m['multiViewLayout']);
  }
  if (m['multiViewCells1x2'] is String) {
    s.multiViewCells1x2 = m['multiViewCells1x2'];
  }
  if (m['multiViewCells2x2'] is String) {
    s.multiViewCells2x2 = m['multiViewCells2x2'];
  }

  return s;
}
```

(Note: the `epgRefreshHours` default went from 12 to 24 to match
the constructor default in `lib/models/settings.dart:124`.)

### Step 10 — wire `applyPendingPreserves` into the refresh path

**File:** `lib/backend/utils.dart`

After line 5 (`import 'package:open_tv/backend/xtream.dart';`), add:

```dart
import 'package:open_tv/backend/settings_io.dart';
```

**Current code (lines 26-29):**

```dart
static Future<void> refreshSource(Source source) async {
  refreshedSeries.clear();
  await processSource(source, true);
}
```

**Replace with:**

```dart
static Future<void> refreshSource(Source source) async {
  refreshedSeries.clear();
  await processSource(source, true);
  // After channels are populated, apply any favorites and last-
  // watched timestamps that an imported backup staged for this
  // source (see fix28.2 / SettingsIo.applyPendingPreserves). No-op
  // if no preserve list is pending.
  await SettingsIo.applyPendingPreserves(source.name);
}
```

> **Heads-up on the circular import:** `settings_io.dart` now imports
> `utils.dart` (for `Utils.refreshAllSources`), and `utils.dart` now
> imports `settings_io.dart` (for `applyPendingPreserves`). Dart
> handles this correctly because neither import is consumed at
> top-level — both uses are inside method bodies. If the analyzer
> complains, the `import ... show Utils;` form in step 2 above
> already narrows the surface; if you still see issues, move the
> `Utils.refreshAllSources()` call out of `importFromFile` into a
> caller (e.g. the Setup screen) and remove that import.

---

# Part 28.3 — Record watch history from multi-view actions

**Why:** `Sql.addToHistory(channelId)` is called from exactly one
place in the codebase (`channel_tile.dart:249`). Channels watched
only via multi-view never appear in the Recent view.

**Files:** `lib/multi_view_screen.dart`, `lib/multi_view_cell.dart`

### Step 1 — record on cell channel pick

**File:** `lib/multi_view_screen.dart`

**Current code (lines 166-175):**

```dart
void _setChannel(int index, Channel channel) {
  AppLog.info(
    'MultiViewScreen: cell $index assigned'
    ' channel="${channel.name}"',
  );
  setState(() => _channels[index] = channel);
  _persistChannels();
  // Give the new cell audio focus automatically.
  if (_focusedCell != index) setState(() => _focusedCell = index);
}
```

**Replace with:**

```dart
void _setChannel(int index, Channel channel) {
  AppLog.info(
    'MultiViewScreen: cell $index assigned'
    ' channel="${channel.name}"',
  );
  setState(() => _channels[index] = channel);
  _persistChannels();
  // Record in watch history. Only fires for explicit user picks;
  // auto-restore of saved layouts on app launch uses a different
  // path (constructor / _restoreSavedCells) that bypasses this
  // setter, so restored channels don't get spurious timestamp
  // bumps.
  if (channel.id != null) {
    unawaited(Sql.addToHistory(channel.id!));
  }
  // Give the new cell audio focus automatically.
  if (_focusedCell != index) setState(() => _focusedCell = index);
}
```

`Sql` is already imported. `unawaited` requires `dart:async`, which
is also already imported (line 1).

### Step 2 — record on cell promotion to full-screen

**File:** `lib/multi_view_cell.dart`

This change is folded into part 28.4 below (the same method body is
modified for the engine-dispose fix). The `addToHistory` call goes
in the new `_promoteToFullScreen` body shown there.

---

# Part 28.4 — Dispose cell engine before promoting to full-screen

**Why:** when a multi-view cell is promoted to full-screen via the
long-press menu's "Full screen" item or via double-tap, the cell's
`MpvEngine` is never disposed. The new full-screen `Player` opens
the same `.ts` URL, the provider rejects the duplicate concurrent
read on the same credentials with "Failed to open", and reconnect
loops produce a permanent error.

Evidence: `free4me_log_1779565841465.txt` lines 696–728 show the
promotion at 15:47:53 followed by `Failed to open` at 15:47:54,
with no `MultiViewCell: disposing engine` log between them.

**File:** `lib/multi_view_cell.dart`

**Current code (lines 498-517):**

```dart
Future<void> _promoteToFullScreen() async {
  final ch = widget.channel;
  if (ch == null) return;
  AppLog.info(
    'MultiViewCell: promoting to full-screen'
    ' cell=${widget.cellIndex}'
    ' channel="${ch.name}"',
  );
  // Clear any stale cooldown — the cell's active stream proves it's live.
  Player.clearCooldown(ch.id);
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Player(
        channel: ch,
        settings: widget.settings,
        source: widget.source,
      ),
    ),
  );
}
```

**Replace with:**

```dart
Future<void> _promoteToFullScreen() async {
  final ch = widget.channel;
  if (ch == null) return;
  AppLog.info(
    'MultiViewCell: promoting to full-screen'
    ' cell=${widget.cellIndex}'
    ' channel="${ch.name}"',
  );
  // Clear any stale cooldown — the cell's active stream proves
  // it's live.
  Player.clearCooldown(ch.id);

  // Record in watch history (part 28.3 / fix26). Mirrors the
  // channel_tile.dart:249 tap-to-play path that's the only other
  // place a user actively chooses a channel.
  if (ch.id != null) {
    unawaited(Sql.addToHistory(ch.id!));
  }

  // CRITICAL: dispose the cell's engine BEFORE pushing the full-
  // screen Player. Both engines would otherwise try to read the
  // same .ts URL from the same provider credentials, and the
  // provider rejects the duplicate read with "Failed to open"
  // (see fix28.4 evidence in free4me_log_1779565841465.txt at
  // 15:47:53–15:47:54). Without this, every long-press → Full
  // screen and every double-tap fails permanently.
  //
  // The cell falls through to _buildLoadingCell() during the
  // promotion (no _engine, _loading true). After the Player pops,
  // we restart the cell so the user gets video back when they
  // return to multi-view.
  _disposeEngine();
  setState(() => _loading = true);

  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Player(
        channel: ch,
        settings: widget.settings,
        source: widget.source,
      ),
    ),
  );

  // Returned from full-screen. Re-open the cell with whatever
  // channel it currently holds. (If the user channel-zapped
  // inside the Player, that changed the Player's channel state,
  // not the cell's.)
  if (!mounted) return;
  final current = widget.channel;
  if (current != null) {
    _startEngine(current);
  }
}
```

`Sql` and `dart:async` are already imported (lines 1, 5).

---

## Apply order

The fixes share no overlapping line edits, but they share imports
and the parts touch the same files in some places. Recommended order
(top to bottom — files are touched in this sequence):

1. **28.1** — `lib/setup.dart` (add import, add method, replace
   welcome page builder).
2. **28.2 steps 1-9** — `lib/backend/settings_io.dart` (bump
   version, imports, exportToFile, staging field, importFromFile
   loop, snackbar+refresh, applyPendingPreserves, both maps).
3. **28.2 step 10** — `lib/backend/utils.dart` (import + refresh
   hook).
4. **28.3 step 1** — `lib/multi_view_screen.dart` (record on
   `_setChannel`).
5. **28.4** — `lib/multi_view_cell.dart` (replace
   `_promoteToFullScreen` with the new body that includes the
   `addToHistory` call from 28.3).

---

## Test plan

### 28.1 — Setup import button

1. Uninstall the app from the test device. Install fresh.
2. The Setup welcome screen should show the "Import settings
   backup" button below the subtitle.
3. Tap the button → file picker opens → select a valid `.json`
   backup → confirm → app navigates to Home with sources restored.
4. Repeat with file-picker cancel: should remain on welcome screen
   with Next still tappable.
5. Open Setup from Settings → Sources → "+" (with at least one
   source). The welcome screen should **not** show the import
   button (`showAppBar=true` gates it off).

### 28.2 — Backup round-trip

1. With several favorited channels and recently-watched items,
   export a backup.
2. Open the JSON file in a text editor. Verify:
   - `"schemaVersion": 3`
   - Each source has a `"preserve"` array with `name`/`favorite`/
     `lastWatched` entries
   - `"settings"` block has all v2 fields **plus** `startupGraceMs`,
     `miniDemuxerMaxMB`, `bufferSizeMB`, `streamCompletedDelayMs`,
     `streamScanMaxCount`, `streamScanTimeoutSecs`,
     `multiViewLayout`, `multiViewCells1x2`, `multiViewCells2x2`.
3. Uninstall and reinstall, import the backup via 28.1's button.
4. Snackbar says "Backup imported. Refreshing channels in the
   background…".
5. Wait ~10–30 seconds for refresh to complete. Channel tiles
   populate. Recent view shows previously-watched channels.
   Favorites view shows previously-favorited channels.
6. **Backward compat:** import an old v2 backup. Should succeed,
   sources and v2 settings restored, no favorites (the v2 backup
   didn't have them), no errors, no "newer version" warning
   (because 2 ≤ 3).
7. **Forward compat:** edit a v3 backup file to `"schemaVersion": 4`
   and try to import. Should show "Backup was created by a newer
   version of the app (schema v4)" snackbar.

### 28.3 — Multi-view history

1. From multi-view, pick a channel that's NOT currently in Recent.
2. Open Home → Recent view. The picked channel should be at the
   top.
3. **Auto-restore regression check:** Force-quit and relaunch. The
   2×2 restores automatically. Recent timestamps should be
   **unchanged** — auto-restore doesn't bump history.

### 28.4 — Promote to full-screen

1. Open 2×2 with four channels. Wait 30s for all to be playing.
2. Long-press cell 1 → tap "Full screen".
3. **Expected log sequence:**
   ```
   MultiViewCell: promoting to full-screen cell=1 ...
   MultiViewCell: disposing engine cell=1 ...           ← NEW
   Player: engine=EngineType.libmpv ...
   MpvEngine: options applied previewMode=false ...
   MpvEngine: open() command sent ...
   Player: open() succeeded ...                          ← no error
   ```
4. Cell briefly shows loading spinner, then full-screen Player
   opens with the channel playing within 2–5 seconds.
5. Press back → multi-view restores → cell 1 re-buffers ~2 seconds
   → resumes playing the same channel.
6. Repeat via double-tap (same code path).
7. **Bottom-right corner icon regression:** in a playing cell, tap
   the media_kit-supplied fullscreen icon. Should expand using the
   same engine (no buffering pause on enter or exit).
8. **Connection-budget verification (if you have `adb`):**
   ```
   adb shell ss -tn | grep media4u | wc -l
   ```
   During multi-view-with-4-streams + one promotion in flight,
   expect 4 connections (3 cells + 1 Player). Before the fix,
   briefly 5 (with the failed-to-open attempt).

---

## Notes for the implementer

- **No SQL schema changes.** Everything uses existing
  `channels.favorite` and `channels.last_watched` columns and the
  existing `getChannelsPreserve` / `restorePreserve` helpers.
- **No new package dependencies.**
- **Total file diff (rough):**
  - `lib/setup.dart`: +50 lines
  - `lib/backend/settings_io.dart`: +75 lines net (most of it the
    new fields list in the maps)
  - `lib/backend/utils.dart`: +5 lines
  - `lib/multi_view_screen.dart`: +5 lines
  - `lib/multi_view_cell.dart`: +20 lines
- Build buffer-size changes from imported settings only take effect
  on the next app launch (because `bufferSizeMB` is read into
  `mk.PlayerConfiguration` at engine construction). The post-import
  snackbar wording reflects this implicitly by not promising
  instant effect.
- `_pendingPreserves` is in-memory only. If the user imports and
  force-quits before refresh runs, the staged preserves are lost.
  They can re-import the same backup file to retry — `getOrCreateSourceByName`
  is idempotent, so the sources won't duplicate. Acceptable.
- Part 28.4's 1–3 second re-buffer when returning from full-screen
  is the cost of avoiding the duplicate-read conflict. If users
  find it jarring, a pre-warm strategy could be added later, but
  the current behaviour matches what users already experience when
  tapping a channel tile from Home.
