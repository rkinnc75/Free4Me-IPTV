# fix64.md — Content type filter doesn't refresh the channel list on tap

> **Version:** Free4Me-IPTV 1.18.3
> **Evidence:** `free4me_log_1779853346656.txt`
>
> Symptom: tapping the All tab to cycle the content type filter
> (All → Live → Movies → Series) changes the icon and label
> correctly but the channel list never updates — it always shows
> all three content types regardless of which state is selected.

---

## Root cause — two bugs in the filter tap handler

### Bug 1 — `updateViewMode` always fires, creating a new Home before settings are saved

**`lib/bottom_nav.dart` — All tab `onTap`:**

```dart
onTap: () {
  setState(() => _selectedIndex = ViewType.all.index);
  _onFilterTap();                     // cycles contentTypeFilter ✓
  widget.updateViewMode(ViewType.all); // ← always navigates ✗
},
```

`widget.updateViewMode(ViewType.all)` calls `Navigator.pushAndRemoveUntil`
which creates a brand new `Home` widget. That new Home initialises
its `filters.mediaTypes` from `SettingsService.cached?.getMediaTypes()`.
But `updateViewMode` runs **synchronously** and the new Home builds
before `onContentTypeChanged` has even been called — so
`SettingsService.cached.contentTypeFilter` is still the old value.
Result: every filter tap creates a new Home showing all types.

The fix: only navigate when the user is switching **views** (e.g.
tapping All while on Categories). When already on All, the filter
tap should update `filters.mediaTypes` in place and reload — no
navigation needed.

### Bug 2 — `updateSettings` blocks `setState` + `load`

**`lib/home.dart` — `onContentTypeChanged` callback:**

```dart
onContentTypeChanged: (filter) async {
  final s = SettingsService.cached;
  if (s == null) return;
  s.contentTypeFilter = filter;
  await SettingsService.updateSettings(s);  // ← waits for DB write
  if (!mounted) return;
  setState(() {
    widget.home.filters.mediaTypes = s.getMediaTypes();
  });
  await load(false);
},
```

`await SettingsService.updateSettings(s)` writes to SQLite before
updating the UI. The DB write takes ~5–20ms but the navigation race
(Bug 1) makes the whole callback moot anyway — by the time it runs,
a new Home is already being created with stale settings.

The fix: update in-memory state and trigger the reload immediately,
then persist to the DB afterwards.

---

## Fix 64.1 — `bottom_nav.dart` — only navigate when switching views

**Current code:**

```dart
onTap: () {
  setState(() => _selectedIndex = ViewType.all.index);
  _onFilterTap();
  widget.updateViewMode(ViewType.all);
},
```

**Replace with:**

```dart
onTap: () {
  setState(() => _selectedIndex = ViewType.all.index);
  // Cycle the content type filter.
  _onFilterTap();
  // Only navigate if we're not already on the All view.
  // When already on All, onContentTypeChanged handles the
  // filter update and reload in place — no navigation needed.
  // Navigating would create a new Home before the new
  // contentTypeFilter is persisted, causing the new Home to
  // read the stale filter value and show the wrong content.
  if (widget.startingView != ViewType.all) {
    widget.updateViewMode(ViewType.all);
  }
},
```

---

## Fix 64.2 — `home.dart` — update in-memory state before DB write

**Current code:**

```dart
onContentTypeChanged: (filter) async {
  final s = SettingsService.cached;
  if (s == null) return;
  s.contentTypeFilter = filter;
  await SettingsService.updateSettings(s);
  if (!mounted) return;
  setState(() {
    widget.home.filters.mediaTypes = s.getMediaTypes();
  });
  await load(false);
},
```

**Replace with:**

```dart
onContentTypeChanged: (filter) async {
  final s = SettingsService.cached;
  if (s == null) return;
  // Update in-memory state immediately so getMediaTypes()
  // returns the correct filter before the DB write completes.
  s.contentTypeFilter = filter;
  if (!mounted) return;
  setState(() {
    widget.home.filters.mediaTypes = s.getMediaTypes();
  });
  // Reload the channel list with the new filter immediately.
  await load(false);
  // Persist to DB after the UI has already updated.
  // User sees the new content without waiting for the write.
  if (mounted) await SettingsService.updateSettings(s);
},
```

---

## Filter correctness verification

With these two fixes, the complete filter flow is:

**User taps All tab (already on All view):**
1. `_onFilterTap()` → `nextContentFilter()` → e.g. `ContentTypeFilter.live`
2. `onContentTypeChanged(live)` fires
3. `s.contentTypeFilter = ContentTypeFilter.live` — in memory
4. `setState(() { filters.mediaTypes = [MediaType.livestream] })` — UI updates
5. `load(false)` → `Sql.search` with `params = [... 0 ...]` (media_type=0 only)
6. Channel grid shows only live channels
7. `SettingsService.updateSettings(s)` — persists to DB

**`getMediaTypes()` return values per state:**

| `contentTypeFilter` | `showLivestreams` | `showMovies` | `showSeries` | Returns |
|---|---|---|---|---|
| `all` | true | true | true | `[livestream, movie, serie]` |
| `all` | true | false | false | `[livestream]` |
| `live` | true | any | any | `[livestream]` |
| `live` | false | any | any | falls through → all enabled |
| `movies` | any | true | any | `[movie]` |
| `series` | any | any | true | `[serie]` |

The fallthrough on `live` when `showLivestreams=false` is the
`availableContentFilters()` guard — that state is never offered in
the cycle if its toggle is off, so the fallthrough is belt-and-braces
only.

**SQL generated for each state** (params count confirms single-type
filter uses the index):

| Filter | SQL clause | `params` |
|---|---|---|
| All (3 enabled) | `media_type IN (?,?,?)` | 3 type params |
| Live | `media_type IN (?)` | 1 type param |
| Movies | `media_type IN (?)` | 1 type param |
| Series | `media_type IN (?)` | 1 type param |

Single-type queries use `index_channel_media_type` directly —
269k rows narrows to 54k (live), 171k (movies), or 44k (series)
before the FTS scan runs.

---

## What the log should show after fix64

Each filter tap produces this sequence (example: All → Live):

```
Home: switching filter All→Live
Home.load[N]: view=All page=1 ... mediaTypes=livestream ...
Sql.search[N]: branch=no-query rows=36 sql=2ms params=4 query=""
Home.load[N]: rendered total=15ms
```

Key things to verify:
- `mediaTypes=livestream` (not `livestream,movie,serie`) on the
  load line immediately after the tap
- `params=4` (not `params=6`) — fewer params confirms single-type
  filter (1 type + 3 pagination vs 3 types + 3 pagination)
- `sql=` stays fast (2–20ms) on all filter states

---

## Test plan

### Cycling

1. Start on All with all three types enabled.
2. Tap the All/filter tab. **Expected:** icon changes to Live
   (`Icons.live_tv`, blue), channel list reloads showing only
   live channels. Log shows `mediaTypes=livestream`.
3. Tap again. **Expected:** Movies icon/label, channel list
   reloads. Log shows `mediaTypes=movie`.
4. Tap again. **Expected:** Series icon/label, channel list
   reloads. Log shows `mediaTypes=serie`.
5. Tap again. **Expected:** All icon/label, channel list reloads
   showing all types. Log shows `mediaTypes=livestream,movie,serie`.

### Already on All — no navigation

6. While on All view with Live filter active, tap the filter tab.
7. **Expected:** filter cycles (Live → Movies), grid reloads.
   Log should NOT show `Home: switching view → All` — that line
   only appears when navigating, which should not happen when
   already on All.

### Switching from Categories back to All

8. While on Categories, tap the All tab.
9. **Expected:** navigates to All view AND the current filter
   is preserved. If filter was Live before going to Categories,
   it should still be Live when returning to All.

### Persistence

10. Set filter to Live. Force-quit. Relaunch.
    **Expected:** Live filter still active.

### All state respects enabled toggles

11. Disable Movies in Settings (only Live and Series enabled).
12. Set filter to All. **Expected:** channel list shows
    `mediaTypes=livestream,serie` — Movies excluded because
    its toggle is off.

---

## Fix 64.3 — AGENTS.md — make tag push mandatory in the release sequence

**File:** `AGENTS.md`

The build runbook currently ends at step 4 with
`bash scripts/build_and_release.sh` — that's the Mac manual path.
The Cowork/Claude path (fix49.md step 10) requires a separate
`git push ... refs/tags/vX.Y.Z` to trigger the Release workflow.
Without the tag push, commits land on `main` but no APK is built
and no GitHub release is created.

Update the "Before every release" block to make the tag push
explicit and mandatory for all paths:

**Current code (lines 182–186):**

```markdown
**Before every release:**
1. `flutter analyze` → 0 issues
2. Bump `version: X.Y.Z+N` in `pubspec.yaml`
3. Add changelog entry to `lib/whats_new_modal.dart` (`_changelog` map, newest key first)
4. `bash scripts/build_and_release.sh`
```

**Replace with:**

```markdown
**Before every release:**
1. `flutter analyze` → 0 issues
2. Bump `version: X.Y.Z+N` in `pubspec.yaml`
3. Add changelog entry to `lib/whats_new_modal.dart` (`_changelog` map, newest key first)
4. Commit and push to `main`
5. **Push the `vX.Y.Z` tag** — this is what triggers the Release workflow:
   ```bash
   # Mac / manual path (script handles both steps):
   bash scripts/build_and_release.sh

   # Cowork / Claude path (must do both explicitly):
   git push origin main
   git push origin vX.Y.Z
   ```
   ⚠️ **Pushing commits without the tag does NOT trigger a build.**
   The Release workflow only fires on `push: tags: - 'v*'`.
   If CI never starts, the tag was not pushed.
```

Also update the "Release pipelines" table row (line 20):

**Current:**
```markdown
| Release pipelines | Automated: tag push → `.github/workflows/release.yml`. Manual: `bash scripts/build_and_release.sh` from a Mac. See `CLAUDE-WORKFLOW.md`. |
```

**Replace with:**
```markdown
| Release pipelines | **Tag push (`vX.Y.Z`) triggers CI** → `.github/workflows/release.yml`. Commits to `main` alone do NOT build. Manual: `bash scripts/build_and_release.sh` (handles tag automatically). Cowork/Claude: must push commit AND tag separately. See `CLAUDE-WORKFLOW.md` and `fix49.md`. |
```

---

## Notes for the implementer

- **Three changes across three files.** `bottom_nav.dart` (~3 lines),
  `home.dart` (~5 lines), `AGENTS.md` (~10 lines).
- **No logic changes to `getMediaTypes()`, `availableContentFilters()`,
  `nextContentFilter()`** — those are correct in 1.18.3.
- **No schema changes, no new dependencies.**
- **The `AppLog` line** `'Home: content filter → Live mediaTypes=livestream'`
  is optional but confirms fix64 is working without parsing
  `mediaTypes=` from the load line. Add to `onContentTypeChanged`
  if desired:
  ```dart
  AppLog.info('Home: content filter → ${filter.name}'
      ' mediaTypes=${s.getMediaTypes().map((m) => m.name).join(",")}');
  ```
- **AGENTS.md change is documentation only** — no code behaviour
  change. The CI workflow trigger is already correct (`v*` tags).
  This just makes the requirement visible to every agent session
  that reads AGENTS.md before starting work.
