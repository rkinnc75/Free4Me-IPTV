import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/backend/background_task_service.dart';
import 'package:open_tv/backend/settings_service.dart';
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
String _etaSuffix(DateTime? start, int done, int total) {
  if (start == null || done <= 0 || done >= total) return '';
  final elapsed = DateTime.now().difference(start).inMilliseconds;
  if (elapsed < 500) return '';
  final perRow = elapsed / done;
  final remainMs = (perRow * (total - done)).round();
  final s = (remainMs / 1000).round();
  if (s < 1) return '';
  if (s < 60) return '  •  ~${s}s left';
  final m = s ~/ 60;
  final r = s % 60;
  return '  •  ~${m}m ${r}s left';
}

Future<void> showSourcesRefreshDialog(BuildContext context) async {
  AppLog.info('SourcesRefreshDialog: showing');

  String title = 'Loading channels…';
  String status = 'Preparing…';
  int sourceIndex = 0;
  int sourceTotal = 0;
  bool done = false;
  // fix620: set when the user taps Cancel. The refresh IIFE checks it between
  // sources (cooperative cancellation — it can't interrupt a synchronous call,
  // but the FTS pre-flight heal in refreshAllSources removes the main hang, so
  // the loop stays responsive at its await points). On cancel we also repair
  // the FTS index so the user is left with a usable database, not a broken one.
  bool cancelRequested = false;
  Object? error;
  // fix611: per-source failures collected during the batch. A single source
  // failing no longer aborts the whole refresh (see Utils.refreshAllSources);
  // the dialog reports a partial-success summary instead of "Refresh failed".
  final List<String> failedSources = [];
  int rowsDone = 0;
  int rowsTotal = 0;
  DateTime? saveStartedAt;

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
                  rowsTotal > 0
                      ? LinearProgressIndicator(
                          value: rowsDone / rowsTotal)
                      : const LinearProgressIndicator(),
                if (!done && rowsTotal > 0) ...
                  [
                    const SizedBox(height: 4),
                    Text(
                      '${((rowsDone / rowsTotal) * 100).clamp(0, 100).toStringAsFixed(0)}%'
                      '  •  ${rowsDone.clamp(0, rowsTotal)} / $rowsTotal'
                      '${_etaSuffix(saveStartedAt, rowsDone, rowsTotal)}',
                      style: Theme.of(sCtx).textTheme.bodySmall,
                    ),
                  ],
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
                      autofocus: true,
                      onPressed: () {
                        AppLog.info('SourcesRefreshDialog: user dismissed');
                        Navigator.pop(sCtx);
                      },
                      child: const Text('OK'),
                    ),
                  ]
                : [
                    // fix620/fix621: Cancel lets the user abort a long refresh
                    // without force-closing. It only FLAGS cooperative
                    // cancellation (shouldCancel); the refresh loop breaks
                    // between sources and the wrapper still runs its
                    // end-of-batch FTS rebuild, which leaves the search index
                    // fully consistent. We do NOT call ensureFtsHealthy here
                    // (fix621: it would race the wrapper's in-flight
                    // DROP+rebuild) and we do NOT mark done here — the refresh
                    // completion handler shows "Cancelled" once the rebuild has
                    // actually finished, so the dialog stays honest.
                    TextButton(
                      onPressed: cancelRequested
                          ? null
                          : () {
                              AppLog.info(
                                  'SourcesRefreshDialog: user requested cancel');
                              setSt(() {
                                cancelRequested = true;
                                status = 'Cancelling — finishing the current '
                                    'source and rebuilding the search index…';
                              });
                            },
                      child: Text(cancelRequested ? 'Cancelling…' : 'Cancel'),
                    ),
                  ],
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
      // fix318: when background processing is enabled, hold the process alive
      // with a foreground service so the refresh survives app-switching. The
      // work still runs on the main isolate; the service only promotes the
      // process and mirrors progress to its notification.
      await BackgroundTaskService.run<void>(
        enabled: SettingsService.cached?.backgroundProcessing ?? false,
        title: 'Refreshing sources',
        work: (update) async {
          await Utils.refreshAllSources(
            onSourceRowProgress: (Source src, int d, int t) {
              setSt(() {
                if (saveStartedAt == null || t != rowsTotal) {
                  saveStartedAt = DateTime.now();
                }
                rowsDone = d;
                rowsTotal = t;
              });
              if (t > 0) update('${src.name}: $d / $t');
            },
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
              update('Loading "${source.name}" ($i/$total)…');
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
            onSourceFailed: (Source source, Object err) {
              setSt(() => failedSources.add(source.name));
            },
            shouldCancel: () => cancelRequested,
          );
        },
      );
      AppLog.info(
        'SourcesRefreshDialog: refresh complete'
        ' — $sourceTotal source(s) done',
      );
    } catch (e, st) {
      // fix619: a malformed FTS index (code 267) makes every refresh fail until
      // the index is rebuilt. Detect it, rebuild channels_fts from scratch, and
      // retry the refresh ONCE. If the retry also fails, surface that error.
      if (Sql.isMalformedDbError(e)) {
        AppLog.warn('SourcesRefreshDialog: malformed FTS detected (code 267) — '
            'rebuilding index and retrying refresh once\n$st');
        setSt(() => status = 'Repairing search index…');
        try {
          await Sql.rebuildFtsTableFromScratch();
          failedSources.clear();
          await BackgroundTaskService.run<void>(
            enabled: SettingsService.cached?.backgroundProcessing ?? false,
            title: 'Refreshing sources',
            work: (update) async {
              await Utils.refreshAllSources(
                onSourceRowProgress: (Source src, int d, int t) {
                  setSt(() {
                    if (saveStartedAt == null || t != rowsTotal) {
                      saveStartedAt = DateTime.now();
                    }
                    rowsDone = d;
                    rowsTotal = t;
                  });
                  if (t > 0) update('${src.name}: $d / $t');
                },
                onSourceStart: (int i, int total, Source source) {
                  setSt(() {
                    sourceIndex = i;
                    sourceTotal = total;
                    status = 'Loading "${source.name}"…';
                  });
                  update('Loading "${source.name}" ($i/$total)…');
                },
                onSourceStatus: (Source source, String msg) {
                  setSt(() {
                    status = '${source.name}: '
                        '${msg.length > 60 ? "${msg.substring(0, 60)}…" : msg}';
                  });
                },
                onSourceFailed: (Source source, Object err) {
                  setSt(() => failedSources.add(source.name));
                },
                // Review finding 158: the FTS-recovery retry omitted
                // shouldCancel, so Cancel became a permanent lying
                // "Cancelling…" no-op during the retry. Now honored, matching
                // the first attempt.
                shouldCancel: () => cancelRequested,
              );
            },
          );
          AppLog.info('SourcesRefreshDialog: refresh complete after FTS '
              'recovery — $sourceTotal source(s) done');
        } catch (e2, st2) {
          error = e2;
          AppLog.warn('SourcesRefreshDialog: refresh STILL failed after FTS '
              'recovery — $e2\n$st2');
        }
      } else {
        error = e;
        AppLog.warn('SourcesRefreshDialog: refresh error — $e\n$st');
      }
    }

    // fix696: the (channels) refresh is finished and the sqlite writer is free,
    // so kick the deferred browse-index rebuild — the ~14 indexes
    // withDroppedBrowseIndexes left dropped to dismiss this dialog sooner.
    // Unawaited so the dialog reports done immediately; the rebuild runs in the
    // background (guarded against overlapping the startup self-heal). Skipped
    // when nothing loaded (no drop happened).
    if (error == null && sourceTotal > 0) {
      unawaited(Sql.ensureBrowseIndexesPresent());
    }

    setSt(() {
      done = true;
      if (error != null) {
        title = 'Refresh failed';
        status = error.toString();
      } else if (cancelRequested) {
        // fix621: reached here only after the wrapper's end-of-batch FTS
        // rebuild completed, so the index is consistent and it is honest to
        // report the cancellation as done.
        title = 'Cancelled';
        status = 'Refresh cancelled. Loaded sources are ready.';
      } else if (sourceTotal == 0) {
        title = 'Nothing to refresh';
        status = 'No enabled sources were found.';
        AppLog.info('SourcesRefreshDialog: no enabled sources');
      } else if (failedSources.isNotEmpty) {
        // fix611: some sources failed but others succeeded — report both
        // instead of a misleading all-or-nothing result.
        final okCount = sourceTotal - failedSources.length;
        title = okCount > 0 ? 'Partly loaded' : 'Refresh failed';
        status = okCount > 0
            ? '$okCount of $sourceTotal sources ready. '
                'Could not refresh: ${failedSources.join(", ")}.'
            : 'Could not refresh: ${failedSources.join(", ")}.';
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
