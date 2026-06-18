// fix400: the channel search skips a single typed character — a 1-char
// substring scans the whole catalogue (~2s on a large library) only to be
// superseded by the next keystroke. ≥2 chars search; exactly 1 leaves the
// current list untouched; empty/whitespace restores the full browse.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/search_query_gate.dart';

void main() {
  group('fix400 search min-length gate', () {
    test('empty and whitespace-only load (restore full browse)', () {
      expect(searchQueryShouldLoad(''), isTrue);
      expect(searchQueryShouldLoad('   '), isTrue);
      expect(searchQueryShouldLoad('\t'), isTrue);
    });

    test('exactly one non-whitespace character is skipped', () {
      expect(searchQueryShouldLoad('y'), isFalse);
      expect(searchQueryShouldLoad(' y '), isFalse);
      expect(searchQueryShouldLoad('7'), isFalse);
    });

    test('two or more characters load (run the search)', () {
      expect(searchQueryShouldLoad('ye'), isTrue);
      expect(searchQueryShouldLoad('yes network'), isTrue);
      expect(searchQueryShouldLoad('  ab  '), isTrue);
    });
  });
}
