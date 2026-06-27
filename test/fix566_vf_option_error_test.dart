// fix566: the low-RAM 30 fps OUTPUT cap (fix565) set `vf` to a filter string
// this libmpv build rejected ("Option vf: fps doesn't exist."). That error was
// reaching errorStream and forcing a spurious reconnect on every channel open
// (onn 4K Plus, v2.0.65 field log). The fix: switch to the lavfi bridge form
// AND classify any `vf`-option error as benign so it can never reconnect — the
// stream simply plays uncapped.
//
// This pins the pure top-level `isVfOptionError` predicate so the detection
// can't drift. The log-once-per-open latch is a _PlayerState state machine
// (not unit-testable without platform mocks) and is verified on-device by
// observing that no reconnect fires when the cap filter is rejected.

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/player.dart';

void main() {
  group('isVfOptionError (fix566)', () {
    test('the exact onn 4K Plus rejection is detected', () {
      // Verbatim from the v2.0.65 field log (mpv format
      // "Option %.*s: %.*s doesn't exist.").
      expect(
        isVfOptionError("Option vf: fps doesn't exist."),
        isTrue,
        reason: 'the canonical fix565 rejection must be classified benign');
    });

    test('a lavfi filter-creation failure is detected', () {
      // If a future build lacks the libavfilter `fps` filter, mpv emits
      // "could not create filter" — also benign (cap just no-ops).
      expect(
        isVfOptionError('vf: could not create filter'),
        isTrue,
        reason: 'filter-creation failures must also be classified benign');
    });

    test('real engine errors are NOT classified as vf-cap errors', () {
      expect(isVfOptionError('avformat: HTTP error 404 Not Found'), isFalse);
      expect(
        isVfOptionError(
            'Failed to open https://provider.example.com/live/123'),
        isFalse);
      expect(isVfOptionError('avformat: Connection refused'), isFalse);
      expect(isVfOptionError('Cannot seek in this stream.'), isFalse);
    });

    test('empty / unrelated strings are NOT detected', () {
      expect(isVfOptionError(''), isFalse);
      expect(isVfOptionError('random unrelated error'), isFalse);
    });
  });
}
