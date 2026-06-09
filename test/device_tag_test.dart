// fix325: deviceTag sanitization (fix322) — pure string logic.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/models/device_detector.dart';

void main() {
  group('DeviceDetector.sanitizeDeviceTag', () {
    test('lowercases and strips non-alphanumerics', () {
      expect(DeviceDetector.sanitizeDeviceTag('SM-S938U'), 'sms938u');
      expect(DeviceDetector.sanitizeDeviceTag('onn. 4K Plus'), 'onn4kplus');
      expect(DeviceDetector.sanitizeDeviceTag('SHIELD Android TV'),
          'shieldandroidtv');
    });

    test('caps at 16 characters', () {
      expect(
        DeviceDetector.sanitizeDeviceTag('A Very Long Device Model Name 9000'),
        'averylongdevicem',
      );
      expect(DeviceDetector.sanitizeDeviceTag('x' * 40).length, 16);
    });

    test('empty when nothing survives', () {
      expect(DeviceDetector.sanitizeDeviceTag(''), '');
      expect(DeviceDetector.sanitizeDeviceTag('--- ___ !!!'), '');
    });
  });
}
