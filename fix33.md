# fix33.md — Block backup import until source refresh completes (with progress)

> Symptom: after picking "Import settings backup" on the welcome
> screen, the app immediately navigates to Home while the channel
> refresh is still running in the background. The user lands on an
> empty-looking Home with no channels visible and no indication that
> work is in progress. Eventually channels appear, but until they do
> the experience looks broken.
>
> User request: "How do we know when the background process
> finishes? Maybe we should just show the same status as manual so
> the user waits until it's done and doesn't get a partially
> enabled experience."
>
> Fix: change the import flow from "fire-and-forget + immediate
> navigation" to "await the refresh with a progress dialog, then
> navigate." The progress dialog shows per-source status as the
> refresh proceeds. Mirrors the pattern already used by the manual
> "Refresh EPG now" flow.

---

## Why this is the right shape

Today's flow (from `setup.dart:320-336`):

```dart
Future<void> _importBackup() async {
  final imported = await SettingsIo.importFromFile(context);
  if (!mounted || !imported) return;

  // ignore: unawaited_futures
  Utils.refreshAllSources();      // ← fire and forget

  final sources = await Sql.getSources();
  if (!mounted) return;
  if (sources.isNotEmpty) {
    navigateToHome();             // ← navigate immediately
  }
}
```

Two problems:

1. The user lands on Home with an empty channel grid. No spinner,
   no progress bar, no "still loading" message. They reasonably
   conclude something is broken.
2. If the user starts interacting with Home (browsing the empty
   list, opening settings, picking a multi-view layout) while the
   refresh runs, they can hit weird half-states — e.g. a multi-view
   cell trying to load a channel by ID that doesn't exist yet
   because the refresh hasn't reached that source.

The user's suggestion is the right one: **block on the refresh**
the same way the manual "Refresh EPG now" does, so when the user
finally reaches Home, the data is actually there.

A minimal "just await the refresh" change would leave the user
staring at a frozen welcome screen for 30 seconds to several
minutes. We need a progress indicator. The codebase already has
the pattern for one in `_runEpgRefresh` (settings_view.dart:434+):
an `AlertDialog` with `barrierDismissible: false`, a
`StatefulBuilder` for live updates, and a summary at the end.

Reuse that pattern by extracting a helper that any caller can
invoke, and route the Setup import through it.

---

## Apply order

The fix has three parts. Apply in order:

1. **33.1** — extend `Utils.refreshSource` and `refreshAllSources`
   to accept an `onProgress` callback that surfaces per-source
   status. Backwards-compatible: existing callers that don't pass
   the callback get current behaviour.
2. **33.2** — add a new helper `_runSourcesRefreshWithDialog`
   shared between Setup and any other caller that wants the
   blocking dialog. Lives in a new file
   `lib/widgets/sources_refresh_dialog.dart`.
3. **33.3** — wire Setup's `_importBackup` to use the new helper
   and navigate to Home only after it completes. Remove the
   misleading snackbar from `SettingsIo.importFromFile` since the
   helper now provides better feedback.

Optional follow-up (not in this fix):
- Wire the manual "Refresh all sources" button in
  `settings_view.dart:1999` to use the same dialog. The current
  plain-spinner experience there has the same drawback, but the
  user didn't ask for that yet. Note logged in the runbook so a
  future fix can pick it up.

---

# Fix 33.1 — Plumb per-source progress through `Utils`

**File:** `lib/backend/utils.dart`

`processSource` already accepts an `onProgress(String)` callback
that source-fetchers use to report status (e.g. "downloaded 12000
channels"). `refreshSource` doesn't forward it; neither does
`refreshAllSources`. Forward both.

### Replace `refreshSource`

**Current code (lines 27–35):**

```dart
static Future<void> refreshSource(Source source) async {
  refreshedSeries.clear();
  await processSource(source, true);
  // After channels are populated, apply any favorites and last-
  // watched timestamps that an imported backup staged for this
  // source (see fix28.2 / SettingsIo.applyPendingPreserves). No-op
  // if no preserve list is pending.
  await SettingsIo.applyPendingPreserves(source.name);
}
```

**Replace with:**

```dart
static Future<void> refreshSource(
  Source source, {
  void Function(String)? onProgress,
}) async {
  refreshedSeries.clear();
  await processSource(source, true, onProgress);
  // After channels are populated, apply any favorites and last-
  // watched timestamps that an imported backup staged for this
  // source (see fix28.2 / SettingsIo.applyPendingPreserves). No-op
  // if no preserve list is pending.
  await SettingsIo.applyPendingPreserves(source.name);
}
```

### Replace `refreshAllSources` (also pulls in fix32 — enabled filter)

**Current code (lines 55–62), after fix32 if you apply both, OR
the original if you don't:**

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
/// Refresh every enabled source. Disabled sources are skipped — same
/// rule as `EpgService.refreshAllSources` and the manual EPG actions.
///
/// [onSourceStart] fires once per source as it begins, with the
/// source's index (1-based) and total count. Use it to drive a
/// progress UI. Omit for fire-and-forget.
///
/// [onSourceStatus] forwards per-source status strings from the
/// underlying M3U / Xtream fetchers (e.g. "downloaded 12000
/// channels"). Same callback applies to whichever source is the
/// current one.
static Future<void> refreshAllSources({
  void Function(int index, int total, Source source)? onSourceStart,
  void Function(Source source, String status)? onSourceStatus,
}) async {
  final enabled = (await Sql.getSources())
      .where((s) => s.enabled)
      .toList(growable: false);
  AppLog.info(
    'Utils.refreshAllSources: ${enabled.length} enabled source(s)'
    ' (${enabled.map((s) => s.name).join(", ")})',
  );

  // Process sequentially when we have a progress UI so the dialog's
  // "Refreshing X of Y" stays accurate. Without a UI, fall back to
  // the original 2-at-a-time concurrency for speed.
  if (onSourceStart != null) {
    for (var i = 0; i < enabled.length; i++) {
      final s = enabled[i];
      onSourceStart(i + 1, enabled.length, s);
      await refreshSource(
        s,
        onProgress: onSourceStatus == null
            ? null
            : (msg) => onSourceStatus(s, msg),
      );
    }
  } else {
    const maxConcurrent = 2;
    for (var i = 0; i < enabled.length; i += maxConcurrent) {
      final end = i + maxConcurrent > enabled.length
          ? enabled.length
          : i + maxConcurrent;
      final chunk = enabled.sublist(i, end);
      await Future.wait(chunk.map(refreshSource));
    }
  }
}
```

Add this import at the top of `utils.dart` if not already present
(fix32 also added it):

```dart
import 'package:open_tv/backend/app_logger.dart';
```

> **Concurrency note.** I dropped the 2-at-a-time concurrency for
> the UI-driven path on purpose. Two concurrent refreshes would
> need a more complex progress UI ("Aniel3000 50%, Emjay 30%") to
> stay honest. Sequential lets us keep one "Refreshing X of Y"
> line. For users with many sources (5+) this slows down the
> import slightly, but a clean progress bar beats a faster
> ambiguous one. Existing callers that don't supply
> `onSourceStart` keep their 2-at-a-time behaviour unchanged.

---

# Fix 33.2 — Add a reusable progress-dialog helper

**File:** `lib/widgets/sources_refresh_dialog.dart` *(new file)*

```dart
import 'package:flutter/material.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/models/source.dart';

/// Show a modal progress dialog while [Utils.refreshAllSources] runs.
/// Returns when the refresh completes (or fails); the caller decides
/// what to do next (navigate, snackbar, etc.).
///
/// The dialog is non-dismissible — the user has to wait. This is the
/// whole point: callers use this helper when they specifically want
/// to block on the refresh so subsequent UI can rely on data being
/// present. Errors are caught here and surfaced via the dialog title
/// changing to "Refresh failed" with a final OK button.
///
/// Used by the post-import flow in setup.dart so the user doesn't
/// land on an empty Home screen while sources are still loading.
Future<void> showSourcesRefreshDialog(BuildContext context) async {
  String title = 'Loading channels…';
  String status = 'Preparing…';
  int sourceIndex = 0;
  int sourceTotal = 0;
  bool done = false;
  Object? error;

  void Function(void Function())? setStateFn;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => StatefulBuilder(
      builder: (sCtx, setSt) {
        setStateFn = setSt;
        return PopScope(
          canPop: done,
          child: AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!done)
                  sourceTotal > 0
                      ? LinearProgressIndicator(
                          value: sourceIndex / sourceTotal,
                        )
                      : const LinearProgressIndicator(),
                const SizedBox(height: 12),
                if (sourceTotal > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      'Source $sourceIndex of $sourceTotal',
                      style: Theme.of(sCtx).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                Text(
                  status,
                  style: Theme.of(sCtx).textTheme.bodySmall,
                ),
              ],
            ),
            actions: done
                ? [
                    FilledButton(
                      onPressed: () => Navigator.pop(sCtx),
                      child: const Text('OK'),
                    ),
                  ]
                : null,
          ),
        );
      },
    ),
  );

  // Drive the refresh, updating dialog state as we go.
  try {
    await Utils.refreshAllSources(
      onSourceStart: (i, total, Source source) {
        if (setStateFn != null) {
          setStateFn!(() {
            sourceIndex = i;
            sourceTotal = total;
            status = 'Loading "${source.name}"…';
          });
        }
      },
      onSourceStatus: (Source source, String msg) {
        if (setStateFn != null) {
          setStateFn!(() {
            // Trim very long status strings so the dialog doesn't
            // jump in size on every update.
            status = '${source.name}: '
                '${msg.length > 60 ? "${msg.substring(0, 60)}…" : msg}';
          });
        }
      },
    );
  } catch (e) {
    error = e;
  }

  if (setStateFn != null) {
    setStateFn!(() {
      done = true;
      if (error != null) {
        title = 'Refresh failed';
        status = error.toString();
      } else if (sourceTotal == 0) {
        // No enabled sources to refresh.
        title = 'Nothing to refresh';
        status = 'No enabled sources were found.';
      } else {
        title = 'Loaded';
        status = sourceTotal == 1
            ? '1 source ready.'
            : '$sourceTotal sources ready.';
      }
    });
  }

  // Wait for the user to tap OK before returning. We do this by
  // not awaiting showDialog above (so we control it), and instead
  // polling for the dialog to close. Simpler: wait until the user
  // taps OK by returning a Completer-driven Future.
  //
  // Actually — `showDialog` already returns a Future that
  // completes when the dialog is dismissed. The pattern above
  // doesn't await it because we need to set up `setStateFn` first.
  // Let the caller use `await` on us — we resolve once Navigator
  // pops the dialog (which happens when user taps OK).
  //
  // Implementation: change the structure so we await the showDialog
  // future at the end. Move the work-doing into an unawaited task
  // that drives the dialog state, and gate the user-visible OK
  // button on `done=true`.
}
```

> **Note on the implementation:** the comment block at the end
> highlights a subtle structural concern. The code above sets up
> `setStateFn` synchronously inside the dialog builder (which runs
> when the dialog frame is first built), then drives the refresh
> in the outer function. The caller's `await` on
> `showSourcesRefreshDialog` resolves when the outer function
> returns — which is when the refresh + final state update
> completes, NOT when the user taps OK.
>
> If you want "wait for user to tap OK" semantics (so the calling
> code can guarantee the user has seen the success message before
> proceeding), refactor as follows:

**Cleaner implementation (preferred):**

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/models/source.dart';

Future<void> showSourcesRefreshDialog(BuildContext context) async {
  String title = 'Loading channels…';
  String status = 'Preparing…';
  int sourceIndex = 0;
  int sourceTotal = 0;
  bool done = false;
  Object? error;

  // Captured inside the builder; used by the outer refresh loop.
  late void Function(void Function()) setSt;

  // Kick off the refresh as soon as the dialog is mounted.
  final dialogClosed = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => StatefulBuilder(
      builder: (sCtx, s) {
        setSt = s;
        return PopScope(
          canPop: done,
          child: AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!done)
                  sourceTotal > 0
                      ? LinearProgressIndicator(
                          value: sourceIndex / sourceTotal,
                        )
                      : const LinearProgressIndicator(),
                const SizedBox(height: 12),
                if (sourceTotal > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      'Source $sourceIndex of $sourceTotal',
                      style: Theme.of(sCtx).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ),
                Text(
                  status,
                  style: Theme.of(sCtx).textTheme.bodySmall,
                ),
              ],
            ),
            actions: done
                ? [
                    FilledButton(
                      onPressed: () => Navigator.pop(sCtx),
                      child: const Text('OK'),
                    ),
                  ]
                : null,
          ),
        );
      },
    ),
  );

  // Schedule the refresh after the dialog has had a chance to build
  // (so setSt is captured).
  unawaited(() async {
    try {
      await Utils.refreshAllSources(
        onSourceStart: (i, total, Source source) {
          setSt(() {
            sourceIndex = i;
            sourceTotal = total;
            status = 'Loading "${source.name}"…';
          });
        },
        onSourceStatus: (Source source, String msg) {
          setSt(() {
            status = '${source.name}: '
                '${msg.length > 60 ? "${msg.substring(0, 60)}…" : msg}';
          });
        },
      );
    } catch (e) {
      error = e;
    }
    setSt(() {
      done = true;
      if (error != null) {
        title = 'Refresh failed';
        status = error.toString();
      } else if (sourceTotal == 0) {
        title = 'Nothing to refresh';
        status = 'No enabled sources were found.';
      } else {
        title = 'Loaded';
        status = sourceTotal == 1
            ? '1 source ready.'
            : '$sourceTotal sources ready.';
      }
    });
  }());

  // Resolves when the user taps OK (or back-button after we set
  // canPop=true via done=true).
  await dialogClosed;
}
```

The key difference: `dialogClosed` is the Future returned by
`showDialog`, which resolves when the dialog is popped (user taps
OK). We `await` it at the bottom of the function, so the caller's
`await showSourcesRefreshDialog(context)` resolves only after the
user has dismissed the dialog.

The refresh loop runs concurrently (inside `unawaited(() async {…}())`)
and pushes state updates into the dialog. When it completes
(success or error), it flips `done = true`, which makes the OK
button appear and the back-gesture work.

---

# Fix 33.3 — Wire Setup to use the dialog

## File: `lib/setup.dart`

### Add the import

After the existing imports (around line 8):

```dart
import 'package:open_tv/widgets/sources_refresh_dialog.dart';
```

### Replace `_importBackup`

**Current code (lines 320–336):**

```dart
Future<void> _importBackup() async {
  final imported = await SettingsIo.importFromFile(context);
  if (!mounted || !imported) return;

  // Kick off the background refresh so channels populate and any
  // staged channel-attribute restores (favorites / last-watched)
  // get applied via Utils.refreshSource → SettingsIo.applyPendingPreserves.
  // ignore: unawaited_futures
  Utils.refreshAllSources();

  // Only navigate forward if the import actually populated a source.
  final sources = await Sql.getSources();
  if (!mounted) return;
  if (sources.isNotEmpty) {
    navigateToHome();
  }
}
```

**Replace with:**

```dart
Future<void> _importBackup() async {
  final imported = await SettingsIo.importFromFile(context);
  if (!mounted || !imported) return;

  // Bail out early if the import didn't actually produce any sources
  // (e.g. backup contained settings only). No point showing a refresh
  // dialog when there's nothing to refresh.
  final sources = await Sql.getSources();
  if (!mounted) return;
  if (sources.isEmpty) return;

  // Block on a full refresh of all enabled sources with a progress
  // dialog. Doing this here — rather than firing the refresh into
  // the background and navigating immediately — means when the user
  // lands on Home, their channels are actually there. The dialog
  // also gives them per-source visibility so they're not staring at
  // a frozen welcome screen for minutes.
  //
  // Channel-attribute restores (favorites / last-watched from the
  // backup) are applied inside Utils.refreshSource via the
  // SettingsIo.applyPendingPreserves hook from fix28.
  await showSourcesRefreshDialog(context);

  if (!mounted) return;
  navigateToHome();
}
```

## File: `lib/backend/settings_io.dart`

### Remove the now-misleading snackbar

The snackbar at lines 234–245 says "Backup imported. Refreshing
channels in the background…". With this fix, the refresh isn't in
the background anymore — it's blocking with its own dialog. The
snackbar will fire just before the dialog appears, causing two
overlapping notifications. Remove it.

**Current code (lines 232–245):**

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

(If you didn't apply fix32, the original snackbar with the
"Backup imported. Refreshing channels in the background…" text is
what's there. Same removal applies.)

**Replace with:** (delete the block entirely — no replacement)

The progress dialog from fix33.2 supersedes this snackbar in the
Setup flow. Other call sites of `SettingsIo.importFromFile` (just
`settings_view.dart:1880` — the in-app "Import settings from file"
in the Backup & Restore section) currently rely on the snackbar
for confirmation feedback. Update that caller too:

## File: `lib/settings_view.dart`

### Update the in-Settings import caller

Find the call site (around line 1880). Current code:

```dart
await SettingsIo.importFromFile(context);
// ... existing follow-up code ...
Utils.refreshAllSources();
```

The Settings UI is already inside a `Loading` (LoaderOverlay)
context, so we could use either approach. For consistency with
the new dialog-based approach in Setup, use it here too:

**Replace with:**

```dart
final imported = await SettingsIo.importFromFile(context);
if (!mounted) return;
if (imported) {
  await showSourcesRefreshDialog(context);
  if (!mounted) return;
  // Reload the Settings view so any newly-imported settings are
  // reflected in the UI (e.g. multi-view layout, EPG settings).
  await initAsync();
}
```

Add the import at the top of `settings_view.dart`:

```dart
import 'package:open_tv/widgets/sources_refresh_dialog.dart';
```

---

## What about the manual "Refresh all sources" button?

`settings_view.dart:1999`:

```dart
IconButton(
  onPressed: () async => await Error.tryAsync(
    () async => await Utils.refreshAllSources(),
    context,
    "Successfully refreshed all sources",
  ),
  icon: const Icon(Icons.refresh),
),
```

This still uses the plain `loaderOverlay` spinner via
`Error.tryAsync`. With this fix in place, you can optionally swap
it for the new dialog:

```dart
IconButton(
  onPressed: () async {
    await showSourcesRefreshDialog(context);
  },
  icon: const Icon(Icons.refresh),
),
```

Either is fine. Leaving the existing plain-spinner behaviour
deliberately untouched in this fix to keep scope tight; the user
asked specifically about the import flow. Future fix can flip
this if desired.

---

## What about Home's refresh-on-start?

`lib/home.dart:111`:

```dart
await Utils.refreshAllSources();
```

This runs INSIDE `tryAsyncNoLoading` so there's no UI dialog at
all — silent background work that produces a "Refreshed all
sources" snackbar at the end. Same trade-off applies: the user
could land on Home with an empty list while it runs.

Leaving this untouched too — same scope discipline as the manual
button. If anyone wants to upgrade it, the new helper makes it a
one-line swap.

---

## Test plan

### Happy path — clean install + import

1. Uninstall the app from the test device.
2. Reinstall fix33-applied build.
3. On the welcome screen, tap "Import settings backup" → select
   a known-good backup with one or more enabled sources →
   confirm.
4. **Expected:**
   - File picker / confirm dialog as before.
   - **NEW**: progress dialog appears titled "Loading channels…"
     with a determinate-ish progress bar ("Source 1 of N"), per-
     source status text, and no OK button (yet).
   - As each source finishes, the bar advances and the status text
     updates ("Loading "Aniel3000"…", then status messages from
     the M3U fetcher).
   - When all sources complete, the title changes to "Loaded",
     the bar disappears, and an OK button appears.
   - User taps OK → app navigates to Home with channels already
     visible.

### Refresh-failure path

1. With the device offline, attempt an import.
2. **Expected:**
   - Dialog appears, attempts the refresh, fails.
   - Title changes to "Refresh failed", error message shown, OK
     button appears.
   - User taps OK → app navigates to Home (with whatever sources
     made it into the DB — channels for non-refreshed sources will
     be empty, which is correct: the source records exist but
     have no channels yet, and the user can manually refresh
     later when online).

### Disabled sources

1. Import a backup that contains a disabled source (the user's
   `free4me-backup__2_.json` qualifies).
2. **Expected:**
   - Progress dialog shows "Source 1 of N" where N = enabled
     count (NOT total source count).
   - Disabled sources are skipped silently (the AppLog line from
     fix32 confirms which were skipped if logging is enabled).

### Empty backup (settings-only, no sources)

1. Manually craft a backup file with no sources array.
2. Import it.
3. **Expected:**
   - No progress dialog appears.
   - User remains on the welcome screen (or navigates back to it).
   - Existing fallback path in `_importBackup` handles
     `sources.isEmpty`.

### Settings → Import settings from file

1. With sources already configured, go to Settings → Backup &
   Restore → "Import settings from file".
2. Pick a valid backup → confirm.
3. **Expected:**
   - Progress dialog appears (same one).
   - On OK, Settings view reloads (the `initAsync()` call in
     fix33.3) so any imported settings show their new values
     immediately.

### Regression — manual Refresh all sources button

1. Settings → Sources → tap the "Refresh all sources" icon.
2. **Expected:** plain spinner as before (no progress dialog —
   we deliberately didn't touch this path in fix33).

### Regression — Home refresh-on-start

1. Enable "Refresh on start" in Settings.
2. Force-quit, relaunch.
3. **Expected:** existing behaviour — silent refresh, "Refreshed
   all sources" snackbar at the end.

---

## Notes for the implementer

- **Three files touched:**
  - `lib/backend/utils.dart` — extended signatures (~30 lines).
  - `lib/widgets/sources_refresh_dialog.dart` — new file (~90 lines).
  - `lib/setup.dart` — modified `_importBackup` (~10 lines).
  - `lib/backend/settings_io.dart` — deleted the snackbar block
    (~14 lines removed).
  - `lib/settings_view.dart` — updated import call site (~6 lines).
- **Backwards-compatible signature change.** `Utils.refreshSource`
  and `refreshAllSources` gain new optional named parameters.
  All existing callers compile without modification.
- **The sequential-when-UI-present concurrency** is a deliberate
  call. Two-at-a-time refreshes would require a progress UI that
  could show two simultaneous source states. Sequential keeps the
  "Source X of N" indicator honest. Cost: slightly slower import
  on multi-source setups. Acceptable.
- **`unawaited(() async {…}())`** — the IIFE pattern. `unawaited`
  needs a `Future`, and we want to start the async work
  immediately without awaiting it (because we want the dialog to
  be visible first). The IIFE constructs the future and
  `unawaited` flags to the analyzer that we're intentionally not
  awaiting it. The work still completes; we just don't block
  here.
- **`PopScope(canPop: done)`** — prevents the user from
  back-button-dismissing the dialog while refresh is in flight.
  Once `done = true`, back button works normally (closes the
  dialog with the OK button visible).
- **No new dependencies.** Uses `StatefulBuilder`, `PopScope`,
  `LinearProgressIndicator`, `AlertDialog` — all stock Material.
- **Localisation:** all strings are user-facing English. If
  there's an existing l10n setup I missed, swap them for the
  appropriate `AppLocalizations` calls.
