import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/models/source.dart';

/// Show a modal progress dialog while [Utils.refreshAllSources] runs.
///
/// The dialog is non-dismissible during the refresh — that's the whole
/// point: callers use this helper when they specifically want to block
/// on the refresh so subsequent UI can rely on data being present
/// (e.g. the post-import flow from Setup, so the user doesn't land on
/// an empty Home screen while sources are still loading).
///
/// Resolves after the user has tapped OK on the final summary.
/// Errors during the refresh are caught and surfaced as a "Refresh
/// failed" title with the error message in the body.
Future<void> showSourcesRefreshDialog(BuildContext context) async {
  String title = 'Loading channels…';
  String status = 'Preparing…';
  int sourceIndex = 0;
  int sourceTotal = 0;
  bool done = false;
  Object? error;

  // Captured inside the builder; used by the outer refresh loop.
  late void Function(void Function()) setSt;

  // Kick off the dialog. We deliberately do NOT await here — we need
  // setSt to be captured first, then drive the refresh, and finally
  // await the dialog Future at the bottom so the caller blocks until
  // the user dismisses.
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

  // Drive the refresh in the background. The IIFE+unawaited pattern
  // starts the work without blocking here so the dialog frame above
  // gets a chance to mount and capture setSt.
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
            // Trim very long status strings so the dialog doesn't
            // jump in size on every update.
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
