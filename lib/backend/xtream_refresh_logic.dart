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

  /// fix752: a content type whose fetch FAILED must never be committed as
  /// "empty" — a failed fetch is not data.
  ///
  /// Every prior guard keyed off PRIOR STATE and all three were defeated by
  /// the 2026-07-14 incident (Trex, S938U): an earlier interrupted refresh had
  /// already emptied the source, so
  ///   * fix321 retry     needed lastCount > 0        → 0, skipped
  ///   * finding-63 keep  needed existing rows        → none, skipped
  ///   * fix322 throw     needed failCount >= 3       → only live failed (1)
  /// …and the refresh committed live=0 over an already-empty catalogue, so the
  /// user's 55,325 live channels stayed gone. (Root cause of the fetch failure
  /// itself: the provider allows max_connections=1 and playback was holding
  /// the connection, so get_live_streams returned null while the smaller VOD
  /// calls succeeded.)
  ///
  /// This decision uses only THIS refresh's outcome, so it protects a source
  /// whose prior state is empty, stale, or unknown: if the fetch failed, the
  /// type is preserved from the wipe. Existing rows (if any) survive; if there
  /// are none, nothing is written — but nothing is destroyed either, and the
  /// caller surfaces the failure instead of silently reporting success.
  static Set<int> typesToKeepOnFetchFailure(Set<int> failedMediaTypes) =>
      Set<int>.from(failedMediaTypes);

  /// fix752: true when at least one type failed but not all of them — a
  /// PARTIAL refresh. The commit proceeds (the types that succeeded are
  /// legitimately fresh), but the user must be told that the failed types kept
  /// their previous contents rather than being updated.
  static bool isPartialRefresh({
    required Set<int> failedMediaTypes,
    required int typeCount,
  }) =>
      failedMediaTypes.isNotEmpty && failedMediaTypes.length < typeCount;
}
