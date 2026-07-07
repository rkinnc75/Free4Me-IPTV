// fix667: unit tests for the padded-window computation. The scheduling +
// alarm + DB paths are device/plugin only; this covers the pure math that
// decides when a recording starts and how long it runs.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/recording_scheduler.dart';

void main() {
  // A show 8:00 PM -> 10:00 PM = 7200s window at an arbitrary epoch.
  const start = 1_800_000_000; // programme start (epoch s)
  const stop = start + 7200; // +2h

  test('default pads 1/1: start -60s, duration = 2h + 2min', () {
    final (s, ms) = RecordingScheduler.computeWindow(start, stop, 1, 1);
    expect(s, start - 60);
    expect(ms, (7200 + 120) * 1000);
  });

  test('live-event override before=1 after=90: records to listed end + 90m', () {
    final (s, ms) = RecordingScheduler.computeWindow(start, stop, 1, 90);
    expect(s, start - 60);
    // 2h base + 1min before + 90min after = 7200 + 60 + 5400 s
    expect(ms, (7200 + 60 + 5400) * 1000);
  });

  test('zero pads: exact programme window', () {
    final (s, ms) = RecordingScheduler.computeWindow(start, stop, 0, 0);
    expect(s, start);
    expect(ms, 7200 * 1000);
  });
}
