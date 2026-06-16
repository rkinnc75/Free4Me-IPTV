// fix380: the seek-probe suppression log line was firing per user-seek
// (after the startup grace window expired) because the suppression
// handler always logged. The new behaviour: log at most once per
// `open()` (during startup grace), then silent. User-seek failures
// remain suppressed (no reconnect) but no longer spam the log.
//
// This test pins the pure top-level `isSeekProbeError` predicate so
// the detection can't drift. The latch-once-per-open behaviour is a
// state machine inside _PlayerState (not testable here without
// platform mocks) and is verified on-device by observing the log
// volume before/after.

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/player.dart';

void main() {
  group('isSeekProbeError (fix380)', () {
    test('mpv "Cannot seek" probe is detected', () {
      expect(
        isSeekProbeError('avformat: Cannot seek in this stream.'),
        isTrue,
        reason: 'the canonical mpv probe message must be detected');
    });

    test('mpv "force-seekable" hint is detected', () {
      // mpv often emits this immediately after the "Cannot seek" line
      // as a self-hint: "You can force it with '--force-seekable=yes'."
      expect(
        isSeekProbeError(
            "You can force it with '--force-seekable=yes'."),
        isTrue,
        reason: 'the mpv self-hint must also be detected');
    });

    test('real engine errors are NOT detected as probe', () {
      // These are the actual failure modes that should trigger a
      // reconnect (or at minimum, get logged loudly). They must NOT
      // be classified as benign seek probes.
      expect(
        isSeekProbeError('avformat: HTTP error 404 Not Found'),
        isFalse,
        reason: '404 must not be misclassified as a seek probe');
      expect(
        isSeekProbeError(
            'Failed to open https://provider.example.com/live/123'),
        isFalse,
        reason: 'open failures must not be misclassified');
      expect(
        isSeekProbeError('avformat: Connection refused'),
        isFalse,
        reason: 'connection failures must not be misclassified');
    });

    test('empty / unrelated strings are NOT detected', () {
      expect(isSeekProbeError(''), isFalse);
      expect(isSeekProbeError('random unrelated error'), isFalse);
    });
  });
}
