// fix403: the DECODE probe labels hwdec-current so a transient first-frame "no"
// (mpv decodes the first frame in software while mediacodec spins up) can't be
// misread as a permanent software fallback — the error made during fix402.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/player/hwdec_decode_state.dart';

void main() {
  group('fix403 hwdecDecodeState', () {
    test('active hardware decoder → hardware', () {
      expect(
        hwdecDecodeState(tag: '+3s', req: 'mediacodec', current: 'mediacodec'),
        'hardware',
      );
      expect(
        hwdecDecodeState(
            tag: 'first-frame',
            req: 'mediacodec-copy',
            current: 'mediacodec-copy'),
        'hardware',
      );
    });

    test('first-frame "no" with HW requested → transient, not software', () {
      expect(
        hwdecDecodeState(
            tag: 'first-frame', req: 'mediacodec', current: 'no'),
        'initializing(transient; trust [+3s])',
      );
      expect(
        hwdecDecodeState(
            tag: 'post-open', req: 'mediacodec-copy', current: 'no'),
        'initializing(transient; trust [+3s])',
      );
    });

    test('settled "no" at [+3s] with HW requested → real software fallback', () {
      expect(
        hwdecDecodeState(tag: '+3s', req: 'mediacodec', current: 'no'),
        'software',
      );
    });

    test('"no" when software was requested → software at any probe', () {
      expect(
        hwdecDecodeState(tag: 'first-frame', req: 'no', current: 'no'),
        'software',
      );
    });

    test('empty/unknown samples are labelled, not mistaken for software', () {
      expect(
        hwdecDecodeState(tag: 'post-open', req: 'mediacodec', current: ''),
        'initializing',
      );
      expect(
        hwdecDecodeState(tag: 'first-frame', req: 'mediacodec', current: '?'),
        'unknown',
      );
    });
  });
}
