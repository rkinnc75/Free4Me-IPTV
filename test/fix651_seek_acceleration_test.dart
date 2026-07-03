// fix651: hold-to-seek acceleration ladder for the ◀/▶ transport keys.
// Pins the pure repeatCount/duration → step-seconds mapping so a refactor
// can't silently change how fast a held key accelerates on different content
// lengths (short VOD must stay gentle; unknown/live-DVR caps at 30s).

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/player/seek_acceleration.dart';

void main() {
  group('seekStepSeconds (fix651)', () {
    const short = Duration(minutes: 3); // a clip
    const episode = Duration(minutes: 22);
    const film = Duration(minutes: 45);
    const epic = Duration(hours: 3);
    const unknown = Duration.zero; // live DVR / unreported

    test('first press and early repeats are always 10s', () {
      for (final d in [short, episode, film, epic, unknown]) {
        for (var r = 0; r < 5; r++) {
          expect(seekStepSeconds(repeatCount: r, duration: d), 10,
              reason: 'repeat=$r duration=$d');
        }
      }
    });

    test('repeats 5-9 step to 30s on content >= 5 min', () {
      expect(seekStepSeconds(repeatCount: 5, duration: episode), 30);
      expect(seekStepSeconds(repeatCount: 9, duration: epic), 30);
    });

    test('very short content never accelerates past 10s', () {
      for (final r in [5, 9, 12, 20]) {
        expect(seekStepSeconds(repeatCount: r, duration: short), 10);
      }
    });

    test('unknown duration (live DVR) caps at 30s', () {
      for (final r in [5, 10, 15, 40]) {
        expect(seekStepSeconds(repeatCount: r, duration: unknown), 30);
      }
    });

    test('repeats 10-14 step to 60s on content >= 30 min', () {
      expect(seekStepSeconds(repeatCount: 10, duration: film), 60);
      expect(seekStepSeconds(repeatCount: 14, duration: epic), 60);
      // 22-min episode stays at 30s — not long enough for the 60s tier.
      expect(seekStepSeconds(repeatCount: 12, duration: episode), 30);
    });

    test('repeats 15+ step to 120s only on content >= 90 min', () {
      expect(seekStepSeconds(repeatCount: 15, duration: epic), 120);
      expect(seekStepSeconds(repeatCount: 40, duration: epic), 120);
      // 45-min film caps at 60s.
      expect(seekStepSeconds(repeatCount: 20, duration: film), 60);
    });
  });
}
