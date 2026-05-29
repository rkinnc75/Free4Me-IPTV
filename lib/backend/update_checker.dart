import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/http_client.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateChecker {
  static const String _versionUrl =
      'https://raw.githubusercontent.com/rkinnc75/Free4Me-IPTV/main/version.json';

  /// Normal check interval. When debug logging is enabled, shortened to 1 hour
  /// so developers can verify the flow without waiting 12 hours.
  static Duration get _checkInterval =>
      AppLog.enabled ? const Duration(hours: 1) : const Duration(hours: 12);

  static const String _cacheFilename = 'update_check_cache.json';


  /// Called once on app launch. Respects the throttle interval; silent on error.
  static Future<void> checkOnLaunch(BuildContext context) async {
    AppLog.info('UpdateChecker: launch check triggered');
    try {
      if (!await _shouldCheck()) {
        AppLog.info('UpdateChecker: skipped — checked recently');
        return;
      }
      // ignore: use_build_context_synchronously
      await _runCheck(context, showUpToDate: false);
    } catch (e) {
      AppLog.warn('UpdateChecker: unexpected error — $e');
    }
  }

  /// Called when the user taps "Check for updates" in Settings.
  /// Always bypasses the throttle and shows "You're up to date" if current.
  static Future<void> checkNow(BuildContext context) async {
    AppLog.info('UpdateChecker: manual check triggered');
    try {
      await _runCheck(context, showUpToDate: true);
    } catch (e) {
      AppLog.warn('UpdateChecker: manual check error — $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update check failed: $e')),
        );
      }
    }
  }


  static Future<void> _runCheck(
    BuildContext context, {
    required bool showUpToDate,
  }) async {
    AppLog.info('UpdateChecker: fetching $_versionUrl');
    final info = await _fetchVersionInfo();
    await _saveCacheTimestamp();

    if (info == null) {
      AppLog.warn('UpdateChecker: fetch returned null (network error or non-200)');
      if (showUpToDate && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not reach update server — check your connection'),
          ),
        );
      }
      return;
    }

    final packageInfo = await PackageInfo.fromPlatform();
    final remote = info['latest'] as String? ?? '';
    final local = packageInfo.version;
    AppLog.info('UpdateChecker: remote=$remote local=$local');

    if (_isNewer(remote, local)) {
      AppLog.info('UpdateChecker: update available ($local → $remote)');
      if (context.mounted) _showUpdateDialog(context, info, local);
    } else {
      AppLog.info('UpdateChecker: already on latest');
      if (showUpToDate && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Free4Me-IPTV $local is up to date')),
        );
      }
    }
  }

  static Future<bool> _shouldCheck() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) {
        AppLog.info('UpdateChecker: no cache file — will check');
        return true;
      }
      final raw = await file.readAsString();
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final lastCheck = DateTime.fromMillisecondsSinceEpoch(
        (map['ts'] as num).toInt(),
      );
      final elapsed = DateTime.now().difference(lastCheck);
      final interval = _checkInterval;
      AppLog.info(
        'UpdateChecker: last check ${elapsed.inMinutes}m ago '
        '(interval ${interval.inMinutes}m)',
      );
      return elapsed > interval;
    } catch (e) {
      AppLog.warn('UpdateChecker: cache read error — $e — will check');
      return true;
    }
  }

  static Future<Map<String, dynamic>?> _fetchVersionInfo() async {
    final uri = Uri.tryParse(_versionUrl);
    if (uri == null) {
      AppLog.warn('UpdateChecker: invalid URL');
      return null;
    }
    final response = await AppHttp.getWithRetry(
      uri,
      timeout: const Duration(seconds: 5),
    );
    if (response == null) {
      AppLog.warn('UpdateChecker: HTTP request returned null');
      return null;
    }
    AppLog.info('UpdateChecker: HTTP ${response.statusCode}');
    if (response.statusCode != 200) return null;
    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      AppLog.warn('UpdateChecker: JSON parse error — $e');
      AppLog.info('UpdateChecker: body was: ${response.body.substring(0, response.body.length.clamp(0, 200))}');
      return null;
    }
  }

  static Future<void> _saveCacheTimestamp() async {
    try {
      final file = await _cacheFile();
      await file.writeAsString(
        jsonEncode({'ts': DateTime.now().millisecondsSinceEpoch}),
      );
      AppLog.info('UpdateChecker: cache timestamp saved');
    } catch (e) {
      AppLog.warn('UpdateChecker: failed to save cache — $e');
    }
  }

  static Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_cacheFilename');
  }

  static bool _isNewer(String remote, String local) {
    final r = _parseSemver(remote);
    final l = _parseSemver(local);
    for (var i = 0; i < 3; i++) {
      if (r[i] > l[i]) return true;
      if (r[i] < l[i]) return false;
    }
    return false;
  }

  static List<int> _parseSemver(String v) {
    final parts = v
        .split('.')
        .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return parts;
  }

  static void _showUpdateDialog(
    BuildContext context,
    Map<String, dynamic> info,
    String localVersion,
  ) {
    final remoteVersion = info['latest'] as String? ?? '';
    final notes = info['releaseNotes'] as String?;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update available'),
        content: Text(
          'v$localVersion → v$remoteVersion'
          '${notes != null && notes.isNotEmpty ? '\n\n$notes' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Skip'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final rawUrl = info['releaseUrl'] as String?;
              if (rawUrl == null) return;
              final url = Uri.tryParse(rawUrl);
              if (url != null) {
                await launchUrl(url, mode: LaunchMode.externalApplication);
              }
            },
            child: const Text('Download'),
          ),
        ],
      ),
    );
  }
}
