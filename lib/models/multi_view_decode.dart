/// Decode mode for multi-view preview cells (fix314).
///
/// On some SoCs — notably NVIDIA Tegra / Shield — running several concurrent
/// `mediacodec-copy` decode sessions for the 2×2 grid corrupts colour output
/// (rainbow / swapped chroma planes). Software decode avoids the bug at the
/// cost of CPU. This setting lets the user pick per device.
///
/// [auto]         — software decode on Tegra/Shield, mediacodec-copy elsewhere.
/// [hardwareCopy] — force mediacodec-copy (the pre-fix314 behaviour).
/// [software]     — force CPU decode (hwdec=no) for all cells.
enum MultiViewDecode {
  auto,
  hardwareCopy,
  software;

  String toJson() => name;

  static MultiViewDecode fromJson(String? v) => switch (v) {
        'hardwareCopy' => hardwareCopy,
        'software' => software,
        _ => auto,
      };

  String get label => switch (this) {
        auto => 'Auto (recommended)',
        hardwareCopy => 'Hardware (copy)',
        software => 'Software',
      };
}
