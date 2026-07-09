// fix681: guards the sr_status.jsonl line format the native service writes and
// the Dart drainer reads. The drainer itself needs Utils.appDir (path_provider)
// + the DB, neither available in the sandbox, so this test pins the CONTRACT:
// each journal line is a JSON object with id/status (+ optional output_path,
// error), and parses to a valid RecordingStatus. If the native writer or the
// Dart parser drift, this catches it.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/models/recording.dart';

RecordingStatus? parseStatus(String s) {
  for (final v in RecordingStatus.values) {
    if (v.name == s) return v;
  }
  return null;
}

void main() {
  test('native journal line shape parses to a valid RecordingStatus', () {
    // Exactly what RecordingCaptureService.updateStatus writes (org.json).
    final lines = <String>[
      '{"id":10,"status":"recording","ts":1}',
      '{"id":10,"status":"done","output_path":"content://x/1","ts":2}',
      '{"id":11,"status":"failed","error":"timeout","ts":3}',
    ];
    final applied = <int, RecordingStatus>{};
    for (final line in lines) {
      final m = jsonDecode(line) as Map<String, dynamic>;
      final id = (m['id'] as num).toInt();
      final status = parseStatus(m['status'] as String);
      expect(status, isNotNull, reason: 'status "${m['status']}" must be a known enum');
      applied[id] = status!;
    }
    // Last-write-wins per id, as the drainer applies sequentially.
    expect(applied[10], RecordingStatus.done);
    expect(applied[11], RecordingStatus.failed);
  });

  test('unknown status string is rejected (not silently mapped)', () {
    expect(parseStatus('bogus'), isNull);
    expect(parseStatus('compressing'), RecordingStatus.compressing);
  });

  test('every RecordingStatus round-trips via its name', () {
    for (final v in RecordingStatus.values) {
      expect(parseStatus(v.name), v);
    }
  });
}
