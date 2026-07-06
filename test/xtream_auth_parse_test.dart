// finding 68: parseXtreamAuthResponse previously only accepted the integer
// auth==1, so panels returning auth as the string "1" or the bool true were
// reported as "login failed". The fix coerces string/bool auth values while
// still rejecting auth==0 (int or string). This test pins that behavior via
// the pure public parser.

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/xtream.dart';

void main() {
  group('parseXtreamAuthResponse auth coercion (finding 68)', () {
    test('auth int 1 → true', () {
      expect(parseXtreamAuthResponse({
        'user_info': {'auth': 1},
      }), isTrue);
    });

    test('auth string "1" → true', () {
      expect(parseXtreamAuthResponse({
        'user_info': {'auth': '1'},
      }), isTrue);
    });

    test('auth bool true → true', () {
      expect(parseXtreamAuthResponse({
        'user_info': {'auth': true},
      }), isTrue);
    });

    test('auth int 0 → false', () {
      expect(parseXtreamAuthResponse({
        'user_info': {'auth': 0},
      }), isFalse);
    });

    test('auth string "0" → false', () {
      expect(parseXtreamAuthResponse({
        'user_info': {'auth': '0'},
      }), isFalse);
    });

    test('missing user_info → false', () {
      expect(parseXtreamAuthResponse(<String, dynamic>{}), isFalse);
    });
  });
}
