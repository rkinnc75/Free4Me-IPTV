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
///  - **Phone → `mediacodec`**: surface mode (hardware, zero-copy) — most
///    efficient, and phones don't hit the Tegra SurfaceTexture failure.
String androidFullscreenHwdec({
  required bool isTegra,
  required bool isLowRam,
  required bool isTV,
}) {
  if (isTegra) return 'mediacodec-copy';
  if (isLowRam) return 'no';
  if (isTV) return 'mediacodec-copy';
  return 'mediacodec';
}
