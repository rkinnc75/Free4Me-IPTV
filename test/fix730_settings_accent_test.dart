// fix730 (mock §4.8) — the Settings two-pane rail selection follows the chosen
// accent (AccentScope), not the seed-blue colorScheme.primary. Source check:
// the selected-row background + icon must read AccentScope, and must NOT fall
// back to colorScheme.primary for the selection highlight.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('lib/settings_view.dart').readAsStringSync();

  // isolate the TV rail itemBuilder region so we don't match unrelated primary uses
  final start = src.indexOf('final selected = i == _railIndex;');
  final region = start < 0 ? '' : src.substring(start, start + 1400);

  test('rail itemBuilder region located', () {
    expect(start, greaterThan(0), reason: 'rail itemBuilder not found');
  });

  test('selected rail row background uses the accent', () {
    expect(
        region.contains('AccentScope.of(context).withValues(alpha: 0.15)'),
        isTrue);
  });

  test('selected rail icon uses the accent', () {
    // the icon color branch resolves to AccentScope when selected
    expect(region.contains('? AccentScope.of(context)'), isTrue);
  });

  test('selection highlight no longer hardcodes the seed-blue primary', () {
    // strip // comments, then assert no colorScheme.primary remains in CODE
    final codeOnly = region
        .split('\n')
        .map((l) => l.contains('//') ? l.substring(0, l.indexOf('//')) : l)
        .join('\n');
    expect(codeOnly.contains('colorScheme.primary'), isFalse,
        reason: 'rail selection must not use seed-blue primary in code');
    expect(codeOnly.contains('.colorScheme'), isFalse,
        reason: 'no multi-line colorScheme.primary selection highlight');
  });
}
