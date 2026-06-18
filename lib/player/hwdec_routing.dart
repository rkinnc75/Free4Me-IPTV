/// fix395: full-screen Android hardware-decode routing for libmpv `hwdec`.
///
/// Extracted as a pure function so the device→hwdec mapping is unit-testable
/// (see test/shield_hwdec_routing_test.dart) and documented in exactly one
/// place. The call site is MpvEngine._applyMpvOptions (full-screen branch).
library;

/// Returns the libmpv `hwdec` value for FULL-SCREEN (non-preview) playback on
/// Android, given the device class.
///
/// Preview / multi-view uses a DIFFERENT path (MpvEngine._applyMpvOptions,
/// gated on `multiViewDecode`) because concurrent hardware decode behaves
/// differently — e.g. Tegra corrupts colour with 4 simultaneous
/// mediacodec-copy pipelines (fix314), so preview tiles use software there.
/// This function is for the single full-screen decoder only.
///
/// Routing rationale:
///  - **Tegra / Shield → `mediacodec-copy`** (checked FIRST): the Tegra X1 has
///    a capable hardware H.264/HEVC decoder. It must NOT use software (`no`) —
///    that starves the video pipeline and produces a black screen with audio
///    still alive (the fix395 bug: fix164 routed every Android TV to `no`).
///    It must NOT use surface-mode `mediacodec` either — that binds directly
///    to a SurfaceTexture and fails silently on Tegra (fix108). Hardware decode
///    with a CPU copy is the proven-good path (pre-fix164). Tegra is matched
///    before the RAM check so a low-RAM *misdetection* can never force a
///    capable Shield onto the broken software path.
///  - **Low-RAM TV → `no`** (software): on weak boxes (onn 4K Plus ~2 GB /
///    Amlogic + Mali-G310) the mediacodec-copy GPU→CPU readback is
///    memory-bandwidth bound and falls behind the audio clock (A/V desync);
///    software decode keeps the clocks in sync (fix164 / fix361).
///  - **Other TV → `mediacodec-copy`** (Fire TV, capable boxes): hardware
///    decode with a CPU copy — the safe universal Android-TV path.
///  - **Phone → `mediacodec-copy`** (fix402): the old phone path used surface
///    mode (`mediacodec`) on the assumption that only Tegra hit the
///    SurfaceTexture failure. It doesn't: media_kit renders through the libmpv
///    render API into a Flutter texture (vo=null), so there is NO native
///    Surface for surface-mode mediacodec to bind to — it silently falls back
///    to software on phones too (the S24 logged hwdec-current="no" while
///    requesting "mediacodec"). mediacodec-copy is real hardware decode with a
///    cheap CPU copy and engages reliably on the render-API path.
String androidFullscreenHwdec({
  required bool isTegra,
  required bool isLowRam,
  required bool isTV,
}) {
  if (isTegra) return 'mediacodec-copy';
  if (isLowRam) return 'no';
  if (isTV) return 'mediacodec-copy';
  // fix402: phone was 'mediacodec' (surface mode), but that silently falls back
  // to software with media_kit's libmpv render API — there is no native Surface
  // for surface-mode mediacodec to bind to, so the S24 logged hwdec-current="no"
  // (software) despite requesting hardware. mediacodec-copy = real hardware
  // decode + a cheap CPU copy, the proven path on every other device class.
  return 'mediacodec-copy';
}
