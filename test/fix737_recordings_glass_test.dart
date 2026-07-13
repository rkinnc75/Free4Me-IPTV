// fix737 (mock §4.9) — TV recording rows are token glass cards (was a bare
// Material ListTile). Phone unchanged (early-returns the bare tile).
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final v = File('lib/recordings_view.dart').readAsStringSync();
  test('TV recording row uses the token glass fill + stroke + gap', () {
    expect(v.contains('color: t.colors.glassFill'), isTrue);
    expect(v.contains('margin: EdgeInsets.symmetric('), isTrue);
    expect(v.contains(': t.colors.glassStroke'), isTrue);
  });
  test('phone still early-returns the bare tile (byte-identical)', () {
    expect(v.contains('if (!widget.tv) return tile;'), isTrue);
  });
}
