// fix576: TV D-pad / remote transport in the full-screen player. Before this,
// the player only handled the dedicated CH+/CH− keys; the D-pad arrows + OK did
// nothing. This pins the key→action mapping the user specified:
//   ▲ / CH+  = channel up        ▼ / CH−  = channel down
//   ◀ / ▶    = seek −/+10s (DVR)  OK/center = play-pause + reveal bars
// Surf actions require a surfable neighbour; seek requires DVR/seek active.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/player/player_key_action.dart';

void main() {
  group('playerKeyAction (fix576)', () {
    test('D-pad up and CH+ → channel up when surfable', () {
      for (final k in [LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.channelUp]) {
        expect(playerKeyAction(k, canSurf: true, dvrActive: false),
            PlayerKeyAction.channelUp);
      }
    });

    test('D-pad down and CH− → channel down when surfable', () {
      for (final k
          in [LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.channelDown]) {
        expect(playerKeyAction(k, canSurf: true, dvrActive: false),
            PlayerKeyAction.channelDown);
      }
    });

    test('channel keys are no-ops when not surfable', () {
      expect(playerKeyAction(LogicalKeyboardKey.arrowUp, canSurf: false, dvrActive: false),
          PlayerKeyAction.none);
      expect(playerKeyAction(LogicalKeyboardKey.channelDown, canSurf: false, dvrActive: false),
          PlayerKeyAction.none);
    });

    test('left/right seek ONLY when DVR/seek is active', () {
      expect(playerKeyAction(LogicalKeyboardKey.arrowLeft, canSurf: true, dvrActive: true),
          PlayerKeyAction.seekBack);
      expect(playerKeyAction(LogicalKeyboardKey.arrowRight, canSurf: true, dvrActive: true),
          PlayerKeyAction.seekForward);
      // No DVR → no seek (so a forward/back press does nothing, as specified).
      expect(playerKeyAction(LogicalKeyboardKey.arrowLeft, canSurf: true, dvrActive: false),
          PlayerKeyAction.none);
      expect(playerKeyAction(LogicalKeyboardKey.arrowRight, canSurf: true, dvrActive: false),
          PlayerKeyAction.none);
    });

    test('OK / center / Enter / PlayPause → play-pause + reveal (always)', () {
      for (final k in [
        LogicalKeyboardKey.select,
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.numpadEnter,
        LogicalKeyboardKey.gameButtonA,
        LogicalKeyboardKey.mediaPlayPause,
      ]) {
        expect(playerKeyAction(k, canSurf: false, dvrActive: false),
            PlayerKeyAction.playPauseReveal,
            reason: '$k should map to play-pause + reveal regardless of state');
      }
    });

    test('unrelated keys are ignored (bubble to Back/traversal)', () {
      for (final k in [
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.goBack,
        LogicalKeyboardKey.keyA,
        LogicalKeyboardKey.tab,
      ]) {
        expect(playerKeyAction(k, canSurf: true, dvrActive: true),
            PlayerKeyAction.none);
      }
    });
  });
}
