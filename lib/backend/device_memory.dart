import 'dart:io';

import 'package:open_tv/backend/app_logger.dart';

/// Detects device RAM at startup and computes RAM-aware buffer defaults.
///
/// Uses `/proc/meminfo` on Android; falls back to conservative defaults
/// everywhere else. Call [init] once before reading any fields.
class DeviceMemory {
  DeviceMemory._();

  /// Total physical RAM in MB. 0 = not yet initialised.
  static int totalMb = 0;

  /// Initialise once at app startup. Safe to call multiple times.
  static Future<void> init() async {
    if (totalMb > 0) return;
    try {
      if (Platform.isAndroid) {
        final lines = await File('/proc/meminfo').readAsLines();
        for (final line in lines) {
          if (line.startsWith('MemTotal:')) {
            // "MemTotal:       3936144 kB"
            final kb = int.tryParse(line.replaceAll(RegExp(r'[^0-9]'), ''));
            if (kb != null) totalMb = kb ~/ 1024;
            break;
          }
        }
      }
    } catch (e) {
      AppLog.warn('DeviceMemory: could not read /proc/meminfo — $e');
    }
    if (totalMb == 0) totalMb = 2048; // safe fallback: assume 2 GB
    AppLog.info('DeviceMemory: totalMb=$totalMb');
  }

  // ── Per-device maximums ────────────────────────────────────────────────────

  /// Maximum recommended live demuxer MB for full-screen (75 % RAM ÷ 1).
  static int get maxLiveDemuxerMb =>
      ((totalMb * 0.75) / 1).round().clamp(32, 512);

  /// Maximum recommended live demuxer MB for mini-player (75 % RAM ÷ 2).
  static int get maxMiniDemuxerMb =>
      ((totalMb * 0.75) / 2).round().clamp(16, 256);

  /// Maximum recommended bufferSize MB per player instance (75 % RAM ÷ 2).
  static int get maxBufferSizeMb =>
      ((totalMb * 0.75) / 2).round().clamp(16, 256);

  // ── Smart defaults ─────────────────────────────────────────────────────────

  /// Default liveDemuxerMaxMB for full-screen based on detected RAM.
  static int get defaultLiveDemuxerMb => switch (totalMb) {
        < 2048 => 64,
        < 3072 => 100,
        < 5120 => 150,
        _ => 200,
      };

  /// Default miniDemuxerMaxMB for mini-player based on detected RAM.
  static int get defaultMiniDemuxerMb => switch (totalMb) {
        < 2048 => 16,
        < 3072 => 24,
        < 5120 => 32,
        _ => 48,
      };

  /// Default bufferSizeMB per player instance based on detected RAM.
  static int get defaultBufferSizeMb => switch (totalMb) {
        < 2048 => 32,
        < 3072 => 64,
        < 5120 => 128,
        _ => 192,
      };
}
