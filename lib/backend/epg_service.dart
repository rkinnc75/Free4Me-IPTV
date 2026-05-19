import 'dart:math' show min;

import 'package:flutter/foundation.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/epg_matcher.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/xmltv_parser.dart';
import 'package:open_tv/backend/xtream_epg.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:workmanager/workmanager.dart';

// Top-level function required by compute() — closures are not allowed.
// Matches a single batch of channels against the full EPG map in an isolate.
(Map<int, String>, MatchReport) _matchInIsolate(
  (Map<String, String>, List<Channel>) args,
) =>
    EpgMatcher.matchWithReport(args.$1, args.$2);

// How many channels to process per isolate invocation. Smaller = more frequent
// progress updates; larger = less overhead. 300 is a good balance.
const _matchBatchSize = 300;

/// Task name registered with WorkManager for background EPG refresh.
const epgBackgroundTask = 'epg_refresh';

/// Top-level WorkManager callback dispatcher.
/// Must be annotated with `@pragma('vm:entry-point')` so tree-shaking
/// doesn't remove it in release builds.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == epgBackgroundTask) {
      await EpgService.refreshAllSources(background: true);
    }
    return true;
  });
}

class EpgService {
  /// Register (or re-register) the periodic background EPG refresh task.
  static Future<void> scheduleBackgroundRefresh() async {
    final settings = await SettingsService.getSettings();
    if (!settings.epgAutoRefresh) {
      await Workmanager().cancelByUniqueName(epgBackgroundTask);
      return;
    }

    await Workmanager().registerPeriodicTask(
      epgBackgroundTask,
      epgBackgroundTask,
      frequency: Duration(hours: settings.epgRefreshHours),
      initialDelay: _delayUntilRefreshHour(settings.epgRefreshHour),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }

  /// Refresh EPG for all sources that have an EPG URL configured.
  static Future<void> refreshAllSources({bool background = false}) async {
    final sources = await Sql.getSources();
    for (final source in sources) {
      if (!source.enabled) continue;
      final epgUrl = _resolveEpgUrl(source);
      if (epgUrl == null) continue;
      await refreshSource(source, epgUrl: epgUrl, background: background);
    }
  }

  /// Refresh EPG for a single source.
  static Future<void> refreshSource(
    Source source, {
    String? epgUrl,
    bool background = false,
    void Function(XmltvProgress)? onProgress,
  }) async {
    final settings = await SettingsService.getSettings();
    final url = epgUrl ?? _resolveEpgUrl(source);
    if (source.id == null) return;
    if (url == null) {
      AppLog.warn(
        'EPG: skipping "${source.name}" — no EPG URL configured',
      );
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final windowStart = now - settings.epgPastDays * 86400;
    final windowEnd = now + settings.epgForecastDays * 86400;

    int inserted = 0;
    String? lastError;

    AppLog.info('EPG: starting refresh for "${source.name}" — $url');
    try {
      await Sql.deleteProgramsForSource(source.id!);

      final channelMap = await XmltvParser.parse(
        url: url,
        sourceId: source.id!,
        windowStartEpoch: windowStart,
        windowEndEpoch: windowEnd,
        onBatch: (batch) async {
          await Sql.insertProgramsBatch(batch);
          inserted += batch.length;
        },
        onProgress: onProgress,
      );

      // Match channels to EPG IDs.
      // Channels that already have a manual override (epg_manual_override is
      // NOT NULL) keep their assignment; auto-matcher only fills the gaps.
      final channels = await Sql.getChannelsForEpgMatching(source.id!);

      // Apply manual overrides first so the matcher sees them as already set.
      final manualOverrides = <int, String>{};
      for (final ch in channels) {
        // epg_manual_override is stored in the same column as epg_channel_id
        // for simplicity; we detect manual assignments by reading the DB
        // column directly in getChannelsForEpgMatching (col 13 = epg_manual_override).
        // For now treat any pre-existing epg_channel_id that already exists as
        // "do not overwrite" by pre-seeding the matched map.
        if (ch.epgChannelId != null && ch.id != null) {
          manualOverrides[ch.id!] = ch.epgChannelId!;
        }
      }

      // Run the matcher in batches of _matchBatchSize channels, each batch in
      // its own Dart isolate so the UI thread stays alive and we can stream
      // progress back to the caller after every batch.
      final allMatched = <int, String>{};
      final tierCounts = <MatchTier, int>{};
      final sampleUnmatched = <String>[];

      for (int i = 0; i < channels.length; i += _matchBatchSize) {
        final end = min(i + _matchBatchSize, channels.length);
        final batch = channels.sublist(i, end);

        final (batchMatched, batchReport) =
            await compute(_matchInIsolate, (channelMap, batch));

        allMatched.addAll(batchMatched);
        for (final e in batchReport.counts.entries) {
          tierCounts[e.key] = (tierCounts[e.key] ?? 0) + e.value;
        }
        if (sampleUnmatched.length < 10) {
          sampleUnmatched.addAll(
            batchReport.sampleUnmatched.take(10 - sampleUnmatched.length),
          );
        }

        onProgress?.call(XmltvProgress(
          programsInserted: inserted,
          matchingChannelsDone: end,
          matchingChannelsTotal: channels.length,
          statusMessage:
              'Matching channels: $end / ${channels.length}',
        ));
      }

      final report = MatchReport(
        counts: tierCounts,
        sampleUnmatched: sampleUnmatched,
        totalChannels: channels.length,
      );
      final autoMatched = allMatched;
      // Merge: manual overrides win; auto fills the rest
      final merged = {...autoMatched, ...manualOverrides};

      if (merged.isNotEmpty) {
        await Sql.setChannelEpgIds(merged);
      }

      AppLog.info(
        'EPG: matcher "${source.name}" — $report',
      );
      if (report.sampleUnmatched.isNotEmpty) {
        AppLog.info(
          'EPG: sample unmatched channels — '
          '${report.sampleUnmatched.map((n) => "\"$n\"").join(", ")}',
        );
      }
      AppLog.info(
        'EPG: done "${source.name}" — $inserted programs, '
        '${merged.length}/${channels.length} channels matched',
      );
      debugPrint(
        'EPG refresh done for "${source.name}": '
        '$inserted programs, ${merged.length}/${channels.length} channels matched',
      );
    } catch (e, st) {
      lastError = e.toString();
      AppLog.error('EPG: refresh failed for "${source.name}": $e');
      debugPrint('EPG refresh error for "${source.name}": $e\n$st');
    }

    await Sql.upsertEpgRefreshLog(source.id!, inserted, lastError);
  }

  /// Determines the EPG URL to use for a source:
  /// - Manual override (source.epgUrl) wins
  /// - Xtream sources fall back to their built-in XMLTV endpoint
  /// - M3U sources have no automatic EPG URL
  static String? _resolveEpgUrl(Source source) {
    if (source.epgUrl != null && source.epgUrl!.isNotEmpty) {
      return source.epgUrl;
    }
    if (source.sourceType == SourceType.xtream) {
      return XtreamEpg.xmltvUrl(source);
    }
    return null;
  }

  /// Computes how long to wait until the next occurrence of [targetHour] (local time).
  static Duration _delayUntilRefreshHour(int targetHour) {
    final now = DateTime.now();
    var next = DateTime(now.year, now.month, now.day, targetHour);
    if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
    return next.difference(now);
  }
}
