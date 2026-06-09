/// fix325: pure decision logic for the Xtream refresh retry/preserve/throw
/// flow (fix321/fix322), extracted from getXtream so it can be unit-tested.
/// Keep this file free of I/O and Flutter imports — `flutter test` exercises
/// it directly (see test/xtream_refresh_logic_test.dart).
class XtreamRefreshLogic {
  XtreamRefreshLogic._();

  /// A content type qualifies for the fix321 retry when its fresh fetch came
  /// back empty but the previous refresh recorded rows for it (a brand-new or
  /// genuinely empty type never retries).
  static bool shouldRetryType({required int count, required int? lastCount}) =>
      count == 0 && (lastCount ?? 0) > 0;

  /// fix322: a retry that recovered data undoes one initial failure so a
  /// successful retry can never leave failCount at the 3/3 throw with real
  /// data in hand (the Z2U bug). Never goes below zero.
  static int reconcileFailCount(int failCount) =>
      failCount > 0 ? failCount - 1 : 0;

  /// fix322: hard-fail ONLY when every content type failed AND nothing was
  /// preserved from a prior refresh — i.e. a genuinely dead or brand-new
  /// source. If any type was preserved, the refresh is a successful no-op for
  /// those types and must commit without throwing.
  static bool shouldThrowAllFailed({
    required int failCount,
    required Set<int> keepMediaTypes,
  }) =>
      failCount >= 3 && keepMediaTypes.isEmpty;
}
