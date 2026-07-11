import 'package:flutter/animation.dart';

/// fix701 (TV GUI redesign, Phase 0) — the single motion vocabulary for TV mode.
///
/// Every animated duration in the TV UI names one of these constants and one of
/// the curves below; no more inline `Duration(milliseconds: …)` / bare `Cubic`.
/// TV-scoped: the phone (`hasTouchScreen`) UI never imports this.
///
/// The defining rule (from the Peer4 focus language): **focus-IN is INSTANT**
/// (the ring alpha snaps to 1.0 on focus gain, no tween) and **only focus-OUT
/// animates** ([focusOut]). That asymmetry is what kills the one-frame
/// no-focus flash on fast D-pad travel — see [TvFocusable].
class F4Motion {
  F4Motion._();

  // --- Durations ---
  /// Focus ring / color changes.
  static const Duration fast = Duration(milliseconds: 150);

  /// Scale / move / scrim fade.
  static const Duration normal = Duration(milliseconds: 200);

  /// Page / hero band emphasis.
  static const Duration emphasis = Duration(milliseconds: 300);

  /// Route crossfade in / out.
  static const Duration crossIn = Duration(milliseconds: 250);
  static const Duration crossOut = Duration(milliseconds: 200);

  /// Focus RING fade-OUT only (asymmetric — focus-in is instant).
  static const Duration focusOut = Duration(milliseconds: 120);

  /// Dense-grid cheap focus (EPG) — near-imperceptible, protects scroll fps.
  static const Duration epgFocus = Duration(milliseconds: 70);

  /// Channel-zap shutter fade-in (Peer2).
  static const Duration shutter = Duration(milliseconds: 150);

  /// Ambient image treatments.
  static const Duration kenBurns = Duration(milliseconds: 20000);
  static const Duration imgCross = Duration(milliseconds: 250);

  // --- Scales ---
  static const double scaleFocused = 1.05;
  static const double scalePressed = 0.97;

  /// Near-imperceptible focus scale for the dense EPG grid.
  static const double scaleEpgFocused = 1.004;

  // --- Curves ---
  /// Decelerate-only. Used by: fast, focusOut, epgFocus, normal (scale/move),
  /// crossIn, crossOut, the player scrim fade (§5), and the zap shutter (§4.7).
  static const Cubic easeOut = Cubic(0, 0, 0.2, 1);

  /// Accelerate-then-decelerate. Used by: emphasis (page / hero band, the route
  /// body and the Phase-6 guide top-band crossfade). Single call site for both
  /// [emphasis] and [fastOutSlow].
  static const Cubic fastOutSlow = Cubic(0.4, 0, 0.2, 1);

  // --- Auto-hide bands (Peer2; any D-pad press resets the timer) ---
  static const Duration osdAutoHide = Duration(milliseconds: 5000);
  static const Duration osdQuickDismiss = Duration(milliseconds: 2000);
  static const Duration menuDetailHide = Duration(milliseconds: 10000);

  // --- D-pad repeat gate (Peer4 per-axis; first press never throttled) ---
  /// Horizontal repeat throttle (column jumps).
  static const Duration repeatHoriz = Duration(milliseconds: 80);

  /// Vertical repeat throttle — slower, because row jumps are more disorienting.
  static const Duration repeatVert = Duration(milliseconds: 112);
}
