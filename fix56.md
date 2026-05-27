# fix56.md — Move `programmes` and `epg_refresh_log` to a separate database file

> **Version:** Free4Me-IPTV 1.17.8
> **Evidence:** `free4me_log_1779778892104.txt`
>
> Root cause: channel search queries the `channels` table in `db.sqlite`.
> EPG programme inserts write to the `programmes` table in the same
> `db.sqlite`. SQLite's WAL is per-file — a 1GB WAL from 601k programme
> inserts blocks ALL reads from that file, including trivial channel
> searches, for 30+ seconds while the checkpoint flushes.
>
> The fix: move `programmes` and `epg_refresh_log` to a second file
> `epg.sqlite`. The two databases never share a WAL. A 1GB WAL in
> `epg.sqlite` has zero effect on reads from `db.sqlite`.

---

## What the log showed

```
02:56:21  EPG: downloading "Aniel3000" — 601k programmes
02:57:23  XMLTV: parse done — 601267 programs inserted
02:57:23  Sql.checkpoint: WAL has 258711 pages (~1010.6MB) — starting TRUNCATE
02:57:37  Sql.search[14]: sql=133845ms  "yes network"   ← 134s blocked
02:57:50  Sql.search[15]: sql=141323ms  "yes network"   ← 141s blocked
02:57:53  Sql.checkpoint: WAL truncated in 30095ms
02:57:53  Sql.checkpoint: WAL has 258711 pages (~1010.6MB) — starting TRUNCATE
02:58:04  Sql.search[16]: sql=145770ms  "yes network"   ← 146s blocked
02:58:23  Sql.checkpoint: WAL truncated in 30063ms
```

Two 30-second checkpoint flushes: one for the 601k inserts, one for
the 832k stale-programme deletes. Channel searches that hit either
flush wait the full duration. Raising the debounce doesn't help —
the query runs immediately after the debounce fires and then blocks.

---

## Scope of changes

| File | Change |
|---|---|
| `lib/backend/db_factory.dart` | Add `EpgDbFactory` class; open `epg.sqlite` separately |
| `lib/backend/sql.dart` | All `programmes`/`epg_refresh_log` methods use `EpgDbFactory.db` |
| No other files change | All callers of `Sql.insertProgramsBatch`, `Sql.getNowNext`, etc. are unchanged — same static method signatures |

---

# Fix 56.1 — Add `EpgDbFactory`

**File:** `lib/backend/db_factory.dart`

Add a second factory class at the bottom of the file, after the
closing `}` of `DbFactory`:

```dart
/// Manages the EPG-specific SQLite database (`epg.sqlite`).
///
/// Lives in a separate file from `db.sqlite` so that large EPG writes
/// (600k+ programme inserts, 800k+ stale-row deletes) never inflate the
/// WAL that channel-search reads must traverse. SQLite WAL contention is
/// per-file; two separate SqliteDatabase instances have independent WALs.
///
/// Schema: `programmes` and `epg_refresh_log` tables only.
/// The `sources` FK from these tables references `db.sqlite`, but SQLite
/// cross-file FK enforcement is not supported — we enforce referential
/// integrity at the application layer (delete programmes when source is
/// deleted by calling Sql.deleteEpgForSource from deleteSource).
class EpgDbFactory {
  static SqliteDatabase? _db;

  static Future<SqliteDatabase> _createDB() async {
    final db = SqliteDatabase(path: '${await Utils.appDir}/epg.sqlite');
    final migrations = SqliteMigrations()
      ..add(SqliteMigration(1, (tx) async {
        // Programme guide — identical schema to the programmes table in
        // db.sqlite migration v5. source_id is a logical FK; no FOREIGN KEY
        // constraint because cross-file FK enforcement is not supported.
        await tx.execute('''
          CREATE TABLE programmes (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            epg_channel_id TEXT NOT NULL,
            source_id   INTEGER NOT NULL,
            title       TEXT NOT NULL,
            description TEXT,
            category    TEXT,
            start_utc   INTEGER NOT NULL,
            stop_utc    INTEGER NOT NULL,
            episode_num TEXT
          );
        ''');
        await tx.execute('''
          CREATE INDEX idx_programs_channel_time
            ON programmes(epg_channel_id, source_id, start_utc);
        ''');
        await tx.execute('''
          CREATE INDEX idx_programs_time_range
            ON programmes(source_id, start_utc, stop_utc);
        ''');
        await tx.execute('''
          CREATE UNIQUE INDEX idx_programs_unique
            ON programmes(source_id, epg_channel_id, start_utc);
        ''');
        // EPG refresh audit log — identical schema to epg_refresh_log in
        // db.sqlite migration v5.
        await tx.execute('''
          CREATE TABLE epg_refresh_log (
            source_id          INTEGER PRIMARY KEY,
            last_refreshed_utc INTEGER NOT NULL,
            programmes_loaded  INTEGER NOT NULL,
            last_error         TEXT
          );
        ''');
      }));
    await migrations.migrate(db);

    AppLog.info('EpgDb: opened epg.sqlite');

    // Same WAL tuning as db.sqlite — raise auto-checkpoint threshold so
    // the explicit Sql.checkpointAndTruncateWal() calls control flushing.
    await db.execute('PRAGMA wal_autocheckpoint = 8000');

    return db;
  }

  static Future<SqliteDatabase> get db async {
    _db ??= await _createDB();
    return _db!;
  }
}
```

> **Schema note:** `epg.sqlite` does not include the UNIQUE constraint
> migration (migration v8 in `db.sqlite`) because it's applied inline
> in migration v1 here — the new DB starts clean, no de-duplication
> needed.
>
> The `FOREIGN KEY(source_id) REFERENCES sources(id) ON DELETE CASCADE`
> constraint from the original schema is omitted — SQLite cannot enforce
> cross-file FKs. `Sql.deleteEpgForSource` (see fix56.2) handles cleanup
> explicitly.

---

# Fix 56.2 — Update `Sql` methods to use `EpgDbFactory.db`

**File:** `lib/backend/sql.dart`

Every method that reads from or writes to `programmes` or
`epg_refresh_log` must switch from `DbFactory.db` to `EpgDbFactory.db`.
No method signatures change — all callers are unaffected.

### Add import

At the top of `sql.dart`, the import for `db_factory.dart` already
covers both classes since they're in the same file. No new import needed.

### Methods to update

Replace `var db = await DbFactory.db` (or `final db = await DbFactory.db`)
with `final db = await EpgDbFactory.db` in these six methods:

| Method | Approx line | What it does |
|---|---|---|
| `insertProgramsBatch` | 832 | Insert EPG programmes |
| `deleteProgramsForSource` | 815 | Delete all programmes for a source |
| `deleteStalePrograms` | 915 | GC programmes outside date window |
| `getNowNext` | 927 | Read now/next programme for a channel tile |
| `getSchedule` | 956 | Read full programme schedule for a channel |
| `getAvailableEpgIds` | 1066 | List EPG IDs with sample titles for mapping UI |
| `upsertEpgRefreshLog` | 991 | Write EPG refresh audit entry |
| `getEpgRefreshLog` | 1009 | Read EPG refresh audit entry |

Also update `checkpointAndTruncateWal` to checkpoint **both** databases:

**Current:**
```dart
static Future<void> checkpointAndTruncateWal() async {
  final db = await DbFactory.db;
  ...
  await db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
  ...
}
```

**Replace with:**
```dart
static Future<void> checkpointAndTruncateWal() async {
  // Checkpoint both databases — epg.sqlite is where the large writes
  // happen; db.sqlite may also have pending WAL from channel updates.
  for (final entry in [
    ('epg.sqlite', await EpgDbFactory.db),
    ('db.sqlite', await DbFactory.db),
  ]) {
    final label = entry.$1;
    final db = entry.$2;
    try {
      final rows = await db.getAll('PRAGMA wal_checkpoint(PASSIVE)');
      if (rows.isNotEmpty) {
        final pages = rows.first.columnAt(1) as int;
        final mb = (pages * 4096 / 1024 / 1024).toStringAsFixed(1);
        AppLog.info(
          'Sql.checkpoint [$label]: WAL has $pages pages (~${mb}MB)'
          ' — starting TRUNCATE',
        );
      }
    } catch (_) {
      AppLog.info(
          'Sql.checkpoint [$label]: WAL size unknown — starting TRUNCATE');
    }
    final t = DateTime.now();
    await db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    final ms = DateTime.now().difference(t).inMilliseconds;
    AppLog.info('Sql.checkpoint [$label]: WAL truncated in ${ms}ms');
  }
}
```

### Add `deleteEpgForSource`

When a source is deleted from `db.sqlite`, its programmes in
`epg.sqlite` must also be cleaned up — the cross-file FK can't do
this automatically.

Add this method near `deleteProgramsForSource`:

```dart
/// Delete all EPG data for a source from epg.sqlite.
/// Call this when deleting a source from db.sqlite, since the cross-file
/// FK cannot cascade automatically.
static Future<void> deleteEpgForSource(int sourceId) async {
  final db = await EpgDbFactory.db;
  await db.writeTransaction((tx) async {
    await tx.execute(
        'DELETE FROM programmes WHERE source_id = ?', [sourceId]);
    await tx.execute(
        'DELETE FROM epg_refresh_log WHERE source_id = ?', [sourceId]);
  });
  AppLog.info('Sql.deleteEpgForSource: removed EPG data for source $sourceId');
}
```

### Update `deleteSource` to call `deleteEpgForSource`

**Current `deleteSource` (around line 547):**
```dart
static Future<void> deleteSource(int sourceId) async {
  var db = await DbFactory.db;
  await db.writeTransaction((tx) async {
    await tx.execute("DELETE FROM channels WHERE source_id = ?", [sourceId]);
    await tx.execute("DELETE FROM groups WHERE source_id = ?", [sourceId]);
    await tx.execute("DELETE FROM sources WHERE id = ?", [sourceId]);
  });
}
```

**Replace with:**
```dart
static Future<void> deleteSource(int sourceId) async {
  // Clean up EPG data in epg.sqlite first (cross-file FK can't cascade).
  await deleteEpgForSource(sourceId);
  var db = await DbFactory.db;
  await db.writeTransaction((tx) async {
    await tx.execute("DELETE FROM channels WHERE source_id = ?", [sourceId]);
    await tx.execute("DELETE FROM groups WHERE source_id = ?", [sourceId]);
    await tx.execute("DELETE FROM sources WHERE id = ?", [sourceId]);
  });
}
```

---

# Fix 56.3 — Migration for existing installs

Existing users have `programmes` and `epg_refresh_log` data in
`db.sqlite`. On first launch after fix56, `epg.sqlite` is empty.
The EPG data in `db.sqlite` is stale by the time the user next
opens the app, so losing it is acceptable — the next EPG refresh
repopulates `epg.sqlite`.

However, the old tables in `db.sqlite` still exist and waste space.
Add a migration to drop them:

**File:** `lib/backend/db_factory.dart`

In `DbFactory._createDB()`, after the existing migration chain, add:

```dart
..add(SqliteMigration(9, (tx) async {
  // fix56: programmes and epg_refresh_log moved to epg.sqlite.
  // Drop the old tables from db.sqlite to reclaim space.
  // EPG data is intentionally lost — next refresh repopulates epg.sqlite.
  await tx.execute('DROP TABLE IF EXISTS programmes;');
  await tx.execute('DROP TABLE IF EXISTS epg_refresh_log;');
  // Also drop the now-orphaned indexes that referenced programmes.
  await tx.execute('DROP INDEX IF EXISTS idx_programs_channel_time;');
  await tx.execute('DROP INDEX IF EXISTS idx_programs_time_range;');
  await tx.execute('DROP INDEX IF EXISTS idx_programs_unique;');
}));
```

---

## What the log will show after fix56

```
EpgDb: opened epg.sqlite
XMLTV: parse done — 15522 channels, 601267 programs inserted
Sql.checkpoint [epg.sqlite]: WAL has 258711 pages (~1010.6MB) — starting TRUNCATE
Sql.checkpoint [epg.sqlite]: WAL truncated in 30095ms
Sql.search[6]: branch=fts sql=2ms  query="yes n"       ← instant, unblocked
Sql.search[7]: branch=fts sql=3ms  query="yes ne"      ← instant
Sql.search[8]: branch=fts sql=4ms  query="yes net"     ← instant
```

The 30-second checkpoint flush still happens in `epg.sqlite`, but
`db.sqlite` is untouched — channel searches return in milliseconds
throughout.

---

## Test plan

### Primary — search unblocked during EPG refresh

1. Enable Emjay and Aniel3000.
2. Run "Refresh EPG now".
3. While the progress dialog is showing (download + insert phase),
   dismiss it or wait for it to complete, then immediately search
   "yes net".
4. **Expected:** results within 200ms. No stall.
5. In the log:
   ```
   Sql.checkpoint [epg.sqlite]: WAL truncated in Nms
   Sql.search[N]: sql=Xms  ← X should be <500ms
   ```
   The checkpoint time for epg.sqlite can still be long (30s for
   1GB), but it runs while the progress dialog shows and does not
   block searches.

### Secondary — source delete cleans up EPG data

1. Delete a source from Settings → Sources.
2. In the log: `Sql.deleteEpgForSource: removed EPG data for source N`.
3. Confirm EPG tiles no longer appear for channels that were on
   that source.

### Migration — existing install

1. Install over an existing 1.17.8 build (which has `programmes` in
   `db.sqlite`).
2. On first launch: migration 9 runs, drops `programmes` and
   `epg_refresh_log` from `db.sqlite`.
3. In the log: `EpgDb: opened epg.sqlite` on next access.
4. EPG tiles show no data initially — correct, data was in db.sqlite.
5. Run "Refresh EPG now" — `epg.sqlite` is populated.
6. EPG tiles now show programme data.

### File sizes (sanity check)

After a full EPG refresh:
- `db.sqlite` should be ~50–200MB (channels, sources, groups, FTS)
- `epg.sqlite` should be ~500MB–1.5GB (600k+ programme rows × 2 sources)
- `db.sqlite-wal` should be small (KB, not GB)
- `epg.sqlite-wal` may be large immediately after a refresh, then
  drops to 0 after the checkpoint

---

## Notes for the implementer

- **No callers change.** `Sql.insertProgramsBatch(batch)`,
  `Sql.getNowNext(...)`, `Sql.getSchedule(...)` etc. all have
  identical signatures. The only change per-method is `DbFactory.db`
  → `EpgDbFactory.db`.
- **`EpgDbFactory` is in the same file as `DbFactory`** so no new
  import is needed in `sql.dart`.
- **The `programmes` FOREIGN KEY to `sources`** is intentionally
  omitted in `epg.sqlite`. SQLite does not support cross-file FK
  enforcement. `Sql.deleteEpgForSource` + the hook in `deleteSource`
  provide the equivalent cleanup.
- **`checkpointAndTruncateWal` now checkpoints both files.** It's
  called from `epg_service.dart` after inserts and assignments. The
  `db.sqlite` checkpoint leg is cheap (WAL is tiny) and adds <5ms.
- **`deleteStalePrograms` remains.** It's now harmless to `db.sqlite`
  since it runs against `epg.sqlite`. The stale-delete WAL still
  inflates `epg.sqlite`'s WAL — the second checkpoint call in
  `epg_service.dart` (added in the previous session) handles that.
- **`epg_refresh_log` moves to `epg.sqlite`** for cohesion — it's
  EPG-specific metadata. Callers are unchanged.
- **Two database files, two WALs.** sqlite_async manages each
  independently. No locking interaction between them.
- **Total code change:** ~120 lines across 2 files
  (`db_factory.dart` +80, `sql.dart` +40 including the 8 one-line
  `DbFactory` → `EpgDbFactory` swaps).
