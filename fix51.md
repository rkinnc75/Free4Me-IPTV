# Fix 51 Review Notes

Read-only review performed against the current working tree after the v1.18.0
changes were staged locally. No files were modified during the review.

## Review Target

- Branch: `main`
- Current HEAD at review time: `c440642 PO-CI Trim release workflow comments`
- Working tree state: dirty, with app changes still present outside HEAD
- Scope reviewed: EPG parsing/storage, backup import/export, Settings refactor,
  source refresh dialogs, release/build metadata

## Findings

### P1 - XMLTV parser can hang forever on an empty or timed-out body

File: `lib/backend/xmltv_parser.dart`

Relevant lines:

- `_maybeUngzip()` is awaited before the XML event stream is built.
- `response.stream.timeout(... onTimeout: sink.close())` can close the stream
  before any non-empty chunk arrives.
- `_maybeUngzip()` only completes its `Completer` after it sees a non-empty
  chunk or receives `onError`; `onDone` closes the controller but does not
  complete the `Completer`.

Impact:

If an EPG server returns an empty body, or the new body timeout closes the
stream before the first chunk, `await _maybeUngzip(...)` never returns. The EPG
refresh dialog remains stuck instead of finishing or reporting an error.

Suggested fix:

In `_maybeUngzip().onDone`, complete the `Completer` when it has not completed
yet. For an empty body, complete with `controller.stream` before closing the
controller, or complete with a stream error that makes the caller surface a
failed refresh.

### P1 - Credential-safe backup import can erase existing Xtream credentials

Files:

- `lib/backend/settings_io.dart`
- `lib/backend/sql.dart`

Relevant lines:

- `_sourceToMap()` intentionally exports `username` and `password` as `null`
  when `includeCredentials` is false.
- `SettingsIo.importFromFile()` rebuilds a `Source` with those null values.
- `Sql.getOrCreateSourceByName()` updates existing rows and writes
  `username = ?`, `password = ?` unconditionally.

Impact:

Re-importing a backup that was exported without credentials can overwrite an
already-configured Xtream source's stored username and password with `null`.
The source will then fail future refresh/playback even though the user chose
the safer backup option.

Suggested fix:

When updating an existing source from import, preserve existing credentials if
the incoming payload has `null` username/password. One option is:

```sql
username = COALESCE(?, username),
password = COALESCE(?, password)
```

If users need a way to explicitly clear credentials, make that a separate
intentional action rather than an implicit effect of credential-safe imports.

### P1 - Migration 8 performs expensive work on data migration 9 drops

File: `lib/backend/db_factory.dart`

Relevant lines:

- Migration 8 deletes duplicate rows from `programmes` and creates a unique
  index on `(source_id, epg_channel_id, start_utc)`.
- Migration 9 immediately drops `programmes` and `epg_refresh_log` from
  `db.sqlite` because EPG data moved to `epg.sqlite`.

Impact:

Users upgrading from schema 7 with a large EPG table pay the full cost of a
large dedupe and index build at app startup, then immediately discard that same
table. On large feeds this can make the first launch after upgrade appear hung
or extremely slow for no benefit.

Suggested fix:

Avoid running the migration-8 programme-table dedupe/index path when the next
target migration drops the table. Options include combining the EPG move into
the same migration path, making migration 8 conditional on a retained
`programmes` table, or replacing migration 8 with a no-op for upgrade paths
that will proceed to migration 9.

### P2 - Restored manual EPG override may not control `epg_channel_id`

File: `lib/backend/sql.dart`

Relevant lines:

- `restorePreserve()` sets:
  - `epg_channel_id = COALESCE(epg_channel_id, ?)`
  - `epg_manual_override = COALESCE(?, epg_manual_override)`

Impact:

If the fresh source import supplies an `epg_channel_id` that differs from the
previous manual override, the manual override is restored into
`epg_manual_override` but `epg_channel_id` keeps the imported value. Since the
guide lookup uses `epg_channel_id`, the restored manual override may appear to
exist but not actually take effect.

Suggested fix:

When `channel.epgManualOverride` is non-null, restore both
`epg_manual_override` and `epg_channel_id` to that override value. Only use the
`COALESCE(epg_channel_id, channel.epgChannelId)` behavior for non-manual
matches.

### P2 - Stale-program delete runs after the explicit WAL checkpoint

Files:

- `lib/backend/epg_service.dart`
- `lib/backend/sql.dart`

Relevant lines:

- `downloadAndParseEpg()` calls `Sql.checkpointAndTruncateWal()`.
- Only after that does it call `Sql.deleteStalePrograms(...)`.

Impact:

The explicit checkpoint is intended to prevent a large EPG WAL from triggering
a delayed auto-checkpoint that stalls UI reads. A large stale-row delete after
that checkpoint can create a fresh WAL, partially reintroducing the stall that
the checkpoint was meant to avoid.

Suggested fix:

Move `deleteStalePrograms()` before `checkpointAndTruncateWal()`, or run a
second checkpoint after deleting stale rows. Prefer deleting stale rows before
the checkpoint so the user only pays one explicit flush while the progress UI
is still visible.

## Verification Performed

- Inspected current `git status`, recent HEAD, and working-tree diff stats.
- Reviewed relevant code paths in:
  - `lib/backend/xmltv_parser.dart`
  - `lib/backend/sql.dart`
  - `lib/backend/db_factory.dart`
  - `lib/backend/epg_service.dart`
  - `lib/backend/settings_io.dart`
  - `lib/settings_view.dart`
- Ran `git diff --check`; no whitespace errors were reported.

## Not Run

- `flutter analyze`
- Flutter tests
- Android release build

These were intentionally not run during the review because the requested phase
was read-only and those commands can touch tool/cache/build state.
