// fix762: EOF fast path for the silent-stall watchdog.
//
// Field evidence (S938U, 2026-07-27, "US| YES NETWORK HD"): the provider closed
// the .ts connection three times. Each drop read identically — cache-speed fell
// to 0, the 20 s demuxer cache drained linearly, then eof-reached=yes with
// core-idle=yes and the position frozen. The fix753 watchdog then sat out its
// full 15 s window before reconnecting, so every drop cost ~15 s of frozen
// picture on top of the unavoidable ~2 s reopen.
//
// Design pins (these encode why the fast path is safe where fix753's rejected
// discriminators were not):
//  - fix753 tested and FALSIFIED cacheSpeed==0, cache depth, core-idle, mpv
//    pause and demuxTime as wedge discriminators: a settled user pause is
//    sensor-identical to a wedge on all of them. eof-reached is different in
//    kind — pausing does not make the demuxer reach end-of-stream. It stays a
//    CONFIRMATION on top of the existing cacheSpeed==0 heuristic, never a
//    replacement for it.
//  - LIVESTREAM ONLY. VOD legitimately reaches EOF when a movie ends; firing
//    there would reconnect the user into a finished film.
//  - Requires a genuinely frozen position for at least one full 3 s sample
//    interval. Never fires off a single tick.
//  - A null property read is NON-CONFIRMING, exactly as cacheSpeed is. The
//    fast path must fall through to the full window on missing data, never
//    fire on it.
//  - The read must be a single-property call on the engine, NOT
//    readPlaybackStats() — that poll only runs while debug logging is on, and
//    a watchdog that only works with debug logging enabled is the fix753 trap.
//  - The full 15 s window keeps its exact prior behaviour and property cost.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final player = File('lib/player.dart').readAsStringSync();
  final engine = File('lib/player/mpv_engine.dart').readAsStringSync();

  test('engine exposes a single-property eof-reached read', () {
    expect(engine.contains('Future<String?> readEofReached() async {'), isTrue);
    expect(engine.contains("getProperty('eof-reached')"), isTrue);
    // must not be routed through the debug-only stats poll: slice to the end
    // of THIS method (its closing brace) rather than a fixed-width window,
    // which would run on into readPlaybackStats and always match.
    final idx = engine.indexOf('Future<String?> readEofReached() async {');
    final body = engine.substring(idx, engine.indexOf('\n  }', idx));
    expect(body.contains('readPlaybackStats'), isFalse);
    // unavailable => null, never a bare 'no'
    expect(body.contains('return null;'), isTrue);
  });

  test('fast path is declared shorter than the full stall window', () {
    expect(player.contains('static const int _stallWatchdogSecs = 15;'), isTrue);
    expect(player.contains('static const int _stallEofFastSecs = 3;'), isTrue);
  });

  test('fast path is gated to livestreams and a confirmed freeze', () {
    final idx = player.indexOf('void _checkStall(Timer _) {');
    expect(idx, greaterThan(0));
    final body = player.substring(idx, idx + 3600);
    // full window unchanged
    expect(body.contains('frozenFor.inSeconds >= _stallWatchdogSecs'), isTrue);
    // fast window: shorter threshold AND livestream-only
    expect(body.contains('frozenFor.inSeconds >= _stallEofFastSecs'), isTrue);
    expect(
        body.contains('widget.channel.mediaType == MediaType.livestream'),
        isTrue);
    expect(body.contains('eofFastPath: true'), isTrue);
  });

  test('fast path fires only on a confirmed EOF, and holds on a null read', () {
    final idx = player.indexOf('Future<void> _confirmAndFireStall(');
    expect(idx, greaterThan(0));
    final body = player.substring(idx, idx + 2200);
    // cacheSpeed==0 remains a precondition for BOTH windows
    expect(body.contains("if (speed == null || speed != '0') {"), isTrue);
    // EOF is an additional confirmation, and anything but 'yes' holds fire —
    // which covers the null (property unavailable) case by construction.
    expect(body.contains("if (eofFastPath && eof != 'yes') return;"), isTrue);
    // the extra read is only paid on the fast path
    expect(body.contains('if (eofFastPath) eof = await eng.readEofReached();'),
        isTrue);
    // distinguishable in the field log...
    expect(body.contains('fix762 fast path'), isTrue);
    // ...but the reconnect reason literal stays stable: fix747 pins it and
    // the log analyzer keys on it, so the fast path must NOT fork the value.
    expect(body.contains("onDisconnect(reason: 'stall watchdog')"), isTrue);
  });
}
