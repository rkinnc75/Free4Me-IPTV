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
/// - ◀ / ▶    → seek −/+     (only when [canSeek]; otherwise no-op)
/// - OK/center/Enter/PlayPause → toggle play-pause and reveal the bars
///
/// fix649: the seek gate is now [canSeek] (was `dvrActive`) — the caller
/// passes live-DVR *or* VOD seekability, so ◀/▶ work on movies/series on TV
/// instead of only inside a live DVR window.
///
/// Returns [PlayerKeyAction.none] for anything else (and for surf/seek when the
/// precondition is unmet), so the caller can leave the key unhandled and let it
/// bubble (Back, focus traversal, etc.).
PlayerKeyAction playerKeyAction(
  LogicalKeyboardKey key, {
  required bool canSurf,
  required bool canSeek,
}) {
  // finding 174: dedicated remote transport keys reuse the existing actions —
  // ⏮ CH+, ⏭ CH−, ⏪ seek−, ⏩ seek+ — so a remote with discrete media keys
  // works without a separate handler (the player.dart switch already covers
  // all five enum values).
  if (key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.channelUp ||
      key == LogicalKeyboardKey.mediaTrackPrevious) {
    return canSurf ? PlayerKeyAction.channelUp : PlayerKeyAction.none;
  }
  if (key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.channelDown ||
      key == LogicalKeyboardKey.mediaTrackNext) {
    return canSurf ? PlayerKeyAction.channelDown : PlayerKeyAction.none;
  }
  if (key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.mediaRewind) {
    return canSeek ? PlayerKeyAction.seekBack : PlayerKeyAction.none;
  }
  if (key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.mediaFastForward) {
    return canSeek ? PlayerKeyAction.seekForward : PlayerKeyAction.none;
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
