// fix703 (TV GUI redesign, Phase 2) — ChannelTile adopts the token focus look
// on the TV path: the focused tile's ring becomes the ACCENT color (was flat
// yellow) and the tile lifts 1.05x, consistent with the tab bar. Gated on
// showSourceEdgeBar (the TV signal for every tile screen — browse/categories/
// search/home-on-TV; false on phone), so the phone path is byte-identical.
// ChannelTile keeps its own FocusNode + all specialized key handling (edge-back,
// checkbox arrow-nav, search up-escape, held-OK, prewarm) — deliberately NOT
// delegated to TvFocusable, which would risk regressions across 5 screens.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _slice(String s, String from, String to) {
  final a = s.indexOf(from);
  if (a < 0) return '';
  final b = to.isEmpty ? s.length : s.indexOf(to, a + from.length);
  return s.substring(a, b < 0 ? s.length : b);
}

void main() {
  final tile = File('lib/channel_tile.dart').readAsStringSync();

  test('imports the accent + motion tokens', () {
    expect(tile.contains('tv/theme/accent_scope.dart'), isTrue);
    expect(tile.contains('tv/theme/f4_motion.dart'), isTrue);
  });

  test('focused TV tile ring is the accent color, not yellow', () {
    final build = _slice(tile, 'Widget build(BuildContext context)', 'class _PrewarmEntry');
    expect(
        build.contains(
            'side: (widget.showSourceEdgeBar && _focusNode.hasFocus)'),
        isTrue,
        reason: 'ring gate unchanged (TV-only)');
    expect(build.contains('BorderSide(color: AccentScope.of(context), width: 2.5)'),
        isTrue);
    // no flat yellow anywhere in the tile now
    expect(tile.contains('Colors.yellow'), isFalse);
  });

  test('TV tile lifts 1.05x on focus; phone path returns the bare tile', () {
    final build = _slice(tile, 'Widget build(BuildContext context)', 'class _PrewarmEntry');
    // phone (no showSourceEdgeBar) returns the tile with no scale wrapper
    expect(build.contains('if (!widget.showSourceEdgeBar) return tile;'), isTrue);
    expect(build.contains('AnimatedScale('), isTrue);
    expect(build.contains('F4Motion.scaleFocused'), isTrue);
    expect(build.contains('final Widget tile = Card('), isTrue);
  });

  test('specialized focus machinery kept (no TvFocusable delegation)', () {
    // ChannelTile still owns its FocusNode + key handling (edge-back etc.)
    expect(tile.contains('_focusNode.onKeyEvent'), isTrue);
    expect(tile.contains('onLeftEdgeBack'), isTrue);
    expect(tile.contains('TvFocusable'), isFalse); // not delegated
  });
}
