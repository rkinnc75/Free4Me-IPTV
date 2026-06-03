# Fix 53 Search Flow Review

This note is for secondary review only. It proposes changes to address search
slowness, but no source files should be edited until the approach is approved.

## Scope

Reviewed the search path from user input through rendering:

- `lib/home.dart`
  - `DpadTextField.onChanged`
  - `_debounce`
  - `load()`
  - pagination via `_scrollListener()`
  - result rendering in `SliverGrid`
- `lib/backend/sql.dart`
  - `Sql.search()`
  - `Sql.searchGroup()`
  - `rowToChannel()`
- `lib/backend/db_factory.dart`
  - `channels_fts`
  - FTS triggers
  - channel indexes
- `lib/models/filters.dart`

## Current Flow

1. User types in `Home` search box.
2. `onChanged` cancels the prior timer and starts a new 200 ms debounce.
3. When the timer fires, it mutates `widget.home.filters.query`.
4. `load(false)` mutates `widget.home.filters.page = 1`.
5. `load()` passes the same mutable `Filters` object into `Sql.search()`.
6. `Sql.search()` awaits `DbFactory.db`, then reads fields from the mutable
   `Filters` object to build SQL.
7. If query has any 3+ character term, search uses `channels_fts`.
8. If every query term is 1-2 characters, search falls back to:

   ```sql
   name LIKE '%x%'
   ```

   or multiple wildcard clauses in keyword mode.
9. Results are mapped into `Channel` objects and rendered in the grid.
10. Late non-pagination results are dropped, but late pagination results are
    not dropped.

## Likely Root Cause

The expensive path is the all-short-term branch in `Sql.search()`:

```dart
// All terms are too short for trigram; fall back to LIKE.
WHERE name LIKE '%x%'
```

Because the pattern has a leading wildcard, SQLite cannot use the normal
`index_channel_name` b-tree index. On a large IPTV channel table this becomes a
full scan. The UI triggers that scan after only 200 ms for the first typed
character, then often triggers another full scan for the second character.

Even though newer search results can replace older ones visually, the old DB
queries still run to completion and can delay the first useful 3+ character FTS
query. That matches the reported "search feels slow while typing" behavior.

## Secondary Issues

### Mutable filters can change mid-query

`load()` passes `widget.home.filters` directly into `Sql.search()`. Inside
`Sql.search()`, the first operation is:

```dart
var db = await DbFactory.db;
```

Only after that await does it read `filters.page`, `filters.query`,
`filters.mediaTypes`, etc. If the user types or pagination fires while that
await is pending, the query can execute with a different filter state than the
one that scheduled the load.

This can produce stale, duplicated, or surprising results, and makes timing
logs harder to trust.

### Superseded pagination results are not dropped

Current guard:

```dart
if (inv != _searchInvocation && !more) return;
```

This drops stale normal searches but intentionally allows stale `load(true)`
pagination results to append. If the user scrolls, then types a new query while
the pagination query is still in flight, the old page can append into the new
search results.

### Short-query category search also uses leading wildcard LIKE

`Sql.searchGroup()` uses `name LIKE '%query%'` as well. The groups table is
usually much smaller than channels, so this is lower risk, but the same pattern
exists.

## Proposed Fix

### 1. Snapshot filters before async work

Add a copy helper to `Filters`:

```dart
Filters copy() => Filters(
  query: query,
  sourceIds: sourceIds == null ? null : List<int>.from(sourceIds!),
  mediaTypes: mediaTypes == null ? null : List<MediaType>.from(mediaTypes!),
  viewType: viewType,
  page: page,
  seriesId: seriesId,
  groupId: groupId,
  useKeywords: useKeywords,
);
```

In `Home.load()`, after mutating `page`, immediately snapshot:

```dart
final filters = widget.home.filters.copy();
```

Use `filters` for logging and `Sql.search(filters, invocation: inv)`.

Expected benefit:

- Query logs correspond to the query that actually ran.
- Pagination cannot accidentally read a page/query value changed by later UI
  events before `DbFactory.db` resolves.

### 2. Drop all superseded results, including pagination

Change:

```dart
if (inv != _searchInvocation && !more) return;
```

to:

```dart
if (inv != _searchInvocation) return;
```

Expected benefit:

- Old pagination pages cannot append into a newer search result set.
- The rendered grid always belongs to the most recent user intent.

### 3. Stop running full-table scans for 1-2 character searches

Add a shared minimum search term constant in `Sql`, for example:

```dart
static const int minFtsSearchTermLength = 3;
```

Then, in `Sql.search()`:

- Empty query still loads the normal unfiltered page.
- Queries with at least one 3+ character term use FTS as today.
- Queries where every term is 1-2 characters return `[]` immediately instead
  of running `LIKE '%x%'`.

Suggested behavior:

```dart
if (rawQuery.isNotEmpty && longTerms.isEmpty) {
  log branch=short-skip;
  return [];
}
```

Apply the same guard in `searchGroup()`.

Expected benefit:

- The first and second typed characters no longer enqueue expensive scans.
- The first useful 3+ character FTS query gets to run sooner.
- Perceived latency should improve most on large 50k-100k channel lists.

Tradeoff:

- 1-2 character searches such as `FX` will not return results until a longer
  term is entered.
- That is preferable to freezing or delaying the UI, but it should be called
  out in release notes or refined later with a dedicated short-token index.

## Optional Follow-up: Short Token Index

If 1-2 character searches must be supported, avoid wildcard scans by adding a
small auxiliary token table, e.g.:

```sql
channel_search_tokens(channel_id INTEGER, token TEXT)
```

Populate it with 1-2 character prefixes or exact short tokens from each channel
name during import. Then short searches can join against `token = ?` instead of
`name LIKE '%x%'`.

This is a larger schema/import change and should be considered a follow-up, not
the immediate fix.

## Suggested Verification

1. Add logging for the new short-query branch:

   ```text
   Sql.search[n]: branch=short-skip rows=0 query="x"
   ```

2. Run `flutter analyze --no-fatal-infos`.
3. Test on a large source:
   - type `n`
   - type `ne`
   - type `new`
   - type `news`
4. Confirm:
   - 1-2 character input returns immediately.
   - 3+ character input uses `branch=fts`.
   - old pagination results do not append after a newer search.
   - clearing the search box still loads the normal channel list.

## Expected Files To Change If Approved

- `lib/models/filters.dart`
- `lib/home.dart`
- `lib/backend/sql.dart`

No database migration should be needed for the immediate fix.
