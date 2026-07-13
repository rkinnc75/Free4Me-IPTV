// fix743: persisted hwdec-probe blocklist. When a stream's hardware-decode
// probe fails ("Could not open codec", fix742) and mpv's software fallback is
// confirmed by a decoded frame, the stream URL is persisted so future opens —
// reconnects AND later tunes — skip the doomed probe entirely.
//
// Design pins (each guards a decision that silently breaks if regressed):
// - Storage is a standalone url-keyed table, NOT a channels column: a source
//   refresh wipes+reinserts channels rows, which would destroy a column flag
//   on every refresh.
// - Self-healing: rows from another app_version, or older than the 30-day
//   TTL, are treated as absent (a libmpv/ffmpeg bump or provider re-encode
//   re-probes hardware automatically).
// - forceHwDecode (fix505 advanced override) bypasses the blocklist READ —
//   manual escape hatch.
// - Blocklist WRITES only happen when hardware was actually requested for the
//   open (appliedHwdecMode gate) and only at the fallback-confirmation moment
//   (fix742's latch), never on unrelated errors.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('migration 45 creates the url-keyed hwdec_blocklist table', () {
    final dbf = File('lib/backend/db_factory.dart').readAsStringSync();
    expect(dbf.contains('SqliteMigration(45, (tx) async {'), isTrue);
    expect(dbf.contains('CREATE TABLE IF NOT EXISTS hwdec_blocklist'), isTrue);
    expect(dbf.contains('url TEXT PRIMARY KEY'), isTrue);
    expect(dbf.contains('failed_at_utc INTEGER NOT NULL'), isTrue);
    expect(dbf.contains('app_version TEXT NOT NULL'), isTrue);
  });

  test('Sql helpers implement TTL + app-version self-healing', () {
    final sql = File('lib/backend/sql.dart').readAsStringSync();
    expect(sql.contains('static const int hwdecBlocklistTtlDays = 30;'), isTrue);
    expect(
        sql.contains('static Future<bool> isHwdecBlocklisted(String url)'),
        isTrue);
    expect(
        sql.contains('static Future<void> addHwdecBlocklist(String url)'),
        isTrue);
    // a row from a different app version is treated as absent
    expect(
        sql.contains(
            "if ((rows.first['app_version'] as String?) != info.version) return false;"),
        isTrue);
    // TTL comparison in days
    expect(sql.contains('return ageDays < hwdecBlocklistTtlDays;'), isTrue);
    // newest failure wins on re-add
    expect(sql.contains('ON CONFLICT(url) DO UPDATE SET'), isTrue);
  });

  test('engine READ gate: blocklist consulted only when hw was chosen and '
      'forceHwDecode is off', () {
    final eng = File('lib/player/mpv_engine.dart').readAsStringSync();
    expect(eng.contains('Sql.isHwdecBlocklisted(chUrl)'), isTrue);
    expect(eng.contains("hwdecMode != 'no' &&"), isTrue);
    expect(eng.contains('!s.forceHwDecode &&'), isTrue);
    expect(eng.contains('if (blocklistHit) hwdecMode = \'no\';'), isTrue);
    // the applied mode is exposed so the player can gate WRITES
    expect(eng.contains('String? appliedHwdecMode;'), isTrue);
    // hit is visible in the fix395/505 log line
    expect(eng.contains("blocklist=hit (fix743)"), isTrue);
  });

  test('player WRITE gate: persist only on confirmed sw fallback after a '
      'hw-requested open', () {
    final player = File('lib/player.dart').readAsStringSync();
    expect(player.contains('unawaited(Sql.addHwdecBlocklist(url));'), isTrue);
    // only at the fallback-confirmation moment (fix742 latch not yet set)
    expect(player.contains('if (_codecErrorLogged &&'), isTrue);
    expect(player.contains('!_codecFallbackConfirmed &&'), isTrue);
    // only when hardware was actually requested for this open
    expect(player.contains("eng.appliedHwdecMode != 'no'"), isTrue);
  });
}
