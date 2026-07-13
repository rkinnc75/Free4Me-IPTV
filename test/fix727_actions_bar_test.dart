// fix727 (mock §4.6) — Player Actions Bar completion: playback-speed picker +
// sleep timer. Source-string checks (the player is not trivially widget-testable
// without a live engine) plus the engine default-rate contract.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final player = File('lib/player.dart').readAsStringSync();
  final engine = File('lib/player/player_engine.dart').readAsStringSync();
  final mpv = File('lib/player/mpv_engine.dart').readAsStringSync();

  test('PlayerEngine exposes a default 1.0x rate + no-op setRate', () {
    expect(engine.contains('double get playbackRate => 1.0'), isTrue);
    expect(engine.contains('Future<void> setRate(double rate) async {}'),
        isTrue);
  });

  test('MpvEngine overrides setRate through media_kit', () {
    expect(mpv.contains('Future<void> setRate(double rate) async'), isTrue);
    expect(mpv.contains('_player.setRate(rate)'), isTrue);
    expect(mpv.contains('double get playbackRate => _rate'), isTrue);
  });

  test('player has the mock speed presets', () {
    expect(player.contains('_speedPresets'), isTrue);
    for (final p in ['0.25', '0.5', '0.75', '1.0', '1.25', '1.5', '2.0']) {
      expect(player.contains(p), isTrue, reason: 'missing speed preset $p');
    }
  });

  test('speed button VOD-gated + opens the picker (adversarial F4)', () {
    expect(player.contains('Icons.speed'), isTrue);
    // gated to VOD (!live), not shown on live/DVR
    expect(player.contains('if (!live && tracks)'), isTrue);
    expect(player.contains('_engine.setRate(_speedPresets[id])'), isTrue);
  });

  test('sleep timer: presets, arm/cancel, deadline-carry, dispose', () {
    expect(player.contains('_sleepPresets = [0, 15, 30, 45, 60, 90]'), isTrue);
    expect(player.contains('void _armSleepTimer(int minutes)'), isTrue);
    expect(player.contains('void _scheduleSleep(DateTime deadline)'), isTrue);
    // "Off" (<=0) cancels cleanly
    expect(player.contains('if (minutes <= 0)'), isTrue);
    // deadline carried across a channel surf (adversarial F2)
    expect(player.contains('final DateTime? sleepDeadline;'), isTrue);
    expect(player.contains('sleepDeadline: _sleepDeadline'), isTrue);
    expect(player.contains('_scheduleSleep(deadline)'), isTrue);
    // dispose cancels it
    expect(player.contains('_sleepTimer?.cancel(); // fix727'), isTrue);
  });

  test('sleep fire dismisses an OSD dialog before exit (adversarial F1)', () {
    // popUntil the player's own route so onExit can't pop a dialog + wedge it
    expect(player.contains('ModalRoute.of(context)'), isTrue);
    expect(player.contains('popUntil((r) => r == route)'), isTrue);
    // then pause + guarded exit, mounted-checked
    expect(player.contains('await _engine.pause()'), isTrue);
    expect(player.contains('if (mounted) onExit();'), isTrue);
  });

  test('sleep button in the bar toggles bedtime icon while armed', () {
    expect(
        player.contains(
            '_sleepMinutes > 0 ? Icons.bedtime : Icons.bedtime_outlined'),
        isTrue);
    expect(player.contains("_openSleepTimerFromOverlay"), isTrue);
  });
}
