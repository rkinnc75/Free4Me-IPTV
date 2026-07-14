// fix748: the "Low latency livestreams" feature is removed entirely. It applied
// mpv profile=low-latency, whose demuxer-lavf-probe-info=nostreams left
// mid-stream live-TS joins without SPS/PPS extradata → h264_mediacodec
// configure() failed and every stream fell back to single-threaded software
// decode (the S938U "never hardware-decodes" outage + the onn freeze/stutter).
// fix745 patched it; the owner directed a full removal. This guards that the
// setting, flag, gate, storage key, and mpv profile are all gone — so it can
// never be re-enabled by a stale setting or restored backup.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no lowLatency field / gate / storage key anywhere in lib code', () {
    final files = [
      'lib/models/settings.dart',
      'lib/backend/settings_service.dart',
      'lib/backend/settings_io.dart',
      'lib/settings_view.dart',
      'lib/player/mpv_engine.dart',
    ];
    for (final f in files) {
      final src = File(f).readAsStringSync();
      expect(src.contains('lowLatency'), isFalse,
          reason: '$f still has lowLatency');
    }
  });

  test('mpv never applies the decode-breaking low-latency profile', () {
    final mpv = File('lib/player/mpv_engine.dart').readAsStringSync();
    expect(mpv.contains("profile', 'low-latency'"), isFalse);
    // the live path is now the unconditional buffered config
    expect(mpv.contains("await np.setProperty('hls-bitrate', 'max');"), isTrue);
    expect(mpv.contains("await np.setProperty('cache-secs', s.liveCacheSecs.toString());"),
        isTrue);
  });

  test('the Settings toggle and its help text are gone', () {
    final sv = File('lib/settings_view.dart').readAsStringSync();
    expect(sv.contains('Low latency livestreams'), isFalse);
    expect(sv.contains('_helpLowLatency'), isFalse);
  });
}
