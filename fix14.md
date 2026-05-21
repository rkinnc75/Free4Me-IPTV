# fix14.md — EPG Incremental Matching + TV Mode Double-Load

---

## Part 1 — Separate EPG Refresh from Channel Matching

### Current behaviour

Every EPG refresh runs this full pipeline regardless of what changed:

```
1. Delete all programs for source
2. Download + parse full XMLTV (500k+ programs, ~2 minutes on Onn 4K)
3. Match ALL channels against EPG — including already-matched ones
4. Write results to DB
```

Step 3 is the slow part on TV hardware. With 92,692 channels (Media4u),
running the matcher in batches of 300 takes ~185 isolate invocations. Every
channel is re-evaluated even if it was correctly matched last time and nothing
changed. On a Snapdragon 4s Gen 2 (Onn 4K), each isolate spin-up has more
overhead than on a phone, making this noticeably slow.

### The fix — incremental matching

Only match channels that have no existing EPG assignment OR that were
previously unmatched. Already-correctly-matched channels (both auto and
manual) are skipped entirely.

#### `lib/backend/sql.dart` — New query: getChannelsNeedingEpgMatch

Add alongside `getChannelsForEpgMatching`:

```dart
/// Channels that need EPG matching:
/// - No epg_channel_id at all (never matched)
/// - OR epg_channel_id is null (previously unmatched)
/// Manual overrides are always excluded — they never need re-matching.
static Future<List<Channel>> getChannelsNeedingEpgMatch(int sourceId) async {
  var db = await DbFactory.db;
  final rows = await db.getAll('''
    SELECT * FROM channels
    WHERE source_id = ?
      AND media_type = 0
      AND epg_manual_override IS NULL
      AND epg_channel_id IS NULL
  ''', [sourceId]);
  return rows.map(rowToChannel).toList();
}
```

#### `lib/backend/epg_service.dart` — Split into two methods

Replace the single `refreshSource()` with two independent methods:

```dart
/// Step 1: Download and parse XMLTV, insert programs.
/// Returns the EPG channel map (id → display names) for use in matching.
static Future<Map<String, String>?> downloadAndParseEpg(
  Source source, {
  String? epgUrl,
  void Function(XmltvProgress)? onProgress,
}) async {
  final settings = await SettingsService.getSettings();
  final url = epgUrl ?? _resolveEpgUrl(source);
  if (source.id == null || url == null) return null;

  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final windowStart = now - settings.epgPastDays * 86400;
  final windowEnd = now + settings.epgForecastDays * 86400;
  int inserted = 0;

  AppLog.info('EPG: downloading "${source.name}" — $url');
  try {
    await Sql.deleteProgramsForSource(source.id!);

    final channelMap = await XmltvParser.parse(
      url: url,
      sourceId: source.id!,
      windowStartEpoch: windowStart,
      windowEndEpoch: windowEnd,
      onBatch: (batch) async {
        await Sql.insertProgramsBatch(batch);
        inserted += batch.length;
      },
      onProgress: onProgress,
    );

    AppLog.info('EPG: downloaded "${source.name}" — $inserted programs');
    await Sql.upsertEpgRefreshLog(source.id!, inserted, null);
    return channelMap;
  } catch (e, st) {
    AppLog.error('EPG: download failed for "${source.name}": $e');
    debugPrint('EPG download error: $e\n$st');
    await Sql.upsertEpgRefreshLog(source.id!, 0, e.toString());
    return null;
  }
}

/// Step 2: Match unmatched channels against the EPG channel map.
/// Only processes channels with no existing epg_channel_id.
/// Channels with manual overrides are always preserved and skipped.
/// Pass forceAll=true to re-match every channel (used for manual re-match).
static Future<void> matchChannels(
  Source source,
  Map<String, String> channelMap, {
  bool forceAll = false,
  void Function(XmltvProgress)? onProgress,
}) async {
  if (source.id == null) return;

  final channels = forceAll
      ? await Sql.getChannelsForEpgMatching(source.id!)
      : await Sql.getChannelsNeedingEpgMatch(source.id!);

  // Preserve manual overrides regardless
  final manualOverrides = <int, String>{};
  for (final ch in channels) {
    if (ch.epgManualOverride != null && ch.id != null) {
      manualOverrides[ch.id!] = ch.epgManualOverride!;
    }
  }

  // Channels that actually need matching (no manual override, no existing id)
  final toMatch = forceAll
      ? channels.where((c) => c.epgManualOverride == null).toList()
      : channels; // getChannelsNeedingEpgMatch already filters

  AppLog.info(
    'EPG: matching ${toMatch.length} channels'
    ' (${forceAll ? "full re-match" : "unmatched only"})'
    ' for "${source.name}"',
  );

  if (toMatch.isEmpty) {
    AppLog.info('EPG: no unmatched channels — skipping matcher');
    return;
  }

  final allMatched = <int, String>{};
  final tierCounts = <MatchTier, int>{};
  final sampleUnmatched = <String>[];

  for (int i = 0; i < toMatch.length; i += _matchBatchSize) {
    final end = min(i + _matchBatchSize, toMatch.length);
    final batch = toMatch.sublist(i, end);

    final (batchMatched, batchReport) =
        await compute(_matchInIsolate, (channelMap, batch));

    allMatched.addAll(batchMatched);
    for (final e in batchReport.counts.entries) {
      tierCounts[e.key] = (tierCounts[e.key] ?? 0) + e.value;
    }
    if (sampleUnmatched.length < 10) {
      sampleUnmatched.addAll(
        batchReport.sampleUnmatched.take(10 - sampleUnmatched.length),
      );
    }

    onProgress?.call(XmltvProgress(
      programsInserted: 0,
      matchingChannelsDone: end,
      matchingChannelsTotal: toMatch.length,
      statusMessage: 'Matching channels: $end / ${toMatch.length}',
    ));
  }

  final merged = {...allMatched, ...manualOverrides};
  if (merged.isNotEmpty) {
    await Sql.setChannelEpgIds(merged);
  }

  final report = MatchReport(
    counts: tierCounts,
    sampleUnmatched: sampleUnmatched,
    totalChannels: toMatch.length,
  );
  AppLog.info('EPG: match done "${source.name}" — $report');
}

/// Combined refresh (download + match). Used for background refresh
/// and manual full refresh. Pass forceRematch=true to re-match all
/// channels, not just unmatched ones.
static Future<void> refreshSource(
  Source source, {
  String? epgUrl,
  bool background = false,
  bool forceRematch = false,
  void Function(XmltvProgress)? onProgress,
}) async {
  final channelMap = await downloadAndParseEpg(
    source,
    epgUrl: epgUrl,
    onProgress: onProgress,
  );
  if (channelMap == null) return;
  await matchChannels(
    source,
    channelMap,
    forceAll: forceRematch,
    onProgress: onProgress,
  );
}
```

### Result

| Scenario | Before | After |
|---|---|---|
| 60-hour background refresh | Match all 92,692 channels | Match only unmatched channels (typically <5%) |
| New channels added by provider | Matched on next refresh | Same |
| Manual re-match from settings | N/A | Pass `forceRematch: true` |
| User-set manual override | Preserved | Always preserved, never re-matched |

On a 60-hour refresh where 95% of channels are already matched, the
matching step goes from ~185 isolate batches to ~9. On the Onn 4K this
is the difference between "takes forever" and "done in seconds."

### New UI option — "Re-match all channels" button in Settings

Since incremental matching is now the default, add a button to force a
full re-match (useful after EPG feed changes or matcher algorithm updates):

```dart
// In settings_view.dart, near the EPG refresh button:
FilledButton.tonal(
  onPressed: () async {
    // Run full re-match against last downloaded EPG
    final sources = await Sql.getSources();
    for (final s in sources) {
      final epgUrl = EpgService.resolveEpgUrl(s); // make _resolveEpgUrl public
      if (epgUrl == null) continue;
      await EpgService.refreshSource(s, forceRematch: true);
    }
  },
  child: const Text('Re-match all channels'),
),
```

---

## Part 2 — TV Mode Double-Load Investigation

### Is there a different code path on TV?

Yes. On TV (`isTV=true` or `forceTVMode=true`), the app renders `TvHome`
instead of `Home`. The player is opened the same way, but there are two
TV-specific differences that affect the double-load:

**Difference 1: Focus-based prewarm fires immediately on TV**

On a TV remote, navigating with D-pad moves focus across channel tiles.
Every focus change fires `_maybePrewarm()` via `_focusNode.addListener()`.
On a phone, prewarm only fires when the user physically taps a tile and
focuses it deliberately. On TV, scrolling through a list rapidly fires
prewarm for every tile that receives focus — including tiles the user
is just passing through.

This means on TV, by the time the user selects a channel, the prewarm
cache may already contain a URL resolved from a **different** tile that
received focus momentarily during scrolling. If the prewarm cache key
collision resolves an incorrect URL, the first open uses it.

However this doesn't explain a double-load by itself.

**Difference 2: The seek error still fires on first load**

The Onn 4K's chipset (Snapdragon 4s Gen 2) takes longer to buffer than
the test phone. Fix12's grace timer is anchored to `buffering=false` +
500ms. If the grace window closes before the seek error arrives (same
root cause as fix12 was solving), the double-load occurs.

**Verify:** the next Onn 4K log should show whether:
- `suppressed seek probe error` appears (fix12 working) → different cause
- `Cannot seek` appears without suppression → fix12 not working on TV

**Difference 3: No `hasTouchScreen` flag on TV home**

In `TvHome.navigateHome()`, `Home` is constructed with
`hasTouchScreen: false` hardcoded. This is correct but worth noting —
the `Home` widget on TV never receives the settings `refreshOnStart`
flag or `firstLaunch: true` that the phone path gets:

```dart
// Phone path (main.dart):
return Home(
  firstLaunch: true,
  refresh: widget.settings.refreshOnStart,  // ← may trigger a data reload
  home: HomeManager(...),
);

// TV path (tv_home.dart):
return Home(
  home: HomeManager(filters: filters),
  hasTouchScreen: false,
  // firstLaunch and refresh NOT passed ← defaults to false
);
```

This means the TV path doesn't trigger `refreshOnStart` — which is
actually correct. But `firstLaunch` being absent could affect initial
state in `Home`.

### Configurable grace window slider

The 500ms post-buffering grace window is hardcoded. Slower TV hardware
(Onn 4K, older Fire TV sticks) may need more time between `buffering=false`
and grace expiry. Make it a user-configurable setting so TV users can tune
it without a code change.

#### `lib/models/settings.dart` — add field

```dart
// After stableThresholdSecs:
/// Milliseconds to hold startup grace after buffering=false before
/// allowing seek errors and completed events to trigger a reconnect.
/// Higher values help slower hardware where the mpv seek probe fires
/// more than 500ms after buffering=false. Default: 500ms. Range: 100–3000ms.
int startupGraceMs;

// In constructor default:
this.startupGraceMs = 500,
```

#### `lib/player.dart` — use setting instead of hardcoded 500ms

In `_onBufferingChanged()`, replace:

```dart
Future.delayed(const Duration(milliseconds: 500), () {
```

With:

```dart
Future.delayed(
  Duration(milliseconds: widget.settings.startupGraceMs), () {
```

#### `lib/backend/settings_service.dart` — persist it

Add alongside other int settings:
```dart
const startupGraceMsProp = "startupGraceMs";

// In _readFromDb():
var graceMs = settingsMap[startupGraceMsProp];
if (graceMs != null) settings.startupGraceMs = int.parse(graceMs);

// In updateSettings():
settingsMap[startupGraceMsProp] = settings.startupGraceMs.toString();
```

#### `lib/settings_view.dart` — add slider

Add after the `stableThresholdSecs` slider, following the same
`_bufferSlider` pattern:

```dart
_bufferSlider(
  label: 'Startup grace window (ms)',
  value: settings.startupGraceMs.toDouble(),
  min: 100,
  max: 3000,
  divisions: 29,   // 100ms steps
  help: (
    title: 'Startup Grace Window (ms)',
    body: 'How long after buffering starts to suppress seek probe '
        'errors that would otherwise cause an immediate reconnect. '
        'Increase this on slower TV hardware (Onn 4K, Fire TV Stick) '
        'if streams still double-start. Default: 500ms. Range: 100–3000ms.',
  ),
  onChanged: (v) {
    setState(() => settings.startupGraceMs = v.round());
    updateSettings();
  },
),
```

### Recommended action

Get a log from the Onn 4K showing the double-load. The log will
immediately reveal whether:
1. Seek error fires with `startupGrace=false` → increase `startupGraceMs`
2. Seek error suppressed but double-start still occurs → different cause
3. Something else in the TV navigation path

---

## Files to edit

### Part 1 (EPG separation):
- `lib/backend/sql.dart` — add `getChannelsNeedingEpgMatch()`
- `lib/backend/epg_service.dart` — split into `downloadAndParseEpg()`,
  `matchChannels()`, updated `refreshSource()`
- `lib/settings_view.dart` — add "Re-match all channels" button
  (optional but recommended)

### Part 2 (TV double-load):
- Pending log from Onn 4K before writing a fix

## Model

Part 1: Opus (architectural split of a core pipeline)
Part 2: Sonnet 4.6 after log analysis

### Part 2 (grace window slider):
- `lib/models/settings.dart` — add `startupGraceMs` field (default: 500)
- `lib/player.dart` — replace hardcoded 500ms with `widget.settings.startupGraceMs`
- `lib/backend/settings_service.dart` — persist `startupGraceMs` (3 additions, same pattern as fix10)
- `lib/settings_view.dart` — add `_bufferSlider` for grace window after `stableThresholdSecs` slider
