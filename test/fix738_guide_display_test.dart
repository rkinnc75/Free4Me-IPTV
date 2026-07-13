// fix738 (mock §4.3) — guide EPG display polish: past-programme dimming, a LIVE
// badge on the on-now cell, and a "NOW hh:mm" pill in the timeline header.
// Derivable-only (Program has no is-new/catch-up flag → no NEW/ARCHIVE badges).
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final g = File('lib/tv/tv_guide_view.dart').readAsStringSync();
  test('past programmes are dimmed via the pastProgramDim token', () {
    expect(g.contains('final isPast = p.stopUtc <= nowEpoch'), isTrue);
    expect(g.contains('opacity: isPast ? tokens.scrim.pastProgramDim : 1.0'),
        isTrue);
  });
  test('on-now cell shows a LIVE badge on the liveRed token', () {
    expect(g.contains("child: const Text('LIVE'"), isTrue);
    expect(g.contains('color: tokens.colors.liveRed'), isTrue);
  });
  test('timeline header has an accent NOW pill', () {
    expect(g.contains("'NOW \${_fmtEpoch(_windowStart)}'"), isTrue);
    expect(g.contains('AccentScope.of(context).withValues(alpha: 0.20)'), isTrue);
  });
}
