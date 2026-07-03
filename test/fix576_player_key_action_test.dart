// fix576: TV D-pad / remote transport in the full-screen player. Before this,
// the player only handled the dedicated CH+/CH− keys; the D-pad arrows + OK did
// nothing. This pins the key→action mapping the user specified:
//   ▲ / CH+  = channel up        ▼ / CH−  = channel down
//   ◀ / ▶    = seek −/+ (seekable)  OK/center = play-pause + reveal bars
// Surf actions require a surfable neighbour; seek requires canSeek — live DVR
// or VOD (fix649 widened the gate from dvrActive so movies/series seek too).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/player/player_key_action.dart';

void main() {
  group('playerKeyAction (fix576)', () {
    test('D-pad up and CH+ → channel up when surfable', () {
      for (final k in [LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.channelUp]) {
        expect(playerKeyAction(k, canSurf: true, canSeek: false),
            PlayerKeyAction.channelUp);
      }
    });

    test('D-pad down and CH− → channel down when surfable', () {
      for (final k
          in [LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.channelDown]) {
        expect(playerKeyAction(k, canSurf: true, canSeek: false),
            PlayerKeyAction.channelDown);
      }
    });

    test('channel keys are no-ops when not surfable', () {
      expect(playerKeyAction(LogicalKeyboardKey.arrowUp, canSurf: false, canSeek: false),
          PlayerKeyAction.none);
      expect(playerKeyAction(LogicalKeyboardKey.channelDown, canSurf: false, canSeek: false),
          PlayerKeyAction.none);
    });

    test('left/right seek ONLY when seeking is available (DVR or VOD)', () {
      expect(playerKeyAction(LogicalKeyboardKey.arrowLeft, canSurf: true, canSeek: true),
          PlayerKeyAction.seekBack);
      expect(playerKeyAction(LogicalKeyboardKey.arrowRight, canSurf: true, canSeek: true),
          PlayerKeyAction.seekForward);
      // Not seekable (plain live, no DVR window) → no seek.
      expect(playerKeyAction(LogicalKeyboardKey.arrowLeft, canSurf: true, canSeek: false),
          PlayerKeyAction.none);
      expect(playerKeyAction(LogicalKeyboardKey.arrowRight, canSurf: true, canSeek: false),
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
        expect(playerKeyAction(k, canSurf: false, canSeek: false),
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
        expect(playerKeyAction(k, canSurf: true, canSeek: true),
            PlayerKeyAction.none);
      }
    });
  });
}
