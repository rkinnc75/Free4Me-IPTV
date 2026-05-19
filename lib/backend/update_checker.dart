import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/http_client.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateChecker {
  // Replace with actual GitHub raw URL after publishing the first release.
  static const String _versionUrl =
      'https://raw.githubusercontent.com/YOUR_USER/free4me-iptv/main/version.json';

  static const Duration _checkInterval = Duration(hours: 12);
  static const String _cacheFilename = 'update_check_cache.json';

  /// Called once on app launch. Non-blocking; fails silently on any error.
  static Future<void> checkOnLaunch(BuildContext context) async {
    try {
      if (!await _shouldCheck()) return;
      final info = await _fetchVersionInfo();
      await _saveCacheTimestamp();
      if (info == null) return;
      final packageInfo = await PackageInfo.fromPlatform();
      if (_isNewer(info['latest'] as String? ?? '', packageInfo.version)) {
        if (context.mounted) _showUpdateDialog(context, info);
      }
    } catch (e) {
      debugPrint('Update check failed (non-fatal): $e');
    }
  }

  static Future<bool> _shouldCheck() async {
    try {
      final file = await _cacheFile();
      if (!await file.exists()) return true;
      final raw = await file.readAsString();
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final lastCheck = DateTime.fromMillisecondsSinceEpoch(
        (map['ts'] as num).toInt(),
      );
      return DateTime.now().difference(lastCheck) > _checkInterval;
    } catch (_) {
      return true;
    }
  }

  static Future<Map<String, dynamic>?> _fetchVersionInfo() async {
    final uri = Uri.tryParse(_versionUrl);
    if (uri == null) return null;
    final response = await AppHttp.getWithRetry(
      uri,
      timeout: const Duration(seconds: 5),
    );
    if (response == null || response.statusCode != 200) return null;
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<void> _saveCacheTimestamp() async {
    final file = await _cacheFile();
    await file.writeAsString(
      jsonEncode({'ts': DateTime.now().millisecondsSinceEpoch}),
    );
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
  ) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Update available'),
        content: Text(
          'Version ${info['latest']} is available.'
          '${info['releaseNotes'] != null ? '\n\n${info['releaseNotes']}' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Skip'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
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
