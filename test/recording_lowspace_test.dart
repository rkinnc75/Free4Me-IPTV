// fix670: unit tests for the low-space guard boundary.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/recording_scheduler.dart';

void main() {
  const floor = RecordingScheduler.minFreeBytes; // 1 GB

  test('null free space (unknown) is allowed', () {
    expect(RecordingScheduler.isLowSpace(null), isFalse);
  });
  test('just below floor is low', () {
    expect(RecordingScheduler.isLowSpace(floor - 1), isTrue);
  });
  test('exactly floor is allowed', () {
    expect(RecordingScheduler.isLowSpace(floor), isFalse);
  });
  test('plenty of space is allowed', () {
    expect(RecordingScheduler.isLowSpace(floor * 20), isFalse);
  });
}
