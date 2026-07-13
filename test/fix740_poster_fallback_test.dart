// fix740 (mock §4.2) — art-less poster tiles get a branded gradient fill + the
// channel name centered over the art region (was a flat fill + generic movie
// glyph). Source checks.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t = File('lib/channel_tile.dart').readAsStringSync();
  test('fallback is a branded gradient (source tint → posterBg)', () {
    expect(t.contains('final Color posterTop ='), isTrue);
    expect(t.contains('gradient: LinearGradient('), isTrue);
    expect(t.contains('colors: [posterTop, posterBg]'), isTrue);
  });
  test('fallback centers the channel name (no lone movie glyph)', () {
    expect(t.contains('child: Text(\n            widget.channel.name'), isTrue);
    // the old generic-glyph fallback is gone
    expect(t.contains('Icon(Icons.movie, size: 28'), isFalse);
  });
}
