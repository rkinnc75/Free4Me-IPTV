// fix404: regression guard for the 3-state zoom toggle.
//
// The Player's `_zoomMode` cycles fit → stretch → crop → fit on each
// tap of the aspect-ratio icon. Each state maps to a BoxFit that the
// MpvEngine's Video widget receives via `setZoomMode`:
//
//   fit     → BoxFit.contain  (letterbox, preserves native aspect)
//   stretch → BoxFit.fill     (force viewport aspect, may distort)
//   crop    → BoxFit.cover    (scale to cover, clip overflow)
//
// Tests pin the cycle order and the BoxFit mapping so accidental
// reordering or wrong-BoxFit mistakes trip CI.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/models/zoom_mode.dart';

void main() {
  group('ZoomMode.next (fix404 cycle)', () {
    test('fit → stretch', () {
      expect(ZoomMode.fit.next(), ZoomMode.stretch);
    });

    test('stretch → crop', () {
      expect(ZoomMode.stretch.next(), ZoomMode.crop);
    });

    test('crop → fit (wraps back to start)', () {
      expect(ZoomMode.crop.next(), ZoomMode.fit);
    });

    test('full cycle returns to start after 3 taps', () {
      var mode = ZoomMode.fit;
      mode = mode.next(); // stretch
      mode = mode.next(); // crop
      mode = mode.next(); // fit
      expect(mode, ZoomMode.fit);
    });
  });

  group('ZoomMode.boxFit (fix404 BoxFit mapping)', () {
    test('fit → BoxFit.contain (letterbox)', () {
      expect(ZoomMode.fit.boxFit, BoxFit.contain);
    });

    test('stretch → BoxFit.fill (force viewport aspect)', () {
      expect(ZoomMode.stretch.boxFit, BoxFit.fill);
    });

    test('crop → BoxFit.cover (scale + clip overflow)', () {
      expect(ZoomMode.crop.boxFit, BoxFit.cover);
    });
  });

  group('ZoomMode.icon (fix404 UI affordance)', () {
    test('each mode has a distinct icon', () {
      final icons = ZoomMode.values.map((m) => m.icon).toSet();
      // Set length equals enum length means no duplicates. The pre-fix404
      // build hardcoded `Icons.aspect_ratio_outlined` for all states,
      // so a single icon (size 1) would be a regression.
      expect(icons.length, ZoomMode.values.length);
    });
  });

  group('ZoomMode.tooltip (fix404 UI affordance)', () {
    test('each mode has a non-empty tooltip', () {
      for (final mode in ZoomMode.values) {
        expect(mode.tooltip, isNotEmpty);
      }
    });
  });
}
