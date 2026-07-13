// fix725 (mock §4.2/§4.3) — source color everywhere + guide micro-ramp.
// (Renumbered from a working fix724 that collided with a parallel APK-sig-v3
// commit that took fix724/v4.1.28.) Guide rail cells get a source-tinted
// background (not just the 5px edge); channel 12→11, programme 11→10; art-less
// TV tiles get the source-tinted card bg (was flat grey). Phone unchanged.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final guide = File('lib/tv/tv_guide_view.dart').readAsStringSync();
  final tile = File('lib/channel_tile.dart').readAsStringSync();

  group('fix725 guide source-tint + micro-ramp', () {
    test('_FocusTile takes a background + rail passes the source tint', () {
      expect(guide.contains('final Color? background;'), isTrue);
      expect(guide.contains('color: widget.background ??'), isTrue);
      expect(guide.contains('background: tint,'), isTrue);
    });
    test('micro-ramp: channel 11, programme title 10', () {
      expect(guide.contains('style: const TextStyle(fontSize: 11)'), isTrue);
      expect(guide.contains('fontSize: 10,'), isTrue);
    });
  });

  group('fix725 tile source-tint', () {
    test('art-less TV tile background = source tint (gated on edge bar)', () {
      expect(
          tile.contains(
              'SourcePalette.tintOver(widget.tintColor, Colors.black26)'),
          isTrue);
      expect(
          tile.contains('widget.showSourceEdgeBar && widget.tintColor != null'),
          isTrue);
    });
    test('fallback + loading placeholders use the tinted bg', () {
      expect(tile.contains('color: posterBg,'), isTrue);
      expect(tile.contains('ColoredBox(color: posterBg)'), isTrue);
    });
  });
}
