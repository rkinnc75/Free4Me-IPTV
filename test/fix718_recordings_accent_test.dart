// fix718 (Phase 5 — Recordings restyle) — the focused recording tile gets the
// shared accent focus ring on TV (matching tabs/tiles/rails/buttons), while the
// phone list stays the bare Material ListTile (byte-identical). The held-OK
// details / short-OK play key model (fix693) is preserved.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final rec = File('lib/recordings_view.dart').readAsStringSync();
  final shell = File('lib/tv/tv_shell.dart').readAsStringSync();

  group('fix718 recordings accent ring', () {
    test('RecordingsView carries a tv flag defaulting to false (phone-safe)',
        () {
      expect(rec.contains('this.tv = false'), isTrue);
      expect(rec.contains('final bool tv;'), isTrue);
    });

    test('only the TV shell opts in (tv: true); phone nav does not', () {
      expect(shell.contains('tv: true'), isTrue);
      final bottomNav = File('lib/bottom_nav.dart').readAsStringSync();
      expect(bottomNav.contains('RecordingsView(tv:'), isFalse);
    });

    test('phone returns the bare ListTile; TV wraps it in the accent ring', () {
      // the early return keeps the phone path byte-identical
      expect(rec.contains('if (!widget.tv) return tile;'), isTrue);
      // fix737: the row is now a glass card — the focus-driven border is accent
      // when focused, the glass stroke when not (was an in-hue alpha fade of
      // accent@0→1). Still shared ring width + token radius.
      expect(rec.contains('_focused'), isTrue);
      expect(rec.contains('? AccentScope.of(context)'), isTrue);
      expect(rec.contains(': t.colors.glassStroke'), isTrue);
      expect(rec.contains('width: t.focus.ringCard'), isTrue);
      expect(rec.contains('BorderRadius.circular(t.radius.card)'), isTrue);
    });

    test('focus ring is driven by a focus-node listener (no leak)', () {
      expect(rec.contains('_node.addListener(_onFocusChange)'), isTrue);
      expect(rec.contains('_node.removeListener(_onFocusChange)'), isTrue);
    });

    test('held-OK details / short-OK play model (fix693) is preserved', () {
      expect(rec.contains('widget.onDetails()'), isTrue);
      expect(rec.contains('widget.onTap?.call()'), isTrue);
      expect(rec.contains('_holdDelay'), isTrue);
    });
  });
}
