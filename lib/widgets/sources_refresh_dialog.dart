import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
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
  Object? error;
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
          );
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
