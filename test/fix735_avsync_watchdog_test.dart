// fix735 (Peer2 watchdog→silent-resync, inverted for mpv) — an always-on,
// live-only A/V-desync watchdog reopens the stream when avsync drifts past
// threshold, with a hold-based backoff so a broken feed can't reopen-loop.
// Source checks (the drift can't be reproduced in a unit window).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final engine = File('lib/player/mpv_engine.dart').readAsStringSync();
  final base = File('lib/player/player_engine.dart').readAsStringSync();
  final player = File('lib/player.dart').readAsStringSync();

  test('PlayerEngine declares desyncStream (empty default)', () {
    expect(
        base.contains(
            'Stream<double> get desyncStream => const Stream<double>.empty()'),
        isTrue);
  });

  test('MpvEngine watchdog is live-only + sustained + guarded', () {
    expect(engine.contains('void _startAvsyncWatchdog()'), isTrue);
    // live-only gate
    expect(
        engine.contains('if (channel.mediaType != MediaType.livestream) return'),
        isTrue);
    // only acts on a playing, advancing, non-buffering, not-rebuffering stream
    expect(engine.contains('if (!st.playing || st.buffering || !advancing)'),
        isTrue);
    expect(engine.contains("getProperty('paused-for-cache') == 'yes'"), isTrue);
    // threshold on the ABSOLUTE value (video ahead OR behind), sustained
    expect(engine.contains('avs.abs() > _desyncThresholdSecs'), isTrue);
    expect(engine.contains('_desyncTicks >= _desyncSustainTicks'), isTrue);
    expect(engine.contains('_desyncThresholdSecs = 3.0'), isTrue);
  });

  test('MpvEngine emits desyncStream + cleans up', () {
    expect(engine.contains('_desyncCtrl.add(avs)'), isTrue);
    expect(engine.contains('_avsyncWatchdog?.cancel(); // fix735'), isTrue);
    expect(engine.contains('await _desyncCtrl.close(); // fix735'), isTrue);
    // started only on the full-screen (!previewMode) open path
    expect(engine.contains('_startAvsyncWatchdog(); // fix735'), isTrue);
  });

  test('player resync has debounce + hold-based give-up + reopen', () {
    expect(player.contains('_engine.desyncStream.listen(_onAvsyncDesync)'),
        isTrue);
    expect(player.contains('void _onAvsyncDesync(double avsync)'), isTrue);
    // guards: not while reconnecting/exiting
    expect(player.contains('_isReconnecting ||'), isTrue);
    // 30s debounce; <3min recurrence = a strike; else reset (drift correction held)
    expect(player.contains('since < const Duration(seconds: 30)) return'),
        isTrue);
    expect(player.contains('since < const Duration(minutes: 3)'), isTrue);
    expect(player.contains('_avsyncResyncStrikes = 0'), isTrue);
    // give up after 3 strikes (broken feed) — keep playing, log only
    expect(player.contains('if (_avsyncResyncStrikes >= 3)'), isTrue);
    // the reopen goes through the proven reconnect path
    expect(player.contains("onDisconnect(reason: 'avsync watchdog')"), isTrue);
  });

  test('review hardening: sticky give-up + casting guard + adopt coverage', () {
    // give-up is TERMINAL (sticky) so a broken feed can't throttled-loop forever
    expect(player.contains('bool _avsyncGaveUp = false'), isTrue);
    expect(player.contains('_avsyncGaveUp = true'), isTrue);
    expect(player.contains('_avsyncGaveUp) {'), isTrue); // in the guard
    // don't resync while casting (local engine paused)
    expect(player.contains('_isCasting ||'), isTrue);
    // adopt/promote path also arms the watchdog
    expect(engine.contains('_startAvsyncWatchdog();'), isTrue);
  });
}
