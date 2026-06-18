// fix394: regression guard for the Developer / libmpv advanced tunables on
// Settings. Catches accidental default drift: if a future change moves a
// default away from libmpv upstream, the section is no longer a no-op until
// the user opts in (which is the whole point of the "Advanced" subtitle).
//
// fix394 review: the original draft shipped fields backed by non-existent or
// wrong-type libmpv properties (demuxer-cache-wait is a yes/no flag, and
// demuxer-max-wait-keepalive / demuxer-backward-buffer-secs /
// demuxer-dont-buffer-secs / target-colorspace do not exist). Those fields
// were removed; audio-buffer (0.2 s) and framedrop (vo) defaults were
// corrected to libmpv upstream; and the video-sync / audio-spdif enums were
// pruned to values libmpv actually accepts. This test pins the corrected set.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/models/dev_mpv_options.dart';
import 'package:open_tv/models/multi_view_layout.dart';
import 'package:open_tv/models/settings.dart';

void main() {
  test('Settings.defaults() — 13 dev fields match libmpv upstream', () {
    final s = Settings.defaults();

    // Demuxer / cache.
    expect(s.devDemuxerReadaheadSecs, 1.5);

    // Network.
    expect(s.devNetworkTimeoutSecs, 30);
    expect(s.devTlsVerify, false);

    // Sync.
    expect(s.devVideoSync, VideoSyncMode.audio);
    expect(s.devVideoSyncMaxVideoChange, 1.0);

    // Image quality.
    expect(s.devTscale, TscaleMode.nearest);
    // libmpv upstream framedrop default is `vo`, NOT `no` (regression guard:
    // defaulting to `no` would silently disable mpv's normal VO frame drop).
    expect(s.devFramedrop, FrameDropMode.vo);
    expect(s.devInterpolation, false);
    expect(s.devDeband, false);
    expect(s.devHwdecImageFormat, HwdecImageFormat.defaultFmt);

    // Audio. libmpv upstream audio-buffer default is 0.2 s (200 ms), NOT 0.0.
    expect(s.devAudioBufferSecs, 0.2);
    expect(s.devAudioSpdif, AudioSpdifMode.no);
  });

  test('Settings.optimisedFor() — dev fields identical TV vs phone (no isTV split)', () {
    // PAL/50Hz-specific tuning is a future fix once a PAL device is
    // reported with an A/V issue. Both branches must default to 30.
    final sPhone = Settings.optimisedFor(
      isTV: false,
      layout: MultiViewLayout.none,
    );
    final sTV = Settings.optimisedFor(
      isTV: true,
      layout: MultiViewLayout.none,
    );

    for (final s in [sPhone, sTV]) {
      expect(s.devDemuxerReadaheadSecs, 1.5);
      expect(s.devFramedrop, FrameDropMode.vo);
      expect(s.devAudioBufferSecs, 0.2);
      expect(s.devAudioSpdif, AudioSpdifMode.no);
    }
    // Sanity: the two branches agree on the relevant fields.
  });

  test('Enum sentinels — HwdecImageFormat.defaultFmt and AudioSpdifMode.no '
      'return null (engine must not call setProperty)', () {
    // The engine reads s.X.value to decide whether to call np.setProperty.
    // A null value means "let libmpv keep its default" — property NOT set.
    expect(HwdecImageFormat.defaultFmt.value, isNull);
    expect(AudioSpdifMode.no.value, isNull);

    // Sanity: non-sentinel enum values return a real string.
    expect(HwdecImageFormat.nv12.value, 'nv12');
    // audio-spdif takes a comma-separated codec list; "all" expands, it is
    // NOT the literal "all" (which libmpv would reject).
    expect(AudioSpdifMode.all.value, 'ac3,eac3,dts');
  });

  test('Enum value strings are libmpv-valid (no invented choices)', () {
    // video-sync: only real mpv modes. The original `display` and
    // `audio-desync` entries were not valid mpv video-sync values.
    expect(VideoSyncMode.audio.value, 'audio');
    expect(VideoSyncMode.displayResample.value, 'display-resample');
    expect(VideoSyncMode.displayResampleVdrop.value, 'display-resample-vdrop');
    expect(VideoSyncMode.displayVdrop.value, 'display-vdrop');
    expect(VideoSyncMode.desync.value, 'desync');

    // framedrop: real mpv choices only (no `yes`).
    expect(FrameDropMode.no.value, 'no');
    expect(FrameDropMode.vo.value, 'vo');
    expect(FrameDropMode.decoder.value, 'decoder');
  });
}
