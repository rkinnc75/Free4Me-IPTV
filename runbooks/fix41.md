# fix32.md — `Utils.refreshAllSources` ignores the source `enabled` flag

> Symptom: after importing a backup (or on app start with
> "Refresh on start" enabled, or by tapping "Refresh all sources" in
> Settings), **disabled sources still get refreshed**. The user
> reports this on import:
>
> > "When import is selected, it says EPG is being processed in the
> > background. It should only import for enabled sources. Emjay was
> > disabled when backup was made."
>
> Confirmed by inspection: `Utils.refreshAllSources` iterates every
> source returned by `Sql.getSources()` with no `enabled` filter.
> Compare `EpgService.refreshAllSources` which correctly filters by
> `s.enabled` (lib/backend/epg_service.dart:78–79).
>
> The user's earlier `free4me-backup__2_.json` confirms Emjay was
> disabled at export time (`"enabled": false`). On import, the
> source is correctly recreated with `enabled: false` — but
> `Utils.refreshAllSources` then walks straight past the flag and
> refreshes it anyway.
>
> Same bug affects two other call sites: Home's refresh-on-start and
> the Settings "Refresh all sources" button. All three are fixed by
> one change inside `Utils.refreshAllSources`.

---

## Evidence

### 1. The function has no enabled filter

`lib/backend/utils.dart:55-62`:

```dart
static Future<void> refreshAllSources() async {
  final sources = await Sql.getSources();
  const maxConcurrent = 2;
  for (var i = 0; i < sources.length; i += maxConcurrent) {
    final chunk = sources.skip(i).take(maxConcurrent);
    await Future.wait(chunk.map(refreshSource));
  }
}
```

`Sql.getSources()` returns every row in the `sources` table
regardless of `enabled`. The loop maps every one through
`refreshSource`, which calls `processSource(source, true)` —
fetching the M3U / Xtream API and rewriting the channels table for
that source.

### 2. The EPG path got this right

`lib/backend/epg_service.dart:77-80`:

```dart
static Future<void> refreshAllSources({bool background = false}) async {
  final eligible = (await Sql.getSources())
      .where((s) => s.enabled && resolveEpgUrl(s) != null)
      .toList(growable: false);
  // ...
}
```

This is the model. The fix is to make `Utils.refreshAllSources`
behave the same way for its slightly different criterion (no EPG
URL requirement, just `enabled`).

### 3. Manual EPG refresh and re-match also got it right

`lib/settings_view.dart:496` (inside `_runEpgRefresh`):

```dart
for (final source in sources) {
  if (!source.enabled) continue;
  // ...
}
```

Same at line 622 (`_runEpgRematch`). So three of the four
"refresh everything" code paths skip disabled sources; the M3U
refresh is the outlier.

### 4. Three call sites are affected — one fix covers all of them

`grep -rn "refreshAllSources" lib/`:

```
lib/setup.dart:328        Utils.refreshAllSources();   // fire-and-forget after import
lib/settings_view.dart:2000 Utils.refreshAllSources()  // "Refresh all sources" button
lib/home.dart:111         await Utils.refreshAllSources();  // refresh-on-start
```

(The two callers in `epg_service.dart` call its own
`EpgService.refreshAllSources` — different function, already
correct.)

The right place for the fix is **inside `Utils.refreshAllSources`**
so the rule is consistent across all three callers. The single-
source `Utils.refreshSource(source)` keeps doing what it's told —
if the user explicitly refreshes a disabled source via Settings →
Sources, we should honour that explicit action.

---

## Fix 32.1 — Filter disabled sources inside `Utils.refreshAllSources`

**File:** `lib/backend/utils.dart`

**Current code (lines 55–62):**

```dart
static Future<void> refreshAllSources() async {
  final sources = await Sql.getSources();
  const maxConcurrent = 2;
  for (var i = 0; i < sources.length; i += maxConcurrent) {
    final chunk = sources.skip(i).take(maxConcurrent);
    await Future.wait(chunk.map(refreshSource));
  }
}
```

**Replace with:**

```dart
/// Refresh every enabled source's M3U / Xtream channel list.
///
/// Disabled sources are skipped — same rule as
/// `EpgService.refreshAllSources` and the per-source EPG actions
/// in Settings. The single-source [refreshSource] is unaffected;
/// callers who explicitly target a disabled source (e.g. the
/// Settings → Sources per-row refresh action) still bypass the
/// filter, which is correct: that action is an explicit user
/// override.
static Future<void> refreshAllSources() async {
  final enabled = (await Sql.getSources())
      .where((s) => s.enabled)
      .toList(growable: false);
  AppLog.info(
    'Utils.refreshAllSources: ${enabled.length} enabled source(s)'
    ' (${enabled.map((s) => s.name).join(", ")})',
  );
  const maxConcurrent = 2;
  for (var i = 0; i < enabled.length; i += maxConcurrent) {
    final end = i + maxConcurrent > enabled.length
        ? enabled.length
        : i + maxConcurrent;
    final chunk = enabled.sublist(i, end);
    await Future.wait(chunk.map(refreshSource));
  }
}
```

Two changes wrapped in one:

1. **`.where((s) => s.enabled)`** — the actual fix.
2. **`AppLog.info` line** — diagnostic to make the next "did it
   skip my source?" question answerable from the log.

The chunked iteration is also rewritten using `sublist` instead of
`skip`/`take` to match the style of `EpgService.refreshAllSources`
— purely cosmetic, but it makes the two functions read identically
side-by-side.

Add the import at the top of `utils.dart` if not already present:

```dart
import 'package:open_tv/backend/app_logger.dart';
```

---

## Fix 32.2 — Make the import snackbar honest about what it refreshes

**File:** `lib/backend/settings_io.dart`

The snackbar text "Backup imported. Refreshing channels in the
background…" is technically correct but misleading when the user
has disabled sources in the backup. Make it explicit about scope so
the user doesn't wonder whether Emjay is being refreshed.

**Current code (lines 232–245):**

```dart
if (context.mounted) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text(
        'Backup imported. Refreshing channels in the background…',
      ),
      duration: Duration(seconds: 4),
    ),
  );
}
```

**Replace with:**

```dart
if (context.mounted) {
  // Count enabled vs total sources so the snackbar can be honest
  // about scope. Users with disabled sources in their backup
  // (e.g. a paused provider) should see that the disabled ones
  // aren't being refreshed.
  final allSources = await Sql.getSources();
  final enabledCount = allSources.where((s) => s.enabled).length;
  final scopeText = enabledCount == allSources.length
      ? '$enabledCount source${enabledCount == 1 ? "" : "s"}'
      : '$enabledCount of ${allSources.length} sources (enabled only)';
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        'Backup imported. Refreshing $scopeText in the background…',
      ),
      duration: const Duration(seconds: 4),
    ),
  );
}
```

So with the user's exact scenario (Aniel3000 enabled, Emjay
disabled), the snackbar becomes:

> Backup imported. Refreshing 1 of 2 sources (enabled only) in the
> background…

If both were enabled it'd say:

> Backup imported. Refreshing 2 sources in the background…

Same message style for the all-enabled case as before (just with a
count), and explicit about scope in the mixed case.

> **Note for the implementer:** the function is `static Future<bool>
> importFromFile(BuildContext context) async`. The new
> `Sql.getSources()` call is `await`ed — no change in async shape.

---

## What about Home's refresh-on-start dialog?

`lib/home.dart:106-117`:

```dart
await Error.tryAsyncNoLoading(
  () async {
    if (mounted) {
      setState(() => blockSettings = true);
    }
    await Utils.refreshAllSources();
    if (mounted) await load(false);
  },
  context,
  true,
  "Refreshed all sources",
);
```

The success message is `"Refreshed all sources"`. Same misleading
wording, but it's a hard-coded string passed to `Error.tryAsyncNoLoading`'s
`successMessage` parameter — and at this stack level we don't have
the enabled count to splice in conveniently. Leaving it as-is
because:

- The misleading aspect ("all" vs "all enabled") is much milder
  than the import case — the user isn't actively doing an import,
  they're just opening the app, so they're not currently thinking
  about backup scope.
- Re-plumbing this would require either an out-param from
  `refreshAllSources` (returning the count) or a separate
  pre-query — neither feels worth it for the start-of-day toast.

The new `AppLog.info` line in fix32.1 ensures the actual scope is
recoverable from the log if anyone asks.

If the implementer wants symmetry and is willing to spend the lines,
the cleanest version is to change `refreshAllSources` to return the
count of sources actually refreshed, then have all three callers
splice it into their message. Out of scope here unless requested.

---

## Test plan

1. Apply fix32 and rebuild.
2. **Import test (the user's scenario):**
   - Make sure you have at least one disabled source. If you've
     since re-enabled Emjay, disable it again in Settings →
     Sources.
   - Export a fresh backup.
   - Uninstall + reinstall.
   - On the welcome screen, tap "Import settings backup" → pick
     the JSON → confirm.
   - **Expected:**
     - Snackbar reads "Backup imported. Refreshing 1 of 2 sources
       (enabled only) in the background…" (counts will reflect your
       actual sources).
     - Log shows `Utils.refreshAllSources: 1 enabled source(s)
       (Aniel3000 )`.
     - In Home, Aniel3000's channels populate.
     - In Home, Emjay's channels do NOT populate (or stay empty if
       previously empty).
     - Settings → Sources confirms Emjay is still showing as
       disabled with no channel count change.
3. **Refresh-all button regression:**
   - Settings → Sources → tap "Refresh all sources" button.
   - Log shows `Utils.refreshAllSources: 1 enabled source(s)`.
   - Snackbar at the end says "Refreshed all sources" (existing
     text, intentionally unchanged).
   - Enabled sources update; disabled don't.
4. **Refresh-on-start regression:**
   - In Settings, enable "Refresh on start" if not already on.
   - Force-quit the app, relaunch.
   - Log shows `Utils.refreshAllSources: 1 enabled source(s)`.
   - Only the enabled source gets its channels refreshed.
5. **Per-source explicit refresh (negative regression):**
   - Settings → Sources → find a disabled source's row → tap its
     per-row refresh action (`Utils.refreshSource(source)` is
     called directly, not via `refreshAllSources`).
   - Source IS refreshed despite being disabled — this is correct
     because the user explicitly chose it. The fix preserves this
     behaviour because we only filter inside `refreshAllSources`,
     not `refreshSource`.
6. **All-enabled snackbar:**
   - Re-enable Emjay.
   - Run another import (or just paste this is harder to test —
     can skip if 2-source enabled scenario is hard to reset).
   - **Expected snackbar:** "Backup imported. Refreshing 2 sources
     in the background…" (no "of N" disambiguation when everything
     is enabled).

---

## Notes for the implementer

- **One real logic line.** The `.where((s) => s.enabled)` filter
  is the fix; everything else is diagnostic logging and snackbar
  copy.
- **No SQL schema changes**, no new dependencies, no migration.
- **The single-source `Utils.refreshSource(source)` is intentionally
  unchanged.** Callers who explicitly pass a disabled source are
  expressing intent. Only the "do all the sources" entry point
  needs the filter.
- **Note about a side effect on imported `preserve` data.** Recall
  fix28: imported channel-attribute preserves (favorites,
  last-watched) only get applied when `Utils.refreshSource` runs
  for that source. If a source is disabled at import time, its
  preserves stay staged in `_pendingPreserves` indefinitely until
  the user enables the source and triggers a refresh. This is the
  right behaviour — a disabled source has no channels populated
  anyway, so there's nothing to apply the favorite flags to. When
  the user enables the source and refreshes, the preserves land
  naturally via the existing refresh hook. No additional code
  needed.
- **Total file diff: ~25 lines** across two files (utils.dart and
  settings_io.dart).
