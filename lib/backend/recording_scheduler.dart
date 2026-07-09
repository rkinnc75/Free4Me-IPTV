import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/recording_capture.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/utils.dart';
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

  /// fix670: refuse to start a recording below this free-space floor (1 GB).
  static const int minFreeBytes = 1024 * 1024 * 1024;

  /// fix670: pure guard — true when [freeBytes] is known and below the floor.
  /// null (unknown) → not low → allowed. Unit-testable.
  static bool isLowSpace(int? freeBytes) =>
      freeBytes != null && freeBytes < minFreeBytes;

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
    // fix670: refuse to start a recording when free space is below the floor
    // (1 GB). A long capture can't be sized ahead of time, so this is a
    // "don't even start on a nearly-full disk" guard, not a hard cap. null
    // free-space (query failed / non-Android) is treated as "unknown → allow".
    final free = await RecordingCapture.freeBytes();
    if (isLowSpace(free)) {
      AppLog.warn('RecordingScheduler: refusing — low space '
          '(${(free ?? 0) ~/ (1024 * 1024)} MB free, floor '
          '${minFreeBytes ~/ (1024 * 1024)} MB)');
      throw const LowDiskSpaceException();
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
// fix676 (DIAGNOSTIC): plugin-free breadcrumb writer for the alarm BACKGROUND
// isolate. fix675 used debugPrint, which only reaches logcat — invisible in the
// Samsung in-app report (that reporter transmits app_log.txt only). This appends
// straight to app_log.txt with dart:io, using NO plugin, so a no-adb device still
// captures the trace. It tries Utils.appDir first (correct path when plugins work
// in this isolate) and falls back to the fixed Android app-files path
// (getApplicationSupportDirectory == context.getFilesDir on Android) so it still
// writes even if path_provider itself is the thing failing. Best-effort: any I/O
// or plugin error here is swallowed so the diagnostic never changes behavior.
// Remove with the rest of the SR diagnostics once capture is verified end-to-end.
Future<void> _srDebug(String msg) async {
  final line = '[${DateTime.now().toLocal().toString().substring(0, 19)}] '
      '[SRDBG] $msg\n';
  debugPrint(line.trimRight());
  String? dir;
  try {
    dir = await Utils.appDir;
  } catch (_) {
    // path_provider unavailable in this isolate — fall back to the fixed path.
    dir = '/data/data/me.free4me.iptv/files';
  }
  try {
    File('$dir/app_log.txt')
        .writeAsStringSync(line, mode: FileMode.append, flush: true);
  } catch (_) {
    // Last resort: try the hardcoded path directly if Utils.appDir returned a
    // path we somehow can't write.
    try {
      File('/data/data/me.free4me.iptv/files/app_log.txt')
          .writeAsStringSync(line, mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}

@pragma('vm:entry-point')
Future<void> recordingAlarmCallback(int recordingId) async {
  // fix668: runs in the alarm's background isolate at the padded start time.
  // The alarm's wakelock only covers this short window, so we DON'T capture
  // here — we look up the row and hand off to the native
  // RecordingCaptureService (its own foreground service + wakelock survive the
  // full duration and Doze). The native side writes done/failed back to the
  // recordings row. No app state in this isolate, so everything goes via DB.
  //
  // fix675 (DIAGNOSTIC): this callback runs in the alarm's BACKGROUND ISOLATE.
  // AppLog is an in-memory singleton whose _enabled/_file are per-isolate, so in
  // this isolate AppLog.info/warn silently no-op (fresh instance, logging never
  // enabled, no file handle) — which is why the on-device report log showed the
  // schedule line but NOTHING from this callback, whether it ran-and-threw or
  // never ran at all. The debugPrint("SR-CB: ...") breadcrumbs below go to
  // Android logcat (pure Dart, no plugin, always emitted), so `adb logcat -s
  // flutter` on the onn shows exactly how far this callback gets and any thrown
  // error+stack. The FIRST breadcrumb is emitted BEFORE any plugin/DB call, so
  // if plugins aren't registered in this isolate (path_provider/MethodChannel
  // MissingPluginException is the leading suspect) we still see the entry line
  // and then the throw. Remove once the SR capture path is verified end-to-end.
  await _srDebug('SR-CB: entered recordingAlarmCallback id=$recordingId');
  try {
    final rec = await Sql.getRecordingById(recordingId);
    await _srDebug('SR-CB: got row id=$recordingId '
        'rec=${rec == null ? "NULL" : "status=${rec.status.name} urlLen=${rec.url.length}"}');
    if (rec == null) {
      AppLog.warn('recordingAlarmCallback: recording $recordingId not found');
      return;
    }
    if (rec.status == RecordingStatus.cancelled) {
      await _srDebug('SR-CB: id=$recordingId cancelled; skipping');
      AppLog.info('recordingAlarmCallback: $recordingId was cancelled; skipping');
      return;
    }
    await Sql.updateRecordingStatus(recordingId, RecordingStatus.recording);
    await _srDebug('SR-CB: id=$recordingId status->recording; '
        'calling RecordingCapture.start');
    await RecordingCapture.start(
      id: recordingId,
      url: rec.url,
      durationMs: rec.durationMs,
      name: rec.channelName,
    );
    await _srDebug('SR-CB: id=$recordingId RecordingCapture.start returned OK');
    AppLog.info('recordingAlarmCallback: started capture $recordingId '
        '("${rec.channelName}", durationMs=${rec.durationMs})');
  } catch (e, st) {
    // fix675: emit the full error + stack to logcat — this is the
    // line that was invisible before (AppLog.warn no-ops in this
    // isolate). A MissingPluginException here means the alarm isolate
    // has no plugin registrant; any other throw points elsewhere.
    await _srDebug('SR-CB: id=$recordingId THREW $e\n$st');
    AppLog.warn('recordingAlarmCallback: $recordingId failed — $e');
    // Best-effort: mark failed so the UI doesn't show a stuck "recording".
    try {
      await Sql.updateRecordingStatus(recordingId, RecordingStatus.failed,
          error: 'Failed to start capture: $e');
    } catch (_) {}
  }
}

/// fix670: thrown by the scheduler when free space is below the 1 GB floor.
class LowDiskSpaceException implements Exception {
  const LowDiskSpaceException();
  @override
  String toString() => 'Not enough free space to start recording (need at least '
      '1 GB free).';
}
