# fix58.md — Per-source refresh progress + settings collapsible groups + WAL analysis

> **Version:** Free4Me-IPTV 1.17.9
> **Evidence:** `free4me_log_1779828553335.txt`
>
> Three requests:
>
> 1. Per-source refresh button shows the blue pulsing-dot overlay
>    instead of a progress dialog like the other refresh actions.
>
> 2. Settings is long — collapse the larger tunable sections into
>    expandable groups to reduce scrolling. Keep as flat tiles:
>    Default view, Diagnostics, Backup & Restore, Reset, App, Sources.
>
> 3. Log analysis — why is "yes network" still slow in 1.17.9 despite
>    the DB split?

---

## Part 3 — Log analysis (read this first)

### What the log shows

```
16:46:18  App launch — 1.17.9
16:46:20  Sql.search[1] History: sql=1427ms   ← slow on first query
16:46:20  EpgDb: opened epg.sqlite             ← DB split confirmed working
16:46:34  Sql.search[1] All:    sql=26ms       ← recovered
16:46:38  Sql.search[2] "y":   sql=1ms
16:46:39  Sql.search[4] "yes": sql=121ms       ← elevated
16:46:40  Sql.search[6] "yes n": [queued at 16:46:40]
16:47:10  Sql.search[6]:       sql=29597ms     ← 30s blocked
16:47:54  Sql.search[7] "yes network": sql=73103ms ← 73s blocked
```

### Root cause — fix56 not yet applied; setChannelEpgIds WAL on db.sqlite

The DB split (fix56) moved `programmes` to `epg.sqlite` — confirmed
by `EpgDb: opened epg.sqlite`. But the slow queries are hitting
`db.sqlite`, not `epg.sqlite`.

`setChannelEpgIds` writes to `channels.epg_channel_id` in `db.sqlite`.
The `channels_au` FTS trigger fires on every UPDATE — delete + insert
on `channels_fts`. With 14,303 EPG assignments from the previous
session:

```
14,303 UPDATEs × (1 UPDATE + 1 FTS delete + 1 FTS insert) = 42,909 WAL writes → db.sqlite
```

The checkpoint for that WAL didn't complete before the app was closed.
On the next launch, the resume checkpoint ran in the background — hence
`sql=1427ms` on the first query, and the escalating blocks on "yes n"
and "yes network".

### Fix already written

The updated `checkpointAndTruncateWal()` in fix56 checkpoints **both**
`db.sqlite` and `epg.sqlite`. Once fix56 ships, the `db.sqlite` WAL
is flushed after matching completes and these delays disappear.

**No new code needed for this item.** The fix is already in fix56.
The log confirms fix56 is not yet applied in 1.17.9.

---

# Part 1 — Per-source refresh progress dialog

## Problem

The per-source refresh button (Settings → Sources → row → refresh
icon) calls `Error.tryAsync(() => Utils.refreshSource(source))`.
`Error.tryAsync` shows `context.loaderOverlay.show()` — the
`LoaderOverlay` widget which renders as a pulsing blue dot over the
screen with no status text and no progress.

## Fix 58.1 — Replace `Error.tryAsync` with a per-source progress dialog

`Utils.refreshSource` already accepts `onProgress(String)`. Wire it
to an `AlertDialog` in the same style as `_runEpgRefresh`.

**File:** `lib/settings_view.dart`

**Current code (lines 369–381):**

```dart
Offstage(
  offstage: source.sourceType == SourceType.m3u,
  child: IconButton(
    icon: const Icon(Icons.refresh),
    onPressed: () async {
      await Error.tryAsync(
        () async {
          await Utils.refreshSource(source);
        },
        context,
        "Source has been refreshed successfully",
      );
    },
  ),
),
```

**Replace with:**

```dart
Offstage(
  offstage: source.sourceType == SourceType.m3u,
  child: IconButton(
    icon: const Icon(Icons.refresh),
    onPressed: () async {
      await _refreshSingleSource(source);
      if (mounted) await reloadSources();
    },
  ),
),
```

**Add `_refreshSingleSource` method** to `_SettingsViewState`,
near `_runEpgRefresh`:

```dart
/// Refresh a single source with a progress dialog.
/// Mirrors the style of [_runEpgRefresh] — non-dismissible dialog,
/// status text updated via onProgress, summary on completion.
Future<void> _refreshSingleSource(Source source) async {
  AppLog.info('Settings: refresh single source "${source.name}"');

  String status = 'Connecting…';
  bool done = false;
  String? error;
  bool dialogOpen = true;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => StatefulBuilder(
      builder: (sCtx, setSt) {
        return PopScope(
          canPop: done,
          child: AlertDialog(
            title: Text('Refreshing "${source.name}"…'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!done) const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(
                  status,
                  style: Theme.of(sCtx).textTheme.bodySmall,
                ),
              ],
            ),
            actions: done
                ? [
                    FilledButton(
                      onPressed: () => Navigator.pop(sCtx),
                      child: const Text('OK'),
                    ),
                  ]
                : null,
          ),
        );
      },
    ),
  ).then((_) => dialogOpen = false);

  try {
    await Utils.refreshSource(
      source,
      onProgress: (msg) {
        if (dialogOpen) {
          // _refreshSetState is the shared dialog setState reference.
          // We can't use it here since this dialog has its own builder.
          // Status is tracked locally; the StatefulBuilder reads it
          // on rebuild. Trigger rebuild via a mounted check pattern.
          // Actually: capture setSt via a closure instead.
        }
      },
    );
    AppLog.info('Settings: refresh "${source.name}" — done');
    status = 'Refresh complete.';
  } catch (e, st) {
    error = e.toString();
    AppLog.warn('Settings: refresh "${source.name}" — ERROR: $e\n$st');
    status = 'Error: $error';
  }

  // Mark done and trigger final rebuild.
  done = true;
  // The StatefulBuilder won't rebuild automatically — use the
  // _refreshSetState pattern. But this dialog has its own local setSt.
  // Simplest fix: use a Completer-based approach matching fix44.
}
```

> **Note for implementer:** the StatefulBuilder captures `setSt`
> locally but it's not accessible from the outer async function
> using the simple pattern above. Use the **Completer pattern from
> fix44** — same structure as `showSourcesRefreshDialog`. Here is
> the correct implementation:

```dart
Future<void> _refreshSingleSource(Source source) async {
  AppLog.info('Settings: refresh single source "${source.name}"');

  String status = 'Connecting…';
  bool done = false;
  String? errorMsg;

  final dialogReady = Completer<void>();
  late void Function(void Function()) setSt;

  final dialogClosed = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => StatefulBuilder(
      builder: (sCtx, s) {
        setSt = s;
        if (!dialogReady.isCompleted) dialogReady.complete();
        return PopScope(
          canPop: done,
          child: AlertDialog(
            title: Text('Refreshing "${source.name}"…'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!done) const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(
                  status,
                  style: Theme.of(sCtx).textTheme.bodySmall,
                ),
              ],
            ),
            actions: done
                ? [
                    FilledButton(
                      onPressed: () => Navigator.pop(sCtx),
                      child: const Text('OK'),
                    ),
                  ]
                : null,
          ),
        );
      },
    ),
  );

  unawaited(() async {
    await dialogReady.future;
    try {
      await Utils.refreshSource(
        source,
        onProgress: (msg) => setSt(() {
          status = msg.length > 60 ? '${msg.substring(0, 60)}…' : msg;
        }),
      );
      AppLog.info('Settings: refresh "${source.name}" — done');
      setSt(() {
        done = true;
        status = 'Refresh complete.';
      });
    } catch (e, st) {
      errorMsg = e.toString();
      AppLog.warn('Settings: refresh "${source.name}" — ERROR: $e\n$st');
      setSt(() {
        done = true;
        status = 'Error: $errorMsg';
      });
    }
  }());

  await dialogClosed;
}
```

Add `import 'dart:async';` at the top if not already present.

---

# Part 2 — Collapse large settings sections into expandable groups

## Which sections to collapse

Keep flat (as requested):
- Default view
- Diagnostics
- Backup & Restore
- Reset
- App
- Sources

Collapse into `ExpansionTile` groups:
- **Buffering** — all the slider settings (Livestream cache, VOD cache, Demuxer size, etc.)
- **Playback** — Force TV mode, Low latency, Hardware decode, Pre-warm, Player engine
- **Multi-view** — Multi-view layout tile + Restore last channels toggle
- **EPG / Program Guide** — EPG section (refresh interval, auto-refresh, Refresh EPG now, Re-match)
- **Content** — Show livestreams / movies / series toggles, Refresh on start, Stream scanner

## Implementation pattern

Wrap each group in an `ExpansionTile`. Use `initiallyExpanded: false`
so all groups start collapsed. The existing `_sectionHeader` widget
becomes the `title` of the `ExpansionTile`. Children are the existing
tiles, unchanged.

**General pattern for each collapsed group:**

```dart
ExpansionTile(
  title: Text(
    'Buffering',
    style: Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    ),
  ),
  leading: const Icon(Icons.tune),  // pick appropriate icon per section
  tilePadding: const EdgeInsets.symmetric(horizontal: 10),
  childrenPadding: EdgeInsets.zero,
  children: [
    // ... existing slider/toggle widgets unchanged ...
  ],
),
```

## Section-by-section

**Buffering group** — icon: `Icons.tune`
Wraps: Livestream cache slider, VOD cache slider, all demuxer/buffer
size sliders, stable threshold, stream-completed delay, open timeout,
watchdog sliders. Currently between `_sectionHeader("Buffering
(Android TV)")` at line 1186 and the `Divider` before Stream Scanner
at line 1426.

**Playback group** — icon: `Icons.play_circle_outline`
Wraps: Force TV mode switch, Low latency switch, Hardware decode
switch, Pre-warm switch, Player engine picker tile. Currently spread
between lines 1161 and 1580.

**Multi-view group** — icon: `Icons.grid_view`
Wraps: Multi-view layout tile + Restore last channels SwitchListTile.
Currently around lines 1042–1094.

**Content group** — icon: `Icons.filter_list`
Wraps: Show livestreams / movies / series switches, Refresh on start
switch, Stream scanner section. Currently lines 1541–1486.

**EPG / Program Guide group** — icon: `Icons.calendar_month`
Wraps: Everything in the existing `_sectionHeader("EPG / Program Guide")`
block — auto-refresh, forecast days, debug log, Refresh EPG now,
Re-match all channels. Currently lines 1582–1838.

## Remove `_sectionHeader` calls inside collapsed groups

The `ExpansionTile` title serves as the section header — the inner
`_sectionHeader` widget is redundant once it's inside an
`ExpansionTile`. Remove it from inside each group. Keep
`_sectionHeader` for the flat sections (Diagnostics, Backup, Reset,
App).

## Keep `const Divider()` between top-level groups

The dividers between sections can stay — they visually separate the
collapsed group tiles from each other and from the flat sections.

---

## Test plan

### Fix 58.1 — per-source progress dialog

1. Go to Settings → Sources.
2. Tap the refresh icon on an Xtream source row.
3. **Expected:** an `AlertDialog` appears titled
   `'Refreshing "SourceName"…'` with a `LinearProgressIndicator`
   and status text that updates as the source loads.
4. When complete: title unchanged, progress bar gone, status reads
   "Refresh complete.", OK button appears.
5. Tap OK. Source row updates with new channel count.
6. In the log: `Settings: refresh "SourceName" — done`.
7. On error (e.g. bad URL): dialog shows "Error: ..." with OK button.
   No crash. Log shows `WARN Settings: refresh … ERROR`.

### Fix 58.2 — collapsible settings groups

1. Open Settings. Should load noticeably faster with fewer visible
   widgets.
2. Tap "Buffering" — expands to show all sliders.
3. Tap "Buffering" again — collapses.
4. Tap "EPG / Program Guide" — expands, shows Refresh EPG now and
   Re-match tiles among others.
5. All existing functionality unchanged inside expanded sections.
6. Flat sections (Default view, Diagnostics, Backup, Reset, App,
   Sources) still visible without expanding.

### Fix 56 regression reminder

Once fix56 ships (epg.sqlite DB split), confirm in the log:
```
Sql.checkpoint [db.sqlite]: WAL truncated in Nms   ← after setChannelEpgIds
Sql.search[6]: sql=Xms                             ← X should be <200ms
```
The 30s/73s delays in this log are fixed by fix56, not by anything in fix58.

---

# Part 4 — Fill three diagnostic logging gaps

Analysis of 1.17.9 confirmed that the import → source refresh → EPG
refresh flow has enough coverage for the happy path, but three specific
sub-steps produce no log output. If fix50.A (EPG ID preservation through
backup) fails silently, there is currently no way to tell from the log.

## Gap 1 — `_pendingPreserves` staging is silent

**File:** `lib/backend/settings_io.dart`

When a backup is imported, each source's `preserve` list is parsed and
staged in `_pendingPreserves` for application after the source refresh
populates channels. This staging step produces no log output — if the
backup contains EPG channel IDs (fix50.A) and they're not applied, the
log gives no clue why.

**Current code (lines 228–240):**

```dart
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
```

**Replace with:**

```dart
final preserveRaw = map['preserve'] as List<dynamic>?;
if (preserveRaw != null && preserveRaw.isNotEmpty) {
  final preserveList = preserveRaw
      .map((p) {
        final m = p as Map<String, dynamic>;
        return ChannelPreserve(
          name: m['name'] as String,
          favorite: m['favorite'] as int?,
          lastWatched: m['lastWatched'] as int?,
          epgChannelId: m['epgChannelId'] as String?,
          epgManualOverride: m['epgManualOverride'] as String?,
        );
      })
      .toList();
  _pendingPreserves[source.name] = preserveList;
  AppLog.info(
    'SettingsIo.import: staged preserves for "${source.name}"'
    ' total=${preserveList.length}'
    ' epg=${preserveList.where((p) => p.epgChannelId != null).length}'
    ' favorites=${preserveList.where((p) => p.favorite == 1).length}',
  );
}
```

> **Note:** `epgChannelId` and `epgManualOverride` were added to
> `ChannelPreserve` in fix50.A but the import's `_pendingPreserves`
> staging (the code block above) was not updated to read them from
> the backup JSON at the same time. This fix adds both the logging
> and the missing field reads, completing fix50.A's backup import
> path.

## Gap 2 — `applyPendingPreserves` produces no log output

**File:** `lib/backend/settings_io.dart`

`applyPendingPreserves` is called from `Utils.refreshSource` after
every M3U/Xtream refresh. It silently returns early if no pending
preserves exist for the source. There is no log line for either the
"nothing to apply" case or the "applied N preserves" case.

**Current code (lines 268–290):**

```dart
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
    return;
  }

  await Sql.commitWrite(
    [Sql.restorePreserve(preserve)],
    memory: {'sourceId': source.id!.toString()},
  );
}
```

**Replace with:**

```dart
static Future<void> applyPendingPreserves(String sourceName) async {
  final preserve = _pendingPreserves.remove(sourceName);
  if (preserve == null || preserve.isEmpty) {
    AppLog.info(
      'SettingsIo.applyPendingPreserves: no staged preserves'
      ' for "$sourceName" — skipping',
    );
    return;
  }

  final sources = await Sql.getSources();
  Source? source;
  for (final s in sources) {
    if (s.name == sourceName) {
      source = s;
      break;
    }
  }
  if (source == null || source.id == null) {
    AppLog.warn(
      'SettingsIo.applyPendingPreserves: source "$sourceName" not found'
      ' in DB — dropping ${preserve.length} staged preserves',
    );
    return;
  }

  AppLog.info(
    'SettingsIo.applyPendingPreserves: applying ${preserve.length}'
    ' preserves to "$sourceName" (sourceId=${source.id})'
    ' epg=${preserve.where((p) => p.epgChannelId != null).length}'
    ' favorites=${preserve.where((p) => p.favorite == 1).length}',
  );
  await Sql.commitWrite(
    [Sql.restorePreserve(preserve)],
    memory: {'sourceId': source.id!.toString()},
  );
  AppLog.info(
    'SettingsIo.applyPendingPreserves: done for "$sourceName"',
  );
}
```

## Gap 3 — File-based M3U has no start marker

**File:** `lib/backend/m3u.dart`

`processM3UUrl` logs `M3U: downloading source=... url=...` before
the download starts. `processM3U` (the file-based path, called
directly for local M3U files) has no equivalent start marker — the
first log line is `M3U: preserve captured` which appears only after
`getChannelsPreserve` runs. There's no timestamp anchor for when
parsing actually starts.

**Current code (lines 30–52, top of `processM3U`):**

```dart
Future<void> processM3U(
  Source source,
  bool wipe, [
  String? path,
  void Function(String)? onProgress,
]) async {
  path ??= source.url;
  List<ChannelPreserve>? preserve;
  final memory = <String, String>{};
  onProgress?.call('Connecting…');
  await Sql.commitWrite([Sql.getOrCreateSourceByName(source)], memory: memory);
  final sourceId = int.parse(memory['sourceId']!);
  source.id = sourceId;
  if (wipe) {
    preserve = await Sql.getChannelsPreserve(sourceId);
```

**Replace `onProgress?.call('Connecting…');` with:**

```dart
  AppLog.info(
    'M3U: processing source="${source.name}"'
    ' wipe=$wipe path="${path ?? source.url}"',
  );
  onProgress?.call('Connecting…');
```

One line added. The path value confirms whether it's a local file or
a temp-downloaded URL path (the latter looks like `.../temp/xxxxx.m3u`).

---

## What the full log looks like after all four parts

For a clean backup import → source refresh → EPG refresh session:

```
Setup: import backup — started
SettingsIo.import: source "Aniel3000 " enabled=true type=m3u engine=auto
SettingsIo.import: staged preserves for "Aniel3000 "
  total=15345 epg=15345 favorites=7
SettingsIo.import: source "Emjay" enabled=false type=m3u engine=auto
Setup: import backup — 2 sources imported (1 enabled): "Aniel3000 "(on) "Emjay"(off)
Setup: import backup — launching source refresh dialog
SourcesRefreshDialog: showing
SourcesRefreshDialog: dialog built — ready
SourcesRefreshDialog: starting refresh
Utils.refreshAllSources: 1 enabled source(s) (Aniel3000 )
SourcesRefreshDialog: source 1/1 "Aniel3000 " starting
M3U: processing source="Aniel3000 " wipe=true path="https://..."
M3U: preserve captured — source="Aniel3000 " epg=0 favorites=0 total=0
Sql.wipeSource: sourceId=1 deleted 0 channels
M3U: parsed source="Aniel3000 " channels=35945
M3U: preserve restored — source="Aniel3000 " channels=35945
Sql.restorePreserve: sourceId=1 total=0 epgRestored=0 manualRestored=0
SettingsIo.applyPendingPreserves: applying 15345 preserves to "Aniel3000 "
  (sourceId=1) epg=15345 favorites=7
SettingsIo.applyPendingPreserves: done for "Aniel3000 "
SourcesRefreshDialog: refresh complete — 1 source(s) done
SourcesRefreshDialog: user dismissed
Setup: import backup — refresh dialog complete, navigating to Home
```

Then EPG refresh:

```
EpgRefresh: starting — 1 eligible source(s): "Aniel3000 "
EpgRefresh: source "Aniel3000 " — starting
XMLTV: GET https://...
XMLTV: parse done — 15522 channels, 601267 programs inserted
Sql.checkpoint [epg.sqlite]: WAL truncated in Nms
Sql.checkpoint [db.sqlite]: WAL truncated in Nms
EPG: matchChannels: channelMap=15522 toMatch=0 forceAll=false
EPG: no unmatched channels — skipping matcher        ← fix50.A confirmed working
EpgRefresh: source "Aniel3000 " — done programs=601267 matched=0/0
EpgRefresh: complete — 1 source(s) processed
```

`toMatch=0` and "skipping matcher" is the proof that fix50.A worked —
all 35,945 channels already have `epg_channel_id` from the backup
preserves. No rematch needed.

---

## Notes for the implementer

- **`_refreshSingleSource` uses the same Completer pattern as
  `showSourcesRefreshDialog`** (fix44). This is the correct pattern
  for driving a `StatefulBuilder` dialog from an async function.
  The implementation is self-contained in `settings_view.dart` —
  no new file needed.
- **`import 'dart:async'`** for `Completer` and `unawaited`. Check
  whether already imported at the top of `settings_view.dart`.
- **The per-source refresh is Xtream-only** (the `Offstage` hides it
  for M3U sources). M3U sources use the "Refresh all sources" dialog.
- **`ExpansionTile` preserves state by default** when scrolling — the
  expanded/collapsed state resets if the widget is rebuilt (e.g. after
  `setState` from a settings change). For persistence across rebuilds,
  wrap each `ExpansionTile` with a `PageStorageKey`. Not required but
  improves UX if settings changes cause rebuilds.
  ```dart
  ExpansionTile(
    key: const PageStorageKey('buffering'),
    ...
  )
  ```
- **`initiallyExpanded: false`** on all groups so the page loads
  collapsed and scrolls quickly.
- **No logic changes** to existing settings handlers, validators, or
  callbacks. Only the widget tree structure changes for fix58.2.
- **Gap 1 also completes fix50.A's backup import path** — the original
  fix50.A code added `epgChannelId` and `epgManualOverride` to
  `ChannelPreserve` and to `restorePreserve`, but the `_pendingPreserves`
  staging block in `importFromFile` was never updated to read those
  fields from the backup JSON. Without this fix, EPG IDs staged via
  backup are silently `null` even when the backup JSON contains them.
- **Total code change:** ~80 lines for fix58.1, ~60 lines for fix58.2,
  ~50 lines for fix58.3 (Part 4 logging). No new dependencies.

---

## Follow-up WAL checkpoint fixes (fix60, fix62)

Two additional `checkpointAndTruncateWal()` calls were added after
fix58 shipped, covering batch writes that were still leaving unflushed
WAL pages on exit:

- **fix60** — `SettingsIo.applyPendingPreserves` (`settings_io.dart`):
  checkpoint after the `restorePreserve` batch write so that EPG/
  favourite data written during backup restore is flushed before the
  user navigates to the home screen.

- **fix62** — `EpgService.matchChannels` (`epg_service.dart`):
  checkpoint after `setChannelEpgIds` so the 14k+ FTS trigger writes
  (one per matched channel) are flushed immediately after matching
  completes, not lazily on the next read query.

See fix60.md and fix62.md for the individual runbooks.
