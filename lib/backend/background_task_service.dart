import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:open_tv/backend/app_logger.dart';

/// fix318: thin wrapper around flutter_foreground_task used to keep long
/// operations (currently source refresh) alive when the user switches away
/// from the app on Android.
///
/// Design notes:
/// - The actual work keeps running on the MAIN isolate (we do NOT move the DB
///   / media_kit / cache singletons into a background isolate). The foreground
///   service exists only to promote the process so Android does not suspend it
///   while backgrounded, and to show a progress notification.
/// - Best-effort: if the service can't start (permission denied, non-Android,
///   plugin error) the caller still runs the work in the foreground as before.
///   Nothing here should throw into the caller.
class BackgroundTaskService {
  const BackgroundTaskService._();

  static bool _inited = false;

  static Future<void> _ensureInit() async {
    if (_inited || !Platform.isAndroid) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'free4me_background',
        channelName: 'Background processing',
        channelDescription:
            'Keeps refreshes running when the app is in the background.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _inited = true;
  }

  /// Run [work] with a foreground service active for its duration when
  /// [enabled] (the user's backgroundProcessing setting) is true on Android.
  /// [title] is the notification title; [work] receives an `update(text)`
  /// callback to refresh the notification body with progress. The service is
  /// always stopped when [work] completes or throws.
  static Future<T> run<T>({
    required bool enabled,
    required String title,
    required Future<T> Function(void Function(String text) update) work,
  }) async {
    final useService = enabled && Platform.isAndroid;
    if (!useService) {
      // No service — just run the work (foreground-only, prior behaviour).
      return work((_) {});
    }
    var started = false;
    try {
      await _ensureInit();
      // fix322: capture WHY the service fails on some devices. Log the
      // notification-permission result and the startService outcome so the
      // background feature can be diagnosed from the debug log (observed
      // "startService not successful" with no detail on a real TV box).
      try {
        final perm =
            await FlutterForegroundTask.requestNotificationPermission();
        AppLog.info('BackgroundTaskService: notification permission = $perm');
      } catch (e) {
        AppLog.warn(
          'BackgroundTaskService: notification permission request failed — $e',
        );
      }
      final res = await FlutterForegroundTask.startService(
        notificationTitle: title,
        notificationText: 'Starting…',
      );
      started = res is ServiceRequestSuccess;
      if (!started) {
        AppLog.warn(
          'BackgroundTaskService: startService not successful '
          '(result=$res) — running in foreground only. The refresh will not '
          'survive switching away on this device.',
        );
      }
      if (started) {
        AppLog.info('BackgroundTaskService: started — "$title"');
      }
    } catch (e) {
      AppLog.warn('BackgroundTaskService: start failed ($e) — '
          'running in foreground only');
      started = false;
    }

    void update(String text) {
      if (!started) return;
      try {
        FlutterForegroundTask.updateService(
          notificationTitle: title,
          notificationText: text,
        );
      } catch (_) {}
    }

    try {
      return await work(update);
    } finally {
      if (started) {
        try {
          await FlutterForegroundTask.stopService();
          AppLog.info('BackgroundTaskService: stopped — "$title"');
        } catch (e) {
          AppLog.warn('BackgroundTaskService: stopService failed — $e');
        }
      }
    }
  }
}
