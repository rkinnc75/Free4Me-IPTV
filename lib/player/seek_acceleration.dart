/// fix651: hold-to-seek acceleration for the ◀/▶ transport keys.
///
/// Pure (no Flutter state) so the ladder is unit-testable in isolation —
/// the same pattern as player_key_action.dart (fix576).
///
/// [repeatCount] is the number of KeyRepeat events since the initial KeyDown
/// (0 = the first press). [duration] is the content duration
/// ([Duration.zero] when unknown — a live DVR window reports a growing /
/// unreliable length, so it is passed as unknown).
///
/// Ladder (seconds per press):
///   repeats 0–4   → 10
///   repeats 5–9   → 30   (content ≥ 5 min; shorter stays at 10)
///   repeats 10–14 → 60   (content ≥ 30 min)
///   repeats 15+   → 120  (content ≥ 90 min)
///
/// Unknown duration is treated conservatively and caps at 30 s — a live DVR
/// cushion is rarely more than a few minutes deep.
int seekStepSeconds({required int repeatCount, required Duration duration}) {
  final unknown = duration <= Duration.zero;
  final mins = duration.inMinutes;
  if (repeatCount < 5) return 10;
  if (repeatCount < 10 || unknown || mins < 30) {
    return (unknown || mins >= 5) ? 30 : 10;
  }
  if (repeatCount < 15 || mins < 90) return 60;
  return 120;
}
