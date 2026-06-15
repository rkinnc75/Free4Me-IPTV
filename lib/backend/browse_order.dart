/// fix344: the browse ORDER BY, extracted as a pure builder so the EXACT
/// string the app emits is also the string the tests EXPLAIN against a real
/// sqlite database (the fix330 verification failure was testing a hand-written
/// approximation instead of the emitted SQL — never again).
///
/// Background: migration 27 added the expression index
/// `idx_channels_browse_tier (source_id, <6-tier CASE>, name COLLATE NOCASE)`,
/// but the runtime ORDER BY wrapped that tier inside an outer CASE gated by a
/// per-row correlated `(select sort_mode from sources …)` subquery — which the
/// planner can never match to the index, so the "All" view still did a full
/// temp-B-tree sort (~11s cold on the Shield; confirmed by EXPLAIN on a seeded
/// 270k-row DB: `SCAN c … USE TEMP B-TREE FOR ORDER BY`).
///
/// Fix: `Sql.search` now resolves the in-scope sources' sort modes ONCE in
/// Dart. When they are uniform, the emitted ORDER BY is mode-specific with NO
/// subqueries — and the alpha form is structurally identical to the index
/// expression, so the planner walks the index and stops after one page. Only
/// when the in-scope sources MIX modes does the legacy correlated form remain
/// (correct, just unindexable — a rare configuration).
class BrowseOrder {
  BrowseOrder._();

  /// The 6-tier CASE (fix138). MUST stay structurally identical to the
  /// expression in migration 27 (`db_factory.dart`, idx_channels_browse_tier)
  /// or the index silently stops being used. The `c.` alias is fine — SQLite
  /// matches expression structure, not text (verified by EXPLAIN).
  static const String tier = 'CASE'
      ' WHEN COALESCE(c.favorite,0)=1 AND COALESCE(c.stream_validated,0)=1 THEN 0'
      ' WHEN COALESCE(c.favorite,0)=1 THEN 1'
      ' WHEN c.last_watched IS NOT NULL AND COALESCE(c.stream_validated,0)=1 THEN 2'
      ' WHEN c.last_watched IS NOT NULL THEN 3'
      ' WHEN COALESCE(c.stream_validated,0)=1 THEN 4'
      ' ELSE 5 END';

  static const String _favFirst =
      '(CASE WHEN COALESCE(c.favorite,0)=1 THEN 0 ELSE 1 END)';

  /// fix375 (option A): within the favorites block, float VALIDATED favorites
  /// above unvalidated ones in provider/category modes. 0 only for
  /// favorite AND stream_validated; 1 for everything else (unvalidated
  /// favorites and ALL non-favorites), so non-favorite ordering is unchanged.
  /// Alpha mode already encodes this via the 6-tier [tier].
  static const String _valFloat = '(CASE WHEN COALESCE(c.favorite,0)=1'
      ' AND COALESCE(c.stream_validated,0)=1 THEN 0 ELSE 1 END)';

  /// Returns the full "\nORDER BY …" clause for a browse view.
  ///
  /// [uniformMode] is the single sort mode shared by every in-scope source
  /// ('alpha' | 'provider' | 'category'), or null when the sources mix modes.
  static String orderBy(String? uniformMode) {
    switch (uniformMode) {
      case 'provider':
        // fix258: favorites first, then the provider's exact sequence.
        // fix375: validated favorites float to the top of the favorites block.
        return '\nORDER BY $_favFirst ASC,'
            ' $_valFloat ASC,'
            ' c.provider_order ASC,'
            ' c.name COLLATE NOCASE ASC';
      case 'category':
        // fix272: favorites first, then category, then provider order within.
        // fix375: validated favorites float to the top of the favorites block.
        return '\nORDER BY $_favFirst ASC,'
            ' $_valFloat ASC,'
            ' c.group_name COLLATE NOCASE ASC,'
            ' c.provider_order ASC,'
            ' c.name COLLATE NOCASE ASC';
      case 'alpha':
        // Index-served: structurally matches idx_channels_browse_tier.
        return '\nORDER BY $tier ASC, c.name COLLATE NOCASE ASC';
      default:
        // Mixed modes across in-scope sources — legacy correlated form
        // (behaviour-identical to pre-fix344; not index-served).
        const sortMode = 'select sort_mode from sources where id = c.source_id';
        return '\nORDER BY'
            " CASE WHEN ($sortMode) IN ('provider','category')"
            '   THEN $_favFirst'
            '   ELSE $tier'
            ' END ASC,'
            " CASE WHEN ($sortMode) = 'category'"
            '   THEN c.group_name COLLATE NOCASE END ASC,'
            " CASE WHEN ($sortMode) = 'provider'"
            '   THEN c.provider_order END ASC,'
            ' c.name COLLATE NOCASE ASC';
    }
  }

  /// Normalises a stored sort_mode value: anything not provider/category is
  /// alpha (matches the legacy SQL's `IN ('provider','category')` test).
  static String normalise(String? stored) =>
      (stored == 'provider' || stored == 'category') ? stored! : 'alpha';
}
