// fix744: device-level hardware-decode fallback. fix742/fix743 handle a single
// stream whose HW probe fails (accept mpv's software fallback; remember that
// URL). But when the DEVICE's mediacodec decoder is broken outright — e.g. an
// OS update that regressed HW decode of FPS-0 live TS, as seen on the S938U
// where every channel logged "Could not open codec" — the per-URL blocklist
// still makes the FIRST tune of every channel eat a fail->fallback cycle, and
// forceHwDecode (fix505) bypasses it entirely, trapping a force-HW user on a
// dead decoder forever.
//
// fix744 counts DISTINCT confirmed HW failures; past a threshold the device is
// judged unhealthy and ALL streams prefer software from the first open.
//
// Design pins (each guards a decision that silently breaks if regressed):
// - Reuses the fix743 hwdec_blocklist rows as the failure signal — no new
//   table/migration; the record site (player.dart) already writes one row per
//   distinct confirmed HW failure, regardless of forceHwDecode.
// - Same self-healing as fix743: the COUNT is filtered by current app_version
//   and the 30-day TTL, so a release / libmpv bump re-probes hardware.
// - Device-unhealthy WINS over forceHwDecode (a proven-broken decoder must not
//   be force-probed back into the reconnect trap), and short-circuits the
//   per-URL lookup so the two checks never stack.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Sql exposes a threshold + a CLUSTER-window, app-version-scoped count',
      () {
    final sql = File('lib/backend/sql.dart').readAsStringSync();
    expect(
        sql.contains(
            'static const int hwdecDeviceUnhealthyThreshold = 3;'),
        isTrue);
    expect(
        sql.contains('static Future<bool> isHwdecDeviceUnhealthy()'),
        isTrue);
    // counts distinct failures, scoped to THIS app version...
    expect(sql.contains('SELECT COUNT(*) AS n FROM hwdec_blocklist'), isTrue);
    expect(sql.contains('WHERE app_version = ? AND failed_at_utc >= ?'), isTrue);
    // ...clustered within a tight window (NOT the full 30-day TTL), so a few
    // odd-profile streams weeks apart never downgrade a healthy device.
    expect(sql.contains('static const int hwdecUnhealthyClusterHours = 48;'),
        isTrue);
    expect(sql.contains('hwdecUnhealthyClusterHours * 3600'), isTrue);
    expect(sql.contains('n >= hwdecDeviceUnhealthyThreshold'), isTrue);
  });

  test('Sql latches a STICKY verdict honored for the full TTL (no 48h churn)',
      () {
    final sql = File('lib/backend/sql.dart').readAsStringSync();
    // marker key + write on trip
    expect(
        sql.contains(
            "static const String hwdecUnhealthyMarkerKey = 'hwdec_unhealthy_marker';"),
        isTrue);
    expect(
        sql.contains(
            "await setAppMeta(hwdecUnhealthyMarkerKey, '\${info.version}|\$nowSec');"),
        isTrue);
    // read + version-scoped TTL check short-circuits before re-counting
    expect(sql.contains('final marker = await getAppMeta(hwdecUnhealthyMarkerKey);'),
        isTrue);
    expect(
        sql.contains(
            '(nowSec - trippedAt) / 86400.0 < hwdecBlocklistTtlDays'),
        isTrue);
  });

  test('engine: device-unhealthy check wins over forceHwDecode and '
      'short-circuits the per-URL blocklist', () {
    final eng = File('lib/player/mpv_engine.dart').readAsStringSync();
    expect(eng.contains('Sql.isHwdecDeviceUnhealthy()'), isTrue);
    // device-unhealthy is evaluated BEFORE (and independent of) forceHwDecode:
    // the per-URL blocklist is the else-branch, so an unhealthy device forces
    // software even when forceHwDecode is on.
    final idxDevice = eng.indexOf('deviceUnhealthy = await Sql.isHwdecDeviceUnhealthy()');
    final idxForce = eng.indexOf('} else if (!s.forceHwDecode &&');
    expect(idxDevice, greaterThan(0));
    expect(idxForce, greaterThan(idxDevice));
    // unhealthy -> software
    expect(eng.contains("if (deviceUnhealthy) {\n          hwdecMode = 'no';"),
        isTrue);
    // surfaced in the fix395/505 log line
    expect(eng.contains("device-unhealthy=hw-off (fix744)"), isTrue);
  });
}
