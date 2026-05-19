import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/models/source_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

const int _schemaVersion = 1;

class SettingsIo {
  /// Export all sources + settings to a JSON file chosen by the user.
  /// [includeCredentials] controls whether Xtream username/password are written.
  static Future<void> exportToFile(
    BuildContext context, {
    bool includeCredentials = false,
  }) async {
    final packageInfo = await PackageInfo.fromPlatform();
    final settings = await SettingsService.getSettings();
    final sources = await Sql.getSources();

    final payload = jsonEncode({
      'schemaVersion': _schemaVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'appVersion': packageInfo.version,
      'settings': _settingsToMap(settings),
      'sources': sources.map((s) => _sourceToMap(s, includeCredentials)).toList(),
    });

    final dir = await getTemporaryDirectory();
    final tmpFile = File('${dir.path}/free4me-backup.json');
    await tmpFile.writeAsString(payload);

    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Free4Me-IPTV backup',
      fileName: 'free4me-backup.json',
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
  static Future<void> importFromFile(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (result == null || result.files.single.bytes == null) return;

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
      return;
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
      return;
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
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Import'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    try {
      if (payload['settings'] != null) {
        final settings = _settingsFromMap(
          payload['settings'] as Map<String, dynamic>,
        );
        await SettingsService.updateSettings(settings);
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
          );
          await Sql.commitWrite([Sql.getOrCreateSourceByName(source)]);
        }
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backup imported successfully')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
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
        'liveCacheSecs': s.liveCacheSecs,
        'liveDemuxerMaxMB': s.liveDemuxerMaxMB,
        'vodCacheSecs': s.vodCacheSecs,
        'vodDemuxerMaxMB': s.vodDemuxerMaxMB,
        'openTimeoutSecs': s.openTimeoutSecs,
        'bufferingWatchdogSecs': s.bufferingWatchdogSecs,
      };

  static Settings _settingsFromMap(Map<String, dynamic> m) {
    return Settings(
      defaultView: ViewType.values[m['defaultView'] as int? ?? 0],
      refreshOnStart: m['refreshOnStart'] as bool? ?? false,
      showLivestreams: m['showLivestreams'] as bool? ?? true,
      showMovies: m['showMovies'] as bool? ?? true,
      showSeries: m['showSeries'] as bool? ?? true,
      forceTVMode: m['forceTVMode'] as bool? ?? false,
      lowLatency: m['lowLatency'] as bool? ?? false,
      hwDecode: m['hwDecode'] as bool? ?? true,
      preWarmOnFocus: m['preWarmOnFocus'] as bool? ?? true,
      liveCacheSecs: m['liveCacheSecs'] as int? ?? 20,
      liveDemuxerMaxMB: m['liveDemuxerMaxMB'] as int? ?? 150,
      vodCacheSecs: m['vodCacheSecs'] as int? ?? 60,
      vodDemuxerMaxMB: m['vodDemuxerMaxMB'] as int? ?? 256,
      openTimeoutSecs: m['openTimeoutSecs'] as int? ?? 15,
      bufferingWatchdogSecs: m['bufferingWatchdogSecs'] as int? ?? 12,
    );
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
      };
}
