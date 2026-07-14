// fix746: manual escape hatch for the fix744 device-unhealthy latch. fix744
// made "device judged broken → software everywhere" win over forceHwDecode,
// which left NO in-app way to re-try hardware until the 30-day TTL or an app
// update (the adversarial review of fix744 flagged exactly this gap). fix746
// adds Settings → Playback → "Re-test hardware decoding": clears the fix744
// app_meta marker AND all fix743 per-URL blocklist rows, so the next open
// probes hardware from scratch (and re-latches within 3 failures/48h if the
// decoder is genuinely still broken — a re-probe, not amnesty).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Sql.clearHwdecHealthState wipes BOTH the marker and the blocklist',
      () {
    final sql = File('lib/backend/sql.dart').readAsStringSync();
    final idx = sql.indexOf('static Future<void> clearHwdecHealthState()');
    expect(idx, greaterThan(0));
    final body = sql.substring(idx, idx + 600);
    expect(body.contains("DELETE FROM hwdec_blocklist"), isTrue);
    expect(
        body.contains(
            "DELETE FROM app_meta WHERE key = ?', [hwdecUnhealthyMarkerKey]"),
        isTrue);
  });

  test('Settings → Playback exposes the re-test action wired to the helper',
      () {
    final sv = File('lib/settings_view.dart').readAsStringSync();
    expect(sv.contains("title: const Text('Re-test hardware decoding')"),
        isTrue);
    expect(sv.contains('await Sql.clearHwdecHealthState();'), isTrue);
    // user feedback on tap (mounted-guarded)
    final idxTap = sv.indexOf('await Sql.clearHwdecHealthState();');
    final after = sv.substring(idxTap, idxTap + 500);
    expect(after.contains('if (!mounted) return;'), isTrue);
    expect(after.contains('re-tested on the'), isTrue);
  });
}
