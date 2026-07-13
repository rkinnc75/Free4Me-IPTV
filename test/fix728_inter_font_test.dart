// fix728 (mock §2) — Inter as the TV 10-foot type face. Bundled OFL variable
// font, applied only when !hasTouchScreen (phone/touch keeps the default).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final main = File('lib/main.dart').readAsStringSync();

  test('Inter family declared in pubspec fonts', () {
    expect(pubspec.contains('family: Inter'), isTrue);
    expect(pubspec.contains('asset: assets/fonts/Inter.ttf'), isTrue);
  });

  test('theme applies Inter on TV only (phone unchanged)', () {
    expect(
        main.contains("fontFamily: hasTouchScreen ? null : 'Inter'"), isTrue);
  });

  test('bundled Inter.ttf is a real, non-trivial TrueType font', () {
    final f = File('assets/fonts/Inter.ttf');
    expect(f.existsSync(), isTrue);
    final bytes = f.readAsBytesSync();
    // sfnt/TrueType magic 0x00010000, and a variable font must carry a wght axis
    expect(bytes.length, greaterThan(200000));
    expect(bytes[0], 0x00);
    expect(bytes[1], 0x01);
    expect(bytes[2], 0x00);
    expect(bytes[3], 0x00);
    expect(String.fromCharCodes(bytes).contains('wght'), isTrue);
  });

  test('OFL license ships alongside the font', () {
    final ofl = File('assets/fonts/Inter-OFL.txt');
    expect(ofl.existsSync(), isTrue);
    expect(ofl.readAsStringSync().contains('SIL OPEN FONT LICENSE'), isTrue);
  });
}
