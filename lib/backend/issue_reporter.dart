import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/settings_io.dart';
import 'package:open_tv/models/device_detector.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// fix607: shared diagnostic-report submitter. Extracted from SettingsView so
/// both the Settings "Report an issue" flow AND the Live-TV held-OK easter egg
/// (tv_shell) build the same scrubbed payload and POST to the same Worker. The
/// Worker opens a GitHub issue + commits the log to the PRIVATE repo; the app
/// only knows the Worker URL + a low-stakes shared key (worst case if extracted:
/// rate-limited spam issues — no GitHub token exposure).
class IssueReportResult {
  final bool success;
  final String? errorMsg;
  const IssueReportResult(this.success, this.errorMsg);
}

class IssueReporter {
  static const String workerUrl =
      'https://free4me-issue-reporter.rkinnc75.workers.dev';
  static const String _appSecret =
      '1rb-1eE4WchkBDjMD6qjb_-PKVCiFKFq3JqbMIS3CIw';

  /// Build the scrubbed payload (log + scrubbed settings export + device +
  /// version + clientId) and POST it. Returns success/error — the caller owns
  /// any UI. The log is re-scrubbed at send time (belt-and-suspenders over the
  /// write-time redaction); the settings export omits credentials.
  ///
  /// SAFETY: callers must gate on `debugLogging && !logUserPass` so a log that
  /// captured raw provider credentials is never sent.
  static Future<IssueReportResult> submit({
    required String subject,
    required String details,
  }) async {
    try {
      final scrubbed = AppLog.scrubSecrets(await AppLog.readLog());
      final logB64 = base64Encode(utf8.encode(scrubbed));
      final settingsRaw =
          await SettingsIo.buildBackupPayload(includeCredentials: false);
      final settingsB64 =
          base64Encode(utf8.encode(AppLog.scrubSecrets(settingsRaw)));
      final clientId = await DeviceDetector.reportClientId();
      final device = await DeviceDetector.deviceLabel();
      final info = await PackageInfo.fromPlatform();
      final resp = await http
          .post(
            Uri.parse(workerUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'secret': _appSecret,
              'subject': subject,
              'details': details,
              'log': logB64,
              'settings': settingsB64,
              'device': device,
              'version': '${info.version}+${info.buildNumber}',
              'clientId': clientId,
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) return const IssueReportResult(true, null);
      if (resp.statusCode == 429) {
        return const IssueReportResult(
            false, "You've sent several reports recently. Please try again later.");
      }
      String detail = '';
      try {
        detail = (jsonDecode(resp.body)['error'] ?? '').toString();
      } catch (_) {}
      return IssueReportResult(
          false,
          'Submit failed (${resp.statusCode})'
          '${detail.isNotEmpty ? ': $detail' : ''}.');
    } catch (_) {
      return const IssueReportResult(false,
          'Could not reach the reporting service. Check your connection and try again.');
    }
  }
}
