import 'dart:io';

import 'package:flutter/services.dart';
import 'package:open_tv/backend/app_logger.dart';

/// fix668: thin bridge to the native RecordingCaptureService.
///
/// The service does the actual long-running HTTP-stream→MediaStore capture and
/// writes status/output_path back to the recordings row in the SQLite DB. Dart
/// only starts/stops it. Callable from the alarm isolate (the MethodChannel is
/// created lazily and the native side routes to the app process's service).
class RecordingCapture {
  RecordingCapture._();

  static const MethodChannel _ch = MethodChannel('me.free4me.iptv/recording');

  /// Start capturing [url] for [durationMs] into a file named after [name],
  /// tagged with recording [id]. No-op off Android.
  static Future<void> start({
    required int id,
    required String url,
    required int durationMs,
    required String name,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('startCapture', {
        'id': id,
        'url': url,
        'durationMs': durationMs,
        'name': name,
      });
    } catch (e) {
      AppLog.warn('RecordingCapture: startCapture($id) failed — $e');
      rethrow;
    }
  }

  /// Stop an in-progress capture (manual stop from the recordings UI).
  static Future<void> stop(int id) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('stopCapture', {'id': id});
    } catch (e) {
      AppLog.warn('RecordingCapture: stopCapture($id) failed — $e');
    }
  }

  /// fix670: free bytes on the recordings volume, or null if unavailable
  /// (non-Android, or the query failed — callers treat null as "unknown,
  /// allow").
  static Future<int?> freeBytes() async {
    if (!Platform.isAndroid) return null;
    try {
      final v = await _ch.invokeMethod<int>('getFreeBytes');
      return v;
    } catch (e) {
      AppLog.warn('RecordingCapture: getFreeBytes failed — $e');
      return null;
    }
  }
}
