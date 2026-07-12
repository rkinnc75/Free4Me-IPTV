// fix702 (TV GUI redesign, Phase 1) — the top tab bar migrates onto the shared
// TvFocusable: accent focus ring + 1.05x lift + the unified fire-on-release
// held-OK, replacing the copy-pasted _TabButtonState hold widget + the flat
// yellow border. The selected pill keeps its section-identity fill (our win),
// and held-OK stays wired only for long-press tabs (others still switch on a
// held OK — fix607). Source-invariant (widget/theme-coupled), matching the
// fix701 foundation test style.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _slice(String s, String from, String to) {
  final a = s.indexOf(from);
  if (a < 0) return '';
  final b = to.isEmpty ? s.length : s.indexOf(to, a + from.length);
  return s.substring(a, b < 0 ? s.length : b);
}

void main() {
  final bar = File('lib/tv/tv_top_tab_bar.dart').readAsStringSync();

  test('imports the focus engine + tokens', () {
    expect(bar.contains("tv/focus/tv_focusable.dart"), isTrue);
    expect(bar.contains("tv/theme/f4_tokens.dart"), isTrue);
  });

  test('_TabButton is now stateless + built on TvFocusable', () {
    expect(bar.contains('class _TabButton extends StatelessWidget'), isTrue);
    expect(bar.contains('class _TabButtonState'), isFalse); // old hold widget gone
    final btn = _slice(bar, 'class _TabButton extends StatelessWidget', '');
    expect(btn.contains('TvFocusable('), isTrue);
    expect(btn.contains('builder: (context, isFocused)'), isTrue);
  });

  test('held-OK wired to the tab long-press; null still switches (fix607)', () {
    final btn = _slice(bar, 'class _TabButton extends StatelessWidget', '');
    // onHeldOk = the tab's longpress action; when null TvFocusable fires onTap
    // on release, so a held OK still switches the tab.
    expect(btn.contains('onHeldOk: onLongPress'), isTrue);
    expect(btn.contains('onTap: onTap'), isTrue);
    // 600ms hold preserved from fix607 (not the 500ms default).
    expect(btn.contains('milliseconds: 600'), isTrue);
  });

  test('selected pill keeps section-identity fill; ring is the accent (no yellow)', () {
    final btn = _slice(bar, 'class _TabButton extends StatelessWidget', '');
    expect(btn.contains('selected ? tab.color : Colors.transparent'), isTrue);
    // focus indicator is now the accent ring (TvFocusable), not a yellow border
    expect(bar.contains('Colors.yellow'), isFalse);
    expect(bar.contains('Border.all'), isFalse);
    // chrome ring width token
    expect(btn.contains('tokens.focus.ringChrome'), isTrue);
  });
}
