import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/services.dart';
import 'package:open_tv/backend/app_logger.dart';

/// fix668: thin bridge to the native RecordingCaptureService.
///
/// The service does the actual long-running HTTP-stream→MediaStore capture and
/// writes status/output_path back to the recordings row in the SQLite DB. Dart
/// only starts/stops it.
///
/// fix678: [start] is invoked from the alarm's BACKGROUND ISOLATE, whose headless
/// Flutter engine only has GeneratedPluginRegistrant (pub) plugins attached — the
/// `me.free4me.iptv/recording` MethodChannel is registered on MainActivity's
/// engine and does NOT exist there, so invoking it threw MissingPluginException
/// and every scheduled recording failed at capture start. So [start] no longer
/// uses the MethodChannel: it sends an EXPLICIT broadcast to our SrStartReceiver
/// via android_intent_plus (a pub plugin that IS attached to the background
/// engine and uses applicationContext — no Activity needed). The receiver then
/// starts RecordingCaptureService. [stop]/[freeBytes] still use the MethodChannel:
/// they are only ever called from the main (UI) isolate, where it exists.
class RecordingCapture {
  RecordingCapture._();

  static const MethodChannel _ch = MethodChannel('me.free4me.iptv/recording');

  static const String _srStartAction = 'me.free4me.iptv.SR_START';
  static const String _pkg = 'me.free4me.iptv';
  static const String _srStartComponent = 'me.free4me.iptv.SrStartReceiver';

  /// Start capturing [url] for [durationMs] into a file named after [name],
  /// tagged with recording [id]. No-op off Android. Works from the alarm
  /// background isolate (see class doc).
  static Future<void> start({
    required int id,
    required String url,
    required int durationMs,
    required String name,
    bool remux = false,
    bool debugLogging = false,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      // Explicit (package + component) broadcast so it stays private and is not
      // subject to Android O+ implicit-broadcast restrictions. The extras become
      // the Intent bundle SrStartReceiver reads. fix681: remux + debugLogging are
      // passed as extras so the native service never opens the DB (single-writer;
      // Dart owns all DB access).
      final intent = AndroidIntent(
        action: _srStartAction,
        package: _pkg,
        componentName: _srStartComponent,
        arguments: <String, dynamic>{
          'id': id,
          'url': url,
          'durationMs': durationMs,
          'name': name,
          'remux': remux,
          'debugLogging': debugLogging,
        },
      );
      await intent.sendBroadcast();
    } catch (e) {
      AppLog.warn('RecordingCapture: startCapture($id) broadcast failed — $e');
      rethrow;
    }
  }

  /// Stop an in-progress capture (manual stop from the recordings UI).
  ///
  /// fix697: [deleteFile] asks the native service to REMOVE the partial capture
  /// file when the copy stops, instead of finalizing it — used by the "Delete +
  /// remove file" choice on a still-recording row. A LIVE capture deletes the
  /// file itself after its output stream closes (no cross-isolate open-fd race,
  /// which is why Dart does not delete it here). [uri] is the row's output URI;
  /// the native ACTION_STOP handler uses it to delete the file directly when NO
  /// live capture thread exists — i.e. the capture already finished but the row
  /// is a stale "recording" (journal not yet drained), or the process was killed
  /// and restarted. Without it those cases would orphan the file.
  static Future<void> stop(int id, {bool deleteFile = false, String? uri}) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod(
          'stopCapture', {'id': id, 'deleteFile': deleteFile, 'uri': uri});
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
