# fix44.md — Sources refresh dialog hangs forever + comprehensive workflow logging

> **Version:** Free4Me-IPTV 1.17.1
> **Evidence:** `free4me_log_1779655751247.txt` (fresh install, import
> stuck at "Preparing…"), `free4me_log_1779656278811.txt` (subsequent
> session: EPG matched 0 channels because the channel table was never
> populated).

---

## Root cause — `late` variable race in `sources_refresh_dialog.dart`

`showSourcesRefreshDialog` uses a `late` variable to capture the
`StatefulBuilder`'s `setState` function:

```dart
late void Function(void Function()) setSt;

final dialogClosed = showDialog<void>(
  builder: (_) => StatefulBuilder(
    builder: (sCtx, s) {
      setSt = s;           // assigned here — only after the dialog builds
      ...
    },
  ),
);

unawaited(() async {       // IIFE starts immediately
  try {
    await Utils.refreshAllSources(
      onSourceStart: (i, total, source) {
        setSt(() { ... }); // may fire before dialog has built
      },
    );
  } catch (e) { error = e; }
  setSt(() { done = true; ... }); // also outside try/catch
}());

await dialogClosed;
```

`showDialog` returns its `Future` **synchronously** — before the
dialog widget has been built. The IIFE begins running immediately.
It hits `await Sql.getSources()` inside `refreshAllSources`, which
yields to the event loop. On a fast device or after a warm-up query,
the database isolate response can come back as a macrotask **before**
Flutter renders the first frame that builds the dialog and assigns
`setSt`.

When that happens:

1. `onSourceStart` fires → calls `setSt(...)` → **`LateInitializationError`**
2. Caught by the `try/catch`, stored as `error`
3. Code falls through to `setSt(() { done = true; ... })` — **outside**
   the `try/catch`
4. Same uninitialized `late` → **second `LateInitializationError`**,
   this time uncaught
5. The IIFE crashes silently (it is `unawaited`)
6. `done` is never set to `true`
7. The `AlertDialog` shows `canPop: false` and no OK button — **stuck
   at "Preparing…" forever**
8. User force-closes the app; channels table is never populated

The log confirms this: `Utils.refreshAllSources: 1 enabled source(s)`
(logged at the top of `refreshAllSources`) **never appears** in either
log, meaning the IIFE died before `refreshAllSources` could log
anything.

---

## Fix 44.1 — Rewrite `sources_refresh_dialog.dart` using a Completer

Replace the `late` variable + IIFE pattern with a `Completer<void>`
that the `StatefulBuilder` resolves the first time it builds. The IIFE
`await`s the completer before touching any dialog state, guaranteeing
`setSt` is initialised.

**File:** `lib/widgets/sources_refresh_dialog.dart`

**Replace the entire file with:**

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/models/source.dart';

/// Show a modal progress dialog while [Utils.refreshAllSources] runs,
/// then resolve after the user taps OK on the final summary.
///
/// The dialog is non-dismissible during the refresh so the caller can
/// rely on the channel table being populated when it returns.
///
/// ## Fix 44 — race condition
/// The previous implementation used a `late` variable to capture the
/// `StatefulBuilder`'s setState function. Because `showDialog` returns
/// its Future synchronously (before the dialog widget builds), and
/// because the refresh work starts immediately in a fire-and-forget
/// IIFE, the late variable could be accessed before it was assigned,
/// producing a `LateInitializationError` that killed the IIFE silently
/// and left the dialog stuck at "Preparing…" with no way to dismiss it.
///
/// The fix: a `Completer<void>` that the `StatefulBuilder` completes on
/// its first build. The refresh work awaits the completer before
/// touching any state, so it is guaranteed to run after the dialog is
/// mounted and the setState reference is valid.
Future<void> showSourcesRefreshDialog(BuildContext context) async {
  AppLog.info('SourcesRefreshDialog: showing');

  String title = 'Loading channels…';
  String status = 'Preparing…';
  int sourceIndex = 0;
  int sourceTotal = 0;
  bool done = false;
  Object? error;

  // Resolved by the StatefulBuilder on its first build.
  // The refresh IIFE awaits this before calling setSt.
  final dialogReady = Completer<void>();
  late void Function(void Function()) setSt;

  final dialogClosed = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => StatefulBuilder(
      builder: (sCtx, s) {
        setSt = s;
        // Complete exactly once — subsequent rebuilds are no-ops.
        if (!dialogReady.isCompleted) {
          dialogReady.complete();
          AppLog.info('SourcesRefreshDialog: dialog built — ready');
        }
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
                      onPressed: () {
                        AppLog.info('SourcesRefreshDialog: user dismissed');
                        Navigator.pop(sCtx);
                      },
                      child: const Text('OK'),
                    ),
                  ]
                : null,
          ),
        );
      },
    ),
  );

  // Drive the refresh after the dialog is guaranteed to be mounted.
  // Using unawaited + IIFE so we can await dialogClosed at the bottom
  // (the call resolves once the user taps OK).
  unawaited(() async {
    // Wait for the dialog to build and capture setSt.
    await dialogReady.future;
    AppLog.info('SourcesRefreshDialog: starting refresh');

    try {
      await Utils.refreshAllSources(
        onSourceStart: (int i, int total, Source source) {
          AppLog.info(
            'SourcesRefreshDialog: source $i/$total'
            ' "${source.name}" starting',
          );
          setSt(() {
            sourceIndex = i;
            sourceTotal = total;
            status = 'Loading "${source.name}"…';
          });
        },
        onSourceStatus: (Source source, String msg) {
          if (AppLog.enabled) {
            AppLog.info(
              'SourcesRefreshDialog: "${source.name}"'
              ' — ${msg.length > 80 ? "${msg.substring(0, 80)}…" : msg}',
            );
          }
          setSt(() {
            status = '${source.name}: '
                '${msg.length > 60 ? "${msg.substring(0, 60)}…" : msg}';
          });
        },
      );
      AppLog.info(
        'SourcesRefreshDialog: refresh complete'
        ' — $sourceTotal source(s) done',
      );
    } catch (e, st) {
      error = e;
      AppLog.warn('SourcesRefreshDialog: refresh error — $e\n$st');
    }

    setSt(() {
      done = true;
      if (error != null) {
        title = 'Refresh failed';
        status = error.toString();
      } else if (sourceTotal == 0) {
        title = 'Nothing to refresh';
        status = 'No enabled sources were found.';
        AppLog.info('SourcesRefreshDialog: no enabled sources');
      } else {
        title = 'Loaded';
        status = sourceTotal == 1
            ? '1 source ready.'
            : '$sourceTotal sources ready.';
      }
    });
  }());

  await dialogClosed;
  AppLog.info('SourcesRefreshDialog: dialog closed');
}
```

---

## Fix 44.2 — Add logging to `_importBackup` in `setup.dart`

`_importBackup` is the first step in the install-from-backup workflow.
Currently produces no log output — a silent failure here is
undiagnosable.

**File:** `lib/setup.dart`

### Step 1 — add import

```dart
import 'package:open_tv/backend/app_logger.dart';
```

### Step 2 — replace `_importBackup`

**Current code (lines 323–345):**

```dart
Future<void> _importBackup() async {
  final imported = await SettingsIo.importFromFile(context);
  if (!mounted || !imported) return;

  final sources = await Sql.getSources();
  if (!mounted) return;
  if (sources.isEmpty) return;

  await showSourcesRefreshDialog(context);

  if (!mounted) return;
  navigateToHome();
}
```

**Replace with:**

```dart
Future<void> _importBackup() async {
  AppLog.info('Setup: import backup — started');

  final imported = await SettingsIo.importFromFile(context);
  if (!mounted) return;
  if (!imported) {
    AppLog.info('Setup: import backup — cancelled or failed, staying on welcome');
    return;
  }

  AppLog.info('Setup: import backup — file accepted, checking sources');
  final sources = await Sql.getSources();
  if (!mounted) return;

  if (sources.isEmpty) {
    AppLog.info('Setup: import backup — no sources in backup, staying on welcome');
    return;
  }

  final enabledCount = sources.where((s) => s.enabled).length;
  AppLog.info(
    'Setup: import backup — ${sources.length} sources imported'
    ' ($enabledCount enabled):'
    ' ${sources.map((s) => '"${s.name}"(${s.enabled ? "on" : "off"})').join(", ")}',
  );
  AppLog.info('Setup: import backup — launching source refresh dialog');

  await showSourcesRefreshDialog(context);

  if (!mounted) return;
  AppLog.info('Setup: import backup — refresh dialog complete, navigating to Home');
  navigateToHome();
}
```

---

## Fix 44.3 — Add logging to `_runEpgRefresh` in `settings_view.dart`

`_runEpgRefresh` runs the full EPG download + match cycle. It produces
progress updates for the dialog but nothing in the log. A failure here
(timeout, SQL error, wrong URL) is invisible unless the user saves the
log at exactly the right moment.

**File:** `lib/settings_view.dart`

### Replace `_runEpgRefresh`

**Current code (lines 437–575):**

```dart
Future<void> _runEpgRefresh(BuildContext ctx) async {
  String status = 'Starting…';
  int programs = 0;
  int matchDone = 0;
  int matchTotal = 0;
  final results = <String>[];

  bool dialogOpen = true;
  showDialog( ... ).then((_) => dialogOpen = false);

  for (final source in sources) {
    if (!source.enabled) continue;
    ...
    try {
      await EpgService.refreshSource(source, ...);
      ...
      results.add('✓ ...');
    } catch (e) {
      sourceError = e.toString();
      results.add('✗ ...');
    }
  }

  if (dialogOpen && ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
  ...
  showDialog( summary dialog );
}
```

**Replace with** (all existing logic preserved; `AppLog` lines added):

```dart
Future<void> _runEpgRefresh(BuildContext ctx) async {
  final enabledWithEpg = sources.where((s) {
    if (!s.enabled) return false;
    final hasManualUrl = s.epgUrl?.isNotEmpty == true;
    final isXtream = s.sourceType == SourceType.xtream;
    return hasManualUrl || isXtream;
  }).toList();

  AppLog.info(
    'EpgRefresh: starting — ${enabledWithEpg.length} eligible source(s):'
    ' ${enabledWithEpg.map((s) => '"${s.name}"').join(", ")}',
  );

  String status = 'Starting…';
  int programs = 0;
  int matchDone = 0;
  int matchTotal = 0;
  final results = <String>[];

  bool dialogOpen = true;
  showDialog(
    context: ctx,
    barrierDismissible: false,
    builder: (_) => StatefulBuilder(
      builder: (sCtx, setSt) {
        _refreshSetState = setSt;
        _refreshStatus = status;

        final isMatching = matchTotal > 0;
        final matchFraction =
            isMatching ? matchDone / matchTotal : null;

        return AlertDialog(
          title: const Text('Refreshing EPG…'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              matchFraction != null
                  ? LinearProgressIndicator(value: matchFraction)
                  : const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Text(
                _refreshStatus,
                style: Theme.of(sCtx).textTheme.bodySmall,
              ),
              if (programs > 0 && !isMatching)
                Text(
                  '$programs programs loaded',
                  style: Theme.of(sCtx).textTheme.bodySmall,
                ),
              if (isMatching)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Channels matched: $matchDone / $matchTotal',
                    style: Theme.of(sCtx).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  ).then((_) => dialogOpen = false);

  for (final source in sources) {
    if (!source.enabled) continue;
    final hasManualUrl = source.epgUrl?.isNotEmpty == true;
    final isXtream = source.sourceType == SourceType.xtream;
    if (!hasManualUrl && !isXtream) continue;

    final url = hasManualUrl ? source.epgUrl : null;
    matchDone = 0;
    matchTotal = 0;
    programs = 0;
    status = 'Preparing "${source.name}"…';
    _updateRefreshDialog(status);

    AppLog.info('EpgRefresh: source "${source.name}" — starting');

    int sourceInserted = 0;
    int sourceMatchedChannels = 0;
    int sourceTotalChannels = 0;
    String? sourceError;
    try {
      await EpgService.refreshSource(
        source,
        epgUrl: url,
        onProgress: (p) {
          sourceInserted = p.programsInserted;
          programs = p.programsInserted;

          if (p.isMatching) {
            matchDone = p.matchingChannelsDone;
            matchTotal = p.matchingChannelsTotal;
            sourceMatchedChannels = p.matchingChannelsDone;
            sourceTotalChannels = p.matchingChannelsTotal;
            status = '${source.name}: matching channels…';
            _updateRefreshDialog(status);
          } else {
            status = p.statusMessage != null
                ? '${source.name}: ${p.statusMessage}'
                : '${source.name}: $programs programs…';
            _updateRefreshDialog(status);
          }
        },
      );
      if (sourceInserted == 0) {
        AppLog.warn(
          'EpgRefresh: source "${source.name}" — 0 programs loaded'
          ' (check EPG URL / server / date window)',
        );
        results.add(
          '⚠ ${source.name}: refresh completed but 0 programs loaded '
          '(check EPG URL, server response, or date window)',
        );
      } else {
        AppLog.info(
          'EpgRefresh: source "${source.name}" — done'
          ' programs=$sourceInserted'
          ' matched=$sourceMatchedChannels/$sourceTotalChannels',
        );
        final matchSuffix = sourceTotalChannels > 0
            ? ' · $sourceMatchedChannels/$sourceTotalChannels channels matched'
            : '';
        results.add(
          '✓ ${source.name}: $sourceInserted programs$matchSuffix',
        );
      }
    } catch (e, st) {
      sourceError = e.toString();
      AppLog.warn('EpgRefresh: source "${source.name}" — ERROR: $e\n$st');
      results.add('✗ ${source.name}: $sourceError');
    }
  }

  AppLog.info(
    'EpgRefresh: complete — ${results.length} source(s) processed\n'
    '${results.join("\n")}',
  );

  if (dialogOpen && ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();

  if (!ctx.mounted) return;
  showDialog(
    context: ctx,
    builder: (_) => AlertDialog(
      title: const Text('EPG Refresh Complete'),
      content: SingleChildScrollView(
        child: Text(results.isEmpty
            ? 'No sources had an EPG URL configured.'
            : results.join('\n')),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
```

---

## Fix 44.4 — Add logging to `_runEpgRematch` in `settings_view.dart`

Same gap as `_runEpgRefresh` — no log output means a force-match
failure is undiagnosable from a saved log.

**File:** `lib/settings_view.dart`

### Replace `_runEpgRematch`

**Current code (lines 579–683)** — replace with (all existing logic
preserved; `AppLog` lines added):

```dart
Future<void> _runEpgRematch(BuildContext ctx) async {
  final eligibleSources = sources.where((s) {
    if (!s.enabled) return false;
    return EpgService.resolveEpgUrl(s) != null;
  }).toList();

  AppLog.info(
    'EpgRematch: starting — ${eligibleSources.length} eligible source(s):'
    ' ${eligibleSources.map((s) => '"${s.name}"').join(", ")}',
  );

  String status = 'Starting…';
  int matchDone = 0;
  int matchTotal = 0;
  bool dialogOpen = true;

  showDialog(
    context: ctx,
    barrierDismissible: false,
    builder: (_) => StatefulBuilder(
      builder: (sCtx, setSt) {
        _refreshSetState = setSt;
        final fraction = matchTotal > 0 ? matchDone / matchTotal : null;
        return AlertDialog(
          title: const Text('Re-matching channels…'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              fraction != null
                  ? LinearProgressIndicator(value: fraction)
                  : const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Text(status, style: Theme.of(sCtx).textTheme.bodySmall),
              if (matchTotal > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Channels matched: $matchDone / $matchTotal',
                    style: Theme.of(sCtx).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  ).then((_) => dialogOpen = false);

  final results = <String>[];
  for (final source in sources) {
    if (!source.enabled) continue;
    final epgUrl = EpgService.resolveEpgUrl(source);
    if (epgUrl == null) continue;

    status = 'Re-matching "${source.name}"…';
    _updateRefreshDialog(status);
    matchDone = 0;
    matchTotal = 0;

    AppLog.info('EpgRematch: source "${source.name}" — downloading EPG');

    try {
      final channelMap = await EpgService.downloadAndParseEpg(
        source,
        epgUrl: epgUrl,
        onProgress: (p) {
          status = '${source.name}: ${p.statusMessage ?? "downloading…"}';
          _updateRefreshDialog(status);
        },
      );
      if (channelMap == null) {
        AppLog.warn('EpgRematch: source "${source.name}" — download returned null');
        results.add('⚠ ${source.name}: failed to download EPG');
        continue;
      }
      AppLog.info(
        'EpgRematch: source "${source.name}" — EPG downloaded'
        ' (${channelMap.length} channel entries),'
        ' starting force-match',
      );
      await EpgService.matchChannels(
        source,
        channelMap,
        forceAll: true,
        onProgress: (p) {
          matchDone = p.matchingChannelsDone;
          matchTotal = p.matchingChannelsTotal;
          status = '${source.name}: matching…';
          _updateRefreshDialog(status);
        },
      );
      AppLog.info(
        'EpgRematch: source "${source.name}" — force-match done'
        ' $matchDone/$matchTotal',
      );
      results.add('✓ ${source.name}: re-match complete'
          '${matchTotal > 0 ? " ($matchDone/$matchTotal)" : ""}');
    } catch (e, st) {
      AppLog.warn('EpgRematch: source "${source.name}" — ERROR: $e\n$st');
      results.add('✗ ${source.name}: $e');
    }
  }

  AppLog.info(
    'EpgRematch: complete — ${results.length} source(s) processed\n'
    '${results.join("\n")}',
  );

  if (dialogOpen && ctx.mounted) Navigator.of(ctx, rootNavigator: true).pop();
  if (!ctx.mounted) return;
  showDialog(
    context: ctx,
    builder: (_) => AlertDialog(
      title: const Text('Re-match Complete'),
      content: SingleChildScrollView(
        child: Text(results.isEmpty
            ? 'No sources with EPG configured.'
            : results.join('\n')),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
```

---

## What the log will show after fix44

### Successful import from setup screen

```
Setup: import backup — started
SettingsIo.import: schemaVersion=3 appVersion=1.17.x ...
Settings: saved multiViewLayout=...
Setup: import backup — file accepted, checking sources
Setup: import backup — 2 sources imported (1 enabled): "Aniel3000 "(on), "Emjay"(off)
Setup: import backup — launching source refresh dialog
SourcesRefreshDialog: showing
SourcesRefreshDialog: dialog built — ready
SourcesRefreshDialog: starting refresh
Utils.refreshAllSources: 1 enabled source(s) (Aniel3000 )
SourcesRefreshDialog: source 1/1 "Aniel3000 " starting
SourcesRefreshDialog: "Aniel3000 " — downloading M3U...
SourcesRefreshDialog: "Aniel3000 " — inserted 35000 channels
SourcesRefreshDialog: refresh complete — 1 source(s) done
SourcesRefreshDialog: user dismissed
Setup: import backup — refresh dialog complete, navigating to Home
```

### Previously failing path (race condition)

With the fix applied, this path no longer occurs. Without the fix,
the log would end after `Utils.refreshAllSources: 1 enabled source(s)`
(or before) with no further entries — the IIFE crashed silently.

### EPG refresh

```
EpgRefresh: starting — 1 eligible source(s): "Aniel3000 "
EpgRefresh: source "Aniel3000 " — starting
(XMLTV log lines from xmltv_parser.dart)
EpgRefresh: source "Aniel3000 " — done programs=574307 matched=14713/35945
EpgRefresh: complete — 1 source(s) processed
✓ Aniel3000 : 574307 programs · 14713/35945 channels matched
```

### EPG rematch

```
EpgRematch: starting — 1 eligible source(s): "Aniel3000 "
EpgRematch: source "Aniel3000 " — downloading EPG
(XMLTV log lines)
EpgRematch: source "Aniel3000 " — EPG downloaded (15522 channel entries), starting force-match
EpgRematch: source "Aniel3000 " — force-match done 14713/35945
EpgRematch: complete — 1 source(s) processed
✓ Aniel3000 : re-match complete (14713/35945)
```

---

## Test plan

### Fix 44.1 — race condition

1. Uninstall and reinstall the app.
2. On the welcome screen tap "Import settings backup", pick a v3
   backup with at least one enabled source.
3. **Expected:** progress dialog appears, advances through
   "Source 1 of N", shows per-source status, eventually shows
   "Loaded — N source(s) ready" with an OK button.
4. Tap OK → Home with channels already populated.
5. Enable debug logging, repeat. In the log confirm the sequence
   ends with `SourcesRefreshDialog: user dismissed` and
   `Setup: import backup — refresh dialog complete, navigating to Home`.
6. **Stress test for the race:** run on a device where the first
   run shows channels populating quickly (fast DB). The dialog
   should still progress correctly — the `Completer` guarantees
   `setSt` is initialized regardless of timing.

### Fix 44.2 — setup logging

In the log after a successful import, verify all seven log lines
appear in order (see "Successful import" section above). In
particular `Setup: import backup — 2 sources imported` should show
the correct enabled/disabled breakdown matching the backup file.

### Fix 44.3 — EPG refresh logging

Run "Refresh EPG now" from Settings. In the log:
- `EpgRefresh: starting` appears before the dialog
- `EpgRefresh: source "X" — starting` per source
- `EpgRefresh: source "X" — done programs=N matched=M/T` on success
- `EpgRefresh: complete` with result summary at end
- Only enabled sources with EPG URLs appear — Emjay should not

### Fix 44.4 — EPG rematch logging

Run "Re-match all channels" from Settings. Same verification as
44.3 but with `EpgRematch:` prefix and `force-match done M/T` line.

---

## Notes for the implementer

- **Only `sources_refresh_dialog.dart` has a logic change.** The
  three other files only add `AppLog` lines. If time is short,
  44.1 is the critical fix; 44.2–44.4 are diagnostic-only.
- **`AppLog.enabled` guard on `onSourceStatus` log.** This callback
  fires on every status string emitted by the M3U / Xtream
  fetchers, which can be hundreds of calls per source. The
  `if (AppLog.enabled)` guard ensures no string formatting happens
  in release builds when logging is off.
- **`_runEpgRefresh` and `_runEpgRematch` compute `enabledWithEpg`
  / `eligibleSources` locally** for the opening log line. This is
  a read-only calculation — it does not change the loop logic.
  Both loops still iterate `sources` (the full list on
  `_SettingsViewState`) and apply the same `if (!source.enabled)
  continue` and URL checks they always did.
- **No schema changes, no new dependencies, no new files.**
- **`import 'package:open_tv/backend/app_logger.dart';`** must be
  added to `setup.dart` — it is not currently imported there.
  `sources_refresh_dialog.dart` and `settings_view.dart` already
  have it.
