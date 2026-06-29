import 'package:flutter/foundation.dart';

Set<int> refreshedSeries = {};

/// fix611: true while a full-catalog FTS index rebuild runs at the end of a
/// bulk source refresh. The search UI watches this and disables the search
/// field (showing "Search updating...") ONLY when the active search method is
/// FTS-backed (ftsPhrase / ftsAnd); likeSubstring and inMemory do not use
/// channels_fts and stay usable. Set true by Sql.withSuspendedFtsTriggers
/// immediately before the global FTS rebuild and cleared in its finally, so it
/// is restored to false even when the refresh body throws. A ValueNotifier so
/// widgets can listen without a heavier state-management dependency.
final ValueNotifier<bool> ftsRebuilding = ValueNotifier<bool>(false);
