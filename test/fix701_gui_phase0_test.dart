// fix701 (TV GUI redesign, Phase 0) — the token tree + focus engine foundation.
// These files are additive and TV-scoped; nothing reads them yet, so the phone
// UI is byte-identical. This pins the foundation's shape + the main.dart wiring
// (F4Tokens attached to ThemeData.extensions; AccentScope installed above route
// content) so a later phase can rely on F4.of(context) / AccentScope.of(context).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fix701 token tree', () {
    final tokens = File('lib/tv/theme/f4_tokens.dart').readAsStringSync();
    final motion = File('lib/tv/theme/f4_motion.dart').readAsStringSync();
    final accent = File('lib/tv/theme/accent_scope.dart').readAsStringSync();

    test('F4Tokens is a ThemeExtension with F4.of + does not shadow `type`', () {
      expect(tokens.contains('class F4Tokens extends ThemeExtension<F4Tokens>'),
          isTrue);
      expect(tokens.contains('static F4Tokens of(BuildContext context)'), isTrue);
      // `type` would override ThemeExtension.type and break extension lookup.
      expect(tokens.contains('F4Type typography'), isTrue);
      expect(tokens.contains('F4Type type;'), isFalse);
    });

    test('motion: asymmetric focus (instant in, 120ms out) + per-axis repeat', () {
      expect(motion.contains('focusOut = Duration(milliseconds: 120)'), isTrue);
      expect(motion.contains('repeatHoriz = Duration(milliseconds: 80)'), isTrue);
      expect(motion.contains('repeatVert = Duration(milliseconds: 112)'), isTrue);
      expect(motion.contains('scaleFocused = 1.05'), isTrue);
    });

    test('accent: InheritedNotifier + ROYGBIV default-white + app notifier', () {
      expect(
          accent.contains(
              'class AccentScope extends InheritedNotifier<ValueNotifier<Color>>'),
          isTrue);
      expect(accent.contains('Color accentFromName(String? name)'), isTrue);
      expect(accent.contains('final ValueNotifier<Color> appAccentNotifier'),
          isTrue);
    });
  });

  group('fix701 focus engine', () {
    final tvf = File('lib/tv/focus/tv_focusable.dart').readAsStringSync();
    final gate = File('lib/tv/focus/dpad_repeat_gate.dart').readAsStringSync();

    test('TvFocusable: accent ring + fire-on-release held-OK (never mid-hold)', () {
      expect(tvf.contains('class TvFocusable extends StatefulWidget'), isTrue);
      expect(tvf.contains('AccentScope.of(context)'), isTrue);
      // instant focus-in, animated focus-out
      expect(tvf.contains('_ring.value = 1.0'), isTrue);
      expect(tvf.contains('_ring.animateTo(0'), isTrue);
      // review fix: focus-out resets transient press/hold state (no stuck 0.97
      // scale / leaked timer if focus is stolen mid-hold).
      expect(tvf.contains('_focused = false') && tvf.contains('_pressed = false'),
          isTrue);
      // fire-on-release: KeyUp decides held vs quick; repeats swallowed
      expect(tvf.contains('event is KeyUpEvent'), isTrue);
      expect(tvf.contains('widget.onHeldOk!()'), isTrue);
      expect(tvf.contains('onLongPress: widget.enabled ? widget.onHeldOk'), isTrue);
    });

    test('DpadRepeatGate: KeyDown always passes, KeyRepeat throttled per axis', () {
      expect(gate.contains('class DpadRepeatGate'), isTrue);
      expect(gate.contains('event is KeyDownEvent'), isTrue);
      expect(gate.contains('event is KeyRepeatEvent'), isTrue);
      expect(gate.contains('F4Motion.repeatHoriz'), isTrue);
      expect(gate.contains('F4Motion.repeatVert'), isTrue);
    });
  });

  group('fix701 main.dart wiring (foundation is live but inert)', () {
    final main = File('lib/main.dart').readAsStringSync();
    test('F4Tokens attached to ThemeData.extensions', () {
      expect(
          main.contains(
              'extensions: const <ThemeExtension<dynamic>>[F4Tokens()]'),
          isTrue);
    });
    test('AccentScope installed above route content', () {
      expect(main.contains('AccentScope('), isTrue);
      expect(main.contains('notifier: appAccentNotifier'), isTrue);
    });
    test('phone path untouched: Material focus fallback stays gated on !touch', () {
      // The existing yellow Material focus borders remain (non-TvFocusable
      // fallback); Phase 0 must not have changed them.
      expect(main.contains('!hasTouchScreen'), isTrue);
    });
  });
}
