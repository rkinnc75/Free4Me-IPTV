// fix734 (mock §4.5) — the TV search field gets a token glass fill + an accent
// focus ring (was a borderless default-filled field). Source checks.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final view = File('lib/tv/tv_search_view.dart').readAsStringSync();

  test('search field uses the token glass fill', () {
    expect(view.contains('fillColor: F4.of(context).colors.glassFill'), isTrue);
  });

  test('search field has an accent focus ring', () {
    expect(view.contains('focusedBorder: OutlineInputBorder('), isTrue);
    expect(
        view.contains('BorderSide(color: AccentScope.of(context), width: 2)'),
        isTrue);
  });

  test('enabled border uses the glass stroke (not none)', () {
    expect(
        view.contains(
            'borderSide: BorderSide(color: F4.of(context).colors.glassStroke)'),
        isTrue);
    // the old borderless default is gone
    expect(view.contains('borderSide: BorderSide.none'), isFalse);
  });
}
