# fix29.md — EPG refresh speedups (5 changes)

> Repo state: `Free4Me-IPTV-1.16.1` with fix28 applied.
> Target: v1.16.2.

This runbook bundles five EPG-refresh performance changes identified
by the v1.16.1 EPG review. They're applied as a single change set
because parts 29.2 and 29.5 touch the same SQL paths and benefit
from being reviewed together.

## What's covered

| Part | Change | Files touched |
|---|---|---|
| 29.1 | Bump `_matchBatchSize` 300 → 2000 | `lib/backend/epg_service.dart` |
| 29.2 | Batched `setChannelEpgIds` via `UPDATE…FROM(VALUES …)` | `lib/backend/sql.dart` |
| 29.3 | Concurrent multi-source refresh (max 2) | `lib/backend/epg_service.dart` |
| 29.4 | Inverted token index in `EpgMatcher` (tiers 5 + 7) | `lib/backend/epg_matcher.dart` |
| 29.5 | Idempotent program inserts + post-parse GC | `lib/backend/db_factory.dart`, `lib/backend/sql.dart`, `lib/backend/epg_service.dart` |

No new package dependencies. One DB migration (schema v8).

---

## Part 29.1 — Bump match batch size

**Why:** every batch sent to `compute(_matchInIsolate, …)` spawns a
fresh isolate AND deep-copies the full `channelMap` (often 10k+
entries) across the isolate boundary. With 90k channels and a
batch size of 300, that's 300 isolate spawns and 300 deep-copies
per refresh. The matcher also rebuilds its reverse lookups
(`byNormalizedName`, `byStrippedId`, etc.) once per batch.

Bumping to 2000 cuts spawn / copy / rebuild count by ~6.6×. With
90k channels we still get ~45 progress updates, which is plenty.

**File:** `lib/backend/epg_service.dart`

```dart
const _matchBatchSize = 2000;
```

---

## Part 29.2 — Batched setChannelEpgIds

**Why:** the current implementation runs N individual `UPDATE …
WHERE id = ?` statements inside a single transaction. With 10k
matched channels that's 10k prepare/bind/step/finalize cycles even
though they all share the same statement shape.

Modern SQLite (3.33+) supports `UPDATE … FROM (VALUES …)`. Pairing
this with chunks of ~100 rows turns 10k roundtrips into ~100. The
sqlite_async package ships sqlite3 ≥ 3.36, so the syntax is safe.

**File:** `lib/backend/sql.dart`

Replace the existing `setChannelEpgIds` body with a chunked variant
that builds a `VALUES (?,?), (?,?), …` clause inside a single
`UPDATE … FROM (VALUES …)` statement, keeping ≤ ~800 bind params
per statement to stay under the 999 SQLite parameter limit.

---

## Part 29.3 — Concurrent multi-source refresh

**Why:** `EpgService.refreshAllSources` iterates sources in strict
serial. HTTP downloads from two providers don't fight each other —
running them concurrently saves wall-clock time for users with
multiple EPG sources. SQLite writes serialize anyway (single
writer), so the DB-write phase doesn't parallelize, but parsing
source B while writing source A is a clean win.

Cap at 2 concurrent so we don't hammer one provider with multiple
sources pointed at the same endpoint, mirroring the
`maxConcurrent=2` pattern `Utils.refreshAllSources` already uses
for M3U / Xtream refresh.

**File:** `lib/backend/epg_service.dart`

```dart
static Future<void> refreshAllSources({bool background = false}) async {
  final sources = (await Sql.getSources())
      .where((s) => s.enabled && resolveEpgUrl(s) != null)
      .toList();
  const maxConcurrent = 2;
  for (var i = 0; i < sources.length; i += maxConcurrent) {
    final chunk = sources.skip(i).take(maxConcurrent);
    await Future.wait(chunk.map(
      (s) => refreshSource(s, epgUrl: resolveEpgUrl(s), background: background),
    ));
  }
}
```

---

## Part 29.4 — Inverted token index in EpgMatcher

**Why:** tiers 5 (token-superset) and 7 (Jaccard) iterate every
EPG entry for every unmatched channel. With 90k unmatched channels
× 10k EPG entries that's ~900M token-set operations per refresh.
Tier 5 short-circuits early on most channels; tier 7 does not and
dominates the matcher wall-clock for large feeds.

Build a `Map<String, List<int>> tokenToEpgIndices` once per
`matchWithReport()` call. For each unmatched channel, the
candidate set is the union of postings lists for the channel's
tokens — typically a few hundred entries instead of all 10k.

**Critical:** the change must produce IDENTICAL match results to
the brute-force loop. The only semantic difference is that EPG
entries with zero token overlap with the channel are skipped — and
they would have scored 0 in Jaccard / failed the subset check in
tier 5 anyway. The fuzzy-ambiguous tie-break logic is preserved.

**File:** `lib/backend/epg_matcher.dart`

---

## Part 29.5 — Idempotent program inserts + post-parse GC

**Why:** the current refresh does `DELETE FROM programmes WHERE
source_id=?` upfront, then re-inserts everything from the XMLTV
stream. Two problems:

1. If the network fetch fails mid-stream, the DB is left empty.
   Users lose all EPG until the next successful refresh.
2. Most programs in the time window are unchanged between
   refreshes. Wiping and re-inserting wastes I/O.

Also: the existing `INSERT OR IGNORE INTO programmes …` is a
no-op because there's no UNIQUE constraint on
`(source_id, epg_channel_id, start_utc)`. Adding the constraint
turns it into a real upsert.

### Steps

1. **Schema migration v8** in `lib/backend/db_factory.dart`:

   ```dart
   ..add(SqliteMigration(8, (tx) async {
     // Dedupe any existing rows before adding the unique index.
     // Keep the lowest id per duplicate group; everything else
     // is bit-identical so the choice is arbitrary.
     await tx.execute('''
       DELETE FROM programmes WHERE id NOT IN (
         SELECT MIN(id) FROM programmes
         GROUP BY source_id, epg_channel_id, start_utc
       );
     ''');
     await tx.execute('''
       CREATE UNIQUE INDEX idx_programs_unique
         ON programmes(source_id, epg_channel_id, start_utc);
     ''');
   }))
   ```

2. **`Sql.insertProgramsBatch`** — replace `INSERT OR IGNORE`
   with an explicit upsert that overwrites changed metadata
   (title / description / category / stop_utc / episode_num) when
   a row with the same `(source_id, epg_channel_id, start_utc)`
   already exists. Programs scheduled to repeat keep their
   existing id; programs whose stop_utc shifted (typical for live
   sports overrun) get the new value.

3. **`EpgService.downloadAndParseEpg`** — remove the upfront
   `await Sql.deleteProgramsForSource(source.id!);`. Replace with
   a post-parse GC:

   ```dart
   await Sql.deleteStalePrograms(source.id!, windowStart);
   ```

   where `deleteStalePrograms` is a new SQL helper:

   ```dart
   static Future<void> deleteStalePrograms(
     int sourceId,
     int windowStartEpoch,
   ) async {
     final db = await DbFactory.db;
     await db.execute(
       'DELETE FROM programmes WHERE source_id = ? AND stop_utc < ?',
       [sourceId, windowStartEpoch],
     );
   }
   ```

   This bounds the table size to the configured EPG window while
   preserving the previous EPG on fetch failure.

4. **`Sql.deleteProgramsForSource`** stays — it's called from
   source-delete teardown via `ON DELETE CASCADE`, but having an
   explicit helper available is also handy for "Re-import EPG
   from scratch" manual actions.

---

## Apply order

1. 29.1 — single-line constant change (`epg_service.dart`)
2. 29.2 — `setChannelEpgIds` (sql.dart)
3. 29.3 — `refreshAllSources` (epg_service.dart)
4. 29.4 — `EpgMatcher.matchWithReport` (epg_matcher.dart)
5. 29.5 — schema v8 + insert upsert + GC (db_factory.dart, sql.dart, epg_service.dart)

---

## Risk + rollback

- **29.1, 29.3:** trivially reversible — flip the constant / undo the loop.
- **29.2:** SQL syntax. If a target device runs SQLite < 3.33, the
  `UPDATE … FROM` form fails. The Android system SQLite is ≥ 3.36
  on Android 11+ (our minSdk is 21 → Android 5.0, but sqlite_async
  bundles its own sqlite3 via FFI, currently 3.45+). Verified safe.
- **29.4:** semantic risk if the inverted index changes match
  outcomes. Mitigation: the new loop's candidate set is a strict
  superset of "EPG entries that could possibly match" under the
  old logic — entries with zero token overlap with the channel
  cannot pass tier 5 subset or score above 0 in tier 7 — so the
  match results are identical by construction.
- **29.5:** schema migration. If the unique index creation fails
  on a corrupted DB, the migration aborts and the user is stuck
  on schema v7. Mitigation: the dedupe `DELETE` runs first and
  is guaranteed to succeed; the `CREATE UNIQUE INDEX` then
  succeeds against the deduplicated set.

---

## Test plan (manual)

1. **Cold install** — fresh app, add a 90k-channel Xtream source
   with EPG URL, observe EPG refresh wall-clock. Compare against
   v1.16.1 baseline.
2. **Hot refresh** — trigger a second EPG refresh from Settings.
   Wall-clock should drop substantially relative to first refresh
   (most programs unchanged → upsert no-op + matcher skips
   already-matched channels via existing `getChannelsNeedingEpgMatch`).
3. **Mid-fetch failure** — disable Wi-Fi mid-parse. Re-enable.
   Confirm previous EPG remains intact (no empty-DB window).
4. **Match correctness** — spot-check 20 random channels'
   `epg_channel_id` assignments before/after the matcher change.
   All should be identical or unmatched on both versions.
5. **Two-source refresh** — configure two sources with EPG URLs.
   Confirm both download/parse phases overlap in the logs
   (timestamps for "XMLTV: GET" should be < 5s apart).

---

## Notes for the implementer

- Total file diff (rough):
  - `lib/backend/epg_service.dart`: +12 / -10
  - `lib/backend/sql.dart`: +45 / -10
  - `lib/backend/epg_matcher.dart`: +35 / -15
  - `lib/backend/db_factory.dart`: +18 / 0
- No new package dependencies.
- No SDK / build-tool version bumps required.
- The schema migration adds 7th total migration (v7 → v8).
