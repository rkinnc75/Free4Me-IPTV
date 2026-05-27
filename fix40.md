# fix31.md — EPG refresh fails with "syntax error near '('" on `UPDATE … FROM (VALUES …)`

> Symptom: tapping "Refresh EPG now" in Settings produces an
> "EPG Refresh Complete" dialog with:
>
> ```
> ✗ Aniel3000 : SqliteException(1): while preparing statement,
> near "(": syntax error, SQL logic error (code 1)
> Causing statement (at position 1304):
> UPDATE channels
>    SET epg_channel_id = _data.epg
>   FROM (VALUES (?,?),(?,?),(?,?),(?,?),…) AS _data(id, epg)
> ```
>
> (Screenshot in `1000058323.jpg`.)
>
> Root cause: the `UPDATE … FROM (VALUES …) AS alias(col1, col2)`
> form uses the **derived-table column-alias-list syntax** that
> SQLite added in **3.39.0** (June 2022). The bundled SQLite shipped
> by `sqlite3_flutter_libs` on this device is parsing it as a syntax
> error at the `(` after the alias name. Either the Android platform
> is loading a different sqlite shared library than expected, or the
> bundled version on this specific device is older than 3.39.
>
> The fix doesn't depend on figuring out exactly which sqlite is
> loaded — it just rewrites the statement to use a CTE form that has
> been supported since SQLite 3.8.3 (2014), so it works regardless
> of which build is loaded.

---

## Evidence trail

### 1. The exact SQL that's failing

`lib/backend/sql.dart:693-698`:

```dart
await tx.execute('''
  UPDATE channels
     SET epg_channel_id = _data.epg
    FROM (VALUES $placeholders) AS _data(id, epg)
   WHERE channels.id = _data.id
''', params);
```

This SQL has three SQLite-version dependencies:

| Feature | Required SQLite version | Released |
|---|---|---|
| `UPDATE … FROM <table>` | 3.33.0 | Aug 2020 |
| `VALUES (…),(…) AS subquery` | 3.0+ (universal) | n/a |
| `AS alias(col1, col2, …)` column-alias list | **3.39.0** | Jun 2022 |

The combination requires 3.39+. Before 3.39, the parser hits the `(`
after `_data` and bails with exactly the error in the screenshot:
`syntax error, near "("`.

### 2. The error position confirms the diagnosis

The dialog says `Causing statement (at position 1304)`. For a chunk
of 200 entries the SQL string looks like:

```
UPDATE channels
   SET epg_channel_id = _data.epg
  FROM (VALUES (?,?),(?,?),…[200 of them]…) AS _data(id, epg)
 WHERE channels.id = _data.id
```

200 × 6 chars per `(?,?),` = 1200 chars for the placeholders + ~100
chars of fixed text → position 1304 lands right after `_data(`. That
is precisely the column-alias-list syntax SQLite is rejecting.

### 3. The log shows where in the EPG flow it fires

`free4me_log_1779637413496.txt` lines 91–92:

```
11:40:47  EPG: downloaded "Aniel3000 " — 573572 programs
11:40:47  EPG: matching 35945 channels (unmatched only) for "Aniel3000 "
11:41:01  EPG: downloading "Emjay" …   ← only 14 s later
```

Aniel3000's match step (matching 35 945 channels) should take
several minutes based on the user's earlier matching log
(35 791 channels took ~5 min). It instead "finished" in 14 s
because the match completed in-memory and threw on the SQL
write-back. The user then saw the error dialog at the end of the
refresh flow.

### 4. Same code in 1.16.2

`sql.dart` `setChannelEpgIds` is identical in 1.16.2 and 1.16.3.
The earlier log (`free4me_log_1779507390618.txt`) has no EPG
events at all — we have no evidence this code path EVER ran
successfully on this user's device. The "EPG Match" lines in the
even earlier log were the match-phase progress, which runs in
memory; the SQL write-back is the only thing this fix touches.

This is a latent bug that any user with bundled SQLite < 3.39
would hit on the first EPG match. The reason it wasn't surfaced
sooner is that most users probably never tap "Refresh EPG now"
manually, and the background EPG worker may swallow the exception
silently.

---

## Fix 31.1 — Rewrite the UPDATE to use a CTE

**File:** `lib/backend/sql.dart`

**Current code (lines 671–700):**

```dart
/// Write matched/manual EPG channel IDs back to the channels table.
///
/// Uses a chunked `UPDATE … FROM (VALUES …)` so a 10k-entry map costs
/// ~50 statements instead of 10k single-row UPDATEs. Requires SQLite
/// 3.33+ (UPDATE-FROM); sqlite_async ships its own sqlite3 well past
/// that version.
static Future<void> setChannelEpgIds(
  Map<int, String> channelIdToEpgId,
) async {
  if (channelIdToEpgId.isEmpty) return;
  // SQLite limits a single statement to 999 bind parameters; 2 params
  // per row → chunks of 200 stay well under that.
  const chunkSize = 200;
  final entries = channelIdToEpgId.entries.toList(growable: false);
  final db = await DbFactory.db;
  await db.writeTransaction((tx) async {
    for (var offset = 0; offset < entries.length; offset += chunkSize) {
      final end = offset + chunkSize > entries.length
          ? entries.length
          : offset + chunkSize;
      final chunk = entries.sublist(offset, end);
      final placeholders = List.filled(chunk.length, '(?,?)').join(',');
      final params = <Object?>[];
      for (final e in chunk) {
        params
          ..add(e.key)
          ..add(e.value);
      }
      await tx.execute('''
        UPDATE channels
           SET epg_channel_id = _data.epg
          FROM (VALUES $placeholders) AS _data(id, epg)
         WHERE channels.id = _data.id
      ''', params);
    }
  });
}
```

**Replace with:**

```dart
/// Write matched/manual EPG channel IDs back to the channels table.
///
/// Uses a chunked CTE-based UPDATE so a 10k-entry map costs ~50
/// statements instead of 10k single-row UPDATEs.
///
/// The earlier `UPDATE … FROM (VALUES …) AS _data(id, epg)` form
/// required SQLite 3.39+ (for the derived-table column-alias-list
/// syntax) and produced "syntax error near '('" on devices whose
/// loaded sqlite is older — see fix31.md and the screenshot at
/// 1000058323.jpg. The CTE-based form below works on SQLite 3.8.3+
/// (2014), which covers every plausible runtime.
static Future<void> setChannelEpgIds(
  Map<int, String> channelIdToEpgId,
) async {
  if (channelIdToEpgId.isEmpty) return;
  // SQLite limits a single statement to 999 bind parameters; 2 params
  // per row → chunks of 200 stay well under that.
  const chunkSize = 200;
  final entries = channelIdToEpgId.entries.toList(growable: false);
  final db = await DbFactory.db;
  await db.writeTransaction((tx) async {
    for (var offset = 0; offset < entries.length; offset += chunkSize) {
      final end = offset + chunkSize > entries.length
          ? entries.length
          : offset + chunkSize;
      final chunk = entries.sublist(offset, end);

      // Build a CTE that names the columns INSIDE the WITH clause —
      // this is the universally-supported way to alias columns of a
      // derived table:   WITH _data(id, epg) AS (VALUES (?,?), …)
      // The UPDATE then references _data.id and _data.epg normally.
      final placeholders = List.filled(chunk.length, '(?,?)').join(',');
      final params = <Object?>[];
      for (final e in chunk) {
        params
          ..add(e.key)
          ..add(e.value);
      }
      await tx.execute('''
        WITH _data(id, epg) AS (VALUES $placeholders)
        UPDATE channels
           SET epg_channel_id = (
             SELECT epg FROM _data WHERE _data.id = channels.id
           )
         WHERE id IN (SELECT id FROM _data)
      ''', params);
    }
  });
}
```

### Why this is a complete fix (not a hack)

1. **CTE syntax `WITH name(col1, col2) AS …`** is supported by SQLite
   ≥ 3.8.3 (2014). It is the original, ANSI-standard way to alias
   the columns of a derived table.

2. **Correlated subquery in `SET`** has been in SQLite since version
   1. Every row in `channels` matching the `WHERE id IN (...)` runs
   one lookup into the (tiny) `_data` CTE.

3. **`WHERE id IN (SELECT id FROM _data)`** restricts the update to
   only channels with a matching entry. Without this filter, the
   subquery would return NULL for non-matching rows and the UPDATE
   would set `epg_channel_id = NULL` on every channel in the table —
   the opposite of what we want. (The original `UPDATE … FROM` form
   has the same filter via `WHERE channels.id = _data.id`.)

### Performance check

The CTE form pays one cost the old form didn't: for each of the up
to 200 channels updated per statement, SQLite scans the CTE looking
for the matching `id`. With chunk size 200, that's 200 × 200 =
40 000 comparisons per chunk in the worst case.

This is a non-issue:

- CTE rows are tiny (int + short string), in-memory, no disk I/O.
- 40 000 in-memory int comparisons per chunk takes well under 1 ms.
- The original 10 000-row map → ~50 chunks → ~50 ms total CTE
  overhead across the entire EPG match write-back.
- The actual `UPDATE channels` step (with its FTS index trigger
  fan-out) dominates by orders of magnitude.

If profiling ever shows the CTE scan as a bottleneck, the fallback
is `INSERT INTO channels (id, epg_channel_id) VALUES (...) ON
CONFLICT(id) DO UPDATE SET epg_channel_id = excluded.epg_channel_id`
(UPSERT, supported since SQLite 3.24, 2018). But that triggers the
`channels_ai` insert trigger as well as the `channels_au` update
trigger, which could double-write the FTS row. Stick with the CTE.

---

## Why I'm sure this fixes the symptom

The error message names exactly the construct we're removing:

```
SqliteException(1): while preparing statement, near "(": syntax error
```

Position 1304 in a 1304-char SQL string lands right after `_data(`
— the column-alias-list syntax that requires 3.39+. The CTE
replacement doesn't use that construct.

If after this fix the error persists, the implementer should
capture and log the *new* failing SQL — but the failure surface
just shrunk from "SQLite 3.39+ only" to "SQLite 3.8.3+", which
covers every device anyone could plausibly run this app on.

---

## Test plan

1. Apply fix31 and rebuild.
2. Install on the same device that produced the screenshot.
3. Open Settings → tap "Refresh EPG now".
4. **Expected:** the refresh completes without the "syntax error
   near '('" dialog. The summary dialog should say something like:
   ```
   ✓ Aniel3000 : 573572 programs · NNNNN/35945 channels matched
   ✓ Emjay : 109395 programs · MMMMM/52861 channels matched
   ```
   (numbers will vary based on match quality).
5. With debug logging enabled, look for two new lines per source:
   ```
   EPG: match done "Aniel3000 " — 14713/35945 matched ...
   EPG: match done "Emjay" — 14305/52861 matched ...
   ```
   These appear ONLY when the SQL write-back succeeded. Their
   presence in the log proves the UPDATE went through.
6. Navigate to a few channels in the All view and confirm that
   EPG program names appear under them (or in the program guide).
   This is the proof that `epg_channel_id` actually got written.
7. **Rematch regression check:** Settings → "Re-match all
   channels". Same expected behaviour — completes cleanly, no
   dialog error.

---

## Notes for the implementer

- **One function changed.** No other call sites or SQL statements
  are affected.
- **No SQL schema changes.** No new dependencies.
- **No migration needed.** The DB on-disk format is identical;
  only the runtime query that writes to it changes.
- **Update the doc comment** as shown — the old comment claimed
  the SQL required "SQLite 3.33+" but the actual `AS _data(id,
  epg)` clause required 3.39+. The new comment names the real
  requirement (3.8.3+) and references this fix.
- **If you want belt-and-braces:** add a one-time SQLite version
  log line at app start so a future "EPG refresh broken" bug
  report comes with the version number attached. Something like
  `final v = await db.get('SELECT sqlite_version()');
  AppLog.info('Sqlite: bundled version ${v.columnAt(0)}');`. Out
  of scope for this fix, but trivially helpful.
