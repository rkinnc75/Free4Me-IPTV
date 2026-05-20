import 'package:flutter/services.dart';

/// Flutter-side bridge to the native PiP implementation in [MainActivity].
///
/// Supports Android 8.0+ (API 26). On older Android or non-Android platforms
/// [isSupported] returns false and all other calls are no-ops.
class PipController {
  static const _channel = MethodChannel('me.free4me.iptv/pip');
  static const _eventChannel = EventChannel('me.free4me.iptv/pip_events');

  static Stream<bool>? _pipStream;

  /// Whether PiP is available on this device (Android 8+ only).
  static Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Manually enter PiP mode. Returns false if unsupported.
  static Future<bool> enterPip() async {
    try {
      return await _channel.invokeMethod<bool>('enterPip') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Tell the native side whether video is actively playing.
  /// Must be called whenever playback starts or stops so that
  /// [onUserLeaveHint] (press-Home auto-PiP) behaves correctly.
  static Future<void> setPlaying(bool playing) async {
    try {
      await _channel.invokeMethod<void>('setPlaying', {'playing': playing});
    } catch (_) {}
  }

  /// Stream of PiP mode changes. Emits `true` when entering PiP and
  /// `false` when returning to full-screen.
  static Stream<bool> get pipModeStream {
    _pipStream ??= _eventChannel
        .receiveBroadcastStream()
        .map((event) => event as bool);
    return _pipStream!;
  }
}
