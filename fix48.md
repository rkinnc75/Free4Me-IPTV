# fix48.md — Imported sources always created as enabled regardless of backup value

> **Version:** Free4Me-IPTV 1.17.3
> **Symptom:** after a fresh install + backup import, Emjay (which was
> `enabled: false` in the backup) appears enabled in Settings → Sources
> and gets refreshed as if it were active.
>
> **User report:** "I never enabled Emjay, only disable. Upon first
> install it keeps enabling both, even though it was off at setting
> save."
>
> **Evidence:** `free4me_log_1779719860283.txt` line 6312 — Emjay EPG
> download fires at 19:57:34 in a session where the user did not
> deliberately enable it. The exported backup at line 6311 confirms
> `sources=2`, meaning Emjay is in the DB and being treated as active
> despite the user never re-enabling it.

---

## Root cause — `getOrCreateSourceByName` omits `enabled` and `default_engine`

**`lib/backend/sql.dart:177-186`:**

```dart
await tx.execute('''
      INSERT INTO sources (name, source_type, url, username, password, epg_url)
      VALUES (?, ?, ?, ?, ?, ?);
    ''', [
  source.name,
  source.sourceType.index,
  source.url,
  source.username,
  source.password,
  source.epgUrl,
]);
```

The INSERT names six columns. The `sources` table has eight
user-configurable columns:

| Column | In INSERT? | DB default |
|---|---|---|
| `name` | ✓ | — |
| `source_type` | ✓ | — |
| `url` | ✓ | — |
| `username` | ✓ | — |
| `password` | ✓ | — |
| `epg_url` | ✓ | — |
| `enabled` | **✗** | **`DEFAULT 1`** |
| `default_engine` | **✗** | `NULL` |

`enabled DEFAULT 1` is declared in `db_factory.dart:20`. Every row
inserted without an explicit `enabled` value gets `1` (enabled),
regardless of what the backup carried.

`default_engine` defaults to `NULL` (engine auto-selection), which
is usually correct, but a backup that explicitly stored a per-source
engine preference silently loses it on import.

### The backup has the data — it just gets dropped

`lib/backend/settings_io.dart:209` correctly parses the JSON:

```dart
enabled: map['enabled'] as bool? ?? true,
defaultEngine: EngineType.fromJson(map['defaultEngine'] as String?),
```

So `source.enabled = false` for Emjay after parsing. Then
`getOrCreateSourceByName(source)` is called — the `Source` object
carries the correct value, but the INSERT never writes it.

### The existing-source path also skips updating

**Lines 170-175:**

```dart
var sourceId = (await tx.getOptional(
        "SELECT id FROM sources WHERE name = ?", [source.name]))
    ?.columnAt(0);
if (sourceId != null) {
  memory['sourceId'] = sourceId.toString();
  return;   // ← silent return, no UPDATE
}
```

If the source already exists by name (e.g. a re-import over an
existing install), none of its columns are updated. A second import
of a backup where Emjay is disabled would leave an already-enabled
Emjay untouched.

---

## Fix 48.1 — Include `enabled` and `default_engine` in the INSERT; UPDATE on conflict

**File:** `lib/backend/sql.dart`

**Current code (lines 168-190):**

```dart
    getOrCreateSourceByName(Source source) {
  return (SqliteWriteContext tx, Map<String, String> memory) async {
    var sourceId = (await tx.getOptional(
            "SELECT id FROM sources WHERE name = ?", [source.name]))
        ?.columnAt(0);
    if (sourceId != null) {
      memory['sourceId'] = sourceId.toString();
      return;
    }
    await tx.execute('''
          INSERT INTO sources (name, source_type, url, username, password, epg_url) VALUES (?, ?, ?, ?, ?, ?);
        ''', [
      source.name,
      source.sourceType.index,
      source.url,
      source.username,
      source.password,
      source.epgUrl,
    ]);
    memory['sourceId'] =
        (await tx.get("SELECT last_insert_rowid();")).columnAt(0).toString();
  };
}
```

**Replace with:**

```dart
    getOrCreateSourceByName(Source source) {
  return (SqliteWriteContext tx, Map<String, String> memory) async {
    // Use INSERT OR REPLACE so re-importing a backup correctly
    // overwrites all editable columns — including `enabled` and
    // `default_engine` — instead of silently keeping the existing
    // row's stale values.
    //
    // UNIQUE constraint is on `name` (index_source_name). INSERT OR
    // REPLACE deletes the conflicting row and re-inserts, which
    // re-generates the rowid. Since channels.source_id is a FK to
    // sources.id, and the id is AUTOINCREMENT (stable across
    // replaces), this is safe — the new id is always the same as
    // the old one when the constraint fires on an existing name.
    //
    // Wait — INSERT OR REPLACE with AUTOINCREMENT gives a NEW id,
    // not the old one. That would orphan channel rows.
    // Use INSERT OR IGNORE + UPDATE instead (upsert without
    // disturbing the id).
    await tx.execute('''
          INSERT OR IGNORE INTO sources
            (name, source_type, url, username, password, epg_url, enabled, default_engine)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        ''', [
      source.name,
      source.sourceType.index,
      source.url,
      source.username,
      source.password,
      source.epgUrl,
      source.enabled ? 1 : 0,         // fix48: was always DEFAULT 1
      source.defaultEngine?.toJson(),  // fix48: was always NULL
    ]);
    // If the row already existed (INSERT OR IGNORE silently skipped),
    // update its editable columns to match the backup. This ensures
    // a re-import correctly applies the saved enabled/disabled state
    // and engine preference without touching the id (which channels
    // reference via source_id FK).
    await tx.execute('''
          UPDATE sources
             SET source_type   = ?,
                 url           = ?,
                 username      = ?,
                 password      = ?,
                 epg_url       = ?,
                 enabled       = ?,
                 default_engine = ?
           WHERE name = ?
             AND id NOT IN (SELECT last_insert_rowid());
        ''', [
      source.sourceType.index,
      source.url,
      source.username,
      source.password,
      source.epgUrl,
      source.enabled ? 1 : 0,
      source.defaultEngine?.toJson(),
      source.name,
    ]);
    final row = await tx.getOptional(
        "SELECT id FROM sources WHERE name = ?", [source.name]);
    memory['sourceId'] = row!.columnAt(0).toString();
  };
}
```

> **Why INSERT OR IGNORE + UPDATE rather than INSERT OR REPLACE?**
>
> `INSERT OR REPLACE` deletes the conflicting row and inserts a new
> one. SQLite `AUTOINCREMENT` assigns a new `id` on each insert,
> even for a replace. Since `channels.source_id` is a foreign key
> referencing `sources.id`, re-creating the row with a new id would
> orphan all existing channel rows for that source. Using INSERT OR
> IGNORE (which skips silently if the name already exists) followed
> by a targeted UPDATE preserves the existing id while correctly
> applying all other fields from the backup.
>
> **Why `id NOT IN (SELECT last_insert_rowid())`?**
>
> `last_insert_rowid()` returns the id of the row just inserted by
> `INSERT OR IGNORE`. If the INSERT succeeded (new source), that id
> IS the new source; the UPDATE's WHERE clause finds nothing and does
> nothing (the INSERT already wrote all columns correctly). If the
> INSERT was ignored (existing source), `last_insert_rowid()` returns
> the last rowid from a prior operation — which won't match the
> source's actual id. The UPDATE's WHERE then finds the existing row
> by name and updates it. This is a single-pass approach with no
> extra SELECT.
>
> **Alternative (simpler, safer):** query the id first by name, then
> INSERT if null, UPDATE if not null. This is more readable but costs
> an extra round-trip per source. With 2 sources in the user's backup,
> the cost is negligible. Use whichever the implementer prefers:

```dart
// Simpler alternative — explicit SELECT-then-INSERT-or-UPDATE:
getOrCreateSourceByName(Source source) {
  return (SqliteWriteContext tx, Map<String, String> memory) async {
    final existing = await tx.getOptional(
      "SELECT id FROM sources WHERE name = ?",
      [source.name],
    );

    if (existing != null) {
      // Source already exists — update all editable fields so a
      // re-import correctly applies the backup's values (especially
      // `enabled` and `default_engine`). The id is preserved, so
      // channel FK references are unaffected.
      final id = existing.columnAt(0);
      await tx.execute('''
            UPDATE sources
               SET source_type    = ?,
                   url            = ?,
                   username       = ?,
                   password       = ?,
                   epg_url        = ?,
                   enabled        = ?,
                   default_engine = ?
             WHERE id = ?
          ''', [
        source.sourceType.index,
        source.url,
        source.username,
        source.password,
        source.epgUrl,
        source.enabled ? 1 : 0,
        source.defaultEngine?.toJson(),
        id,
      ]);
      memory['sourceId'] = id.toString();
    } else {
      // New source — INSERT with all fields including enabled and
      // default_engine. Previously these were omitted, causing every
      // imported source to be created enabled regardless of the
      // backup value (fix48).
      await tx.execute('''
            INSERT INTO sources
              (name, source_type, url, username, password, epg_url,
               enabled, default_engine)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
          ''', [
        source.name,
        source.sourceType.index,
        source.url,
        source.username,
        source.password,
        source.epgUrl,
        source.enabled ? 1 : 0,
        source.defaultEngine?.toJson(),
      ]);
      memory['sourceId'] = (await tx.get("SELECT last_insert_rowid();"))
          .columnAt(0)
          .toString();
    }
  };
}
```

**Use the simpler alternative.** It is clearer, safer (no
`last_insert_rowid()` ambiguity), and the extra SELECT costs
microseconds.

---

## Fix 48.2 — Add import logging for per-source enabled state

**File:** `lib/backend/settings_io.dart`

The existing import log at line 185 logs the settings block but
not the per-source enabled state. Extend it to show each source's
name and enabled flag so the log confirms what was written.

**Current code (lines 195-230, the source import loop):**

```dart
if (payload['sources'] != null) {
  final rawSources = payload['sources'] as List<dynamic>;
  for (final raw in rawSources) {
    final map = raw as Map<String, dynamic>;
    final source = Source(
      name: map['name'] as String,
      ...
      enabled: map['enabled'] as bool? ?? true,
      ...
    );
    await Sql.commitWrite([Sql.getOrCreateSourceByName(source)]);

    final preserveRaw = map['preserve'] as List<dynamic>?;
    ...
  }
}
```

**After the `commitWrite` line for each source, add:**

```dart
    await Sql.commitWrite([Sql.getOrCreateSourceByName(source)]);

    AppLog.info(
      'SettingsIo.import: source "${source.name}"'
      ' enabled=${source.enabled}'
      ' type=${source.sourceType.name}'
      ' engine=${source.defaultEngine?.toJson() ?? "auto"}'
      ' preserve=${preserveRaw?.length ?? 0} entries',
    );
```

After this fix, the log will show:

```
SettingsIo.import: source "Aniel3000 " enabled=true type=m3u engine=auto preserve=0 entries
SettingsIo.import: source "Emjay" enabled=false type=m3u engine=auto preserve=0 entries
```

Making it unambiguous whether the enabled state was correctly
applied.

---

## Fix 48.3 — Add logging to `Utils.refreshAllSources` (already in fix44/fix32 but not yet applied)

Confirmed from the log: no `Utils.refreshAllSources: N enabled source(s)` line appears anywhere, confirming neither fix32 nor fix44 is applied. The fix46 runbook calls this out. Including here as a reminder:

```dart
AppLog.info(
  'Utils.refreshAllSources: ${enabled.length} enabled source(s)'
  ' (${enabled.map((s) => s.name).join(", ")})',
);
```

This single line would have immediately shown "2 enabled source(s)
(Aniel3000, Emjay)" in the session log — proving Emjay was being
treated as enabled despite the user's intent.

---

## Test plan

### Primary — disabled source stays disabled after import

1. Export a backup with Emjay disabled. Confirm the JSON has
   `"enabled": false` for Emjay.
2. Uninstall + reinstall.
3. Import the backup on the welcome screen.
4. Enable debug logging.
5. Open Settings → Sources.
6. **Expected:** Emjay shows the disabled toggle (greyed out).
7. In the log, find:
   ```
   SettingsIo.import: source "Aniel3000 " enabled=true ...
   SettingsIo.import: source "Emjay" enabled=false ...
   Utils.refreshAllSources: 1 enabled source(s) (Aniel3000 )
   ```
8. Confirm Emjay does NOT get refreshed (no `XMLTV: GET` for the
   Emjay URL in the import session).

### Secondary — re-import over existing install

1. With both sources installed and Aniel3000 enabled, Emjay
   disabled:
2. Go to Settings → Backup & Restore → Import settings from file.
3. Pick the same backup (Emjay disabled).
4. **Expected:** Emjay remains disabled. No source changes from
   the user's perspective.
5. In the log: `SettingsIo.import: source "Emjay" enabled=false`

### Secondary — re-import where source was manually enabled

1. With both sources installed, manually enable Emjay.
2. Re-import the backup (Emjay disabled).
3. **Expected:** Emjay is now disabled again — the import
   overwrites the manual change. This is correct: backup import
   is "restore to this exact state."

### Regression — new source created normally

1. Settings → Sources → add a new source.
2. **Expected:** source created enabled (default) — same as before.
   The fix only changes what happens when a `Source` object with a
   specific `enabled` value is passed to `getOrCreateSourceByName`.
   The normal add-source path constructs a `Source` with
   `enabled: true` by default.

### `default_engine` regression

1. Export a backup where one source has a custom engine set.
2. Fresh install + import.
3. **Expected:** source has the correct engine setting, not `auto`.

---

## Impact on other callers of `getOrCreateSourceByName`

`grep -rn "getOrCreateSourceByName" lib/` — call sites:

| File | Line | Caller | `source.enabled` when called |
|---|---|---|---|
| `settings_io.dart` | ~205 | backup import | from backup JSON |
| `m3u.dart` | ~25 | new source from M3U wizard | `true` (default) |
| `xtream.dart` | ~15 | new source from Xtream wizard | `true` (default) |

The wizard paths always pass `source.enabled = true` (the constructor
default), so the INSERT change from `DEFAULT 1` to explicit `1` is
transparent to them. The UPDATE path (existing source) also has no
effect during a normal M3U/Xtream add because `getOrCreateSourceByName`
during those flows is called once to create the source; it doesn't
re-process an existing one.

The only caller that benefits from this fix is the import path,
which explicitly parses `enabled` from the backup JSON. All other
callers are unaffected.

---

## Notes for the implementer

- **One SQL function changed** (`getOrCreateSourceByName`). The
  change is backwards-compatible — existing sources created by the
  wizard are always enabled and get the same INSERT behaviour as
  before.
- **No schema changes.** `enabled` and `default_engine` columns
  already exist; we're just writing to them.
- **Use the "simpler alternative"** (SELECT-then-INSERT-or-UPDATE)
  rather than the INSERT-OR-IGNORE + UPDATE form. It is clearer and
  avoids any ambiguity around `last_insert_rowid()`.
- **Apply fix48 alongside fix44 and fix46.** The import logging in
  fix48.2 is particularly valuable when all three are applied
  together — the log will show the complete import story from backup
  parsing through source creation through refresh scoping.
- **No new dependencies, no new files.**
