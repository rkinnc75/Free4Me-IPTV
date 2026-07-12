// fix707 (TV GUI redesign) — chrome pass: the global TV button focus themes in
// main.dart (Filled / Icon / Text / Outlined `ButtonStyle.side`, all gated on
// !hasTouchScreen) adopt the accent colour instead of flat yellow. This is the
// Settings / dialog / gear focus ring — the last flat-yellow surface — so the
// accent-ring language (fix702 tabs, fix703 tiles, fix704 rails) is now
// consistent across ALL TV chrome. Phone path unchanged (all four are inside
// `if (states.contains(WidgetState.focused) && !hasTouchScreen)`).
//
// Reactivity: the colour is read from `appAccentNotifier.value` at theme-build
// time (non-const). Accent is white today (no picker UI), so this is visually
// identical to the intended white ring; a future accent-preset unit adds live
// reactivity by rebuilding the theme when the notifier changes.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final main = File('lib/main.dart').readAsStringSync();

  test('no flat-yellow focus ring remains in the button themes', () {
    expect(main.contains('Colors.yellow'), isFalse);
  });

  test('all four button focus rings read the accent notifier', () {
    // width-3 rings (icon / text / outlined) + the width-4 filled ring
    final w3 = 'BorderSide(color: appAccentNotifier.value, width: 3)'
        .allMatches(main)
        .length;
    expect(w3, greaterThanOrEqualTo(3),
        reason: 'icon + text + outlined button focus rings');
    expect(main.contains('color: appAccentNotifier.value,\n                  width: 4'),
        isTrue,
        reason: 'filled button focus ring');
  });

  test('still TV-only (phone path untouched)', () {
    // the focused-side resolver is still gated on !hasTouchScreen
    expect(
        main.contains(
            'states.contains(WidgetState.focused) && !hasTouchScreen'),
        isTrue);
  });
}
