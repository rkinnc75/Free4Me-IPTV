// fix716 (Phase 4 — TV player OSD, unit 3) — the Peer2 Channel Bar: a
// DISPLAY-ONLY horizontal strip of the current surf group, centered on the
// tuned channel (accent-highlighted), above the Info Bar in the revealed OSD.
// IgnorePointer + no FocusNode → it never joins the overlay FocusTraversalGroup,
// so the D-pad / _navMode / trigger model is untouched (Option B). ▲▼ still
// surfs; a fresh Player at the new index re-centers the strip.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _slice(String s, String from, String to) {
  final a = s.indexOf(from);
  if (a < 0) return '';
  final b = to.isEmpty ? s.length : s.indexOf(to, a + from.length);
  return s.substring(a, b < 0 ? s.length : b);
}

void main() {
  final cb = File('lib/player/tv_osd/channel_bar.dart').readAsStringSync();
  final player = File('lib/player.dart').readAsStringSync();

  group('PlayerChannelBar', () {
    test('display-only: IgnorePointer + non-scrollable, no FocusNode/InkWell',
        () {
      expect(cb.contains('IgnorePointer('), isTrue);
      expect(cb.contains('NeverScrollableScrollPhysics()'), isTrue);
      // no actual focus/gesture USAGE (the doc comment mentions the words)
      expect(cb.contains('FocusNode('), isFalse);
      expect(cb.contains('focusNode:'), isFalse);
      expect(cb.contains('InkWell(') || cb.contains('GestureDetector('),
          isFalse);
    });
    test('highlights the tuned channel (accent border, brighter)', () {
      expect(cb.contains('final isCurrent = i == current'), isTrue);
      expect(cb.contains('AccentScope.of(context)'), isTrue);
      expect(cb.contains('Border.all(color: accent, width: 2)'), isTrue);
      expect(cb.contains('opacity: isCurrent ? 1.0 : 0.55'), isTrue);
    });
    test('auto-centers the current channel via a ScrollController', () {
      expect(cb.contains('ScrollController'), isTrue);
      expect(cb.contains('addPostFrameCallback'), isTrue);
      expect(cb.contains('_centerCurrent'), isTrue);
      expect(cb.contains('_sc.dispose()'), isTrue); // no leak
    });
    test('reuses the PlaybackPlaylist (channels + index) — no new data', () {
      expect(cb.contains('widget.playlist.channels'), isTrue);
      expect(cb.contains('widget.playlist.index'), isTrue);
    });
  });

  test('wired into the OSD above the Info Bar, gated on a surfable group', () {
    expect(
        player.contains(
            "import 'package:open_tv/player/tv_osd/channel_bar.dart'"),
        isTrue);
    final overlay = _slice(player, 'Widget _buildTvOverlay()', 'KeyEventResult _onPlayerKey');
    expect(overlay.contains('if (_canSurf && widget.playlist != null)'), isTrue);
    expect(overlay.contains('PlayerChannelBar(playlist: widget.playlist!)'),
        isTrue);
    // above the Info Bar (Channel Bar appears earlier in the Column)
    expect(
        overlay.indexOf('PlayerChannelBar(') < overlay.indexOf('PlayerInfoBar('),
        isTrue);
  });
}
