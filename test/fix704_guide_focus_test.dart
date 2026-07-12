// fix704 (TV GUI redesign, Phase 3 — EPG guide, unit 1) — the content-rail
// focus rings adopt the accent color (AccentScope, default white), matching the
// tab bar (fix702) and channel/poster tiles (fix703). Covers all THREE
// copy-pasted `_FocusTile` rails on the browsing surface: the guide rail
// (tv_guide_view), the browse rail (tv_browse_view) and the categories rail
// (tv_categories_view). This unifies the whole browsing surface on the accent
// ring; the global button/chrome focus theme (main.dart, settings/dialogs) is a
// separate later unit and intentionally NOT touched here.
//
// Lowest-risk touch of the 1405-line flagship guide file: the ring color only —
// no layout, no data layer; rail Y-alignment / :00:30 snap / preview / place-
// memory untouched (verified separately per the Phase-3 risk plan).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _slice(String s, String from, String to) {
  final a = s.indexOf(from);
  if (a < 0) return '';
  final b = to.isEmpty ? s.length : s.indexOf(to, a + from.length);
  return s.substring(a, b < 0 ? s.length : b);
}

const _railFiles = <String>[
  'lib/tv/tv_guide_view.dart',
  'lib/tv/tv_browse_view.dart',
  'lib/tv/tv_categories_view.dart',
];

void main() {
  final byFile = {for (final f in _railFiles) f: File(f).readAsStringSync()};

  for (final f in _railFiles) {
    final src = byFile[f]!;
    test('$f imports the accent scope', () {
      expect(src.contains('tv/theme/accent_scope.dart'), isTrue);
    });

    test('$f _FocusTile ring is the accent color, not flat yellow', () {
      final ft = _slice(src, 'class _FocusTileState', '');
      expect(
          ft.contains(
              'color: _focused ? AccentScope.of(context) : Colors.transparent'),
          isTrue,
          reason: 'ring reads the accent at draw time');
      // no flat yellow focus ring anywhere in this TV view now
      expect(src.contains('Colors.yellow'), isFalse);
    });

    test('$f ring width 3 kept (row chrome budget unchanged)', () {
      final ft = _slice(src, 'class _FocusTileState', '');
      final ring = _slice(ft, 'border: Border.all(', '),');
      expect(ring.contains('width: 3'), isTrue);
    });
  }

  test('guide kept-win markers still present (no accidental regression)', () {
    final guide = byFile['lib/tv/tv_guide_view.dart']!;
    expect(guide.contains('static const double _rowHeight = 56'), isTrue);
    expect(guide.contains('itemExtent: _rowHeight'), isTrue);
    // held-OK still opens on release (the P0 win), not mid-hold
    expect(guide.contains('open the menu on release'), isTrue);
  });

  // NOTE: fix704 deliberately left the global TV button focus theme (main.dart)
  // yellow — that higher-blast-radius chrome pass was done separately in fix707
  // (see test/fix707_chrome_accent_test.dart). The old "main.dart still has
  // yellow" guard here was removed when fix707 completed that migration.
}
