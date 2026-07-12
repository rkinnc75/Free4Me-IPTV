// fix722 (Phase 5) — the LAST TV surface on the old `colorScheme.primary` focus
// ring joins the accent-ring language: the multi-view focused-cell ring (and the
// empty-cell "+" button focus border) paint with the shared AccentScope accent
// on TV. Gated on the ambient isTvLike signal (like channel_tile finding 107) so
// a phone keeps the original color (touch UI byte-identical) — no constructor or
// call-site plumbing.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final cell = File('lib/multi_view_cell.dart').readAsStringSync();

  group('fix722 multi-view accent ring', () {
    test('isTvLike gate mirrors channel_tile (forceTVMode / isTv / no-touch)',
        () {
      expect(cell.contains('bool get _isTvLike =>'), isTrue);
      expect(cell.contains('widget.settings.forceTVMode'), isTrue);
      expect(cell.contains('DeviceDetector.isTvCached == true'), isTrue);
      expect(cell.contains('Utils.hasTouchScreenCached == false'), isTrue);
    });

    test('_ringColor = accent on TV, else the original fallback', () {
      expect(
          cell.contains(
              '_isTvLike ? AccentScope.of(context) : fallback'),
          isTrue);
    });

    test('both cell focus rings route through _ringColor (fallback=primary)',
        () {
      // two identical cell-ring sites, both gated
      expect(
          RegExp(r'_ringColor\(\s*context, Theme\.of\(context\)\.colorScheme\.primary\)')
              .allMatches(cell)
              .length,
          2);
    });

    test('the empty-cell + button border is gated too (fallback=white)', () {
      expect(cell.contains('? _ringColor(context, Colors.white)'), isTrue);
    });

    test('no raw colorScheme.primary focus-ring color remains', () {
      // the old `color: Theme.of(context).colorScheme.primary,` ring lines are
      // gone (the add-button FILL keeps primary — that is not a `color:` ring).
      expect(cell.contains('color: Theme.of(context).colorScheme.primary,'),
          isFalse);
    });
  });
}
