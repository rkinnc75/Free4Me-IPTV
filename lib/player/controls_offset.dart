/// fix406: how far DOWN to translate the single-cell centre control row
/// (media_kit's `primaryButtonBar`) from its hard-coded vertical centre, so it
/// sits just above the bottom icon row without colliding.
///
/// media_kit centres `primaryButtonBar` in the gap between the top bar and the
/// bottom bar (`Expanded` → `Center`) and exposes no knob for it, so the row is
/// shifted with a `Transform.translate`. This computes that shift:
///   • a formula that lands the row just above the bottom controls on phones
///     (the common case), plus
///   • a safe cap (≈⅓ of the height) so it can never overshoot into the bottom
///     row on tall screens (TVs), and a `>= 0` floor so it never moves up.
///
/// `isLive` widens the bottom reserve on VOD to also clear the seek bar.
double loweredPrimaryBarOffset({
  required double height,
  required bool isLive,
}) {
  const topRegion = 56.0; // top button bar + margin
  final bottomRegion = isLive
      ? 72.0 // bottom icon row + margin (no seek bar on live)
      : 150.0; // + seek bar on VOD
  const clearance = 24.0; // gap left above the bottom row
  const halfRow = 24.0; // half the 48px play/pause button
  final byFormula =
      (height / 2) - (topRegion + bottomRegion) / 2 - clearance - halfRow;
  final safeCap = height * 0.32;
  return byFormula.clamp(0.0, safeCap);
}
