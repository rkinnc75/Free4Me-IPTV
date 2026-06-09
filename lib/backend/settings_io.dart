import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel_preserve.dart';
import 'package:open_tv/models/engine_type.dart';
import 'package:open_tv/models/device_detector.dart';
import 'package:open_tv/models/engine_preference.dart';
import 'package:open_tv/models/multi_view_layout.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

const int _schemaVersion = 3;

class SettingsIo {
  /// fix166: local snapshot stamp `yyyymmdd-HHMMSS` for export filenames.
  static String exportStamp(DateTime now) {
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${p2(now.month)}${p2(now.day)}'
        '-${p2(now.hour)}${p2(now.minute)}${p2(now.second)}';
  }

  /// fix322: `<deviceTag>-<stamp>` (or just `<stamp>` when no tag) so exports
  /// from different devices don't collide / are self-identifying. e.g.
  /// `shield-20260609-131737`.
  static Future<String> stampWithDevice([DateTime? now]) async {
    final stamp = exportStamp(now ?? DateTime.now());
    final tag = await DeviceDetector.deviceTag();
    return tag.isEmpty ? stamp : '$tag-$stamp';
  }

  /// Channel-attribute restores staged by importFromFile, keyed by
  /// source name. Consumed by applyPendingPreserves once channel
  /// rows are populated by the first source refresh.
  ///
  /// In-memory only — if the app is killed before refresh runs, the
  /// entries are lost (the backup file itself is still on disk so
  /// the user can re-import). Persisting to SQLite is possible but
  /// adds schema-migration work; not worth it for a rare edge case.
  static final Map<String, List<ChannelPreserve>> _pendingPreserves = {};

  /// Export all sources + settings to a JSON file chosen by the user.
  /// [includeCredentials] controls whether Xtream username/password are written.
  // fix158: extracted so TV export can build the payload without FilePicker.
  static Future<String> buildBackupPayload({
    bool includeCredentials = false,
  }) async {
    final packageInfo = await PackageInfo.fromPlatform();
    final settings = await SettingsService.getSettings();
    final sources = await Sql.getSources();

    final sourcesPayload = <Map<String, dynamic>>[];
    for (final s in sources) {
      final base = _sourceToMap(s, includeCredentials);
      if (s.id != null) {
        final preserve = await Sql.getChannelsPreserve(s.id!);
        if (preserve.isNotEmpty) {
          base['preserve'] = preserve
              .map((p) => {
                    'name': p.name,
                    if (p.favorite != null) 'favorite': p.favorite,
                    if (p.lastWatched != null) 'lastWatched': p.lastWatched,
                    if (p.epgChannelId != null) 'epgChannelId': p.epgChannelId,
                    if (p.epgManualOverride != null)
                      'epgManualOverride': p.epgManualOverride,
                  })
              .toList();
        }
      }
      sourcesPayload.add(base);
    }

    return jsonEncode({
      'schemaVersion': _schemaVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'appVersion': packageInfo.version,
      'settings': _settingsToMap(settings),
      'sources': sourcesPayload,
    });
  }

  static Future<void> exportToFile(
    BuildContext context, {
    bool includeCredentials = false,
  }) async {
    final packageInfo = await PackageInfo.fromPlatform();
    final settings = await SettingsService.getSettings();
    final sources = await Sql.getSources();

    AppLog.info(
      'SettingsIo.export: schema=$_schemaVersion'
      ' sources=${sources.length}'
      ' multiViewLayout=${settings.multiViewLayout.name}'
      ' multiViewCells1x2="${settings.multiViewCells1x2}"'
      ' multiViewCells2x2="${settings.multiViewCells2x2}"'
      ' multiViewAutoRestoreChannels=${settings.multiViewAutoRestoreChannels}',
    );

    // For each source, capture the per-channel attributes worth
    // round-tripping (favorite flag + last-watched timestamp). Keyed
    // by channel name — restorePreserve matches on (name, source_id)
    // after a refresh repopulates the channel table.
    final sourcesPayload = <Map<String, dynamic>>[];
    for (final s in sources) {
      final base = _sourceToMap(s, includeCredentials);
      if (s.id != null) {
        final preserve = await Sql.getChannelsPreserve(s.id!);
        if (preserve.isNotEmpty) {
          base['preserve'] = preserve
              .map((p) => {
                    'name': p.name,
                    if (p.favorite != null) 'favorite': p.favorite,
                    if (p.lastWatched != null) 'lastWatched': p.lastWatched,
                    // preserves matched channel IDs across source refresh.
                    if (p.epgChannelId != null) 'epgChannelId': p.epgChannelId,
                    if (p.epgManualOverride != null)
                      'epgManualOverride': p.epgManualOverride,
                  })
              .toList();
        }
      }
      sourcesPayload.add(base);
    }

    final payload = jsonEncode({
      'schemaVersion': _schemaVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'appVersion': packageInfo.version,
      'settings': _settingsToMap(settings),
      'sources': sourcesPayload,
    });

    final stamp = await stampWithDevice(); // fix166/fix322
    final dir = await getTemporaryDirectory();
    final tmpFile = File('${dir.path}/free4me-backup-$stamp.json');
    await tmpFile.writeAsString(payload);

    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Free4Me-IPTV backup',
      fileName: 'free4me-backup-$stamp.json',
      bytes: tmpFile.readAsBytesSync(),
    );

    await tmpFile.delete().catchError((_) => tmpFile);

    if (result != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup exported successfully')),
      );
    }
  }

  /// Import settings and sources from a user-selected JSON file.
  /// Returns `true` if the payload was successfully applied; `false`
  /// on user cancel, parse failure, or version mismatch. Callers are
  /// expected to fire `Utils.refreshAllSources()` themselves when the
  /// return value is true — kept here as a separate call so this
  /// module doesn't have to import `utils.dart` (which would create
  /// an import cycle, since utils.dart imports this module for
  /// `applyPendingPreserves`).
  /// fix317: import ONLY the sources from a backup payload, merging them into
  /// the existing source list (by name) and skipping all other settings —
  /// device-specific values (buffering, decode, multi-view, etc.) should not be
  /// carried across devices. Returns the number of sources imported, or -1 on
  /// a parse/schema error. Channel preserves (favorites/history/EPG ids) are
  /// staged for re-application after the next refresh, exactly like a full
  /// import. The caller is responsible for triggering the source refresh.
  static Future<int> importSourcesOnly(List<int> jsonBytes) async {
    final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(utf8.decode(jsonBytes)) as Map<String, dynamic>;
    } catch (e) {
      AppLog.warn('SettingsIo.importSourcesOnly: parse failed — $e');
      return -1;
    }
    final version = payload['schemaVersion'] as int? ?? 0;
    if (version > _schemaVersion) {
      AppLog.warn(
        'SettingsIo.importSourcesOnly: backup schema v$version newer than '
        'app schema v$_schemaVersion — refusing',
      );
      return -1;
    }
    final rawSources = payload['sources'] as List<dynamic>?;
    if (rawSources == null || rawSources.isEmpty) {
      AppLog.warn('SettingsIo.importSourcesOnly: no sources in payload');
      return 0;
    }
    var count = 0;
    for (final raw in rawSources) {
      final map = raw as Map<String, dynamic>;
      final source = Source(
        name: map['name'] as String,
        url: map['url'] as String?,
        username: map['username'] as String?,
        password: map['password'] as String?,
        sourceType: SourceType.values[map['sourceType'] as int? ?? 0],
        enabled: map['enabled'] as bool? ?? true,
        epgUrl: map['epgUrl'] as String?,
        defaultEngine: EngineType.fromJson(map['defaultEngine'] as String?),
      );
      // getOrCreateSourceByName merges by name — existing sources are reused,
      // new ones created. Other settings are intentionally NOT touched.
      await Sql.commitWrite([Sql.getOrCreateSourceByName(source)]);
      count++;
      AppLog.info(
        'SettingsIo.importSourcesOnly: source "${source.name}"'
        ' type=${source.sourceType.name} enabled=${source.enabled}',
      );
      final preserveRaw = map['preserve'] as List<dynamic>?;
      if (preserveRaw != null && preserveRaw.isNotEmpty) {
        _pendingPreserves[source.name] = preserveRaw
            .map((p) {
              final m = p as Map<String, dynamic>;
              return ChannelPreserve(
                name: m['name'] as String,
                favorite: m['favorite'] as int?,
                lastWatched: m['lastWatched'] as int?,
                epgChannelId: m['epgChannelId'] as String?,
                epgManualOverride: m['epgManualOverride'] as String?,
              );
            })
            .toList();
      }
    }
    AppLog.info('SettingsIo.importSourcesOnly: imported $count source(s)');
    return count;
  }

  static Future<bool> importFromFile(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (result == null || result.files.single.bytes == null) return false;

    final raw = utf8.decode(result.files.single.bytes!);
    final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invalid backup file — could not parse JSON'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return false;
    }

    final version = payload['schemaVersion'] as int? ?? 0;
    if (version > _schemaVersion) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Backup was created by a newer version of the app '
              '(schema v$version). Please update the app first.',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
      return false;
    }

    // Show confirmation before applying.
    if (context.mounted) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Import backup?'),
          content: Text(
            'Exported: ${payload['exportedAt'] ?? 'unknown'}\n'
            'App version: ${payload['appVersion'] ?? 'unknown'}\n\n'
            'This will overwrite your current settings and replace all sources.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Import'),
            ),
          ],
        ),
      );
      if (confirmed != true) return false;
    }

    try {
      if (payload['settings'] != null) {
        final rawSettings = payload['settings'] as Map<String, dynamic>;
        final settings = _settingsFromMap(rawSettings);

        // what _settingsFromMap produced. If a v2 backup is imported,
        // the multi-view fields are absent from rawSettings and the
        // resulting settings hold constructor defaults. That's expected
        // and not a bug — the old backup simply doesn't carry that data.
        AppLog.info(
          'SettingsIo.import: schemaVersion=${payload['schemaVersion']}'
          ' appVersion=${payload['appVersion']}'
          ' payload-has-multiViewLayout=${rawSettings.containsKey('multiViewLayout')}'
          ' payload-multiViewLayout=${rawSettings['multiViewLayout']}'
          ' parsed-multiViewLayout=${settings.multiViewLayout.name}'
          ' parsed-cells1x2="${settings.multiViewCells1x2}"'
          ' parsed-cells2x2="${settings.multiViewCells2x2}"'
          ' parsed-autoRestore=${settings.multiViewAutoRestoreChannels}',
        );

        await SettingsService.updateSettings(settings);
        // the import session is captured. Without this, a fresh
        // install that imports a backup with debugLogging=true
        // produces an empty log file for the entire first session.
        await AppLog.setEnabled(settings.debugLogging);
      }

      if (payload['sources'] != null) {
        final rawSources = payload['sources'] as List<dynamic>;
        for (final raw in rawSources) {
          final map = raw as Map<String, dynamic>;
          final source = Source(
            name: map['name'] as String,
            url: map['url'] as String?,
            username: map['username'] as String?,
            password: map['password'] as String?,
            sourceType: SourceType.values[map['sourceType'] as int? ?? 0],
            enabled: map['enabled'] as bool? ?? true,
            epgUrl: map['epgUrl'] as String?,
            defaultEngine: EngineType.fromJson(map['defaultEngine'] as String?),
          );
          await Sql.commitWrite([Sql.getOrCreateSourceByName(source)]);

          AppLog.info(
            'SettingsIo.import: source "${source.name}"'
            ' enabled=${source.enabled}'
            ' type=${source.sourceType.name}'
            ' engine=${source.defaultEngine?.toJson() ?? "auto"}',
          );

          // Stage favorites / last-watched for re-application after the
          // first refresh populates channels for this source. Keyed by
          // source name because IDs differ between export and import
          // databases; names are the only stable identifier across the
          // boundary.
          final preserveRaw = map['preserve'] as List<dynamic>?;
          if (preserveRaw != null && preserveRaw.isNotEmpty) {
            final preserveList = preserveRaw
                .map((p) {
                  final m = p as Map<String, dynamic>;
                  return ChannelPreserve(
                    name: m['name'] as String,
                    favorite: m['favorite'] as int?,
                    lastWatched: m['lastWatched'] as int?,
                    epgChannelId: m['epgChannelId'] as String?,
                    epgManualOverride: m['epgManualOverride'] as String?,
                  );
                })
                .toList();
            _pendingPreserves[source.name] = preserveList;
            AppLog.info(
              'SettingsIo.import: staged preserves for "${source.name}"'
              ' total=${preserveList.length}'
              ' epg=${preserveList.where((p) => p.epgChannelId != null).length}'
              ' favorites=${preserveList.where((p) => p.favorite == 1).length}',
            );
          }
        }
      }

      // feedback (the new showSourcesRefreshDialog supersedes the
      // old "Refreshing in the background…" snackbar — the dialog
      // is what the user actually sees during refresh).
      return true;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return false;
    }
  }

  /// Apply any pending channel-attribute restores for [sourceName]
  /// that were staged by a recent importFromFile call. Safe to call
  /// repeatedly; the entry is consumed and cleared on first
  /// successful match. No-op if nothing is pending.
  ///
  /// Called from Utils.refreshSource after channels are populated.
  static Future<void> applyPendingPreserves(String sourceName) async {
    final preserve = _pendingPreserves.remove(sourceName);
    if (preserve == null || preserve.isEmpty) {
      AppLog.info(
        'SettingsIo.applyPendingPreserves: no staged preserves'
        ' for "$sourceName" — skipping',
      );
      return;
    }

    final sources = await Sql.getSources();
    Source? source;
    for (final s in sources) {
      if (s.name == sourceName) {
        source = s;
        break;
      }
    }
    if (source == null || source.id == null) {
      AppLog.warn(
        'SettingsIo.applyPendingPreserves: source "$sourceName" not found'
        ' in DB — dropping ${preserve.length} staged preserves',
      );
      return;
    }

    AppLog.info(
      'SettingsIo.applyPendingPreserves: applying ${preserve.length}'
      ' preserves to "$sourceName" (sourceId=${source.id})'
      ' epg=${preserve.where((p) => p.epgChannelId != null).length}'
      ' favorites=${preserve.where((p) => p.favorite == 1).length}',
    );
    await Sql.commitWrite(
      [Sql.restorePreserve(preserve)],
      memory: {'sourceId': source.id!.toString()},
    );
    await Sql.checkpointAndTruncateWal();
    AppLog.info(
      'SettingsIo.applyPendingPreserves: done for "$sourceName"',
    );
  }

  static Map<String, dynamic> _settingsToMap(Settings s) => {
        'defaultView': s.defaultView.index,
        'refreshOnStart': s.refreshOnStart,
        'showLivestreams': s.showLivestreams,
        'showMovies': s.showMovies,
        'showSeries': s.showSeries,
        'forceTVMode': s.forceTVMode,
        'lowLatency': s.lowLatency,
        'hwDecode': s.hwDecode,
        'preWarmOnFocus': s.preWarmOnFocus,
        'backgroundProcessing': s.backgroundProcessing, // fix318
        'liveCacheSecs': s.liveCacheSecs,
        'liveDemuxerMaxMB': s.liveDemuxerMaxMB,
        'vodCacheSecs': s.vodCacheSecs,
        'vodDemuxerMaxMB': s.vodDemuxerMaxMB,
        'openTimeoutSecs': s.openTimeoutSecs,
        'bufferingWatchdogSecs': s.bufferingWatchdogSecs,
        'stableThresholdSecs': s.stableThresholdSecs,
        'forcedEngine': s.forcedEngine.toJson(),
        'enginePreference': s.enginePreference.toJson(), // fix315
        // EPG & debug (schema v2)
        'debugLogging': s.debugLogging,
        'epgAutoRefresh': s.epgAutoRefresh,
        'epgRefreshHours': s.epgRefreshHours,
        'epgRefreshHour': s.epgRefreshHour,
        'epgPastDays': s.epgPastDays,
        'epgForecastDays': s.epgForecastDays,
        // Schema v3 additions:
        'startupGraceMs': s.startupGraceMs,
        'miniDemuxerMaxMB': s.miniDemuxerMaxMB,
        'bufferSizeMB': s.bufferSizeMB,
        'streamCompletedDelayMs': s.streamCompletedDelayMs,
        'maxReconnectAttempts': s.maxReconnectAttempts,
        'streamScanMaxCount': s.streamScanMaxCount,
        'streamScanTimeoutSecs': s.streamScanTimeoutSecs,
        'multiViewLayout': s.multiViewLayout.toJson(),
        'multiViewCells1x2': s.multiViewCells1x2,
        'multiViewCells2x2': s.multiViewCells2x2,
        'multiViewAutoRestoreChannels': s.multiViewAutoRestoreChannels,
        'contentTypeFilter': s.contentTypeFilter.index,
        'searchMethod': s.searchMethod.index,
        'safeMode': s.safeMode,
      };

  static Settings _settingsFromMap(Map<String, dynamic> m) {
    // Construct with v2 fields first, then overlay v3 additions.
    // Missing v3 fields silently fall back to constructor defaults,
    // which matches user expectation when restoring a v2 backup.
    final s = Settings(
      defaultView: ViewType.values[m['defaultView'] as int? ?? 0],
      refreshOnStart: m['refreshOnStart'] as bool? ?? false,
      showLivestreams: m['showLivestreams'] as bool? ?? true,
      showMovies: m['showMovies'] as bool? ?? true,
      showSeries: m['showSeries'] as bool? ?? true,
      forceTVMode: m['forceTVMode'] as bool? ?? false,
      lowLatency: m['lowLatency'] as bool? ?? false,
      hwDecode: m['hwDecode'] as bool? ?? true,
      preWarmOnFocus: m['preWarmOnFocus'] as bool? ?? true,
      backgroundProcessing: m['backgroundProcessing'] as bool? ?? false,
      liveCacheSecs: m['liveCacheSecs'] as int? ?? 20,
      liveDemuxerMaxMB: m['liveDemuxerMaxMB'] as int? ?? 150,
      vodCacheSecs: m['vodCacheSecs'] as int? ?? 60,
      vodDemuxerMaxMB: m['vodDemuxerMaxMB'] as int? ?? 256,
      openTimeoutSecs: m['openTimeoutSecs'] as int? ?? 15,
      bufferingWatchdogSecs: m['bufferingWatchdogSecs'] as int? ?? 12,
      stableThresholdSecs: m['stableThresholdSecs'] as int? ?? 30,
      forcedEngine: EngineType.fromJson(m['forcedEngine'] as String?),
      enginePreference:
          EnginePreference.fromJson(m['enginePreference'] as String?),
      debugLogging: m['debugLogging'] as bool? ?? false,
      epgAutoRefresh: m['epgAutoRefresh'] as bool? ?? true,
      epgRefreshHours: m['epgRefreshHours'] as int? ?? 24,
      epgRefreshHour: m['epgRefreshHour'] as int? ?? 3,
      epgPastDays: m['epgPastDays'] as int? ?? 1,
      epgForecastDays: m['epgForecastDays'] as int? ?? 7,
    );

    if (m['startupGraceMs'] is int) s.startupGraceMs = m['startupGraceMs'];
    if (m['miniDemuxerMaxMB'] is int) s.miniDemuxerMaxMB = m['miniDemuxerMaxMB'];
    if (m['bufferSizeMB'] is int) s.bufferSizeMB = m['bufferSizeMB'];
    if (m['streamCompletedDelayMs'] is int) {
      s.streamCompletedDelayMs = m['streamCompletedDelayMs'];
    }
    if (m['maxReconnectAttempts'] is int) {
      s.maxReconnectAttempts = m['maxReconnectAttempts'];
    }
    if (m['streamScanMaxCount'] is int) {
      s.streamScanMaxCount = m['streamScanMaxCount'];
    }
    if (m['streamScanTimeoutSecs'] is int) {
      s.streamScanTimeoutSecs = m['streamScanTimeoutSecs'];
    }
    if (m['multiViewLayout'] is String) {
      s.multiViewLayout = MultiViewLayout.fromJson(m['multiViewLayout']);
    }
    if (m['multiViewCells1x2'] is String) {
      s.multiViewCells1x2 = m['multiViewCells1x2'];
    }
    if (m['multiViewCells2x2'] is String) {
      s.multiViewCells2x2 = m['multiViewCells2x2'];
    }
    if (m['multiViewAutoRestoreChannels'] is bool) {
      s.multiViewAutoRestoreChannels = m['multiViewAutoRestoreChannels'];
    }
    if (m['contentTypeFilter'] is int) {
      final idx = m['contentTypeFilter'] as int;
      final parsed = ContentTypeFilter.values.elementAtOrNull(idx)
          ?? ContentTypeFilter.all;
      // Validate against enabled content types.
      final available = s.availableContentFilters();
      s.contentTypeFilter =
          available.contains(parsed) ? parsed : ContentTypeFilter.all;
    }
    if (m['searchMethod'] is int) {
      s.searchMethod = SearchMethod.values
              .elementAtOrNull(m['searchMethod'] as int) ??
          SearchMethod.inMemory;
    }
    if (m['safeMode'] is bool) s.safeMode = m['safeMode'];

    return s;
  }

  /// Save an arbitrary text string to a user-chosen file location.
  ///
  /// On Android/iOS, `file_picker.saveFile(bytes: ...)` writes the file via
  /// the Storage Access Framework directly and returns a SAF document URI
  /// (e.g. `/document/primary:foo.txt`) which is NOT a real filesystem path.
  /// On desktop, file_picker just returns the chosen path and we must write
  /// the bytes ourselves.
  static Future<void> exportStringToFile(
    BuildContext context, {
    required String content,
    required String suggestedName,
  }) async {
    try {
      final bytes = utf8.encode(content);
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: suggestedName,
        type: FileType.custom,
        allowedExtensions: ['txt', 'log', 'json'],
        bytes: Uint8List.fromList(bytes),
      );
      if (path == null) return;

      final isMobile =
          !kIsWeb && (Platform.isAndroid || Platform.isIOS);
      // On desktop file_picker only returns the path — we have to write.
      // On mobile file_picker has already persisted the bytes via SAF.
      if (!isMobile) {
        await File(path).writeAsBytes(bytes);
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved to $suggestedName')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  static Map<String, dynamic> _sourceToMap(
    Source s,
    bool includeCredentials,
  ) =>
      {
        'name': s.name,
        'url': s.url,
        'sourceType': s.sourceType.index,
        'username': includeCredentials ? s.username : null,
        'password': includeCredentials ? s.password : null,
        'enabled': s.enabled,
        'epgUrl': s.epgUrl,
        'defaultEngine': s.defaultEngine?.toJson(),
      };
}
