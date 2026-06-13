import 'dart:io';

import 'package:open_tv/backend/device_memory.dart';
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

  /// fix322: a short, filename-safe device tag (e.g. "shield", "onn4kplus")
  /// so exports from different devices are distinguishable. Derived from the
  /// Android model/device; cached after first read. Empty string on failure /
  /// non-Android (callers should then omit the tag).
  /// fix325: pure filename-safe sanitizer behind [deviceTag], extracted so it
  /// can be unit-tested without a device: lowercase, strip to [a-z0-9], cap at
  /// 16 chars, empty string when nothing survives.
  static String sanitizeDeviceTag(String raw) {
    final cleaned = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (cleaned.isEmpty) return '';
    return cleaned.length > 16 ? cleaned.substring(0, 16) : cleaned;
  }

  /// fix329: a human-readable device name (e.g. "Samsung SM-S938U",
  /// "onn. 4K Plus") for display in the export portal, so the QR page
  /// identifies which device the export came from — aligning with the
  /// device-tagged filenames (deviceTag) used elsewhere. Empty on failure /
  /// non-Android. Cached after first read.
  static String? _deviceLabel;
  static Future<String> deviceLabel() async {
    if (_deviceLabel != null) return _deviceLabel!;
    if (!Platform.isAndroid) {
      _deviceLabel = '';
      return '';
    }
    try {
      final a = await _deviceInfo.androidInfo;
      final model = a.model.isNotEmpty ? a.model : a.device;
      final maker = a.manufacturer.trim();
      // Avoid "Samsung Samsung SM-..." when the model already starts with the
      // manufacturer.
      final label = (maker.isEmpty ||
              model.toLowerCase().startsWith(maker.toLowerCase()))
          ? model
          : '$maker $model';
      _deviceLabel = label.trim();
    } catch (_) {
      _deviceLabel = '';
    }
    return _deviceLabel!;
  }

  static String? _deviceTag;
  static Future<String> deviceTag() async {
    if (_deviceTag != null) return _deviceTag!;
    if (!Platform.isAndroid) {
      _deviceTag = '';
      return '';
    }
    try {
      final a = await _deviceInfo.androidInfo;
      // Prefer model, fall back to device.
      _deviceTag = sanitizeDeviceTag(a.model.isNotEmpty ? a.model : a.device);
    } catch (_) {
      _deviceTag = '';
    }
    return _deviceTag!;
  }
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

  /// fix361: a low-RAM Android TV box (e.g. onn 4K Plus, ~1.9 GB, Amlogic).
  /// Used to route multi-view preview tiles to software decode: 4 concurrent
  /// mediacodec-copy pipelines exhaust shared GPU texture memory on these
  /// devices (TEXTURE-ATTACH-FAILED). Threshold 2300 MB matches the existing
  /// ChannelSearchCache low-RAM cutoff.
  static Future<bool> isLowRamTv() async {
    if (!Platform.isAndroid) return false;
    if (!await isTV()) return false;
    return DeviceMemory.totalMb > 0 && DeviceMemory.totalMb < 2300;
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
