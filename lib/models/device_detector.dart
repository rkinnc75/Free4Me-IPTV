import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';

class DeviceDetector {
  static final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  static Future<bool> isTV() async {
    if (Platform.isAndroid) {
      return await _isAndroidTV();
    } else if (Platform.isIOS) {
      return await _isAppleTV();
    }
    return false;
  }

  static Future<bool> _isAndroidTV() async {
    final androidInfo = await _deviceInfo.androidInfo;
    return androidInfo.systemFeatures.contains('android.software.leanback');
  }

  static Future<bool> _isAppleTV() async {
    final iosInfo = await _deviceInfo.iosInfo;
    return iosInfo.model.toLowerCase().contains('appletv') ||
        iosInfo.utsname.machine.toLowerCase().contains('appletv');
  }

  /// fix314: detect NVIDIA Tegra / Shield, where concurrent mediacodec-copy
  /// decode sessions (2×2 multi-view) corrupt colour output. Matches on
  /// manufacturer/brand/board/hardware/model so it covers Shield TV variants.
  static Future<bool> isTegra() async {
    if (!Platform.isAndroid) return false;
    try {
      final a = await _deviceInfo.androidInfo;
      final hay = [
        a.manufacturer,
        a.brand,
        a.board,
        a.hardware,
        a.model,
        a.device,
      ].map((s) => s.toLowerCase()).join('|');
      return hay.contains('tegra') ||
          hay.contains('shield') ||
          hay.contains('nvidia');
    } catch (_) {
      return false;
    }
  }

  /// fix314: human-readable Android board/SoC info for the startup diagnostic,
  /// so we can confirm Tegra detection on real hardware.
  static Future<String> boardInfo() async {
    if (!Platform.isAndroid) return 'non-android';
    try {
      final a = await _deviceInfo.androidInfo;
      return 'manufacturer=${a.manufacturer} brand=${a.brand} '
          'model=${a.model} device=${a.device} board=${a.board} '
          'hardware=${a.hardware}';
    } catch (e) {
      return 'boardInfo error: $e';
    }
  }
}
