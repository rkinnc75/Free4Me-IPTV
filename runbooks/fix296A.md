# fix296 — Select-all crash fix + on-device search diagnostic → v1.26.13+296

> ## ⚠️ BUILD MACHINE — THIS IS A CODE RUNBOOK. APPLY VERBATIM, ANALYZE, RELEASE.
> **You have exactly four edits to make: 296.1, 296.2, 296.3, 296.4 — all are code/text replacements in the repo.**
> **There are NO questions for you to answer. There is NO database for you to query. You cannot see the app's database — it lives on an Android device, not on this machine. Do not attempt to run any SELECT/SQL diagnostic; none is asked of you.**
> Everything below the line `=== END OF BUILD WORK ===` is NOT for you — it is a note for the human, to be read after you have shipped. Stop reading at that line.
>
> **FIRST: delete any stale file named `fix296-DIAGNOSE-search.md` if it exists in the repo, outputs, or runbooks/ — it is obsolete and contains SQL that does not apply here. It must not be applied.**
> ```bash
> find . -name 'fix296-DIAGNOSE*.md' -delete 2>/dev/null || true
> ```

## What this runbook does (summary — no action implied by this section)
1. **Crash fix** — `setAllGroupsEnabled` (the Select all / Unselect all buttons) builds `media_type IN ()` when no media-type filter is active (`generatePlaceholders(0)` returns `""`), which is a SQLite syntax error that breaks those buttons. Fixed by omitting the media clause when the list is empty.
2. **Diagnostic logging** — adds log lines (gated behind the existing debug-logging flag) so the *app itself*, running on the device, records why an in-memory search drops candidate rows. This is app code that writes to the debug log; it is not something you run.

## Verified by the author before delivery (do not re-verify; just apply)
- `flutter analyze --no-fatal-infos` on the full tree after all four edits → **2 issues found** (the 2 tolerated `settings_view.dart` INFOs at 2232 / 2827), no warnings, no errors.
- 296.1 executed against real SQLite, all three paths: old empty-list query errors (the bug); new empty-list path omits the clause and succeeds; new non-empty path stays correctly scoped by `media_type`.
- All four `Current code (verbatim)` blocks were located in live `main` (1.26.12+294) and confirmed to match byte-for-byte and to be unique.

---

## Fix 296.1 — `lib/backend/sql.dart` — fix the `media_type IN ()` crash
This block is unique (the only `setAllGroupsEnabled` UPDATE; identified by `...mt` in the params and the `if (sourceIds.isEmpty) return;` guard above it).

### Current code (verbatim)
```dart
    if (sourceIds.isEmpty) return;
    final db = await DbFactory.db;
    final mt = mediaTypes.map((x) => x.index).toList();
    await db.execute(
      'UPDATE groups SET enabled = ?'
      ' WHERE source_id IN (${generatePlaceholders(sourceIds.length)})'
      ' AND (media_type IS NULL OR media_type IN (${generatePlaceholders(mt.length)}))',
      [enabled ? 1 : 0, ...sourceIds, ...mt],
    );
```
### Replacement code (verbatim)
```dart
    if (sourceIds.isEmpty) return;
    final db = await DbFactory.db;
    final mt = mediaTypes.map((x) => x.index).toList();
    // fix296: when no media-type filter is active (mt empty), do NOT emit
    // "media_type IN ()" — that is a SQLite syntax error (peer Finding 1).
    // Empty filter means "all media types", so omit the media_type predicate.
    final mediaClause = mt.isEmpty
        ? ''
        : ' AND (media_type IS NULL OR media_type IN (${generatePlaceholders(mt.length)}))';
    await db.execute(
      'UPDATE groups SET enabled = ?'
      ' WHERE source_id IN (${generatePlaceholders(sourceIds.length)})'
      '$mediaClause',
      [enabled ? 1 : 0, ...sourceIds, ...mt],
    );
```

---

## Fix 296.2 — `lib/backend/sql.dart` — add on-device search diagnostic logging
This block is unique (the only `final rows = await db.getAll(sqlQuery, [...ids]);` immediately followed by the `// Preserve the cache's result order` comment — the other `getAll(sqlQuery` call in the file uses `params`, not `[...ids]`, and has no such comment).

### Current code (verbatim)
```dart
    final rows = await db.getAll(sqlQuery, [...ids]);

    // Preserve the cache's result order — WHERE IN does not guarantee ordering.
```
### Replacement code (verbatim)
```dart
    final rows = await db.getAll(sqlQuery, [...ids]);

    // fix296 DIAGNOSTIC (temporary): if the cache returned candidate ids but the
    // filter dropped some/all, dump per-id raw values so we can see WHICH clause
    // excluded them (group_id / is_divider / enabled lookup / hide_dividers).
    // Only fires for an actual query when rows < ids, to avoid log spam.
    if (AppLog.enabled && rawQuery.trim().isNotEmpty && rows.length < ids.length) {
      try {
        final diag = await db.getAll(
          'SELECT c.id, c.name, c.group_id, c.is_divider, c.url IS NOT NULL AS has_url,'
          ' (SELECT g.enabled FROM groups g WHERE g.id = c.group_id) AS enabled_lookup,'
          ' (SELECT g.name FROM groups g WHERE g.id = c.group_id) AS group_match,'
          ' (SELECT hide_dividers FROM sources s WHERE s.id = c.source_id) AS hide_div'
          ' FROM channels c WHERE c.id IN (${generatePlaceholders(ids.length)})',
          [...ids],
        );
        AppLog.info('fix296 DIAG: query="$rawQuery" cacheIds=${ids.length} '
            'passedFilter=${rows.length} droppedCandidates below:');
        for (final r in diag) {
          AppLog.info('fix296 DIAG: id=${r.columnAt(0)} '
              'name="${r.columnAt(1)}" group_id=${r.columnAt(2)} '
              'is_divider=${r.columnAt(3)} has_url=${r.columnAt(4)} '
              'enabled_lookup=${r.columnAt(5)} group_match="${r.columnAt(6)}" '
              'hide_dividers=${r.columnAt(7)}');
        }
      } catch (e) {
        AppLog.info('fix296 DIAG: diagnostic query failed: $e');
      }
    }

    // Preserve the cache's result order — WHERE IN does not guarantee ordering.
```

---

## Fix 296.3 — `lib/whats_new_modal.dart` — changelog entry
### Current code (verbatim)
```dart
const _changelog = <String, List<String>>{
```
### Replacement code (verbatim)
```dart
const _changelog = <String, List<String>>{
  '1.26.13': [
    'Fix: the Select all / Unselect all buttons on the Categories screen no longer fail when no media-type filter is active.',
    'Maintenance: added temporary diagnostics to investigate a search issue. No change to app behavior.',
  ],
```

---

## Fix 296.4 — `pubspec.yaml` — version bump
### Current code (verbatim)
```yaml
version: 1.26.12+294
```
### Replacement code (verbatim)
```yaml
version: 1.26.13+296
```

---

## Required verification before tagging
1. `flutter analyze --no-fatal-infos` → must be exactly **2 issues found** (the 2 tolerated `settings_view.dart` INFOs). Any warning/error → STOP and report.
2. `grep '^version:' pubspec.yaml` → must print `version: 1.26.13+296`.
3. `grep -c "  '1.26.13':" lib/whats_new_modal.dart` → must print `1`.
4. This change does NOT add or alter a migration and does NOT change any browse/search ORDER BY or WHERE. 296.1 only changes how one existing UPDATE is assembled (tested against real SQLite by the author). 296.2 is log-only, gated behind `AppLog.enabled`. No on-device launch step is required for this runbook.

## Release — EXECUTE EXACTLY (fix290 main-only procedure; never checkout a tag)
```bash
cd /path/to/Free4Me-IPTV
git checkout main
git fetch origin
git reset --hard origin/main          # start from real main, NEVER a tag
# apply 296.1–296.4 to the working tree here
flutter analyze --no-fatal-infos      # 2 tolerated INFOs, no errors/warnings
grep '^version:' pubspec.yaml          # version: 1.26.13+296
grep -c "  '1.26.13':" lib/whats_new_modal.dart   # 1
git config core.hooksPath              # should print .githooks (fix290 guard active)
git add -A
git commit -m "fix296: setAllGroupsEnabled empty-mediaTypes crash + on-device search diagnostics (1.26.13)"
git push origin main
./scripts/build_and_release.sh         # pushes main, THEN tags the pushed commit
```
Then verify the tag landed on main and version.json is current:
```bash
git fetch origin --tags
git merge-base --is-ancestor v1.26.13 origin/main && echo "v1.26.13 IS on main — GOOD" || echo "NOT on main — STOP"
git show origin/main:pubspec.yaml | grep '^version:'      # 1.26.13+296
git checkout v1.26.13
python3 scripts/update_version_json.py
git diff --quiet version.json && echo "version.json CURRENT — GUARD PASSES" || { echo "STALE"; git --no-pager diff version.json; }
git checkout main
```

**Once the release is published, your job is done. Do not act on anything below.**

=== END OF BUILD WORK ===

---
---

# ⛔ NOT FOR THE BUILD MACHINE — NOTE FOR RICH ONLY (read after 1.26.13 is installed)

*The build machine should have stopped at the line above. The following is the manual capture procedure and the interpretation key for the diagnostic that 1.26.13 now writes to the device log. None of this is a build step.*

## Capture the diagnostic (on the Android device, after installing 1.26.13)
1. Install the 1.26.13 build on the device.
2. Settings → make sure debug logging is **ON**.
3. Clear the log.
4. Go to **Live**, type **`espn`** in search (reproduce the bug — nothing shows).
5. Export / pull the debug log.
6. Send me the log. Look for lines beginning `fix296 DIAG:` — one summary line, then one line per candidate id.

## How to read it (this determines the real fix)
- **`enabled_lookup=0`** on the ESPN candidates → those channels are in a category you disabled. Search is behaving correctly; the "ESPN" you enabled is a *different* group. → fix is UX/clarity, not the filter.
- **`enabled_lookup=1`** on ESPN candidates but they were still dropped → a real filter bug (most likely the divider clause). The `is_divider` / `hide_dividers` columns on the same line will show which one. → fix the filter.
- **`enabled_lookup=null`** → orphaned `group_id`. `COALESCE` should have shown them, so if they're still dropped it means the cache ids don't match these channels → cache staleness; fix = invalidate the search cache on category toggle.
- **No `fix296 DIAG:` lines at all** → the cache returned 0 ids; the problem is upstream in `ChannelSearchCache` (name-matching / limit), not the filter.

## What we already know (from the 2026-06-05 Z2U dump analysis)
- ESPN-0 is **unambiguously a bug**: ~500+ real, enabled ESPN-named channels exist (ESPN PLUS ~500, ESPN PLAY EVENTS ~98). Ruled out "all disabled," "all dividers," "all `- NO EVENT STREAMING -` placeholders," and "cache corruption" (the 405548 cache count = 49036 live + ~356512 series episodes, legitimate).
- The only thing the dump *can't* tell us is device-runtime state: your actual `groups.enabled` checkbox values, the cache ids returned for "espn", and which clause drops them. That is exactly what these DIAG lines capture.

## After we have the log
The follow-up fix will (a) apply the real correction indicated by the branch above, and (b) **remove the 296.2 diagnostic block** (it's temporary).
