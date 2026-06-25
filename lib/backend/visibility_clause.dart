/// fix371 (cold-eyes MED-2): the channel-visibility WHERE predicates, extracted
/// as ONE pure builder so all three search/browse paths emit byte-identical
/// filtering — the same discipline `BrowseOrder` (fix344) applied to ORDER BY.
///
/// Why this exists: episode exclusion (fix355/362), divider hiding (fix272),
/// and category-enabled hiding (fix278 → fix365's denormalized `cat_enabled`)
/// were duplicated across `Sql.search`'s FTS/no-query path, `Sql._searchLike`,
/// and the in-memory `ChannelSearchCache`. They drifted: fix365 migrated the
/// FTS path to `c.cat_enabled = 1` but LEFT `_searchLike` on the slow
/// correlated `(SELECT g.enabled …)` subquery, and fix370 had to retrofit the
/// restore path because the rule lived in three places. One builder makes that
/// class of bug impossible: change the rule once, every path follows.
class VisibilityClause {
  VisibilityClause._();

  /// Build the visibility predicates appended after the WHERE base and before
  /// ORDER BY. [alias] is the column prefix the calling query uses (`''` for
  /// the unaliased no-query path, `'c.'` for the FTS and LIKE paths).
  ///
  /// Returns the SQL fragment plus the ordered positional params it introduces.
  /// Behaviour (identical across every path):
  ///   - seriesId set  → `series_id = ?`        (series view: only its episodes)
  ///   - seriesId null → `series_id IS NULL`    (exclude episodes)
  ///                     + groupId set: `group_id = ?` (browsing a category)
  ///   - always        → divider-hide correlated guard (fix272)
  ///   - groupId null   → `cat_enabled = 1`     (hide disabled categories;
  ///                       fix365 denormalized column, index-covered)
  static (String sql, List<Object> params) build({
    required String alias,
    required int? seriesId,
    required int? groupId,
  }) {
    final p = alias;
    final params = <Object>[];
    final b = StringBuffer();

    if (seriesId != null) {
      b.write('\nAND ${p}series_id = ?'); // series view — only its episodes
      params.add(seriesId);
    } else {
      b.write('\nAND ${p}series_id IS NULL'); // exclude episodes (fix355)
      if (groupId != null) {
        // Browsing INTO a category (fix302): show all its channels regardless
        // of the enabled checkbox.
        b.write('\nAND ${p}group_id = ?');
        params.add(groupId);
      }
    }

    // fix546: the divider-hiding filter was removed. "##### HEADER #####"
    // divider rows are now discarded at import (xtream.dart / m3u.dart) and
    // purged from existing catalogs by Sql.runPendingDividerCleanup(), so no
    // per-row is_divider/hide_dividers check is needed on every browse query.
    // (Previously: AND NOT (is_divider=1 AND (SELECT hide_dividers …)=1), a
    // correlated subquery whose backing idx_channel_divider was already dropped
    // in fix537.)

    // Category-enabled hiding (fix278 → fix365): applied whenever NOT browsing
    // into a specific category (groupId null) — exactly the original shipped
    // gate. cat_enabled (denormalized groups.enabled) is covered by
    // idx_channels_browse_enabled, so disabled rows are skipped without a
    // per-row subquery (was a 5s grid load on large catalogs). Note this also
    // applies in a series view (seriesId set, groupId null), matching prior
    // behaviour: a series whose category is disabled stays hidden.
    if (groupId == null) {
      b.write('\nAND ${p}cat_enabled = 1');
    }

    return (b.toString(), params);
  }
}
