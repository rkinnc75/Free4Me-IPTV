// fix715 (Phase 4 — TV player OSD, unit 2) — OSD action buttons get the Peer2
// focus LIFT (scale-up on focus) on top of the accent ring the global
// iconButtonTheme already draws (fix707). Option B: the reveal trigger and all
// D-pad / _navMode behavior are UNCHANGED — `_ovlButton` just routes through
// OsdActionButton, so every call site is untouched.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _slice(String s, String from, String to) {
  final a = s.indexOf(from);
  if (a < 0) return '';
  final b = to.isEmpty ? s.length : s.indexOf(to, a + from.length);
  return s.substring(a, b < 0 ? s.length : b);
}

void main() {
  final ab = File('lib/player/tv_osd/action_button.dart').readAsStringSync();
  final player = File('lib/player.dart').readAsStringSync();

  group('OsdActionButton', () {
    test('scales up on focus via AnimatedScale (F4Motion lift)', () {
      expect(ab.contains('AnimatedScale('), isTrue);
      expect(ab.contains('scale: _focused ? 1.15 : 1.0'), isTrue);
      expect(ab.contains('F4Motion.fast'), isTrue);
      expect(ab.contains('F4Motion.easeOut'), isTrue);
    });
    test('observes the focus node; onInteract fires before onTap', () {
      expect(ab.contains('_node.addListener(_onFocusChange)'), isTrue);
      expect(ab.contains('_node.removeListener(_onFocusChange)'), isTrue);
      final onPressed = _slice(ab, 'onPressed:', '},');
      expect(onPressed.indexOf('onInteract') < onPressed.indexOf('onTap'),
          isTrue);
    });
    test('disposes ONLY a self-created node (caller node is theirs)', () {
      // caller-supplied node (e.g. play/pause autofocus) must NOT be disposed
      expect(ab.contains('_own?.dispose()'), isTrue);
      expect(ab.contains('widget.focusNode ?? (_own ??= FocusNode())'), isTrue);
    });
    test('didUpdateWidget moves the listener if the node changes (robustness)',
        () {
      expect(ab.contains('void didUpdateWidget('), isTrue);
      expect(ab.contains('old.focusNode != widget.focusNode'), isTrue);
      expect(ab.contains('(old.focusNode ?? _own)?.removeListener'), isTrue);
    });
  });

  group('player.dart wiring', () {
    test('_ovlButton routes through OsdActionButton (call sites unchanged)', () {
      expect(
          player.contains(
              "import 'package:open_tv/player/tv_osd/action_button.dart'"),
          isTrue);
      final ovl = _slice(player, 'Widget _ovlButton(', 'Future<void> _openSubtitlesFromOverlay');
      expect(ovl.contains('OsdActionButton('), isTrue);
      expect(ovl.contains('onInteract: _resetOverlayHideTimer'), isTrue);
      // the bare IconButton form is gone from the helper
      expect(ovl.contains('IconButton('), isFalse);
    });
    test('kept: trigger/focus model unchanged (play/pause autofocus node)', () {
      expect(player.contains('focusNode: _overlayFirstFocus'), isTrue);
      expect(player.contains('KeyEventResult _onPlayerKey'), isTrue);
    });
  });
}
