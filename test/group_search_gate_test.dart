// fix401: the Categories (group) search short-skip is lowered from < 3 to < 2
// to match fix400's ≥2-char UI gate — a 2-char query like "us"/"en" now runs
// (groups are small and LIKE-searched) instead of returning empty in 0ms.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/group_search_gate.dart';

void main() {
  group('fix401 Categories search min-length gate', () {
    test('empty / whitespace does not skip (restores the full list)', () {
      expect(groupSearchAllTermsTooShort(''), isFalse);
      expect(groupSearchAllTermsTooShort('   '), isFalse);
    });

    test('a single-character query is skipped', () {
      expect(groupSearchAllTermsTooShort('u'), isTrue);
      expect(groupSearchAllTermsTooShort(' e '), isTrue);
    });

    test('a two-character query runs (the bug fix400 missed)', () {
      expect(groupSearchAllTermsTooShort('us'), isFalse);
      expect(groupSearchAllTermsTooShort('en'), isFalse);
      expect(groupSearchAllTermsTooShort('sports'), isFalse);
    });

    test('keyword mode: skip only when every term is a single char', () {
      expect(groupSearchAllTermsTooShort('a b', useKeywords: true), isTrue);
      expect(groupSearchAllTermsTooShort('us hd', useKeywords: true), isFalse);
      expect(groupSearchAllTermsTooShort('a hd', useKeywords: true), isFalse);
    });
  });
}
