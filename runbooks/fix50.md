# fix50.md — EPG/channel refresh systemic fix + rematch stall + false warning

> **Version:** Free4Me-IPTV 1.17.6
> **Evidence:** `free4me_log_1779758640161.txt`, `free4me-backup__4_.json`

---

## Three bugs, one session — and one systemic root cause tying them together

```
21:15:05  EpgRefresh: starting — 1 eligible source(s): "Aniel3000 "
21:15:05  XMLTV: GET …
21:16:02  XMLTV: parse done — 15522 channels, 601434 programs inserted
21:16:07  EPG: downloaded "Aniel3000 " — 601434 programs
21:16:07  EPG: matching 20600 channels (unmatched only) for "Aniel3000 "
21:16:16  EPG: match done "Aniel3000 " — 0/20600 matched (none=8558, ambiguous=12042)
21:16:16  EpgRefresh: source "Aniel3000 " — 0 programs loaded    ← false warning
21:16:28  EpgRematch: starting — 1 eligible source(s): "Aniel3000 "
           [log ends — rematch never progressed]                  ← stall
```

### The systemic issue — epg_channel_id is not preserved through source refresh

Every M3U or Xtream source refresh (wipe=true) follows this pattern:

1. `getChannelsPreserve(sourceId)` — saves `(name, favorite, last_watched)` only
2. `wipeSource(sourceId)` — DELETE all channels for the source
3. Re-import channels (all with `epg_channel_id = NULL`)
4. `restorePreserve(preserve)` — restores `favorite` and `last_watched` only

`epg_channel_id` and `epg_manual_override` are **not captured and not
restored**. Every source refresh silently erases every EPG assignment the
matcher produced. The user must then manually refresh EPG or wait up to
60 hours for the background refresh.

This explains the `0/20600 matched` result in the log: a source refresh
ran at some point (channel count dropped 35,945 → 20,600 and
`matchChannels` was called with `forceAll=false` meaning only channels
with `epg_channel_id IS NULL` are matched — which is now ALL channels).
The 15,345 previously-matched channels are literally the same channels
that were removed from the M3U (they're not in the 20,600 post-refresh
set), so their matches can't come back. The remaining 20,600 genuinely
produce 0 matches from the matcher — `none=8558, ambiguous=12042`.

The EPG data is fine. The programs are fine. The channels just have
no EPG IDs after each refresh.

### Bug A — `sourceInserted` clobbered by match-phase onProgress

`_runEpgRefresh` uses a single `onProgress` callback for both phases.
`matchChannels` fires `onProgress` with `programsInserted: 0` (because
the match phase doesn't insert programs). This overwrites `sourceInserted`
(which was correctly 601,434 after download) with 0. The
`if (sourceInserted == 0)` check fires a false warning.

### Bug B — Rematch stalls because `_refreshSetState` holds disposed widget

After EpgRefresh closes its dialog, `_refreshSetState` holds the
disposed dialog's `setSt`. When `_runEpgRematch` calls
`_updateRefreshDialog` before its own dialog builds, it invokes the
disposed `State.setState`. Flutter's `State.setState` executes
`_element!.markNeedsBuild()` — `_element` is null after dispose →
`Null check operator used on a null value` → exception propagates
through the for-loop (no try-catch) → kills all work before
`downloadAndParseEpg` is ever called. Dialog stays open at
"Starting…" forever with no OK button.

---

## Apply order

1. **Fix 50.A** — `ChannelPreserve` + `getChannelsPreserve` + `restorePreserve` — the systemic fix
2. **Fix 50.B** — logging throughout the refresh/match pipeline
3. **Fix 50.C** — `sourceInserted` guard (Bug A)
4. **Fix 50.D** — `_refreshSetState = null` before each dialog (Bug B)

---

# Fix 50.A — Preserve `epg_channel_id` and `epg_manual_override` through source refresh

## Step 1 — Extend `ChannelPreserve`

**File:** `lib/models/channel_preserve.dart`

**Replace entire file:**

```dart
class ChannelPreserve {
  String name;
  int? favorite;
  int? lastWatched;
  // fix50: also preserve EPG assignments so source refresh doesn't
  // erase every EPG match the user has accumulated.
  String? epgChannelId;
  String? epgManualOverride;

  ChannelPreserve({
    required this.name,
    this.favorite,
    this.lastWatched,
    this.epgChannelId,
    this.epgManualOverride,
  });
}
```

## Step 2 — Extend `getChannelsPreserve`

**File:** `lib/backend/sql.dart`

**Current code (lines 665-679):**

```dart
static Future<List<ChannelPreserve>> getChannelsPreserve(int sourceId) async {
  var db = await DbFactory.db;
  var results = await db.getAll('''
    SELECT name, favorite, last_watched
    FROM channels
    WHERE (favorite = 1 OR last_watched IS NOT NULL) AND source_id = ?
  ''', [sourceId]);
  return results.map(rowToChannelPreserve).toList();
}

static ChannelPreserve rowToChannelPreserve(Row row) {
  return ChannelPreserve(
      name: row.columnAt(0),
      favorite: row.columnAt(1),
      lastWatched: row.columnAt(2));
}
```

**Replace with:**

```dart
/// Capture per-channel attributes that must survive a source wipe:
/// favorites, watch history, EPG assignments, and manual EPG overrides.
///
/// fix50: extended to include epg_channel_id and epg_manual_override.
/// Before this fix, every source refresh erased all EPG matches,
/// requiring a full re-match after every M3U/Xtream reload.
static Future<List<ChannelPreserve>> getChannelsPreserve(int sourceId) async {
  var db = await DbFactory.db;
  var results = await db.getAll('''
    SELECT name, favorite, last_watched, epg_channel_id, epg_manual_override
    FROM channels
    WHERE source_id = ?
      AND (
        favorite = 1
        OR last_watched IS NOT NULL
        OR epg_channel_id IS NOT NULL
        OR epg_manual_override IS NOT NULL
      )
  ''', [sourceId]);
  final preserve = results.map(rowToChannelPreserve).toList();
  AppLog.info(
    'Sql.getChannelsPreserve: sourceId=$sourceId'
    ' total=${preserve.length}'
    ' favorites=${preserve.where((p) => p.favorite == 1).length}'
    ' lastWatched=${preserve.where((p) => p.lastWatched != null).length}'
    ' epgMatched=${preserve.where((p) => p.epgChannelId != null).length}'
    ' epgManual=${preserve.where((p) => p.epgManualOverride != null).length}',
  );
  return preserve;
}

static ChannelPreserve rowToChannelPreserve(Row row) {
  return ChannelPreserve(
    name: row.columnAt(0),
    favorite: row.columnAt(1),
    lastWatched: row.columnAt(2),
    epgChannelId: row.columnAt(3) as String?,
    epgManualOverride: row.columnAt(4) as String?,
  );
}
```

## Step 3 — Extend `restorePreserve`

**File:** `lib/backend/sql.dart`

**Current code (lines 682-695):**

```dart
static Future<void> Function(SqliteWriteContext, Map<String, String>)
    restorePreserve(List<ChannelPreserve> preserve) {
  return (SqliteWriteContext tx, Map<String, String> memory) async {
    final sourceId = int.parse(memory['sourceId']!);
    for (var channel in preserve) {
      await tx.execute('''
        UPDATE channels
        SET favorite = ?, last_watched = ?
        WHERE name = ?
        AND source_id = ?
      ''', [channel.favorite, channel.lastWatched, channel.name, sourceId]);
    }
  };
}
```

**Replace with:**

```dart
/// Restore per-channel attributes after a wipe+re-import.
///
/// fix50: extended to also restore epg_channel_id and epg_manual_override.
/// epg_channel_id is only restored if the channel doesn't already have
/// one (from an M3U/Xtream that embeds its own EPG IDs). Manual overrides
/// are always restored — the user explicitly set them.
static Future<void> Function(SqliteWriteContext, Map<String, String>)
    restorePreserve(List<ChannelPreserve> preserve) {
  return (SqliteWriteContext tx, Map<String, String> memory) async {
    final sourceId = int.parse(memory['sourceId']!);
    int restoredEpg = 0;
    int restoredManual = 0;
    for (var channel in preserve) {
      await tx.execute('''
        UPDATE channels
        SET favorite       = ?,
            last_watched   = ?,
            -- Only fill epg_channel_id if the fresh import left it null.
            -- Some M3U/Xtream sources embed their own EPG IDs; if so the
            -- COALESCE in insertChannel already handled it and we don't
            -- want to overwrite a fresher value with a stale one.
            epg_channel_id    = COALESCE(epg_channel_id, ?),
            -- Manual overrides always win — the user pinned these.
            epg_manual_override = COALESCE(?, epg_manual_override)
        WHERE name = ?
        AND source_id = ?
      ''', [
        channel.favorite,
        channel.lastWatched,
        channel.epgChannelId,
        channel.epgManualOverride,
        channel.name,
        sourceId,
      ]);
      if (channel.epgChannelId != null) restoredEpg++;
      if (channel.epgManualOverride != null) restoredManual++;
    }
    AppLog.info(
      'Sql.restorePreserve: sourceId=$sourceId'
      ' total=${preserve.length}'
      ' epgRestored=$restoredEpg'
      ' manualRestored=$restoredManual',
    );
  };
}
```

---

# Fix 50.B — Comprehensive logging throughout the refresh pipeline

## `lib/backend/sql.dart` — wipeSource and setChannelEpgIds

**In `wipeSource` — add a pre-delete count log:**

```dart
static Future<void> Function(SqliteWriteContext, Map<String, String>)
    wipeSource(int sourceId) {
  return (SqliteWriteContext tx, Map<String, String> memory) async {
    final countRow = await tx.getOptional(
      'SELECT COUNT(*) FROM channels WHERE source_id = ?', [sourceId]);
    final before = countRow?.columnAt(0) ?? 0;
    await tx.execute('DELETE FROM channels WHERE source_id = ?', [sourceId]);
    await tx.execute('DELETE FROM groups WHERE source_id = ?', [sourceId]);
    AppLog.info('Sql.wipeSource: sourceId=$sourceId deleted $before channels');
  };
}
```

**In `setChannelEpgIds` — add a completion log:**

After the `writeTransaction` block, add:

```dart
AppLog.info('Sql.setChannelEpgIds: wrote ${channelIdToEpgId.length} EPG assignments');
```

## `lib/backend/epg_service.dart` — matchChannels

Add logs for channelMap size, toMatch breakdown, and the match
write at the end. Find the section around line 185-248 and add:

**After line 189 (`AppLog.info('EPG: matching...'`):**

```dart
AppLog.info(
  'EPG: matchChannels: channelMap=${channelMap.length} entries'
  ' toMatch=${toMatch.length}'
  ' forceAll=$forceAll'
  ' manualOverrides=${manualOverrides.length}',
);
```

**After line 232 (`final merged = ...`):**

```dart
AppLog.info(
  'EPG: matchChannels write: merged=${merged.length}'
  ' (matched=${allMatched.length} + manualOverrides=${manualOverrides.length})',
);
```

## `lib/backend/m3u.dart` — log preserve before and after

**After line 44 (`preserve = await Sql.getChannelsPreserve(sourceId);`):**

```dart
AppLog.info(
  'M3U: preserve captured — source="${source.name}"'
  ' epg=${preserve.where((p) => p.epgChannelId != null).length}'
  ' favorites=${preserve.where((p) => p.favorite == 1).length}'
  ' total=${preserve.length}',
);
```

**After line 107 (`await Sql.commitWrite(tail, memory: memory);`):**

```dart
AppLog.info(
  'M3U: preserve restored — source="${source.name}"'
  ' channels=$channelCount',
);
```

## `lib/backend/xtream.dart` — same pattern

After `preserve = await Sql.getChannelsPreserve(source.id!);`:

```dart
AppLog.info(
  'Xtream: preserve captured — source="${source.name}"'
  ' epg=${preserve.where((p) => p.epgChannelId != null).length}'
  ' favorites=${preserve.where((p) => p.favorite == 1).length}'
  ' total=${preserve.length}',
);
```

## `lib/settings_view.dart` — `_runEpgRefresh` and `_runEpgRematch`

In `_runEpgRefresh`, after `EpgService.refreshSource` completes (but
inside the try, before the `if (sourceInserted == 0)` check), add:

```dart
AppLog.info(
  'EpgRefresh: source "${source.name}" — onProgress summary:'
  ' finalInserted=$sourceInserted'
  ' matched=$sourceMatchedChannels/$sourceTotalChannels',
);
```

In `_runEpgRematch`, after the `EpgService.matchChannels` call completes:

```dart
AppLog.info(
  'EpgRematch: source "${source.name}" — match complete:'
  ' done=$matchDone total=$matchTotal',
);
```

---

# Fix 50.C — Guard `sourceInserted` against match-phase overwrites

**File:** `lib/settings_view.dart`

**Current code (lines 531-534):**

```dart
onProgress: (p) {
  sourceInserted = p.programsInserted;
  programs = p.programsInserted;
```

**Replace with:**

```dart
onProgress: (p) {
  // fix50.C: only update program count during download phase.
  // matchChannels fires onProgress with programsInserted: 0 (it
  // doesn't insert programs). Without this guard, the match-phase
  // callbacks overwrite sourceInserted with 0, producing a false
  // "0 programs loaded" warning even when 600k+ programs were inserted.
  if (!p.isMatching) {
    sourceInserted = p.programsInserted;
    programs = p.programsInserted;
  }
```

---

# Fix 50.D — Clear `_refreshSetState` before each dialog

**File:** `lib/settings_view.dart`

**In `_runEpgRefresh` — add one line immediately before `showDialog`:**

```dart
    bool dialogOpen = true;
    // fix50.D: clear any stale setSt from a previous dialog.
    // After EpgRefresh or EpgRematch closes, _refreshSetState still
    // holds the disposed dialog's setSt. Calling it throws
    // "Null check operator used on a null value" inside Flutter's
    // State.setState → _element! (which is null after dispose).
    // This crashes the for-loop silently, leaving the new dialog
    // open at "Starting…" forever. Clearing to null makes the first
    // _updateRefreshDialog call a no-op until the new dialog builds.
    _refreshSetState = null;

    showDialog(
```

**In `_runEpgRematch` — same line immediately before `showDialog`:**

```dart
    bool dialogOpen = true;
    _refreshSetState = null; // fix50.D — clear stale disposed-dialog reference

    showDialog(
```

---

## What the log will show after all fixes

### Source refresh → EPG assignments preserved

```
M3U: parsed source="Aniel3000 " channels=35945
Sql.getChannelsPreserve: sourceId=1 total=15400 favorites=7 lastWatched=6
  epgMatched=15345 epgManual=0
Sql.wipeSource: sourceId=1 deleted 35945 channels
[M3U re-import — 35945 channels]
Sql.restorePreserve: sourceId=1 total=15400
  epgRestored=15345 manualRestored=0
```

After this, `getChannelsNeedingEpgMatch` returns only the NEW channels
(those with no EPG ID because they weren't in the previous import). The
next EPG refresh runs an incremental match against only those new
channels instead of all 35,945.

### EpgRefresh — correct program count

```
EpgRefresh: source "Aniel3000 " — onProgress summary:
  finalInserted=601434 matched=14713/35945
EpgRefresh: source "Aniel3000 " — done programs=601434 matched=14713/35945
✓ Aniel3000 : 601434 programs · 14713/35945 channels matched
```

No false `⚠` warning.

### EpgRematch — completes instead of stalling

```
EpgRematch: starting — 1 eligible source(s): "Aniel3000 "
EpgRematch: source "Aniel3000 " — downloading EPG      ← now appears
XMLTV: GET …
XMLTV: parse done — 15522 channels, 601434 programs inserted
EpgRematch: source "Aniel3000 " — EPG downloaded (15522 entries),
  starting force-match
EPG: matchChannels: channelMap=15522 entries toMatch=35945 forceAll=true
EPG: match done "Aniel3000 " — 14713/35945 matched
EPG: matchChannels write: merged=14713
Sql.setChannelEpgIds: wrote 14713 EPG assignments
EpgRematch: source "Aniel3000 " — match complete: done=14713 total=35945
EpgRematch: complete — 1 source(s) processed
✓ Aniel3000 : re-match complete (14713/35945)
```

---

## Why 0/20600 matched in the log session (not a code bug, confirmed)

Comparing the two log sessions:

| | Before refresh | After refresh |
|---|---|---|
| Channel count | 35,945 | 20,600 |
| EPG matched | 15,345 | 0 |
| `none` tier | 8,558 | 8,558 |
| `ambiguous` tier | 12,042 | 12,042 |

`none=8558, ambiguous=12042` are identical — these 20,600 channels are
**exactly the same set** in both sessions, just without the 15,345
previously-matched channels (which were removed from the M3U). With
fix50.A, if those channels survive the M3U refresh by name, their EPG
assignments are preserved and they don't need re-matching at all.

---

## Test plan

### Fix 50.A — EPG assignments survive source refresh

1. Run "Refresh EPG now" until channels are matched.
2. Enable debug logging.
3. Tap Settings → Sources → refresh icon for Aniel3000.
4. In the log:
   ```
   Sql.getChannelsPreserve: sourceId=1 total=14720
     epgMatched=14713 ...
   Sql.wipeSource: sourceId=1 deleted 35945 channels
   Sql.restorePreserve: sourceId=1 total=14720
     epgRestored=14713 manualRestored=0
   ```
5. After refresh, navigate to any channel with EPG data. **Expected:**
   EPG tiles still show programme info (because `epg_channel_id` was
   preserved, so the NOW/NEXT query still works).
6. Run "Refresh EPG now" again. The `EPG: matching N channels
   (unmatched only)` count should now show only NEW channels (those
   added to the M3U since the last match), not all 35,945.

### Fix 50.C — No false "0 programs" warning

1. Run "Refresh EPG now".
2. Results dialog shows `✓ Aniel3000 : 601434 programs · M/N channels
   matched`. No `⚠` warning.

### Fix 50.D — Rematch completes after refresh

1. Run "Refresh EPG now". Wait for the results dialog. Tap OK.
2. Immediately tap "Re-match all channels".
3. Dialog advances past "Starting…" within one frame.
4. Results dialog eventually appears.
5. In the log: `EpgRematch: source "Aniel3000 " — downloading EPG`
   appears immediately after `EpgRematch: starting`.

### Cold-start rematch (no prior refresh this session)

1. Force-quit and relaunch the app.
2. Go straight to Settings → tap "Re-match all channels".
3. **Expected:** same clean completion — `_refreshSetState` is null at
   app start, the null-clear is a no-op, the dialog builds normally.

### Manual EPG override preservation (fix 50.A)

1. In Settings → EPG Channel Mapping, manually pin a channel to an
   EPG ID.
2. Refresh the source (M3U refresh).
3. **Expected:** the manual override survives (
   `epg_manual_override` is restored by `restorePreserve`).

---

## Notes for the implementer

- **Files changed:**
  - `lib/models/channel_preserve.dart` — 2 new fields
  - `lib/backend/sql.dart` — `getChannelsPreserve`, `rowToChannelPreserve`,
    `restorePreserve`, `wipeSource`, `setChannelEpgIds`
  - `lib/backend/epg_service.dart` — 2 AppLog lines in `matchChannels`
  - `lib/backend/m3u.dart` — 2 AppLog lines
  - `lib/backend/xtream.dart` — 1 AppLog line
  - `lib/settings_view.dart` — 50.C guard + 50.D null-clears + AppLog lines
- **No SQL schema changes.** `epg_channel_id` and `epg_manual_override`
  columns already exist.
- **`COALESCE(epg_channel_id, ?)` in `restorePreserve`** means: if the
  fresh re-import already populated an EPG ID (e.g. the M3U embeds
  `tvg-id`), keep that fresher value. Only fill in the preserved value
  if the fresh import left it null. This is the same `COALESCE` logic
  used in `insertChannel` for the same reason.
- **`COALESCE(?, epg_manual_override)` for manual overrides** goes the
  other way: the preserved value (user-pinned) takes priority over
  whatever the fresh import might have set. Manual wins.
- **The `restorePreserve` log runs inside the write transaction** —
  the counters are computed during iteration, so there's no extra SQL
  round-trip.
- **Xtream sources** also use `getChannelsPreserve`/`restorePreserve`
  and benefit from fix50.A automatically.
- **Background EPG refresh** (`EpgService.refreshAllSources` with
  `background=true`) calls `matchChannels` with `forceAll=false`. With
  fix50.A, most channels will already have `epg_channel_id` set after
  a source refresh, so the incremental match processes only genuinely
  new channels — making background refreshes dramatically faster.
