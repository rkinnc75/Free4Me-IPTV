# fix52.md — WAL checkpoint blocks search + progress indicators for all long waits

> **Version:** Free4Me-IPTV 1.17.7
> **Evidence:** `free4me_log_1779765900144.txt`
>
> Two requests in one runbook:
>
> 1. **Fix the WAL checkpoint blocking search** — after a large EPG
>    insert (112k programs), searches stall for 90–150 seconds because
>    SQLite's automatic checkpoint runs concurrently with the user's
>    first queries. Force an explicit checkpoint while the progress
>    dialog is still visible so the user never feels it.
>
> 2. **Add progress indicators to every long wait** — the EPG
>    checkpoint itself needs a status update ("Optimising database…"),
>    the Home refresh-on-start shows only a pulsing spinner with no
>    text, and the Settings "Refresh all sources" button does the same.
>    All three should use the same progress dialog already used by the
>    backup import flow.

---

## Root cause — WAL checkpoint contention

### What happened in the log

```
23:20:52  XMLTV: parse done — 4377 channels, 112865 programs inserted
23:21:02  Sql.setChannelEpgIds: wrote 46 EPG assignments
23:21:13  Sql.search sql=839ms      ← History, already blocked
23:21:35  Sql.search sql=470ms      ← "yes", checkpoint running
23:21:38  Home.load[6] "yes n" queued
23:24:07  Sql.search sql=149114ms   ← 149s queue wait, checkpoint done
23:24:17  Sql.search sql=158665ms   ← "yes ne", 158s
```

### Why

`XmltvParser` calls `onBatch` every 1,000 programs. Each `onBatch`
→ `insertProgramsBatch` → one `writeTransaction`. For 112k programs:
113 `writeTransaction` calls commit to the WAL without a checkpoint
keeping pace. The WAL grows to ~110MB. SQLite's automatic PASSIVE
checkpoint defers because writers are active, then runs after the
insert — flushing 110MB to phone flash takes 90–150 seconds and
blocks every read in the queue.

---

# Fix 52.1 — Force `PRAGMA wal_checkpoint(TRUNCATE)` after EPG parse

**File:** `lib/backend/epg_service.dart`

The checkpoint runs inside `downloadAndParseEpg`, after parse
completes and before `deleteStalePrograms`, while the progress
dialog is still showing. The `onProgress` callback is used to
push a status update into the dialog during the checkpoint so
the user sees "Optimising database…" instead of a frozen screen.

**Current code (lines 124–143):**

```dart
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

// GC rows whose stop time is before the configured window so the
// table stays bounded across refreshes.
await Sql.deleteStalePrograms(source.id!, windowStart);
```

**Replace with:**

```dart
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

// Force a WAL checkpoint before returning to the caller. Without
// this, SQLite's automatic PASSIVE checkpoint runs concurrently
// with the user's first searches after EPG completes. For a large
// source (100k+ programs → ~100MB WAL), this checkpoint takes
// 90–150 seconds on phone flash and blocks every read query during
// that time — causing searches like "yes net" to stall for 2+
// minutes (see fix52.md, free4me_log_1779765900144.txt).
//
// Running the checkpoint here while the progress dialog is still
// visible hides the cost entirely. The "Optimising database…"
// status update below tells the user something is happening.
//
// TRUNCATE mode: waits for active readers, flushes the full WAL,
// then zeroes the WAL file so the next insert starts fresh.
onProgress?.call(XmltvProgress(
  programsInserted: inserted,
  statusMessage: 'Optimising database…',
));
await Sql.checkpointAndTruncateWal();

// GC rows whose stop time is before the configured window so the
// table stays bounded across refreshes.
await Sql.deleteStalePrograms(source.id!, windowStart);
```

---

# Fix 52.2 — Add `Sql.checkpointAndTruncateWal`

**File:** `lib/backend/sql.dart`

Add this static method near `insertProgramsBatch`:

```dart
/// Force a full WAL checkpoint and truncate the WAL file to zero.
///
/// Call after large batch writes (e.g. EPG programme inserts) to
/// prevent SQLite's automatic PASSIVE checkpoint from running
/// concurrently with UI reads. An unmanaged checkpoint on a 100MB+
/// WAL blocks all read queries for 90–150 seconds on phone flash.
///
/// TRUNCATE mode: waits for all active readers, flushes the entire
/// WAL to the main DB file, then truncates the WAL file to 0 bytes.
/// Subsequent writes start with a clean WAL.
///
/// Uses db.execute (not writeTransaction) — PRAGMA wal_checkpoint
/// must run outside a transaction.
static Future<void> checkpointAndTruncateWal() async {
  final db = await DbFactory.db;
  // Read WAL size before flush for diagnostics.
  try {
    final info = await db.get('PRAGMA wal_checkpoint(PASSIVE)');
    // Returns (busy, log, checkpointed). log = total WAL frames.
    final pages = info.columnAt(1) as int;
    final mb = (pages * 4096 / 1024 / 1024).toStringAsFixed(1);
    AppLog.info(
      'Sql.checkpoint: WAL has $pages pages (~${mb}MB)'
      ' — starting TRUNCATE',
    );
  } catch (_) {
    // Diagnostic only — proceed regardless.
    AppLog.info('Sql.checkpoint: WAL size unknown — starting TRUNCATE');
  }
  final t = DateTime.now();
  await db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  final ms = DateTime.now().difference(t).inMilliseconds;
  AppLog.info('Sql.checkpoint: WAL truncated in ${ms}ms');
}
```

---

# Fix 52.3 — Raise `wal_autocheckpoint` at DB open time

**File:** `lib/backend/db_factory.dart`

The default threshold is 1000 pages (4MB), causing SQLite to
attempt automatic checkpoints every 4MB during the insert — each
attempt competes with the ongoing write batches, producing a
fragmented, slow checkpoint. Raising to 8000 pages (32MB) allows
each `writeTransaction` batch to commit cleanly without checkpoint
interference. The explicit TRUNCATE in fix52.1 then handles the
full flush in one shot at the end.

Find the end of `_createDB` after `SqliteMigrations().migrate(db)`
completes and add:

```dart
// Raise WAL auto-checkpoint from 1000 pages (4MB) to 8000 pages
// (32MB). This prevents fragmented automatic checkpoints during
// large batch inserts (EPG programme loading). The explicit
// Sql.checkpointAndTruncateWal() call in epg_service.dart handles
// the full flush after each EPG download. See fix52.md.
await db.execute('PRAGMA wal_autocheckpoint = 8000');
```

> **Placement:** set this AFTER migrations, on the live connection.
> The pragma persists for the lifetime of the connection so it must
> be set every time `_createDB` runs (i.e. once per app launch).

---

# Fix 52.4 — Replace loaderOverlay spinner with progress dialog on Home refresh-on-start

**File:** `lib/home.dart`

The current refresh-on-start flow uses `tryAsyncNoLoading` — it
shows nothing at all while sources download. The user sees a channel
grid that may or may not be populated. With multiple sources this
can take 30–60 seconds.

**Current code (lines 105–118):**

```dart
if (!mounted || !widget.refresh) return;
await Error.tryAsyncNoLoading(
  () async {
    if (mounted) {
      setState(() => blockSettings = true);
    }
    await Utils.refreshAllSources();
    if (mounted) await load(false);
  },
  context,
  true,
  "Refreshed all sources",
);
if (mounted) setState(() => blockSettings = false);
```

**Replace with:**

```dart
if (!mounted || !widget.refresh) return;
// Show the same progress dialog used by the backup import flow.
// Previously this ran behind tryAsyncNoLoading with no visible
// feedback — the user saw an empty grid for up to 60 seconds with
// no indication that loading was in progress. (fix52 / point 5)
if (mounted) setState(() => blockSettings = true);
await showSourcesRefreshDialog(context);
if (mounted) {
  setState(() => blockSettings = false);
  await load(false);
}
```

Add the import at the top of `home.dart`:

```dart
import 'package:open_tv/widgets/sources_refresh_dialog.dart';
```

The `showSourcesRefreshDialog` function already handles errors
internally (shows a "Refresh failed" title with an OK button on
the dialog). The `blockSettings` flag is preserved to prevent the
user opening Settings while the refresh runs.

---

# Fix 52.5 — Replace loaderOverlay spinner with progress dialog on Settings "Refresh all sources"

**File:** `lib/settings_view.dart`

The "Refresh all sources" icon button uses `Error.tryAsync` which
shows the `loaderOverlay` pulsing-grid spinner — no text, no
per-source status. Same fix.

**Current code (lines 2076–2082):**

```dart
IconButton(
  onPressed: () async => await Error.tryAsync(
    () async => await Utils.refreshAllSources(),
    context,
    "Successfully refreshed all sources",
  ),
  icon: const Icon(Icons.refresh),
),
```

**Replace with:**

```dart
IconButton(
  onPressed: () async {
    // Show the full progress dialog instead of the plain spinner.
    // The dialog shows per-source status, a progress bar, and a
    // summary on completion — same as the backup import flow.
    // (fix52 / point 5)
    await showSourcesRefreshDialog(context);
    // Reload the sources list in case names or counts changed.
    if (mounted) await reloadSources();
  },
  icon: const Icon(Icons.refresh),
),
```

Add the import at the top of `settings_view.dart` if not already
present (fix28.3 may have added it):

```dart
import 'package:open_tv/widgets/sources_refresh_dialog.dart';
```

---

## What the log will show after fix52

### EPG refresh with large source

```
XMLTV: parse done — 4377 channels, 112865 programs inserted
EPG: downloaded "Emjay" — 112865 programs
Sql.checkpoint: WAL has 27840 pages (~109.5MB) — starting TRUNCATE
Sql.checkpoint: WAL truncated in 8234ms
EPG: matching 38548 channels (unmatched only) for "Emjay" ...
EPG: match done "Emjay" — 46/38548 matched
EpgRefresh: complete
```

The user sees in the dialog: "Emjay: Optimising database…" for ~8s,
then "Emjay: matching channels…". Both are during the blocking
dialog — no frozen UI.

### Searches after EPG completes

```
Sql.search[4]: branch=fts sql=3ms  query="yes"
Sql.search[6]: branch=fts sql=4ms  query="yes n"
Sql.search[7]: branch=fts sql=2ms  query="yes net"
```

All sub-10ms. No queue wait.

### Home refresh-on-start

Instead of an empty grid with a pulsing spinner, the user sees the
`showSourcesRefreshDialog` with:
- "Loading channels…" title
- "Source 1 of N" counter
- Linear progress bar
- Per-source status text ("Loading 'Aniel3000 '…")
- "Loaded — N sources ready." with OK button when done

### Settings refresh button

Same progress dialog as above instead of the plain pulsing grid.

---

## Apply order

1. **52.2** — `Sql.checkpointAndTruncateWal` in `sql.dart`
2. **52.3** — `PRAGMA wal_autocheckpoint = 8000` in `db_factory.dart`
3. **52.1** — Call checkpoint + progress update in `epg_service.dart`
4. **52.4** — Replace Home refresh with `showSourcesRefreshDialog`
5. **52.5** — Replace Settings refresh button with `showSourcesRefreshDialog`

---

## Test plan

### WAL checkpoint (52.1–52.3)

1. Enable Emjay (or any source with 100k+ programs).
2. Run "Refresh EPG now". While the dialog is open, watch for
   "Optimising database…" status text — should appear after parse
   completes, before matching starts.
3. Log should show:
   ```
   Sql.checkpoint: WAL has NNNNN pages (~XXXmb) — starting TRUNCATE
   Sql.checkpoint: WAL truncated in NNNNms
   ```
4. Tap OK. Immediately type "yes net" in search.
5. **Expected:** results appear within ~400ms (200ms debounce +
   <10ms SQL). No stall.

### Home refresh-on-start progress (52.4)

1. Enable "Refresh on start" in Settings.
2. Force-quit the app. Relaunch.
3. **Expected:** `showSourcesRefreshDialog` appears immediately
   with "Loading channels…" title and per-source progress. No
   empty grid while waiting.
4. User taps OK after refresh. Home shows populated channels.

### Settings refresh button progress (52.5)

1. Go to Settings → Sources section.
2. Tap the "Refresh all sources" refresh icon.
3. **Expected:** progress dialog appears (not a plain spinner).
   Per-source status updates visible. Results dialog on completion.

### Regression — EPG refresh dialog flow unchanged

1. Run "Refresh EPG now" (manual).
2. The EPG refresh progress dialog (the existing one from
   `_runEpgRefresh`) still appears and works as before. The
   `showSourcesRefreshDialog` is only used for M3U/Xtream channel
   refreshes, not EPG.

### Regression — loaderOverlay still works elsewhere

1. Trigger any action that uses `Error.tryAsync` directly (e.g.
   individual channel tile scan, source add/edit). The pulsing-grid
   spinner should still appear for these — we're not removing it
   globally, only replacing it where sources refresh is the work.

---

## Notes for the implementer

- **`showSourcesRefreshDialog` already exists** (`lib/widgets/
  sources_refresh_dialog.dart`, from fix44). Fixes 52.4 and 52.5
  reuse it directly — no new widget needed.
- **`blockSettings` is preserved in 52.4.** It disables the Settings
  tab during the refresh. `showSourcesRefreshDialog` is modal
  (`barrierDismissible: false`) which also prevents dismissal, but
  `blockSettings` is still needed for the bottom nav Settings button.
- **52.5 adds `reloadSources()` after the dialog.** The original
  `Error.tryAsync` wrapper provided a success snackbar and handled
  errors. `showSourcesRefreshDialog` handles errors internally (shows
  "Refresh failed" in the dialog). The `reloadSources()` call
  replaces the implicit UI refresh that happened when `tryAsync`
  resolved.
- **The `onProgress` call in 52.1** fires a `XmltvProgress` with
  `statusMessage: 'Optimising database…'` and the current
  `programsInserted` count. This is safe — `onProgress` is nullable
  and the call is guarded with `?.call(...)`.
- **`PRAGMA wal_checkpoint(PASSIVE)`** in the diagnostic block of
  `checkpointAndTruncateWal` does a lightweight checkpoint attempt
  as a side effect of reading the page count. This is intentional —
  it pre-warms the checkpoint mechanism before the TRUNCATE. If you
  prefer zero side effects on the diagnostic call, replace with
  `PRAGMA wal_checkpoint` (no mode) which returns counts without
  flushing anything.
- **No schema changes. No new dependencies. No new files.**
- **Total code change:** ~60 lines across 4 files.
