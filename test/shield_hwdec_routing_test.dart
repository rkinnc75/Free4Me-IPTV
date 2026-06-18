// fix395: regression guard for full-screen Android hardware-decode routing.
//
// The bug: fix164 routed EVERY Android TV to `hwdec=no` (software). On the
// NVIDIA Shield (Tegra X1, isTV=true, ~2.9 GB) full-screen playback then
// stalled the video pipeline — audio alive, no frames, black screen
// (free4me_log-shieldandroidtv-20260617). The working reference app uses
// ExoPlayer (hardware MediaCodec), which is `mediacodec-copy` here.
//
// This pins the corrected routing so it can't silently regress again.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_tv/player/hwdec_routing.dart';

void main() {
  group('androidFullscreenHwdec (fix395)', () {
    test('Shield / Tegra → mediacodec-copy (hardware; never software)', () {
      // The fix: a capable Tegra decoder must use hardware, not software.
      expect(
        androidFullscreenHwdec(isTegra: true, isLowRam: false, isTV: true),
        'mediacodec-copy',
      );
    });

    test('Tegra is matched FIRST — RAM misdetection cannot force software', () {
      // Even if isLowRam were (mis)reported true, a Tegra device still gets
      // hardware decode. Guards against detector drift on Shield variants.
      expect(
        androidFullscreenHwdec(isTegra: true, isLowRam: true, isTV: true),
        'mediacodec-copy',
      );
    });

    test('low-RAM non-Tegra TV → software (A/V sync on weak SoCs)', () {
      // onn 4K Plus (~2 GB, Amlogic + Mali-G310): fix164/fix361 path preserved.
      expect(
        androidFullscreenHwdec(isTegra: false, isLowRam: true, isTV: true),
        'no',
      );
    });

    test('capable non-Tegra TV → mediacodec-copy (Fire TV, etc.)', () {
      expect(
        androidFullscreenHwdec(isTegra: false, isLowRam: false, isTV: true),
        'mediacodec-copy',
      );
    });

    test('phone → mediacodec-copy (fix402: surface mode falls to software)', () {
      // fix402: surface-mode `mediacodec` has no native Surface to bind under
      // media_kit's libmpv render API, so it silently drops to software on
      // phones (S24: hwdec-current="no"). Hardware decode requires copy mode.
      expect(
        androidFullscreenHwdec(isTegra: false, isLowRam: false, isTV: false),
        'mediacodec-copy',
      );
    });

    test('low-RAM phone → software fallback', () {
      expect(
        androidFullscreenHwdec(isTegra: false, isLowRam: true, isTV: false),
        'no',
      );
    });

    test('NO path ever returns surface-mode mediacodec (fix108 + fix402)', () {
      // Surface-mode `mediacodec` binds a SurfaceTexture and fails silently
      // under media_kit's render API — on TV (fix108) AND phone (fix402). No
      // device class may return it; only `mediacodec-copy` or `no`.
      for (final tegra in [true, false]) {
        for (final lowRam in [true, false]) {
          for (final tv in [true, false]) {
            final mode = androidFullscreenHwdec(
                isTegra: tegra, isLowRam: lowRam, isTV: tv);
            expect(mode, isNot('mediacodec'),
                reason: 'surface-mode mediacodec never works with the render API');
          }
        }
      }
    });
  });
}
