import 'package:flutter/services.dart';

/// fix576: the transport action a player key maps to. Pure (no Flutter state)
/// so the D-pad/remote mapping is unit-testable in isolation from the Player
/// widget + engine.
enum PlayerKeyAction {
  channelUp,
  channelDown,
  seekBack,
  seekForward,
  playPauseReveal,
  none,
}

/// Map a logical key to a [PlayerKeyAction] for the full-screen player.
///
/// - ▲ / CH+  → channel up   (only when [canSurf])
/// - ▼ / CH−  → channel down (only when [canSurf])
/// - ◀ / ▶    → seek −/+10s  (only when [dvrActive]; otherwise no-op)
/// - OK/center/Enter/PlayPause → toggle play-pause and reveal the bars
///
/// Returns [PlayerKeyAction.none] for anything else (and for surf/seek when the
/// precondition is unmet), so the caller can leave the key unhandled and let it
/// bubble (Back, focus traversal, etc.).
PlayerKeyAction playerKeyAction(
  LogicalKeyboardKey key, {
  required bool canSurf,
  required bool dvrActive,
}) {
  if (key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.channelUp) {
    return canSurf ? PlayerKeyAction.channelUp : PlayerKeyAction.none;
  }
  if (key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.channelDown) {
    return canSurf ? PlayerKeyAction.channelDown : PlayerKeyAction.none;
  }
  if (key == LogicalKeyboardKey.arrowLeft) {
    return dvrActive ? PlayerKeyAction.seekBack : PlayerKeyAction.none;
  }
  if (key == LogicalKeyboardKey.arrowRight) {
    return dvrActive ? PlayerKeyAction.seekForward : PlayerKeyAction.none;
  }
  if (key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA ||
      key == LogicalKeyboardKey.mediaPlayPause) {
    return PlayerKeyAction.playPauseReveal;
  }
  return PlayerKeyAction.none;
}
