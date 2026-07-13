// fix742: mpv's "Could not open codec." is emitted when ONE decoder in its
// candidate list fails to open — most commonly the hwdec probe
// (h264_mediacodec rejecting an interlaced/odd-profile stream). mpv then
// falls back to the next candidate (ultimately software) ON ITS OWN and
// playback proceeds. The app was classifying the error as a transient
// disconnect and tearing down the already-recovered session — three cycles,
// then "max reconnects reached" on a perfectly decodable stream (S938U field
// log 2026-07-13, "YES Network").
//
// This pins the pure top-level `isCodecOpenError` predicate (fix566 idiom)
// plus the escalation-window wiring as source checks: instead of an immediate
// disconnect, the error arms a short timer that only escalates if no frame
// decodes; the first-frame event cancels it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/player.dart';

void main() {
  group('isCodecOpenError (fix742)', () {
    test('the exact S938U hwdec rejection is detected', () {
      // Verbatim from the 2026-07-13 field log ("vd: Could not open codec.").
      expect(isCodecOpenError('Could not open codec.'), isTrue,
          reason: 'the canonical hwdec-probe rejection must be classified '
              'as fallback-pending, not disconnect');
    });

    test('real engine errors are NOT classified as codec-open', () {
      expect(isCodecOpenError('avformat: HTTP error 404 Not Found'), isFalse);
      expect(
          isCodecOpenError(
              'Failed to open https://provider.example.com/live/123'),
          isFalse);
      expect(isCodecOpenError('avformat: Connection refused'), isFalse);
      expect(isCodecOpenError('Cannot seek in this stream.'), isFalse);
      expect(isCodecOpenError(''), isFalse);
      expect(isCodecOpenError('random unrelated error'), isFalse);
    });
  });

  test('codec-open error arms an escalation window instead of disconnecting',
      () {
    final player = File('lib/player.dart').readAsStringSync();
    expect(player.contains('if (isCodecOpenError(err)) {'), isTrue);
    // ??= so an error storm cannot stack timers
    expect(player.contains('_codecFallbackTimer ??= Timer('), isTrue);
    // the first decoded frame confirms the fallback and cancels escalation
    expect(player.contains('_codecFallbackConfirmed = true;'), isTrue);
    expect(player.contains('_codecFallbackTimer?.cancel();'), isTrue);
    // escalation preserves the original disconnect reason
    expect(
        player.contains(
            "onDisconnect(reason: 'player error: Could not open codec')"),
        isTrue);
    // fresh window per open() and cleanup in dispose()
    expect(player.contains('_codecFallbackTimer?.cancel(); // fix742'), isTrue);
  });
}
