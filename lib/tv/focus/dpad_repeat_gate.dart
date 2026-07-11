import 'package:flutter/services.dart';

import '../theme/f4_motion.dart';

/// fix701 (TV GUI redesign, Phase 0) — per-axis D-pad auto-repeat throttle.
///
/// Cheap TV remotes fire fast auto-repeat that overscrolls dense rails/grids.
/// This gate lets the FIRST press ([KeyDownEvent]) through always, and throttles
/// HELD repeats ([KeyRepeatEvent]) per axis — horizontal [F4Motion.repeatHoriz]
/// (80ms) and vertical [F4Motion.repeatVert] (112ms, slower because row jumps
/// are more disorienting). Flutter's [KeyEvent] has no `repeatCount`; first-vs-
/// held is the event TYPE, so no app-maintained counter is needed. Uses the
/// event's monotonic [KeyEvent.timeStamp] (no wall-clock).
class DpadRepeatGate {
  Duration? _lastHoriz;
  Duration? _lastVert;

  /// Whether [event] should be acted on. Non-directional keys always pass;
  /// the caller still decides what to do with them.
  bool allow(KeyEvent event) {
    final k = event.logicalKey;
    final horiz = k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight;
    final vert = k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown;
    if (!horiz && !vert) return true;

    if (event is KeyDownEvent) {
      // First press is never throttled; reset the axis clock.
      if (horiz) {
        _lastHoriz = event.timeStamp;
      } else {
        _lastVert = event.timeStamp;
      }
      return true;
    }
    if (event is KeyRepeatEvent) {
      final now = event.timeStamp;
      final gate = horiz ? F4Motion.repeatHoriz : F4Motion.repeatVert;
      final last = horiz ? _lastHoriz : _lastVert;
      if (last == null || now - last >= gate) {
        if (horiz) {
          _lastHoriz = now;
        } else {
          _lastVert = now;
        }
        return true;
      }
      return false; // held repeat within the throttle window — drop it
    }
    return false; // KeyUpEvent etc. are not actionable moves
  }
}
