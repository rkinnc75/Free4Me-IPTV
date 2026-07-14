// fix745: mpv's low-latency profile broke hardware decoding. Root cause of
// the S938U "phone never hardware-decodes" outage (2026-07-13/14): enabling
// the "Low latency mode" setting applies mpv profile=low-latency, which sets
// demuxer-lavf-probe-info=nostreams + demuxer-lavf-analyzeduration=0.1 —
// stream probing is skipped, so a mid-stream live-TS join reaches the decoder
// with NO SPS/PPS extradata. ffmpeg's h264_mediacodec must build MediaCodec
// csd buffers from extradata at configure(), so EVERY hardware open died with
// "Could not open codec" (software parses SPS/PPS in-band and survived,
// masking this as a broken device decoder). The profile also sets
// vd-lavc-threads=1, single-threading the software path — a stutter risk on
// weak SoCs that are routed to software by design.
//
// The fix: keep profile=low-latency (nobuffer, audio-buffer=0, small stream
// buffer, low_delay — the actual latency wins) but restore mpv defaults for
// the three poisoned options immediately AFTER applying the profile, matching
// the fix700 post-profile override pattern (cache-pause).
//
// Evidence chain (private repo logs): 7/11 log (no low-latency) hw-decoded
// fine; every 7/13-14 log applies profile=low-latency seconds before
// "Could not open codec"; the restored backup carried lowLatency=true into
// the 4.1.9 revert, which is why reverting the app didn't help.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final mpv = File('lib/player/mpv_engine.dart').readAsStringSync();

  test('low-latency block restores probe-info/analyzeduration mpv defaults '
      'AFTER the profile (hardware decode needs extradata)', () {
    final idxProfile =
        mpv.indexOf("await np.setProperty('profile', 'low-latency');");
    final idxProbe = mpv
        .indexOf("await np.setProperty('demuxer-lavf-probe-info', 'auto');");
    final idxAnalyze = mpv.indexOf(
        "await np.setProperty('demuxer-lavf-analyzeduration', '0');");
    expect(idxProfile, greaterThan(0));
    // overrides exist and come AFTER the profile application (a profile set
    // later would clobber them back to the broken values)
    expect(idxProbe, greaterThan(idxProfile));
    expect(idxAnalyze, greaterThan(idxProfile));
  });

  test('low-latency block restores multi-threaded software decode', () {
    final idxProfile =
        mpv.indexOf("await np.setProperty('profile', 'low-latency');");
    final idxThreads =
        mpv.indexOf("await np.setProperty('vd-lavc-threads', '0');");
    expect(idxThreads, greaterThan(idxProfile));
  });

  test('profile=low-latency is applied in exactly one place (no unguarded '
      'second application that would re-poison the options)', () {
    expect(
        RegExp(r"setProperty\('profile', 'low-latency'\)")
            .allMatches(mpv)
            .length,
        1);
  });
}
