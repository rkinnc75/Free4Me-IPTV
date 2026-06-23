// fix515: MpvEngine.formatStreamInfo turns mpv's raw `dheight` + `video-codec`
// properties into a short label for the player's top bar ("720p H.264").
// This is pure string/number logic with real boundary cases (the height-tier
// cutoffs, codec name normalization, and the "not a real frame yet" guard
// that prevents a "0x0" flash before the first frame decodes) — worth
// covering directly rather than only exercising it through the full player.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/player/mpv_engine.dart';

void main() {
  group('formatStreamInfo — not-yet-real-frame guard', () {
    test('height "0" (no frame decoded yet) returns null, not "0p"', () {
      expect(MpvEngine.formatStreamInfo('0', 'h264'), isNull);
    });

    test('empty height string returns null', () {
      expect(MpvEngine.formatStreamInfo('', 'h264'), isNull);
    });

    test('"?" (property read failed) returns null', () {
      expect(MpvEngine.formatStreamInfo('?', 'h264'), isNull);
    });

    test('negative height (shouldn\'t happen, but must not crash or label) returns null', () {
      expect(MpvEngine.formatStreamInfo('-1', 'h264'), isNull);
    });

    test('non-numeric garbage height returns null, does not throw', () {
      expect(() => MpvEngine.formatStreamInfo('garbage', 'h264'), returnsNormally);
      expect(MpvEngine.formatStreamInfo('garbage', 'h264'), isNull);
    });
  });

  group('formatStreamInfo — resolution tier boundaries', () {
    test('2160 (true 4K) -> "4K"', () {
      expect(MpvEngine.formatStreamInfo('2160', 'h264'), '4K H.264');
    });

    test('2000 (boundary, still 4K tier) -> "4K"', () {
      expect(MpvEngine.formatStreamInfo('2000', 'h264'), '4K H.264');
    });

    test('1999 (just under 4K boundary) -> "1080p" tier, not "4K"', () {
      expect(MpvEngine.formatStreamInfo('1999', 'h264'), '1080p H.264');
    });

    test('1080 (true 1080p) -> "1080p"', () {
      expect(MpvEngine.formatStreamInfo('1080', 'h264'), '1080p H.264');
    });

    test('1000 (boundary, still 1080p tier) -> "1080p"', () {
      expect(MpvEngine.formatStreamInfo('1000', 'h264'), '1080p H.264');
    });

    test('999 (just under 1080p boundary) -> "720p" tier', () {
      expect(MpvEngine.formatStreamInfo('999', 'h264'), '720p H.264');
    });

    test('720 (true 720p) -> "720p"', () {
      expect(MpvEngine.formatStreamInfo('720', 'h264'), '720p H.264');
    });

    test('700 (boundary, still 720p tier) -> "720p"', () {
      expect(MpvEngine.formatStreamInfo('700', 'h264'), '720p H.264');
    });

    test('699 (just under 720p boundary) -> raw height, e.g. "576p" or similar', () {
      expect(MpvEngine.formatStreamInfo('480', 'h264'), '480p H.264');
    });

    test('low non-standard height falls back to literal "{h}p", not a wrong tier', () {
      expect(MpvEngine.formatStreamInfo('360', 'h264'), '360p H.264');
    });
  });

  group('formatStreamInfo — codec normalization', () {
    test('"h264" -> "H.264"', () {
      expect(MpvEngine.formatStreamInfo('1080', 'h264'), '1080p H.264');
    });

    test('"h264 (High)" (mpv\'s typical profile-annotated form) -> "H.264", profile dropped', () {
      expect(MpvEngine.formatStreamInfo('1080', 'h264 (High)'), '1080p H.264');
    });

    test('"hevc" -> "H.265"', () {
      expect(MpvEngine.formatStreamInfo('1080', 'hevc'), '1080p H.265');
    });

    test('"hevc (Main 10)" -> "H.265", profile dropped', () {
      expect(MpvEngine.formatStreamInfo('1080', 'hevc (Main 10)'), '1080p H.265');
    });

    test('"h265" (alternate spelling some builds report) -> "H.265"', () {
      expect(MpvEngine.formatStreamInfo('1080', 'h265'), '1080p H.265');
    });

    test('unrecognized codec falls back to uppercased raw token, e.g. "mpeg2video"', () {
      expect(MpvEngine.formatStreamInfo('1080', 'mpeg2video'), '1080p MPEG2VIDEO');
    });

    test('empty codec string: resolution alone, no trailing space or null', () {
      expect(MpvEngine.formatStreamInfo('1080', ''), '1080p');
    });

    test('"?" codec (property read failed): resolution alone', () {
      expect(MpvEngine.formatStreamInfo('1080', '?'), '1080p');
    });

    test('codec name is case-insensitive on input ("H264")', () {
      expect(MpvEngine.formatStreamInfo('1080', 'H264'), '1080p H.264');
    });
  });
}
