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

  // fix752: the 2026-07-14 Trex/S938U incident. An earlier interrupted refresh
  // had already emptied the source, so EVERY prior guard — which all key off
  // PRIOR STATE — was defeated:
  //   fix321 retry    needed lastCount > 0   -> 0,    skipped
  //   finding-63 keep needed existing rows   -> none, skipped
  //   fix322 throw    needed failCount >= 3  -> 1,    no throw
  // …and get_live_streams' FAILED fetch (HTTP null; the provider's
  // max_connections=1 was held by playback) was committed as live=0, so 55,325
  // live channels stayed gone. A failed fetch is not data.
  group('fix752 — a FAILED fetch must never be committed as empty', () {
    test('the incident: only live failed -> live is kept from the wipe', () {
      final keep = XtreamRefreshLogic.typesToKeepOnFetchFailure({0});
      expect(keep, contains(0),
          reason: 'live failed, so it must be preserved from the wipe even '
              'though the source had no rows and lastLiveCount was 0');
      expect(keep, isNot(contains(1)));
      expect(keep, isNot(contains(2)));
    });

    test('decision uses ONLY this refresh — prior state is irrelevant', () {
      // No lastCount, no existing rows, nothing preserved: the old guards all
      // fail here. This one still protects the type.
      expect(XtreamRefreshLogic.typesToKeepOnFetchFailure({0, 2}), {0, 2});
    });

    test('a clean refresh keeps nothing (no false preservation)', () {
      expect(XtreamRefreshLogic.typesToKeepOnFetchFailure({}), isEmpty);
    });

    test('the incident is a PARTIAL refresh -> user must be warned', () {
      expect(
          XtreamRefreshLogic.isPartialRefresh(
              failedMediaTypes: {0}, typeCount: 3),
          isTrue,
          reason: 'live failed while movies+series succeeded — the commit '
              'proceeds, but reporting a bare "Refresh complete." is what let '
              'an empty catalogue masquerade as success');
    });

    test('a fully-successful refresh is NOT partial', () {
      expect(
          XtreamRefreshLogic.isPartialRefresh(
              failedMediaTypes: {}, typeCount: 3),
          isFalse);
    });

    test('a TOTAL failure is not "partial" — shouldThrowAllFailed owns it', () {
      expect(
          XtreamRefreshLogic.isPartialRefresh(
              failedMediaTypes: {0, 1, 2}, typeCount: 3),
          isFalse,
          reason: 'all three failed: that is a hard failure, not a partial '
              'refresh needing a soft warning');
    });
  });
}
