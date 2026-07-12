// fix714 (Phase 4 — TV player OSD, unit 1) — the Peer2 bottom Info Bar. The
// channel name + NOW/NEXT EPG + seek-progress row move out of the flat top bar
// into a token-glass Info Bar anchored above the action buttons. Chrome-only:
// no engine / focus / key-handling / channel-surf changes; the touch (non-TV)
// control path is untouched (still uses the labels directly).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _slice(String s, String from, String to) {
  final a = s.indexOf(from);
  if (a < 0) return '';
  final b = to.isEmpty ? s.length : s.indexOf(to, a + from.length);
  return s.substring(a, b < 0 ? s.length : b);
}

void main() {
  final player = File('lib/player.dart').readAsStringSync();
  // the TV overlay method only (touch path lives in a different method)
  final overlay =
      _slice(player, 'Widget _buildTvOverlay()', 'KeyEventResult _onPlayerKey');

  test('TV overlay renders the PlayerInfoBar with the seek-progress row', () {
    expect(player.contains("import 'package:open_tv/player/tv_osd/info_bar.dart'"),
        isTrue);
    expect(overlay.contains('PlayerInfoBar('), isTrue);
    expect(overlay.contains('channel: widget.channel'), isTrue);
    // the seek-progress row is now fed INTO the Info Bar, not a standalone row
    expect(
        overlay.contains('progress: seekable ? _buildOverlayProgress() : null'),
        isTrue);
  });

  test('name + NOW/NEXT moved OUT of the TV overlay top bar', () {
    // they now live in the Info Bar; the touch path (different method) still
    // uses them, so we assert against the _buildTvOverlay slice specifically.
    expect(overlay.contains('PlayerChannelNameLabel'), isFalse);
    expect(overlay.contains('PlayerEpgNowLabel'), isFalse);
  });

  test('kept: focus/key/surf machinery untouched', () {
    // the action bottomBar, playPause autofocus, and _navMode key model stay
    expect(player.contains('focusNode: _overlayFirstFocus'), isTrue);
    expect(player.contains('FocusTraversalGroup'), isTrue);
    expect(player.contains('KeyEventResult _onPlayerKey'), isTrue);
  });

  group('info_bar.dart', () {
    final ib = File('lib/player/tv_osd/info_bar.dart').readAsStringSync();
    test('reuses the existing self-updating label widgets + progress', () {
      expect(ib.contains('PlayerChannelNameLabel('), isTrue);
      expect(ib.contains('PlayerEpgNowLabel('), isTrue);
      expect(ib.contains('progress'), isTrue);
      // NOW/NEXT only on live
      expect(ib.contains('if (live)'), isTrue);
    });
    test('token-glass surface (F4 tokens)', () {
      expect(ib.contains('F4.of(context)'), isTrue);
      expect(ib.contains('t.colors.glassFill'), isTrue);
      expect(ib.contains('display-only'), isTrue); // documented: no focus nodes
    });
  });
}
