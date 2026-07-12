// fix705 (TV GUI redesign, Phase 3 — EPG guide, unit 2) — NOW emphasis:
//  (1) the NOW vertical line gets a soft glow (token nowGlowRadius), colour kept
//      `primary` so it stays distinct from the white accent focus ring;
//  (2) the on-now programme cell shows a progress-within-cell fill — the elapsed
//      fraction of its runtime tints the left portion a little stronger.
// Both use only Program times (startUtc/stopUtc/nowEpoch) — NO data layer, no
// new Program field (HD/SD badges are intentionally NOT added: Program has no
// quality field, and a title heuristic would be a separate, riskier concern).
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

  test('imports the f4 tokens (for the glow radius)', () {
    expect(guide.contains('tv/theme/f4_tokens.dart'), isTrue);
  });

  test('NOW line has a glow from the token, colour stays primary', () {
    final nl = _slice(guide, 'Widget _nowLine(', '/// Small D-pad-friendly');
    expect(nl.contains('F4.of(context).focus.nowGlowRadius'), isTrue);
    expect(nl.contains('boxShadow'), isTrue);
    expect(nl.contains('BoxShadow('), isTrue);
    // still primary (blue) — deliberately NOT the accent, so time != focus
    expect(nl.contains('color: scheme.primary'), isTrue);
    expect(nl.contains('AccentScope'), isFalse);
  });

  test('on-now cell computes a guarded elapsed fraction', () {
    final blk = _slice(guide, 'Widget _block(', 'Widget _nowLine(');
    // divide-by-zero / bad-EPG guard: only when isNow AND duration positive
    expect(blk.contains('final int dur = p.stopUtc - p.startUtc'), isTrue);
    expect(
        blk.contains('(isNow && dur > 0)') &&
            blk.contains('((nowEpoch - p.startUtc) / dur).clamp(0.0, 1.0)'),
        isTrue);
  });

  test('progress fill: FractionallySizedBox widthFactor = elapsedFrac, clipped',
      () {
    final blk = _slice(guide, 'Widget _block(', 'Widget _nowLine(');
    expect(blk.contains('clipBehavior: isNow ? Clip.antiAlias : Clip.none'),
        isTrue,
        reason: 'fill clipped to rounded corners, only on the on-now cell '
            '(non-now cells keep Clip.none to protect scroll fps)');
    expect(blk.contains('FractionallySizedBox('), isTrue);
    expect(blk.contains('widthFactor: elapsedFrac'), isTrue);
    expect(blk.contains('alignment: Alignment.centerLeft'), isTrue);
    // only drawn when there is progress to show
    expect(blk.contains('if (elapsedFrac > 0)'), isTrue);
  });

  test('kept: passive grid cells stay excluded from D-pad focus', () {
    final blk = _slice(guide, 'Widget _block(', 'Widget _nowLine(');
    // finding 75 must survive the Stack rework
    expect(blk.contains('ExcludeFocus('), isTrue);
    expect(blk.contains('onTap: () => _play(ch)'), isTrue);
  });
}
