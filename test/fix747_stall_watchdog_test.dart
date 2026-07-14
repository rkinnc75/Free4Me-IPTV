// fix747: silent-stall watchdog. The existing _bufferingWatchdog only arms on
// a buffering=true event; a live feed can wedge (demuxer starves at cache=0,
// playback frozen on one frame) with NO buffering signal while mpv still
// reports playing=true — the onn "frozen frame for 25 min" freeze, which
// recovered never because no watchdog was armed. fix747 adds a periodic
// position-progress watchdog: if a live stream's position stops advancing
// while playing and not buffering, it reconnects.
//
// Design pins:
// - Gated on _enginePlaying (tracked from playingStream) so a user/DVR pause
//   — a legitimately frozen position — never triggers a reconnect.
// - Stands down while buffering (the _bufferingWatchdog owns that window),
//   during startup grace, while casting/reconnecting; re-arms on buffering=false.
// - Livestream-only (VOD position legitimately holds when paused/ended).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final player = File('lib/player.dart').readAsStringSync();

  test('declares the stall-watchdog timer, baseline, and play-state track', () {
    expect(player.contains('Timer? _stallWatchdog;'), isTrue);
    expect(player.contains('Duration? _stallLastPos;'), isTrue);
    expect(player.contains('DateTime? _stallLastAdvanceAt;'), isTrue);
    expect(player.contains('bool _enginePlaying = false;'), isTrue);
    expect(player.contains('static const int _stallWatchdogSecs = 15;'), isTrue);
    // play/pause tracked from the engine so a paused live stream is exempt
    expect(
        player.contains(
            '_engine.playingStream.listen((p) => _enginePlaying = p)'),
        isTrue);
  });

  test('fires onDisconnect only after a real frozen-while-playing stall', () {
    expect(player.contains("onDisconnect(reason: 'stall watchdog')"), isTrue);
    // the guard resets the baseline (never fires) when progress is not expected
    expect(player.contains('!_enginePlaying) {'), isTrue);
    final idxCheck = player.indexOf('void _checkStall(Timer _) {');
    expect(idxCheck, greaterThan(0));
    final body = player.substring(idxCheck, idxCheck + 1400);
    // exempts pause / buffering / grace / casting / reconnect
    expect(body.contains('_bufferingState != null'), isTrue);
    expect(body.contains('_startupGrace'), isTrue);
    expect(body.contains('frozenFor.inSeconds >= _stallWatchdogSecs'), isTrue);
  });

  test('lifecycle: armed on buffering=false, stood down on buffering / '
      'reconnect / dispose', () {
    // re-armed for live when playback (re)flows
    expect(
        player.contains(
            'if (widget.channel.mediaType == MediaType.livestream) {\n        _startStallWatchdog();'),
        isTrue);
    // cancelled in dispose
    expect(player.contains('_stallWatchdog?.cancel(); // fix747'), isTrue);
    // buffering=true and onDisconnect both null it out (two more cancels)
    expect(
        RegExp(r'_stallWatchdog = null;').allMatches(player).length,
        greaterThanOrEqualTo(3));
  });
}
