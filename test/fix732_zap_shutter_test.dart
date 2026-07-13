// fix732 (mock §4.7) — channel-zap shutter: a black cover over the fresh-play
// black-load that fades out on first-frame, driven by a new engine
// firstFrameStream signal. Source checks.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final engine = File('lib/player/player_engine.dart').readAsStringSync();
  final mpv = File('lib/player/mpv_engine.dart').readAsStringSync();
  final player = File('lib/player.dart').readAsStringSync();

  test('PlayerEngine declares firstFrameStream (empty default)', () {
    expect(
        engine.contains(
            'Stream<void> get firstFrameStream => const Stream<void>.empty()'),
        isTrue);
  });

  test('MpvEngine fires firstFrameStream on the real dwidth first-frame', () {
    expect(mpv.contains('_firstFrameCtrl'), isTrue);
    expect(
        mpv.contains('Stream<void> get firstFrameStream => _firstFrameCtrl.stream'),
        isTrue);
    // fired inside the verified-real dwidth branch, and closed in dispose
    expect(mpv.contains('if (!_firstFrameCtrl.isClosed) _firstFrameCtrl.add(null)'),
        isTrue);
    expect(mpv.contains('await _firstFrameCtrl.close()'), isTrue);
  });

  test('player shows a fading black shutter cleared on first-frame', () {
    expect(player.contains('bool _showShutter = true'), isTrue);
    expect(player.contains('_buildZapShutter()'), isTrue);
    expect(player.contains('opacity: _showShutter ? 1.0 : 0.0'), isTrue);
    expect(player.contains('duration: F4Motion.shutter'), isTrue);
    expect(player.contains('const ColoredBox(color: Colors.black)'), isTrue);
    // cleared on the first-frame event (block closure since fix742 — the
    // same listener also latches _codecFallbackConfirmed and cancels the
    // codec-open escalation window)
    expect(player.contains('_engine.firstFrameStream.listen((_) {'), isTrue);
    expect(player.contains('_clearShutter();'), isTrue);
  });

  test('shutter has a dead-engine fallback + skips on adopt', () {
    expect(player.contains('_shutterTimeout = Timer(const Duration(seconds: 4)'),
        isTrue);
    expect(player.contains('_shutterTimeout?.cancel(); // fix732'), isTrue);
    // an adopted (already-rendering) engine starts with no shutter
    expect(player.contains('_showShutter = false; // fix732'), isTrue);
  });
}
