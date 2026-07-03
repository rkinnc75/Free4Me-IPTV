import 'package:flutter/services.dart';

/// fix647: TV voice search bridge.
///
/// The remote's mic button is an Assistant key — the SYSTEM consumes it and
/// the press never reaches the app, so it cannot be captured. What we CAN do:
/// launch Android's speech recognizer (RecognizerIntent) ourselves and treat
/// the recognized text as a search. Triggers:
///  - the mic button in the Search tab's field (works on every remote), and
///  - a hardware KEYCODE_SEARCH press from ANY screen, on remotes that have
///    one (handled natively in MainActivity.onKeyDown).
///
/// Flow: Dart (or the native key handler) starts the system voice dialog;
/// MainActivity delivers the recognized text back through this channel as an
/// inbound "voiceResult" call. TvShell routes it: stash [pendingQuery], switch
/// to the Search tab (rebuilt fresh under the shell's reloadGen key), and the
/// search view consumes the pending query in its init — prefilled + run, as if
/// typed. "voiceUnavailable" fires when no recognizer activity exists on the
/// device (rare on Google TV; common on de-Googled boxes).
class VoiceSearch {
  static const MethodChannel _ch = MethodChannel('me.free4me.iptv/voice');

  /// Recognized text handed from the shell to the Search tab across the tab
  /// rebuild. Consumed (nulled) by the search view.
  static String? pendingQuery;

  /// Set by TvShell. Phone mode never binds, so the native side's inbound
  /// calls are simply dropped there.
  static void Function(String text)? onResult;
  static void Function()? onUnavailable;

  static bool _bound = false;

  /// Idempotent — installs the inbound handler once.
  static void bind() {
    if (_bound) return;
    _bound = true;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'voiceResult':
          final t = (call.arguments as String?)?.trim();
          if (t != null && t.isNotEmpty) onResult?.call(t);
        case 'voiceUnavailable':
          onUnavailable?.call();
      }
    });
  }

  /// Launch the system voice-recognition dialog. The result arrives via the
  /// inbound "voiceResult" call, NOT as this future's value.
  static Future<void> start() async {
    try {
      await _ch.invokeMethod('start');
    } catch (_) {
      // Channel not registered (e.g. hot restart edge) — treat as unavailable.
      onUnavailable?.call();
    }
  }
}
