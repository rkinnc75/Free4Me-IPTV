import 'dart:io';

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/recording_capture.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/program.dart';
import 'package:open_tv/models/recording.dart';

/// fix667: schedules Scheduled Recordings (SR) — record-to-file, distinct from the app's live DVR (rewind-within-live-stream) feature.
///
/// This phase establishes the schema, the padded-window computation, and the
/// exact wall-clock alarm registration. The alarm CALLBACK is a stub that logs
/// and flips status — the actual stream capture is fix668. Split this way so
/// the (verifiable) scheduling foundation ships independently of the
/// device-only capture path.
///
/// AndroidAlarmManager is initialised once from main() (Android only). The
/// alarm id is the recording's row id, so cancelling is a direct
/// `cancel(recordingId)`.
class RecordingScheduler {
  RecordingScheduler._();

  static bool _inited = false;

  /// fix667: pure padded-window computation (unit-testable).
  /// Returns (startUtc, durationMs). The before-pad moves the start earlier;
  /// both pads extend the duration past the programme's listed end.
  static (int, int) computeWindow(
      int programmeStartUtc, int programmeStopUtc, int padBeforeMin, int padAfterMin) {
    final startUtc = programmeStartUtc - padBeforeMin * 60;
    final baseLenSec = programmeStopUtc - programmeStartUtc;
    final durationMs =
        (baseLenSec + (padBeforeMin + padAfterMin) * 60) * 1000;
    return (startUtc, durationMs);
  }

  /// Call once at startup (Android only). Safe to call repeatedly.
  static Future<void> init() async {
    if (_inited || !Platform.isAndroid) return;
    try {
      await AndroidAlarmManager.initialize();
      _inited = true;
    } catch (e) {
      AppLog.warn('RecordingScheduler: AndroidAlarmManager init failed — $e');
    }
  }

  /// Schedule a recording of [programme] on [channel], applying the global pad
  /// defaults unless [padBeforeMin]/[padAfterMin] override them. Returns the
  /// new recording id, or null if it couldn't be scheduled.
  ///
  /// Padded window:
  ///   start    = programme.startUtc - padBefore*60
  ///   duration = (stopUtc - startUtc) + (padBefore + padAfter)*60
  static Future<int?> scheduleForProgramme(
    Channel channel,
    Program programme, {
    int? padBeforeMin,
    int? padAfterMin,
  }) async {
    final s = await SettingsService.getSettings();
    final padB = (padBeforeMin ?? s.recordPadBeforeMin).clamp(0, 15);
    final padA = (padAfterMin ?? s.recordPadAfterMin).clamp(0, 240);

    final (startUtc, durationMs) =
        computeWindow(programme.startUtc, programme.stopUtc, padB, padA);
    return _schedule(channel, programme.title, startUtc, durationMs, padB, padA);
  }

  /// Schedule a manual "record now for [durationMinutes]" of [channel]. No
  /// after-pad (there's no listed end to pad from).
  static Future<int?> scheduleNow(
    Channel channel, {
    int durationMinutes = 60,
    String? title,
  }) async {
    final startUtc = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final durationMs = durationMinutes.clamp(1, 720) * 60 * 1000;
    return _schedule(
        channel, title ?? channel.name, startUtc, durationMs, 0, 0);
  }

  static Future<int?> _schedule(
    Channel channel,
    String title,
    int startUtc,
    int durationMs,
    int padBeforeMin,
    int padAfterMin,
  ) async {
    final url = channel.url;
    if (url == null || url.isEmpty) {
      AppLog.warn('RecordingScheduler: channel "${channel.name}" has no url');
      return null;
    }
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rec = Recording(
      channelId: channel.id,
      channelName: title,
      url: url,
      scheduledStartUtc: startUtc,
      durationMs: durationMs,
      padBeforeMin: padBeforeMin,
      padAfterMin: padAfterMin,
      status: RecordingStatus.scheduled,
      createdUtc: now,
    );
    final id = await Sql.insertRecording(rec);

    if (Platform.isAndroid) {
      await init();
      final fireAt = DateTime.fromMillisecondsSinceEpoch(startUtc * 1000);
      // If the start is already in the past (manual "now", or a late schedule),
      // fire almost immediately.
      final when = fireAt.isAfter(DateTime.now())
          ? fireAt
          : DateTime.now().add(const Duration(seconds: 2));
      try {
        await AndroidAlarmManager.oneShotAt(
          when,
          id,
          recordingAlarmCallback,
          exact: true,
          wakeup: true,
          allowWhileIdle: true,
          rescheduleOnReboot: true,
        );
        AppLog.info('RecordingScheduler: scheduled recording $id '
            '"$title" at $when (durationMs=$durationMs)');
      } catch (e) {
        AppLog.warn('RecordingScheduler: alarm registration failed — $e');
        await Sql.updateRecordingStatus(id, RecordingStatus.failed,
            error: 'Could not register alarm: $e');
        return id;
      }
    }
    return id;
  }

  /// Cancel a scheduled recording (removes the alarm + marks cancelled).
  static Future<void> cancel(int recordingId) async {
    if (Platform.isAndroid) {
      try {
        await AndroidAlarmManager.cancel(recordingId);
      } catch (e) {
        AppLog.warn('RecordingScheduler: cancel alarm failed — $e');
      }
    }
    await Sql.updateRecordingStatus(recordingId, RecordingStatus.cancelled);
  }
}

/// fix667: alarm entry point — runs in a BACKGROUND isolate at the scheduled
/// time. STUB for this phase: it only marks the recording as started, so the
/// scheduling path is verifiable end-to-end without the capture engine. The
/// real HTTP-stream capture is wired here in fix668.
@pragma('vm:entry-point')
Future<void> recordingAlarmCallback(int recordingId) async {
  // fix668: runs in the alarm's background isolate at the padded start time.
  // The alarm's wakelock only covers this short window, so we DON'T capture
  // here — we look up the row and hand off to the native
  // RecordingCaptureService (its own foreground service + wakelock survive the
  // full duration and Doze). The native side writes done/failed back to the
  // recordings row. No app state in this isolate, so everything goes via DB.
  try {
    final rec = await Sql.getRecordingById(recordingId);
    if (rec == null) {
      AppLog.warn('recordingAlarmCallback: recording $recordingId not found');
      return;
    }
    if (rec.status == RecordingStatus.cancelled) {
      AppLog.info('recordingAlarmCallback: $recordingId was cancelled; skipping');
      return;
    }
    await Sql.updateRecordingStatus(recordingId, RecordingStatus.recording);
    await RecordingCapture.start(
      id: recordingId,
      url: rec.url,
      durationMs: rec.durationMs,
      name: rec.channelName,
    );
    AppLog.info('recordingAlarmCallback: started capture $recordingId '
        '("${rec.channelName}", durationMs=${rec.durationMs})');
  } catch (e) {
    AppLog.warn('recordingAlarmCallback: $recordingId failed — $e');
    // Best-effort: mark failed so the UI doesn't show a stuck "recording".
    try {
      await Sql.updateRecordingStatus(recordingId, RecordingStatus.failed,
          error: 'Failed to start capture: $e');
    } catch (_) {}
  }
}
