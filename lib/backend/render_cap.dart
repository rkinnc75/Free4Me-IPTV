import 'package:flutter/services.dart';
import 'package:open_tv/backend/app_logger.dart';

/// fix506: bridges the 1080p render-cap preference to the native side.
///
/// `MainActivity` reads the mirrored SharedPref at launch (`attachBaseContext`
/// / `onCreate`) to decide whether to downscale the FlutterSurfaceView on a
/// low-RAM 4K box. Because the cap is applied at launch, a change takes effect
/// on the NEXT app start. Best-effort — never throws into the caller.
class RenderCap {
  static const MethodChannel _channel = MethodChannel('me.free4me.iptv/render');

  static Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod('setCap', {'enabled': enabled});
    } catch (e) {
      AppLog.warn('RenderCap.setEnabled failed — $e');
    }
  }
}
