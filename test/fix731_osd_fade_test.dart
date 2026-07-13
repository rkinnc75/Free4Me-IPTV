// fix731 (mock §4.6/§5) — the player TV OSD fades in/out (AnimatedOpacity on
// crossIn/crossOut) instead of snapping mount↔unmount, with a token
// panelSlate→transparent scrim. Source checks (the player needs a live engine
// to widget-test).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final player = File('lib/player.dart').readAsStringSync();

  test('OSD is always mounted (not gated behind if(_navMode))', () {
    expect(player.contains('if (_navMode) _buildTvOverlay()'), isFalse,
        reason: 'overlay must stay mounted so it can fade out');
    // the mount is now the bare call
    expect(
        player.contains(
            '// it self-hides (opacity 0 + focus/pointer excluded) when !_navMode.\n              _buildTvOverlay(),'),
        isTrue);
  });

  test('OSD fades via AnimatedOpacity on the motion tokens', () {
    expect(player.contains('AnimatedOpacity('), isTrue);
    expect(player.contains('opacity: _navMode ? 1.0 : 0.0'), isTrue);
    expect(
        player.contains(
            'duration: _navMode ? F4Motion.crossIn : F4Motion.crossOut'),
        isTrue);
    expect(player.contains('curve: F4Motion.easeOut'), isTrue);
  });

  test('hidden OSD is focus- and pointer-excluded (D-pad model preserved)', () {
    expect(player.contains('IgnorePointer('), isTrue);
    expect(player.contains('ignoring: !_navMode'), isTrue);
    expect(player.contains('ExcludeFocus('), isTrue);
    expect(player.contains('excluding: !_navMode'), isTrue);
  });

  test('scrim uses the panelSlate token at playerMenu alpha, not black54', () {
    expect(
        player.contains(
            'tokens.colors.panelSlate\n        .withValues(alpha: tokens.scrim.playerMenu)'),
        isTrue);
    expect(player.contains('colors: [scrim, Colors.transparent, scrim]'),
        isTrue);
    // the old static gradient is gone
    expect(
        player.contains(
            'colors: [Colors.black54, Colors.transparent, Colors.black54]'),
        isFalse);
  });
}
