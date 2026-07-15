// fix747: silent-stall watchdog. The existing _bufferingWatchdog only arms on
// a buffering=true event; a live feed can wedge (demuxer starves at cache=0,
// playback frozen on one frame) with NO buffering signal while mpv still
// reports playing=true — the onn "frozen frame for 25 min" freeze, which
// recovered never because no watchdog was armed. fix747 adds a periodic
// position-progress watchdog: if a live stream's position stops advancing
// while playing and not buffering, it reconnects.
//
// Design pins (REVISED by fix753 — fix747's central assumption was falsified
// by field data):
// - fix747 assumed a silent stall keeps playing=true and bailed on
//   `!_enginePlaying`. The measured S938U wedge (2026-07-14, ABC30 Fresno)
//   reports playing=false AND mpv self-sets pause=yes with a FULL 95s buffer —
//   so bailing on EITHER flag makes the watchdog structurally blind to the
//   exact failure it exists for, while ALSO refreshing its own baseline every
//   tick. Five sensor discriminators (mpv pause, eof, demuxTime progress,
//   cacheSpeed==0, cache depth) were each tested against field logs and
//   falsified: a settled user pause is sensor-identical to the wedge.
// - fix753 keys on INTENT (_pauseRequested: user/cast/sleep/overlay set it,
//   resume + every open() clear it) plus a LIFECYCLE gate (only accumulate
//   while resumed — an answered call backgrounds the app), with cacheSpeed==0
//   as a firing-time heuristic only (null/nonzero = hold fire).
// - ANY position change — forward, backward, or the provider PTS resets that
//   jump negative (36002ms → -10031ms) — refreshes the baseline; only a truly
//   unchanged position accumulates.
// - Stands down while buffering (the _bufferingWatchdog owns that window),
//   during startup grace, while casting/reconnecting, while DVR is active;
//   re-arms on buffering=false.
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

  test('fires onDisconnect only after a real unexplained freeze', () {
    expect(player.contains("onDisconnect(reason: 'stall watchdog')"), isTrue);
    final idxCheck = player.indexOf('void _checkStall(Timer _) {');
    expect(idxCheck, greaterThan(0));
    final body = player.substring(idxCheck, idxCheck + 3200);
    // guard clause only — the warn line legitimately REPORTS enginePlaying.
    final guard = body.substring(0, body.indexOf('final pos = _engine.position;'));
    // exempts buffering / grace / casting / reconnect / requested pause /
    // backgrounded app / DVR scrub
    expect(guard.contains('_bufferingState != null'), isTrue);
    expect(guard.contains('_startupGrace'), isTrue);
    expect(guard.contains('_pauseRequested ||'), isTrue);
    expect(guard.contains('!_lifecycleResumed ||'), isTrue);
    expect(guard.contains('_engine.dvrActive) {'), isTrue);
    // fix753: an UNEXPLAINED playing=false IS the wedge — bailing on mpv's
    // playing flag re-introduces fix747's structural blindness (the S938U
    // wedge reports playing=false and refreshes the baseline forever).
    expect(guard.contains('_enginePlaying'), isFalse,
        reason: 'fix753: the guard must not consult mpv\'s playing flag');
    expect(body.contains('frozenFor.inSeconds >= _stallWatchdogSecs'), isTrue);
    // threshold reached -> firing goes through the async confirmation
    expect(body.contains('unawaited(_confirmAndFireStall(pos, frozenFor));'),
        isTrue);
  });

  test('fix753: firing-time heuristic — cacheSpeed read by the watchdog '
      'itself, null/nonzero holds fire', () {
    // the watchdog does its OWN property read (STATS only polls with debug
    // logging on; a debug-only watchdog fails silently in production)
    expect(player.contains('await eng.readCacheSpeed();'), isTrue);
    expect(player.contains("if (speed == null || speed != '0') {"), isTrue);
    // post-await revalidation before firing
    final idxFire = player.indexOf('Future<void> _confirmAndFireStall(');
    expect(idxFire, greaterThan(0));
    final fire = player.substring(idxFire, idxFire + 2200);
    expect(fire.contains('if (_engine.position != pos) return;'), isTrue);
    expect(fire.contains('_pauseRequested ||'), isTrue);
    expect(fire.contains('!_lifecycleResumed ||'), isTrue);
  });

  test('fix753: every intentional pause sets the intent flag; resume and '
      'every open() clear it; lifecycle tracked', () {
    // set at: user toggle, cast handoff, sleep timer, overlay handoff
    expect(RegExp(r'_pauseRequested = true;').allMatches(player).length,
        greaterThanOrEqualTo(4));
    // cleared at: user resume, DVR resume, per-open reset
    expect(RegExp(r'_pauseRequested = false;').allMatches(player).length,
        greaterThanOrEqualTo(3));
    // foreground gate maintained from the lifecycle callback
    expect(
        player.contains(
            '_lifecycleResumed = state == AppLifecycleState.resumed;'),
        isTrue);
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
