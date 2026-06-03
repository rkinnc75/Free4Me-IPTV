# fix78 — Favorite logging + picker WAL contention

**Version:** 1.19.0+93  
**Date:** 2026-05-27  
**Platform:** Mac/Cowork (odd)

---

## Background

Log `free4me_log_1779916612048.txt` captured ~18 minutes of multi-view session
activity. Two issues stood out:

1. **No favorite events in logs.** Long-press → favorite shows a snackbar in UI
   but nothing is written to `AppLog`, making it impossible to correlate user
   actions with subsequent search/playback activity.

2. **Picker search flood (WAL contention).** `Sql.search[invocation=0]` fired
   **8,814 times** (4,407 × 2 SQL calls per while-loop pass) over ~18 minutes.
   Response times escalated from ~50 ms to over 310 seconds as the SQLite WAL
   grew under sustained concurrent stream reads. The root causes were:

   - `channel_picker_screen.dart::_load()` never passed `invocation:` to
     `Sql.search`, so every call logged as `[0]` with no correlation.
   - There was no stale-load guard — if a rebuild triggered `_load('')` while a
     previous `_load('')` was still in-flight, both would complete and the later
     one would overwrite state with an identical result set.
   - The empty-query browse case (no text typed) has no cache, so every
     rebuild-triggered call hits SQLite even though the result is identical to
     the last call.

---

## fix78.1 — Favorite toggle logging (channel_tile.dart)

**File:** `lib/channel_tile.dart`  
**Method:** `favorite()`

Added two `AppLog.info` calls:

- **Before the DB write:** logs channel name and the transition
  (`wasFavorite=true → false`).
- **After the DB write succeeds and UI updates:** logs the confirmed new state.

This makes favorite events appear in the log at the same granularity as play
and prewarm events, enabling timeline correlation.

---

## fix78.2 — Picker stale-load guard + empty-query cache (channel_picker_screen.dart)

**File:** `lib/channel_picker_screen.dart`  
**Method:** `_load()`

### Stale-load guard

Added `int _loadInvocation = 0` field. `_load()` increments it at entry and
captures the value as `inv`. Three guards:

1. Before the while loop starts (caught in tight retry loops).
2. Inside the while loop after each `Sql.search` returns (caught while fetching
   large result sets).
3. After the final page returns, before calling `setState` (caught when a newer
   call has already completed).

`inv` is also forwarded to `Sql.search(…, invocation: inv)` so log lines are
now correlatable with the picker's own load ID.

### Empty-query result cache

Added `List<Channel>? _cachedEmptyQuery` field. When `query.isEmpty` and the
cache is warm, `_load('')` returns the cached list immediately — no SQL, no
`setState(() => _loading = true)` flash, no WAL pressure. The cache is
populated on the first successful empty-query load and is scoped to the
lifetime of the picker screen (disposed when the screen pops).

**Effect:** Rebuild-triggered `_load('')` calls — whatever their source — are
now O(1) memory lookups instead of O(SQL × pages). The escalating WAL
contention is eliminated.

---

## Files changed

| File | Change |
|------|--------|
| `lib/channel_tile.dart` | `favorite()` — added two `AppLog.info` calls |
| `lib/channel_picker_screen.dart` | `_load()` — stale-load guard + empty-query cache |
| `pubspec.yaml` | version `1.18.9+92` → `1.19.0+93` |
| `CHANGELOG.md` | Added fix78 entry |
| `assets/version.json` | Regenerated via `scripts/update_version_json.py` |
