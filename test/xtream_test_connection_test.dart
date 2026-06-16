// fix388: the Xtream "Test connection" probe in the Edit Source
// dialog was reporting a false "login failed" for any account whose
// user_info had auth=1 but max_connections missing or 0. Real-world
// trigger: A3000/Media4u test users with limited permissions (their
// user_info reports auth=1 but max_connections=0). Pre-fix388 the
// dialog said "Login failed"; fix388 says "Connected". This test
// pins the new behavior via the pure public parser
// `parseXtreamAuthResponse`.

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/xtream.dart';

void main() {
  group('parseXtreamAuthResponse (fix388)', () {
    test('auth=1 with max_connections=4 → true (full permissions)', () {
      // The "normal" case: a real account, positive max_connections.
      final response = {
        'user_info': {
          'auth': 1,
          'max_connections': 4,
          'status': 'Active',
        },
      };
      expect(parseXtreamAuthResponse(response), isTrue);
    });

    test('auth=1 with max_connections=0 → true (permission-limited)', () {
      // The bug we are fixing: A3000/Media4u test users report
      // auth=1 but max_connections=0 because their permission scope
      // doesn't include that field. Pre-fix388, the dialog said
      // "Login failed" for this case.
      final response = {
        'user_info': {
          'auth': 1,
          'max_connections': 0,
          'status': 'Active',
          'active_cons': 2,
        },
      };
      expect(parseXtreamAuthResponse(response), isTrue);
    });

    test('auth=0 → false (bad credentials)', () {
      final response = {
        'user_info': {
          'auth': 0,
          'max_connections': 0,
        },
      };
      expect(parseXtreamAuthResponse(response), isFalse);
    });

    test('auth=1 with max_connections missing → true', () {
      // Some providers omit max_connections entirely. Auth still
      // succeeded, so the dialog should say "Connected".
      final response = {
        'user_info': {
          'auth': 1,
        },
      };
      expect(parseXtreamAuthResponse(response), isTrue);
    });

    test('missing user_info → false', () {
      // Server returned an error payload (e.g. 401) without user_info.
      final response = <String, dynamic>{};
      expect(parseXtreamAuthResponse(response), isFalse);
    });

    test('non-Map response → false', () {
      // Some servers return a string error or null body on failure.
      expect(parseXtreamAuthResponse(null), isFalse);
      expect(parseXtreamAuthResponse('error'), isFalse);
      expect(parseXtreamAuthResponse(42), isFalse);
    });
  });
}
