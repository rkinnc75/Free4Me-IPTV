# fix60.md — Missing WAL checkpoints after EPG ID writes

> **Version:** Free4Me-IPTV 1.18.2
> **Evidence:** `free4me_log_1779828553335.txt` (1.17.9),
> backup inspection `free4me-backup__7_.json`
>
> Two `checkpointAndTruncateWal()` calls are missing after large
> writes to `db.sqlite`. Both cause the same symptom: channel
> searches stall for 30–120 seconds immediately after an EPG
> refresh or backup import.

---

## Root cause

Both missing checkpoints write to the **`channels` table** in
`db.sqlite`. The `channels_au` FTS trigger fires on every
`UPDATE channels SET epg_channel_id = ?` — producing 3 WAL
entries per row (UPDATE + FTS delete + FTS insert). With
14,000–15,000 rows updated, that is ~42,000–45,000 WAL entries
written to `db.sqlite` with no subsequent flush. The automatic
SQLite checkpoint then runs concurrently with the user's first
search, blocking reads for 30–120 seconds.

The EPG programme insert is already checkpointed (fix52/fix56
via `checkpointAndTruncateWal` in `downloadAndParseEpg`). These
two are the remaining unguarded write paths.

---

## Fix 60.1 — Checkpoint after `setChannelEpgIds` in `matchChannels`

**File:** `lib/backend/epg_service.dart`

`matchChannels` calls `Sql.setChannelEpgIds(merged)` after
computing matches. This writes 14,000–15,000 channel EPG ID
assignments to `db.sqlite`. No checkpoint follows.

**Current code (lines 257–259):**

```dart
    if (merged.isNotEmpty) {
      await Sql.setChannelEpgIds(merged);
    }
```

**Replace with:**

```dart
    if (merged.isNotEmpty) {
      await Sql.setChannelEpgIds(merged);
      // Checkpoint db.sqlite after writing EPG assignments. Each
      // UPDATE triggers channels_au FTS (delete + insert on
      // channels_fts), so 14k assignments = ~42k WAL writes to
      // db.sqlite. Without this flush, searches immediately after
      // EPG refresh block for 30-120s on the pending checkpoint.
      // The EPG progress dialog is still showing at this point so
      // the user does not see the flush time.
      await Sql.checkpointAndTruncateWal();
    }
```

---

## Fix 60.2 — Checkpoint after `applyPendingPreserves`

**File:** `lib/backend/settings_io.dart`

`applyPendingPreserves` calls `Sql.restorePreserve` which writes
EPG channel IDs and favorites back to channel rows after a source
refresh. The same FTS trigger overhead applies: 14,359 EPG
assignments in the backup → ~43,000 WAL writes to `db.sqlite`
with no checkpoint.

This is the reason search was slow immediately after the backup
import + source refresh sequence tested in 1.18.2.

**Current code (lines 315–320):**

```dart
  await Sql.commitWrite(
    [Sql.restorePreserve(preserve)],
    memory: {'sourceId': source.id!.toString()},
  );
  AppLog.info(
    'SettingsIo.applyPendingPreserves: done for "$sourceName"',
  );
```

**Replace with:**

```dart
  await Sql.commitWrite(
    [Sql.restorePreserve(preserve)],
    memory: {'sourceId': source.id!.toString()},
  );
  // Checkpoint db.sqlite after restoring EPG IDs from backup.
  // Each UPDATE triggers channels_au FTS (delete + insert), so
  // 14k preserves = ~42k WAL writes. Without this flush, the
  // first search after import blocks for 30-120s. The sources
  // refresh dialog is still showing at this point so the user
  // does not see the flush time.
  await Sql.checkpointAndTruncateWal();
  AppLog.info(
    'SettingsIo.applyPendingPreserves: done for "$sourceName"',
  );
```

---

## Fix 60.3 — Enable logging immediately after import

**File:** `lib/backend/settings_io.dart`

On a fresh install `db.sqlite` doesn't exist. `main.dart` calls
`SettingsService.getSettings()` → gets constructor default
`debugLogging = false` → calls `AppLog.setEnabled(false)`. The
logger never opens.

The backup import writes `debugLogging = true` to the DB via
`SettingsService.updateSettings(settings)` — but `AppLog.setEnabled`
is never called again during that session. The logger stays off.
The log file is empty. The user has no way to diagnose the slow
search in the same session as the import.

**Current code (line 201):**

```dart
201        await SettingsService.updateSettings(settings);
```

**Replace with:**

```dart
201        await SettingsService.updateSettings(settings);
202        await AppLog.setEnabled(settings.debugLogging);
```

Add the import at the top of `settings_io.dart` if not already
present:

```dart
import 'package:open_tv/backend/app_logger.dart';
```

---

## Backup analysis — `free4me-backup__7_.json`

```
schemaVersion: 3
appVersion:    1.18.1
debugLogging:  true      ← confirmed on, log will capture everything
multiViewLayout: oneByTwo

Sources:
  Aniel3000 : enabled=false  preserve=0      epg=0
  Emjay:      enabled=true   preserve=14361  epg=14359
```

Key points:

- **Aniel3000 is disabled.** Only Emjay gets refreshed on import.
  The `SourcesRefreshDialog` will show "Source 1 of 1 — Emjay".
- **Emjay has 14,359 EPG IDs staged.** After the source refresh
  populates Emjay's channels, `applyPendingPreserves` writes
  14,359 EPG assignments → fix 60.2 checkpoints this.
- **Aniel3000 has 0 preserve entries.** Nothing to restore for it.
  If Aniel3000 is later enabled and refreshed, its channels will
  have no EPG IDs until a full EPG refresh + match runs.
- **Debug logging is on.** The next test session will capture the
  full pipeline.

---

## What the log should show after fix60

### Backup import + source refresh

```
Setup: import backup — started
SettingsIo.import: source "Aniel3000 " enabled=false type=m3u ... preserve=0 entries
SettingsIo.applyPendingPreserves: no staged preserves for "Aniel3000 " — skipping
SettingsIo.import: source "Emjay" enabled=true type=m3u ... preserve=14361 entries
SettingsIo.import: staged preserves for "Emjay" total=14361 epg=14359 favorites=N
Setup: import backup — 2 sources imported (1 enabled): "Aniel3000 "(off), "Emjay"(on)
Setup: import backup — launching source refresh dialog
SourcesRefreshDialog: source 1/1 "Emjay" starting
M3U: processing source="Emjay" wipe=true path="http://..."
M3U: preserve captured — source="Emjay" epg=0 favorites=0 total=0
Sql.wipeSource: sourceId=2 deleted 0 channels
M3U: parsed source="Emjay" channels=52861
M3U: preserve restored — source="Emjay" channels=52861
Sql.restorePreserve: sourceId=2 total=0 epgRestored=0 manualRestored=0
SettingsIo.applyPendingPreserves: applying 14361 preserves to "Emjay"
  (sourceId=2) epg=14359 favorites=N
Sql.checkpoint [epg.sqlite]: WAL has N pages (~NMB) — starting TRUNCATE
Sql.checkpoint [epg.sqlite]: WAL truncated in Nms
Sql.checkpoint [db.sqlite]: WAL has N pages (~NMB) — starting TRUNCATE
Sql.checkpoint [db.sqlite]: WAL truncated in Nms         ← fix60.2 fires here
SettingsIo.applyPendingPreserves: done for "Emjay"
SourcesRefreshDialog: refresh complete — 1 source(s) done
SourcesRefreshDialog: user dismissed
Setup: import backup — refresh dialog complete, navigating to Home
```

### Search immediately after (should be instant)

```
Sql.search[1]: branch=no-query sql=1ms    ← no blocking
Sql.search[4]: branch=fts sql=3ms  query="yes net"
Sql.search[6]: branch=fts sql=4ms  query="yes network"
Home.load[6]: rendered total=12ms
```

### EPG refresh (Emjay only — Aniel3000 disabled)

```
EpgRefresh: starting — 1 eligible source(s): "Emjay"
XMLTV: GET http://joint76486...
XMLTV: parse done — 4365 channels, 109395 programs inserted
Sql.checkpoint [epg.sqlite]: WAL truncated in Nms
Sql.checkpoint [db.sqlite]: WAL truncated in Nms
EPG: matchChannels: channelMap=4365 toMatch=0 forceAll=false
EPG: no unmatched channels — skipping matcher    ← fix50.A confirmed working
EpgRefresh: source "Emjay" — done programs=109395 matched=0/0
EpgRefresh: complete
```

`toMatch=0` is the proof that fix50.A + fix60.2 worked together:
the 14,359 EPG IDs from the backup were applied to Emjay's fresh
channel rows, so all channels are already matched before EPG
refresh even runs.

---

## Test plan

### Primary — search instant after import

1. Uninstall. Reinstall 1.18.2 (with fix60 applied).
2. On welcome screen, import `free4me-backup__7_.json`.
3. Wait for the sources refresh dialog to complete (Emjay only).
4. Tap OK. Immediately type "yes network" in search.
5. **Expected:** results within 400ms. No stall.
6. In the log: both `Sql.checkpoint [db.sqlite]: WAL truncated`
   lines appear before `SourcesRefreshDialog: user dismissed`.

### Secondary — search instant after EPG refresh

1. Settings → Refresh EPG now.
2. Wait for EPG Refresh Complete dialog. Tap OK.
3. Immediately type "yes network".
4. **Expected:** results within 400ms.
5. In the log: `Sql.checkpoint [db.sqlite]: WAL truncated` appears
   inside `_runEpgRefresh` after `setChannelEpgIds` completes.

### fix50.A proof

1. After EPG refresh completes, check the log for:
   ```
   EPG: matchChannels: channelMap=4365 toMatch=0 forceAll=false
   EPG: no unmatched channels — skipping matcher
   ```
   This confirms all 14,359 EPG IDs from the backup were restored
   successfully and no rematch was needed.

### Fix 60.3 — Log file populated on fresh install import

1. Uninstall. Reinstall. Import backup with `debugLogging: true`.
2. **Without relaunching**, go to Settings → Diagnostics → Save log.
3. **Expected:** log file exists and contains entries starting from
   the import (including `SettingsIo.import:` lines and all
   subsequent activity).
4. **Before this fix:** log file was empty or unavailable because
   the logger was never started during the import session.

---

## Notes for the implementer

- **Three changes across two files.** No signature changes, no new
  dependencies, no schema changes.
- **Fix 60.3 `AppLog.setEnabled` is idempotent** — if logging is
  already enabled (non-fresh-install case), `setEnabled(true)` checks
  `if (_enabled == value) return` and does nothing. Safe to call
  unconditionally after every import.
- **`app_logger.dart` import** — likely already present in
  `settings_io.dart` given the existing `AppLog.info` calls. Verify
  before adding.
- **`checkpointAndTruncateWal` checkpoints both `epg.sqlite` and
  `db.sqlite`** — the db.sqlite checkpoint is what matters for
  fixes 60.1 and 60.2, but the epg.sqlite leg is cheap and
  consistent.
- **Both checkpoint calls run while the sources refresh dialog is
  still showing** — the user sees the dialog status text rather
  than a frozen screen.
- **`matchChannels` is called from both `_runEpgRefresh` and
  `_runEpgRematch`** — fix 60.1 covers both paths since it is
  inside `matchChannels` itself.
