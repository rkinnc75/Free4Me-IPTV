import 'dart:async';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/channel_search_cache.dart';
import 'package:open_tv/backend/m3u.dart';
import 'package:open_tv/backend/settings_io.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/xtream.dart';
import 'package:open_tv/memory.dart';
import 'package:open_tv/models/source.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_tv/backend/epg_discovery_runner.dart';
import 'package:open_tv/models/source_type.dart';

class Utils {
  static String? _appDir;
  static Future<String> get appDir async {
    _appDir ??= (await getApplicationSupportDirectory()).path;
    return _appDir!;
  }

  static Future<String> getTempPath(String fileName) async {
    final path = await appDir;
    final tempDir = join(path, "temp");
    await Directory(tempDir).create(recursive: true);
    return join(tempDir, fileName);
  }

  static Future<void> refreshSource(
    Source source, {
    void Function(String)? onProgress,
    void Function(int done, int total)? onRowProgress,
  }) async {
    refreshedSeries.clear();
    // fix620: repair a malformed FTS index BEFORE touching it — a corrupt index
    // makes the per-source delete hang on the main isolate (the single-source
    // "Emjay" refresh hang). Heal proactively. Non-fatal on failure.
    try {
      if (await Sql.ensureFtsHealthy()) {
        onProgress?.call('Repaired search index');
      }
    } catch (e) {
      AppLog.warn('Utils.refreshSource: FTS pre-flight check failed '
          '(non-fatal, continuing) — $e');
    }
    await processSource(source, true, onProgress, onRowProgress);
    // After channels are populated, apply any favorites and last-
    // watched timestamps that an imported backup staged for this
    // if no preserve list is pending.
    await SettingsIo.applyPendingPreserves(source.name);
    // No-op if SearchMethod.inMemory was never selected this session.
    if (ChannelSearchCache.isBuilt) {
      await ChannelSearchCache.rebuild();
      AppLog.info(
          'ChannelSearchCache: rebuilt after source refresh (${source.name})');
    }
  }

  static Future<void> processSource(
    Source source, [
    bool wipe = false,
    void Function(String)? onProgress,
    void Function(int done, int total)? onRowProgress,
  ]) async {
    // fix383: the importers commit the source row UP FRONT (fix376 for Xtream,
    // m3u.dart for M3U) so source.id is known before the bulk channel insert.
    // If the fetch/auth then fails and the import throws, that row would leak —
    // leaving a broken empty source, and making the user's corrected retry hit
    // a false "name already exists" (setup.dart pre-check) or end up with a
    // duplicate. When this is a brand-new add (the name did not already exist),
    // delete the just-created source on failure before rethrowing. A refresh /
    // re-import of an existing source (name already present) is left untouched,
    // so a transient refresh failure never deletes a working source.
    // fix617: stage logging to pinpoint where a phone refresh hangs at
    // "Preparing…" (no on-device repro; the log now survives so the next run
    // shows the exact stall point).
    AppLog.info('fix617 processSource: "${source.name}" — checking name exists');
    final bool namePreExisted = await Sql.sourceNameExists(source.name);
    AppLog.info('fix617 processSource: "${source.name}" — namePreExisted='
        '$namePreExisted; entering withDroppedBrowseIndexes');
    try {
      // fix518: drop the channels browse indexes around the bulk wipe+reinsert
      // and rebuild once after, instead of maintaining ~a dozen indexes per
      // row. Re-entrant — a no-op when refreshAllSources already dropped them
      // around the whole multi-source loop.
      await Sql.withDroppedBrowseIndexes(() async {
        AppLog.info('fix617 processSource: "${source.name}" — indexes dropped,'
            ' dispatching ${source.sourceType} fetch');
        switch (source.sourceType) {
          case SourceType.m3u:
            await processM3U(source, wipe, null, onProgress);
            break;
          case SourceType.m3uUrl:
            await processM3UUrl(source, wipe, onProgress);
            break;
          case SourceType.xtream:
            await getXtream(source, wipe, onProgress, onRowProgress);
            break;
        }
        AppLog.info('fix617 processSource: "${source.name}" — fetch+write'
            ' returned (inside withDroppedBrowseIndexes)');
      }, onProgress: onProgress);
      AppLog.info('fix617 processSource: "${source.name}" —'
          ' withDroppedBrowseIndexes complete');
      // fix386: brand-new Xtream add — fire EPG auto-discovery.
      // The runner is sticky (skips if epgDiscoveryState is set) and
      // is fire-and-forget; a probe failure must not roll back the
      // add. Gated on `!namePreExisted` so refreshes of existing
      // sources never re-probe.
      if (!namePreExisted && source.sourceType == SourceType.xtream) {
        // Detach: don't await. The Add Source dialog is already
        // dismissing (setup.dart pops the route on success); the
        // probe runs in the background and the user sees the
        // source-list pill update when it finishes.
        unawaited(
          EpgDiscoveryRunner.runIfNewXtream(source),
        );
      }
    } catch (e) {
      // The importer set source.id during its up-front commit; remove that row
      // (deleteSource cascades channels/groups/EPG). Guard the cleanup so a
      // failure to delete never masks the original import error.
      if (!namePreExisted && source.id != null) {
        try {
          await Sql.deleteSource(source.id!);
          AppLog.warn(
            'Utils.processSource: removed leaked source "${source.name}"'
            ' (id=${source.id}) after failed add — $e',
          );
        } catch (cleanupErr) {
          AppLog.error(
            'Utils.processSource: cleanup of leaked source "${source.name}"'
            ' failed — $cleanupErr (original error: $e)',
          );
        }
      }
      rethrow;
    }
  }

  /// Refresh every enabled source's M3U / Xtream channel list.
  ///
  /// Disabled sources are skipped — same rule as
  /// [EpgService.refreshAllSources] and the per-source EPG actions in
  /// Settings. The single-source [refreshSource] is unaffected; callers
  /// who explicitly target a disabled source (e.g. Settings → Sources
  /// per-row refresh) still bypass the filter, which is correct — that
  /// action is an explicit user override.
  ///
  /// [onSourceStart] fires once per source as it begins, with the
  /// source's 1-based index and the total count. Use it to drive a
  /// progress UI. Omit for fire-and-forget.
  ///
  /// [onSourceStatus] forwards per-source status strings from the
  /// underlying M3U / Xtream fetchers (e.g. "downloaded 12000
  /// channels"). The same callback gets called for whichever source
  /// is currently being refreshed.
  ///
  /// When [onSourceStart] is null, sources refresh 2-at-a-time for
  /// speed (the original behaviour). When non-null, the loop runs
  /// sequentially so the dialog's "Source X of N" stays honest.
  static Future<void> refreshAllSources({
    void Function(int index, int total, Source source)? onSourceStart,
    void Function(Source source, String status)? onSourceStatus,
    void Function(Source source, int done, int total)? onSourceRowProgress,
    void Function(Source source, Object error)? onSourceFailed,
    bool Function()? shouldCancel, // fix620: cooperative cancellation
  }) async {
    final enabled = (await Sql.getSources())
        .where((s) => s.enabled)
        .toList(growable: false);
    AppLog.info(
      'Utils.refreshAllSources: ${enabled.length} enabled source(s)'
      ' (${enabled.map((s) => s.name).join(", ")})',
    );
    // fix620: repair a malformed FTS index BEFORE the loop. A corrupt index
    // makes the per-source delete hang (not throw) on the main isolate, which
    // no Cancel button can interrupt — so heal it proactively here.
    try {
      final repaired = await Sql.ensureFtsHealthy();
      if (repaired && enabled.isNotEmpty) {
        onSourceStatus?.call(enabled.first, 'Repaired search index');
      }
    } catch (e) {
      AppLog.warn('Utils.refreshAllSources: FTS pre-flight check failed '
          '(non-fatal, continuing) — $e');
    }

    if (enabled.isEmpty) return;

    // fix521: suspend the FTS triggers around the WHOLE batch (outermost) so
    // every source inserts trigger-free and the FTS index is rebuilt exactly
    // ONCE at the end — not once per source. The per-source wrap in xtream.dart
    // hits the _ftsTriggersSuspended early-return and becomes a pass-through,
    // and M3U (which has no per-source wrap) is still covered because the
    // fix614 batch targeted re-index below reindexes every SUCCEEDED source by
    // source_id regardless of type (M3U included). On the error path (body
    // threw) the wrapper falls back to a full global rebuild for safety.
    //
    // fix518: drop the channels browse indexes ONCE around the whole loop and
    // rebuild them once at the end (not per source) — the per-row index
    // maintenance across every source's wipe+reinsert was the dominant cost.
    // The loop is now always SEQUENTIAL: the previous 2-at-a-time path raced
    // both the shared FTS-trigger suspend and this index drop/recreate, and
    // SQLite serializes writes anyway, so concurrency bought nothing on the
    // DB-write-bound refresh.
    // fix621: FTS is NOT maintained per-source inside the loop anymore
    // (fix619's per-source delete-before-wipe degraded to ~86 min on a large
    // source — onn, 2026-06-30). Each source is wiped+reinserted with the FTS
    // triggers suspended (pass-through branch), leaving the index stale; the
    // wrapper rebuilds it ONCE at end-of-batch via DROP+repopulate. The
    // batchTargetedRebuild closure below is just the "batch succeeded"
    // sentinel; the error path still falls back to a global rebuild.
    await Sql.withSuspendedFtsTriggers(() async {
      await Sql.withDroppedBrowseIndexes(() async {
        // fix611: one source failing must NEVER stop the rest from
        // refreshing. Each source gets up to TWO attempts (the original try +
        // one retry — distinct from xtream.dart's per-content-type retry); if
        // both fail, record it via onSourceFailed and CONTINUE to the next
        // source. The whole-batch FTS-trigger suspend + browse-index drop stay
        // owned by the outer wrappers, so a mid-loop failure still ends in the
        // single end-of-batch rebuild.
        final failures = <Source, Object>{};
        for (var i = 0; i < enabled.length; i++) {
          // fix620: stop cleanly between sources if the user cancelled. Sources
          // already refreshed keep their data + FTS (maintained per-source);
          // remaining sources are simply skipped.
          if (shouldCancel?.call() ?? false) {
            AppLog.info('Utils.refreshAllSources: cancelled by user before '
                'source ${i + 1}/${enabled.length}');
            break;
          }
          final s = enabled[i];
          onSourceStart?.call(i + 1, enabled.length, s);
          const maxAttempts = 2;
          Object? lastError;
          for (var attempt = 1; attempt <= maxAttempts; attempt++) {
            try {
              await refreshSource(
                s,
                onProgress: onSourceStatus == null
                    ? null
                    : (msg) => onSourceStatus(s, msg),
                onRowProgress: onSourceRowProgress == null
                    ? null
                    : (done, total) => onSourceRowProgress(s, done, total),
              );
              lastError = null;
              break;
            } catch (e) {
              lastError = e;
              if (attempt < maxAttempts) {
                AppLog.warn(
                  'Utils.refreshAllSources: source "${s.name}" attempt'
                  ' $attempt/$maxAttempts failed — $e; retrying',
                );
                onSourceStatus?.call(s, 'Retrying "${s.name}"...');
              }
            }
          }
          if (lastError != null) {
            failures[s] = lastError;
            AppLog.warn(
              'Utils.refreshAllSources: source "${s.name}" failed after'
              ' $maxAttempts attempt(s) — $lastError; continuing with'
              ' remaining source(s)',
            );
            onSourceFailed?.call(s, lastError);
          }
        }
        if (failures.isNotEmpty) {
          AppLog.warn(
            'Utils.refreshAllSources: ${failures.length} of'
            ' ${enabled.length} source(s) failed:'
            ' ${failures.keys.map((s) => s.name).join(", ")}',
          );
        }
      },
          // fix549: the once-at-the-end index recreate runs AFTER the loop, so
          // attribute its progress to the last source's status sink — keeps the
          // dialog updating ("Building index N/M…") through the final rebuild
          // instead of sitting frozen on the last source's "Saving…" line.
          onProgress: onSourceStatus == null || enabled.isEmpty
              ? null
              : (msg) => onSourceStatus(enabled.last, msg));
    },
        // fix621: batch "success sentinel". Its mere presence (plus body
        // success) tells withSuspendedFtsTriggers this was a batch refresh, so
        // it rebuilds the whole FTS index ONCE (DROP+repopulate) after the loop
        // instead of the per-source maintenance fix619 used. If the body
        // throws, the wrapper ignores this and does the safe global rebuild
        // instead. Kept as a closure for signature stability.
        batchTargetedRebuild: () async {});

    // fix615: checkpoint db.sqlite's WAL HERE, where the big channel write just
    // happened, instead of leaving a large WAL (wal_autocheckpoint is raised to
    // 8000 pages) for a later EPG refresh to inherit and hard-TRUNCATE at a bad
    // moment (the sms938u crash). epg.sqlite was not written by this path, so
    // skip it. Guarded so a checkpoint hiccup never fails an otherwise-good
    // refresh.
    try {
      await Sql.checkpointAndTruncateWal(epg: false);
    } catch (e) {
      AppLog.warn('Utils.refreshAllSources: post-refresh db.sqlite '
          'checkpoint failed (non-fatal) — $e');
    }
  }

  // fix580: memoized so the Player can read the resolved value synchronously at
  // build time (main.dart resolves this at startup, before any Player opens).
  static bool? _hasTouchCached;
  static bool? get hasTouchScreenCached => _hasTouchCached;

  static Future<bool> hasTouchScreen() async {
    if (_hasTouchCached != null) return _hasTouchCached!;
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      return _hasTouchCached = androidInfo.systemFeatures
          .contains('android.hardware.touchscreen');
    }
    return _hasTouchCached = true;
  }
}
