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
import 'package:open_tv/models/source_type.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

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
  }) async {
    refreshedSeries.clear();
    await processSource(source, true, onProgress);
    // After channels are populated, apply any favorites and last-
    // watched timestamps that an imported backup staged for this
    // source (see fix28.2 / SettingsIo.applyPendingPreserves). No-op
    // if no preserve list is pending.
    await SettingsIo.applyPendingPreserves(source.name);
    // fix68.6: rebuild in-memory search cache if it was previously populated.
    // No-op if SearchMethod.inMemory was never selected this session.
    if (ChannelSearchCache.isBuilt) {
      await ChannelSearchCache.rebuild(); // fix55: safeMode now a per-search flag
      AppLog.info(
          'ChannelSearchCache: rebuilt after source refresh (${source.name})');
    }
  }

  static Future<void> processSource(
    Source source, [
    bool wipe = false,
    void Function(String)? onProgress,
  ]) async {
    switch (source.sourceType) {
      case SourceType.m3u:
        await processM3U(source, wipe, null, onProgress);
        break;
      case SourceType.m3uUrl:
        await processM3UUrl(source, wipe, onProgress);
        break;
      case SourceType.xtream:
        await getXtream(source, wipe, onProgress);
        break;
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
  }) async {
    final enabled = (await Sql.getSources())
        .where((s) => s.enabled)
        .toList(growable: false);
    AppLog.info(
      'Utils.refreshAllSources: ${enabled.length} enabled source(s)'
      ' (${enabled.map((s) => s.name).join(", ")})',
    );

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

  static Future<bool> hasTouchScreen() async {
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      return androidInfo.systemFeatures
          .contains('android.hardware.touchscreen');
    }
    return true;
  }
}
