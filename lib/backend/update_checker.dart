import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/http_client.dart';
import 'package:open_filex/open_filex.dart';
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

  // fix310: download the release APK with a progress dialog, then hand it to
  // the Android package installer (OpenFilex). The user confirms the system
  // install prompt and must have granted "install unknown apps" once. On any
  // failure, falls back to opening the release page in the browser.
  static Future<void> _downloadAndInstall(
    BuildContext context,
    String apkUrl,
    String version,
    String? expectedSha256,
  ) async {
    // Review finding 151: reject any non-https apkUrl (AndroidManifest sets
    // usesCleartextTraffic=true, so without this an http:// URL is honored and
    // the APK arrives over cleartext).
    final uri = Uri.tryParse(apkUrl);
    if (uri == null || uri.scheme.toLowerCase() != 'https') {
      AppLog.warn('UpdateChecker: apkUrl missing or not https — $apkUrl');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'Update rejected: download URL is not secure (https required)')),
        );
      }
      return;
    }
    final progress = ValueNotifier<double>(0);
    var cancelled = false;
    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text('Downloading v$version'),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, p, child) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: p > 0 ? p : null),
                const SizedBox(height: 12),
                Text(p > 0 ? '${(p * 100).toStringAsFixed(0)}%' : 'Starting…'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                Navigator.pop(ctx);
              },
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
    }

    File? outFile;
    final client = HttpClient(); // fix363/LOW-3: hoisted for finally
    // Review finding 151: declared in the outer scope so the integrity check
    // after the try/catch/finally can read the computed digest.
    String? actualSha;
    try {
      final dir = await getApplicationSupportDirectory();
      outFile = File('${dir.path}/Free4Me-IPTV-$version.apk');
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw 'HTTP ${response.statusCode}';
      }
      final total = response.contentLength;
      var received = 0;
      final sink = outFile.openWrite();
      // Review finding 151: compute SHA-256 incrementally so the >100MB APK is
      // never buffered in memory to verify it. crypto's DigestSink lives under
      // src/ and is NOT exported from package:crypto/crypto.dart, so capture
      // the single emitted Digest with a tiny local Sink instead.
      Digest? digest;
      final hashInput = sha256.startChunkedConversion(
        ChunkedConversionSink<Digest>.withCallback((digests) {
          if (digests.isNotEmpty) digest = digests.last;
        }),
      );
      await for (final chunk in response) {
        if (cancelled) {
          await sink.close();
          await outFile.delete().catchError((_) => outFile!);
          client.close(force: true);
          AppLog.info('UpdateChecker: download cancelled');
          return;
        }
        received += chunk.length;
        sink.add(chunk);
        hashInput.add(chunk);
        if (total > 0) progress.value = received / total;
      }
      await sink.close();
      hashInput.close();
      actualSha = digest?.toString();
      AppLog.info('UpdateChecker: downloaded $received bytes to ${outFile.path}');
    } catch (e) {
      // fix363/LOW-3: client released in finally; error path no longer leaks it.
      AppLog.warn('UpdateChecker: download failed — $e');
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop(); // dismiss progress
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: $e')),
        );
      }
      return;
    } finally {
      client.close(); // fix363/LOW-3: always release the HttpClient
    }

    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop(); // dismiss progress
    }
    // Review finding 151: verify integrity before handing the file to the
    // installer. Enforced-if-present, warn-if-absent — the currently-published
    // version.json carries no sha field, so hard-blocking on null would break
    // every existing client's update. Flip to hard-block once all releases
    // emit apkSha256.
    if (expectedSha256 != null && expectedSha256.isNotEmpty) {
      if (actualSha == null ||
          actualSha.toLowerCase() != expectedSha256.toLowerCase()) {
        AppLog.warn('UpdateChecker: SHA-256 mismatch expected=$expectedSha256 '
            'actual=$actualSha');
        await outFile.delete().catchError((_) => outFile!);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Update rejected: file integrity check failed')),
          );
        }
        return;
      }
      AppLog.info('UpdateChecker: SHA-256 verified');
    } else {
      AppLog.warn('UpdateChecker: no expected SHA-256 in version.json — '
          'installing unverified APK');
    }
    // Hand off to the Android installer. The user confirms the install prompt.
    // fix758: suppress PiP for the handoff so a video that is playing behind
    // the updater cannot pop into a picture-in-picture window on top of the
    // system install prompt (it would show the OLD version, right where the
    // user is being asked to install the NEW one). The flag is cleared when
    // the user returns to the app (native onResume) or, if the installer
    // never opened, immediately below.
    await _beginApkInstallHandoff();
    final result = await OpenFilex.open(outFile.path);
    AppLog.info('UpdateChecker: installer result ${result.type} ${result.message}');
    if (result.type != ResultType.done) {
      // The installer did not open — nothing to hand off to, so restore
      // normal PiP behaviour right away rather than waiting for onResume.
      await _endApkInstallHandoff();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not open the installer. Enable "install unknown apps" for '
              'Free4Me-IPTV in Android settings, then try again.',
            ),
          ),
        );
      }
    }
  }

  // fix758: PiP-suppression handoff around the APK install.
  //
  // Deliberately NOT removing the app task and NOT killing this process:
  // OpenFilex serves the downloaded APK to the system installer through this
  // app's own FileProvider, so the process must stay alive for the installer
  // to read the file (the real package replace kills us at the right moment).
  // All we need is to stop PiP/auto-enter from surfacing the old build over
  // the install prompt; the native side clears the flag on onResume.
  static const MethodChannel _installHandoffCh =
      MethodChannel('me.free4me.iptv/update_install');

  static Future<void> _beginApkInstallHandoff() async {
    if (!Platform.isAndroid) return;
    try {
      await _installHandoffCh.invokeMethod<void>('beginApkInstall');
    } catch (e) {
      AppLog.warn('UpdateChecker: beginApkInstall failed: $e');
    }
  }

  static Future<void> _endApkInstallHandoff() async {
    if (!Platform.isAndroid) return;
    try {
      await _installHandoffCh.invokeMethod<void>('endApkInstall');
    } catch (e) {
      AppLog.warn('UpdateChecker: endApkInstall failed: $e');
    }
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

  /// fix692: pick the smallest APK matching this device's ABI.
  ///
  /// Releases >= 4.1.0 publish four APKs and advertise them in version.json's
  /// `apkUrls` map ({arm, arm64, x64, universal}) with matching SHA-256s in
  /// `apkSha256s`. Walk the device's ABI preference order
  /// (Build.SUPPORTED_ABIS) and take the first slim APK available; fall back
  /// to the universal entry, then to the legacy single `apkUrl` (which also
  /// keeps this working against an older version.json that has no map).
  /// Returns the URL and its hash (null hash = updater skips verification,
  /// finding 151 semantics).
  static Future<(String?, String?)> _pickApk(Map<String, dynamic> info) async {
    final urls = info['apkUrls'];
    final shas = info['apkSha256s'];
    if (urls is Map) {
      String? urlFor(String key) {
        final u = urls[key];
        return (u is String && u.isNotEmpty) ? u : null;
      }

      String? shaFor(String key) {
        if (shas is! Map) return null;
        final s = shas[key];
        return (s is String && s.isNotEmpty) ? s : null;
      }

      try {
        if (Platform.isAndroid) {
          final android = await DeviceInfoPlugin().androidInfo;
          for (final abi in android.supportedAbis) {
            final key = switch (abi) {
              'arm64-v8a' => 'arm64',
              'armeabi-v7a' => 'arm',
              'x86_64' => 'x64',
              _ => null,
            };
            final url = key == null ? null : urlFor(key);
            if (url != null) {
              AppLog.info('UpdateChecker: ABI $abi → $key APK');
              return (url, shaFor(key!));
            }
          }
        }
      } catch (e) {
        AppLog.warn('UpdateChecker: ABI detection failed — $e');
      }
      final uni = urlFor('universal');
      if (uni != null) {
        AppLog.info('UpdateChecker: no ABI-specific APK — using universal');
        return (uni, shaFor('universal'));
      }
    }
    // Legacy version.json (pre-4.1.0): single apkUrl + optional apkSha256.
    return (info['apkUrl'] as String?, info['apkSha256'] as String?);
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
            autofocus: true,
            onPressed: () async {
              Navigator.pop(ctx);
              // fix310: prefer the in-app download + installer flow. Fall back
              // to opening the release page if no direct apkUrl is present.
              // fix692: ABI-aware — download the slim per-ABI APK when the
              // release publishes one (apkUrls map), else the universal/legacy.
              final (apkUrl, apkSha) = await _pickApk(info);
              final remoteVersion = info['latest'] as String? ?? '';
              if (apkUrl != null && apkUrl.isNotEmpty) {
                if (!context.mounted) return;
                await _downloadAndInstall(
                    context, apkUrl, remoteVersion, apkSha);
                return;
              }
              final rawUrl = info['releaseUrl'] as String?;
              if (rawUrl == null) return;
              final url = Uri.tryParse(rawUrl);
              if (url != null) {
                await launchUrl(url, mode: LaunchMode.externalApplication);
              }
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }
}
