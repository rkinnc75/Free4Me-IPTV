// fix754 (Free4Me-libmpv-harvest §2): narrow the hardware-decode codec
// allowlist to the codecs Android mediacodec handles reliably (h264, hevc).
// Everything else (av1/vp9/vp8/vc1/mpeg2/mpeg4/prores) is decoded in software
// per-codec, so a device that lacks that hardware decoder never fails a hw
// probe and eats a fix742 software-fallback cycle — while the two codecs that
// matter for IPTV stay hardware-accelerated.
//
// Design pins:
// - Set ONCE, before the hwdec branch chain, so every branch (full-screen,
//   preview, multi-view) AND the runtime routed switches inherit the
//   session-global mpv property. (Setting it per-branch would miss the
//   preview-only / routed paths.)
// - Android + hwDecode only: a no-op on hwdec=no paths; iOS videotoolbox
//   handles a broader codec set well so it is left untouched.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final mpv = File('lib/player/mpv_engine.dart').readAsStringSync();

  test('allowlist constant is h264 + hevc', () {
    expect(
        mpv.contains(
            "static const String _hwdecCodecsAllowlist = 'h264,hevc';"),
        isTrue);
  });

  test('hwdec-codecs is set on the Android hardware path, gated correctly', () {
    expect(
        mpv.contains(
            "await np.setProperty('hwdec-codecs', _hwdecCodecsAllowlist);"),
        isTrue);
    // gated on Android + user hwdec enabled (no-op on the software paths)
    expect(mpv.contains('if (Platform.isAndroid && s.hwDecode) {'), isTrue);
  });

  test('set BEFORE the hwdec branch chain so all paths inherit it', () {
    final idxSet =
        mpv.indexOf("await np.setProperty('hwdec-codecs', _hwdecCodecsAllowlist);");
    final idxBranch = mpv.indexOf('if (forceSoftwareDecode) {');
    expect(idxSet, greaterThan(0));
    expect(idxBranch, greaterThan(0));
    // the codec allowlist is applied ahead of the first hwdec-mode branch
    expect(idxSet, lessThan(idxBranch));
  });
}
