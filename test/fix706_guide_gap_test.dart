// fix706 (TV GUI redesign, Phase 3 — EPG guide, unit 4) — "never a blank row".
// Channels with no EPG programmes in the window (loop / VOD-style feeds that
// carry no XMLTV — common in these bundles) used to render an empty grid row;
// now they show a dim full-width "No guide data" placeholder. Purely additive:
// the placeholder is drawn ONLY in the `progs.isEmpty` branch, so populated
// rows are byte-identical (the for-loop over real cells is unchanged and the
// collection-if contributes nothing when progs is non-empty). No data layer.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _slice(String s, String from, String to) {
  final a = s.indexOf(from);
  if (a < 0) return '';
  final b = to.isEmpty ? s.length : s.indexOf(to, a + from.length);
  return s.substring(a, b < 0 ? s.length : b);
}

void main() {
  final guide = File('lib/tv/tv_guide_view.dart').readAsStringSync();

  test('empty rows render a placeholder, gated on progs.isEmpty', () {
    final row = _slice(guide, 'Widget _gridRow(', 'Color _edgeColor(');
    expect(row.contains('if (progs.isEmpty) _emptyRowPlaceholder(c.maxWidth)'),
        isTrue);
    // populated rows unchanged: the real-cell loop + now-line still present
    expect(row.contains('for (final p in progs) _block(p, c.maxWidth, nowEpoch, ch)'),
        isTrue);
    expect(row.contains('_nowLine(c.maxWidth, nowEpoch)'), isTrue);
  });

  test('placeholder is a dim full-width cell with "No guide data"', () {
    final ph = _slice(guide, 'Widget _emptyRowPlaceholder(', 'Widget _block(');
    expect(ph.isNotEmpty, isTrue, reason: 'method defined before _block');
    expect(ph.contains("'No guide data'"), isTrue);
    expect(ph.contains('width: width'), isTrue); // spans the row
    expect(ph.contains('surfaceContainerHighest'), isTrue); // muted cell colour
  });

  test('kept: fix705 NOW-glow + progress fill untouched', () {
    expect(guide.contains('F4.of(context).focus.nowGlowRadius'), isTrue);
    expect(guide.contains('widthFactor: elapsedFrac'), isTrue);
  });
}
