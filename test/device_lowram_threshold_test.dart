// fix379: the low-RAM mitigation that was scoped to Android TV boxes
// (formerly `isLowRamTv`) now also covers low-RAM phones (e.g. OPPO
// PGEM10, ~2 GB). The threshold is 2300 MB (matches the existing
// ChannelSearchCache low-RAM cutoff). This test pins the pure threshold
// helper `isLowRamDeviceThreshold` so the cutoff can't drift.
//
// The async `isLowRamDevice()` wrapper depends on Platform.isAndroid and
// `_deviceInfo.androidInfo` (platform channels), so it's not unit-testable
// here — the on-device test (OPPO PGEM10) covers the wrapper behaviour.

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/models/device_detector.dart';

void main() {
  group('DeviceDetector.isLowRamDeviceThreshold (fix379)', () {
    test('below 1 MB is uninitialised → false', () {
      // 0 means DeviceMemory.init() never ran or /proc/meminfo was
      // unreadable. Must NOT trigger software decode on a device that
      // we couldn't read.
      expect(DeviceDetector.isLowRamDeviceThreshold(0), isFalse,
          reason: 'totalMb=0 means uninitialised; not a low-RAM signal');
    });

    test('just under threshold is true', () {
      // OPPO PGEM10 reports ~1999 MB; onn 4K Plus ~1925 MB.
      // 1999 < 2300 → true.
      expect(DeviceDetector.isLowRamDeviceThreshold(1999), isTrue,
          reason: 'OPPO-class device totalMb must trigger the mitigation');
      expect(DeviceDetector.isLowRamDeviceThreshold(1925), isTrue,
          reason: 'onn 4K Plus class totalMb must trigger the mitigation');
    });

    test('at the threshold is false (exclusive upper bound)', () {
      // The cutoff is strictly < 2300, so 2300 itself is "not low-RAM".
      // 2300 MB devices have been observed to handle 4 mediacodec-copy
      // pipelines without TEXTURE-ATTACH-FAILED; only below 2300 triggers
      // the bug.
      expect(DeviceDetector.isLowRamDeviceThreshold(2300), isFalse,
          reason: '2300 is the documented cutoff; inclusive above');
    });

    test('just above threshold is false', () {
      expect(DeviceDetector.isLowRamDeviceThreshold(2301), isFalse);
      expect(DeviceDetector.isLowRamDeviceThreshold(4096), isFalse,
          reason: 'S24-class device must not trigger low-RAM mitigation');
    });

    test('OPPO PGEM10 (1999 MB) is the canonical low-RAM phone', () {
      // Regression guard for the fix379 design intent: the OPPO PGEM10
      // (~1999 MB phone) is the device this fix was scoped for. If the
      // threshold ever changes (e.g. someone bumps it to 2500 because
      // "a 2400 MB phone exists"), this test forces a conversation.
      const oppoPgEm10TotalMb = 1999;
      expect(
        DeviceDetector.isLowRamDeviceThreshold(oppoPgEm10TotalMb),
        isTrue,
        reason: 'fix379 was scoped for the OPPO PGEM10; this test pins that',
      );
    });
  });
}
