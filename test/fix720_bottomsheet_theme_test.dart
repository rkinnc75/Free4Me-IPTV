// fix720 (Phase 5 — settings/menus) — tokenize the modal bottom sheets (the
// channel context menu, fix586) to the redesign glass look on TV: dark glass
// fill + rounded top corners. TV-gated (null on phone → Material default, so the
// touch UI stays byte-identical).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final main = File('lib/main.dart').readAsStringSync();

  group('fix720 bottom-sheet theme', () {
    test('bottomSheetTheme is TV-gated (null on phone)', () {
      expect(main.contains('bottomSheetTheme: hasTouchScreen'), isTrue);
      // the ternary form: phone → null, TV → the themed sheet
      expect(main.contains('? null'), isTrue);
      expect(main.contains('BottomSheetThemeData('), isTrue);
    });

    test('TV sheet uses the glass fill + rounded top (F4 tokens as literals)',
        () {
      expect(main.contains('backgroundColor: Color(0xF00B0F19)'), isTrue);
      expect(main.contains('modalBackgroundColor: Color(0xF00B0F19)'), isTrue);
      expect(
          main.contains(
              'BorderRadius.vertical(top: Radius.circular(20))'),
          isTrue);
    });
  });
}
