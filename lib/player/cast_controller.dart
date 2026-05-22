import 'package:flutter/services.dart';
import 'package:open_tv/backend/app_logger.dart';

/// Cast state as reported by the native Cast SDK.
enum CastState {
  /// Google Play Services not available on this device.
  unavailable,
  /// Play Services present but no Chromecast devices found on the network.
  noDevices,
  /// A device was found but no session is active.
  notConnected,
  /// Connecting to a device.
  connecting,
  /// Actively casting to a Chromecast.
  connected,
}

/// Flutter-side wrapper around the native Cast MethodChannel.
///
/// The native side ([CastPlugin.kt]) implements the Cast SDK session
/// lifecycle. This class is a thin bridge that translates Flutter
/// method calls to/from the native channel.
class CastController {
  static const _channel = MethodChannel('me.free4me.iptv/cast');

  /// Returns whether Google Cast is available on this device.
  /// Returns false if Play Services are not installed (e.g. sideloaded
  /// Android TV without GMS, or non-Android platforms).
  static Future<bool> isAvailable() async {
    try {
      final result = await _channel.invokeMethod<bool>('isAvailable');
      return result ?? false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      if (AppLog.enabled) {
        AppLog.info('CastController: isAvailable failed — $e');
      }
      return false;
    }
  }

  /// Returns the current cast state.
  static Future<CastState> getState() async {
    try {
      final s = await _channel.invokeMethod<String>('getState');
      return _parseState(s);
    } catch (e) {
      if (AppLog.enabled) {
        AppLog.info('CastController: getState failed — $e');
      }
      return CastState.unavailable;
    }
  }

  /// Open the Cast device picker dialog (calls the native MediaRouter).
  /// The user selects a device; if they pick one, the native side
  /// creates a session automatically (Cast SDK behaviour).
  static Future<void> showDevicePicker() async {
    try {
      await _channel.invokeMethod<void>('showDevicePicker');
    } catch (e) {
      AppLog.warn('CastController: showDevicePicker failed — $e');
    }
  }

  /// Load and begin casting [url] to the currently connected Chromecast.
  ///
  /// [title] is shown on the TV's loading screen.
  /// [contentType] is the MIME type (e.g. 'application/x-mpegURL' for HLS,
  /// 'video/mp4' for MP4, 'application/dash+xml' for DASH).
  ///
  /// Returns false if there is no active session.
  static Future<bool> startCast({
    required String url,
    required String title,
    String contentType = 'video/mp4',
  }) async {
    try {
      await _channel.invokeMethod<void>('startCast', {
        'url': url,
        'title': title,
        'contentType': contentType,
      });
      return true;
    } on PlatformException catch (e) {
      if (e.code == 'NO_SESSION') return false;
      rethrow;
    } catch (e) {
      AppLog.warn('CastController: startCast failed — $e');
      return false;
    }
  }

  /// End the current cast session and return playback to local.
  static Future<void> stopCast() async {
    try {
      await _channel.invokeMethod<void>('stopCast');
    } catch (e) {
      AppLog.warn('CastController: stopCast failed — $e');
    }
  }

  /// Current playback position on the receiver (milliseconds).
  static Future<Duration> getPosition() async {
    try {
      final ms = await _channel.invokeMethod<int>('getPosition');
      return Duration(milliseconds: ms ?? 0);
    } catch (e) {
      if (AppLog.enabled) {
        AppLog.info('CastController: getPosition failed — $e');
      }
      return Duration.zero;
    }
  }

  /// Infer the MIME content type from a stream URL.
  static String mimeTypeFor(String url) {
    final u = url.toLowerCase().split('?').first;
    if (u.contains('.m3u8')) return 'application/x-mpegURL';
    if (u.contains('.mpd')) return 'application/dash+xml';
    if (u.endsWith('.mp4') || u.endsWith('.m4v')) return 'video/mp4';
    if (u.endsWith('.mkv')) return 'video/x-matroska';
    if (u.endsWith('.ts') || u.contains('mpeg')) return 'video/mp2t';
    return 'video/mp4';
  }

  /// Whether [url] is castable via the Default Media Receiver.
  /// MPEG-TS and RTMP are not supported by Google's default receiver.
  static bool isCastable(String url) {
    final mime = mimeTypeFor(url);
    return mime != 'video/mp2t';
  }

  static CastState _parseState(String? s) => switch (s) {
        'connected' => CastState.connected,
        'connecting' => CastState.connecting,
        'not_connected' => CastState.notConnected,
        'no_devices' => CastState.noDevices,
        _ => CastState.unavailable,
      };
}
