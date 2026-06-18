/// fix401: whether a Categories (group) search should skip the scan because
/// every term is too short to be meaningful.
///
/// Aligned with fix400's ≥2-char UI gate: a 2-char term is allowed (the groups
/// table is small and LIKE-searched, so a 2-char scan costs ~ms). The old
/// threshold was < 3, which made the Categories search silently require three
/// characters even on `likeSubstring`, where a 2-char query matches fine.
///   • empty / whitespace-only → false (don't skip; restores the full list)
///   • every term exactly 1 char → true (skip)
///   • any term ≥2 chars → false (run the search)
bool groupSearchAllTermsTooShort(String rawQuery, {bool useKeywords = false}) {
  final q = rawQuery.trim();
  if (q.isEmpty) return false;
  final terms = useKeywords
      ? q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty)
      : [q];
  return terms.every((t) => t.length < 2);
}
