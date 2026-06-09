// fix325: the fix321/fix322 retry/preserve/throw decision table, as proven
// on-device 2026-06-09 (Z2U retry-recovery, Emjay partial preserve).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/backend/xtream_refresh_logic.dart';

void main() {
  group('shouldRetryType', () {
    test('retries only empty-now + had-rows-before', () {
      expect(XtreamRefreshLogic.shouldRetryType(count: 0, lastCount: 55000),
          isTrue);
      expect(XtreamRefreshLogic.shouldRetryType(count: 0, lastCount: 0),
          isFalse);
      expect(XtreamRefreshLogic.shouldRetryType(count: 0, lastCount: null),
          isFalse); // brand-new source: never retry/preserve
      expect(XtreamRefreshLogic.shouldRetryType(count: 100, lastCount: 55000),
          isFalse);
    });
  });

  group('reconcileFailCount', () {
    test('successful retry undoes one failure, floor at zero', () {
      expect(XtreamRefreshLogic.reconcileFailCount(3), 2);
      expect(XtreamRefreshLogic.reconcileFailCount(1), 0);
      expect(XtreamRefreshLogic.reconcileFailCount(0), 0);
    });
  });

  group('shouldThrowAllFailed', () {
    test('Z2U bug: all empty but all recovered on retry -> no throw', () {
      // 3 initial failures, 3 successful retries: failCount 3 -> 0.
      var f = 3;
      for (var i = 0; i < 3; i++) {
        f = XtreamRefreshLogic.reconcileFailCount(f);
      }
      expect(
          XtreamRefreshLogic.shouldThrowAllFailed(
              failCount: f, keepMediaTypes: {}),
          isFalse);
    });

    test('all empty, retries fail, prior data preserved -> no throw', () {
      expect(
          XtreamRefreshLogic.shouldThrowAllFailed(
              failCount: 3, keepMediaTypes: {0, 1, 2}),
          isFalse);
    });

    test('new source, all empty, nothing to preserve -> throw', () {
      expect(
          XtreamRefreshLogic.shouldThrowAllFailed(
              failCount: 3, keepMediaTypes: {}),
          isTrue);
    });

    test('Emjay case: one type live, two preserved -> no throw', () {
      expect(
          XtreamRefreshLogic.shouldThrowAllFailed(
              failCount: 2, keepMediaTypes: {1, 2}),
          isFalse);
    });
  });
}
