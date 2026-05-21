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
      AppLog.info('EPG: auto-refresh disabled — cancelling background task');
      await Workmanager().cancelByUniqueName(epgBackgroundTask);
      return;
    }

    AppLog.info(
      'EPG: scheduling background refresh — '
      'interval=${settings.epgRefreshHours}h '
      'refreshHour=${settings.epgRefreshHour}',
    );
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
      final epgUrl = resolveEpgUrl(source);
      if (epgUrl == null) continue;
      await refreshSource(source, epgUrl: epgUrl, background: background);
    }
  }

  /// Step 1 — Download and parse XMLTV, insert programs.
  /// Returns the EPG channel map (epgId → display names) for use in
  /// [matchChannels], or null if the source has no EPG URL or an error occurs.
  static Future<Map<String, String>?> downloadAndParseEpg(
    Source source, {
    String? epgUrl,
    void Function(XmltvProgress)? onProgress,
  }) async {
    final settings = await SettingsService.getSettings();
    final url = epgUrl ?? resolveEpgUrl(source);
    if (source.id == null) return null;
    if (url == null) {
      AppLog.warn('EPG: skipping "${source.name}" — no EPG URL configured');
      return null;
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final windowStart = now - settings.epgPastDays * 86400;
    final windowEnd = now + settings.epgForecastDays * 86400;

    int inserted = 0;
    AppLog.info('EPG: downloading "${source.name}" — $url');
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

      AppLog.info(
          'EPG: downloaded "${source.name}" — $inserted programs');
      await Sql.upsertEpgRefreshLog(source.id!, inserted, null);
      return channelMap;
    } catch (e, st) {
      AppLog.error('EPG: download failed for "${source.name}": $e');
      debugPrint('EPG download error: $e\n$st');
      await Sql.upsertEpgRefreshLog(source.id!, 0, e.toString());
      return null;
    }
  }

  /// Step 2 — Match channels against the EPG channel map.
  ///
  /// By default (incremental mode) only channels with no existing
  /// [Channel.epgChannelId] are processed — already-matched channels are
  /// skipped entirely, making background refreshes much faster on sources
  /// with large channel lists (e.g. 90k+ channels).
  ///
  /// Pass [forceAll] = true to re-evaluate every channel regardless of
  /// existing assignments (used by the "Re-match all channels" button in
  /// Settings or after the matcher algorithm is updated).
  ///
  /// Manual overrides ([Channel.epgManualOverride] IS NOT NULL) are always
  /// preserved and never re-matched.
  static Future<void> matchChannels(
    Source source,
    Map<String, String> channelMap, {
    bool forceAll = false,
    void Function(XmltvProgress)? onProgress,
  }) async {
    if (source.id == null) return;

    final toMatch = forceAll
        ? (await Sql.getChannelsForEpgMatching(source.id!))
              .where((c) => c.epgManualOverride == null)
              .toList()
        : await Sql.getChannelsNeedingEpgMatch(source.id!);

    final manualOverrides = <int, String>{};
    for (final ch in toMatch) {
      if (ch.epgManualOverride != null && ch.id != null) {
        manualOverrides[ch.id!] = ch.epgManualOverride!;
      }
    }

    AppLog.info(
      'EPG: matching ${toMatch.length} channels'
      ' (${forceAll ? "full re-match" : "unmatched only"})'
      ' for "${source.name}"',
    );

    if (toMatch.isEmpty) {
      AppLog.info('EPG: no unmatched channels — skipping matcher');
      onProgress?.call(XmltvProgress(
        programsInserted: 0,
        matchingChannelsDone: 0,
        matchingChannelsTotal: 0,
        statusMessage: 'All channels already matched',
      ));
      return;
    }

    final allMatched = <int, String>{};
    final tierCounts = <MatchTier, int>{};
    final sampleUnmatched = <String>[];

    for (int i = 0; i < toMatch.length; i += _matchBatchSize) {
      final end = min(i + _matchBatchSize, toMatch.length);
      final batch = toMatch.sublist(i, end);

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
        programsInserted: 0,
        matchingChannelsDone: end,
        matchingChannelsTotal: toMatch.length,
        statusMessage: 'Matching channels: $end / ${toMatch.length}',
      ));
    }

    final merged = {...allMatched, ...manualOverrides};
    if (merged.isNotEmpty) {
      await Sql.setChannelEpgIds(merged);
    }

    final report = MatchReport(
      counts: tierCounts,
      sampleUnmatched: sampleUnmatched,
      totalChannels: toMatch.length,
    );
    AppLog.info('EPG: match done "${source.name}" — $report');
    if (report.sampleUnmatched.isNotEmpty) {
      AppLog.info(
        'EPG: sample unmatched — '
        '${report.sampleUnmatched.map((n) => '"$n"').join(", ")}',
      );
    }
  }

  /// Combined refresh (download + incremental match).
  ///
  /// Pass [forceRematch] = true to re-match every channel, not just
  /// unmatched ones (e.g. after an EPG feed change or matcher update).
  static Future<void> refreshSource(
    Source source, {
    String? epgUrl,
    bool background = false,
    bool forceRematch = false,
    void Function(XmltvProgress)? onProgress,
  }) async {
    final channelMap = await downloadAndParseEpg(
      source,
      epgUrl: epgUrl,
      onProgress: onProgress,
    );
    if (channelMap == null) return;
    await matchChannels(
      source,
      channelMap,
      forceAll: forceRematch,
      onProgress: onProgress,
    );
  }

  /// Determines the EPG URL to use for a source:
  /// - Manual override (source.epgUrl) wins
  /// - Xtream sources fall back to their built-in XMLTV endpoint
  /// - M3U sources have no automatic EPG URL
  static String? resolveEpgUrl(Source source) {
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
