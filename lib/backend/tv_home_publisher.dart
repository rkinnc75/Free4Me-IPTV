import 'dart:io';

import 'package:flutter/services.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/device_detector.dart';

/// fix665: bridges the Android TV home-screen favorites row.
///
/// Outbound: [refresh] queries favorites (most-recently-watched first, capped
/// at the tvHomeRowCount setting) and hands them to the native
/// TvHomeChannelPublisher to publish as launcher cards; [clear] removes the row.
///
/// Inbound: the native side forwards a tapped card's deep link
/// (free4me://play/{channelId}) as a "playChannel" method call. A link that
/// launched the app before Dart bound the handler is pulled once via
/// consumePendingDeepLink. Consumers register [onPlayChannel] to route it.
class TvHomePublisher {
  TvHomePublisher._();

  static const MethodChannel _ch = MethodChannel('me.free4me.iptv/tvhome');

  /// Set by the app shell; receives a channelId to open into playback.
  static void Function(int channelId)? onPlayChannel;

  static bool _handlerBound = false;

  /// Bind the inbound handler once (app shell startup). Also pulls any deep
  /// link that arrived before binding.
  static Future<void> bind() async {
    if (_handlerBound || !Platform.isAndroid) return;
    _handlerBound = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'playChannel') {
        final id = call.arguments;
        if (id is int) onPlayChannel?.call(id);
      }
    });
    // Flush a deep link that launched the app pre-bind.
    try {
      final pending = await _ch.invokeMethod<int?>('consumePendingDeepLink');
      if (pending != null) onPlayChannel?.call(pending);
    } catch (e) {
      AppLog.warn('TvHomePublisher: consumePendingDeepLink failed — $e');
    }
  }

  /// Publish (or clear) the row to match current settings + favorites.
  /// No-op off Android TV. Best-effort — never throws to the caller.
  static Future<void> refresh() async {
    if (!Platform.isAndroid) return;
    if (!(await DeviceDetector.isTV())) return;
    try {
      final s = await SettingsService.getSettings();
      if (!s.tvHomeRowEnabled) {
        await _ch.invokeMethod('clear');
        return;
      }
      final count = s.tvHomeRowCount.clamp(1, 20);
      final favs = await Sql.getFavoritesByLastWatched(count);
      final payload = favs
          .where((c) => c.id != null)
          .map((c) => <String, Object?>{
                'id': c.id,
                'name': c.name,
                'image': c.image,
              })
          .toList();
      await _ch.invokeMethod('publish', {'favorites': payload});
      AppLog.info('TvHomePublisher: published ${payload.length} favorite(s)');
    } catch (e) {
      AppLog.warn('TvHomePublisher: refresh failed — $e');
    }
  }

  /// Explicitly clear the row (called when the user turns the feature off).
  static Future<void> clear() async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('clear');
    } catch (e) {
      AppLog.warn('TvHomePublisher: clear failed — $e');
    }
  }
}
