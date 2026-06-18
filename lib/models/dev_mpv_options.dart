/// fix394: Developer / libmpv advanced tunables.
///
/// All defaults here match libmpv's upstream defaults exactly so the new
/// Developer section in Settings is a no-op until the user opts in. Each
/// enum has a `value` getter that returns the literal libmpv expects, plus
/// a `null`-returning sentinel for the "don't set the property" case
/// (where libmpv's upstream auto is the right behaviour and we shouldn't
/// force a particular value).
library;

/// A/V sync mode. Maps to libmpv's `video-sync` property.
/// Default: [audio]. Only values that libmpv actually accepts are listed
/// (fix394 review: the original `display` and `audio-desync` entries were
/// not real mpv `video-sync` choices — see the mpv manual's video-sync list).
enum VideoSyncMode {
  /// Default. Sync video to audio; resample/drop only on large desync.
  audio,

  /// Resample audio to keep video at display refresh (smoothest motion).
  displayResample,

  /// Like display-resample, but drop video frames instead of duplicating
  /// when the display can't keep up.
  displayResampleVdrop,

  /// Sync to display refresh without resampling audio; may repeat/drop frames.
  displayVdrop,

  /// Sync to display refresh and let A/V drift (no correction).
  desync;

  String get value => switch (this) {
        audio => 'audio',
        displayResample => 'display-resample',
        displayResampleVdrop => 'display-resample-vdrop',
        displayVdrop => 'display-vdrop',
        desync => 'desync',
      };

  String get label => switch (this) {
        audio => 'Audio (default)',
        displayResample => 'Display (resample)',
        displayResampleVdrop => 'Display (resample + drop)',
        displayVdrop => 'Display (drop)',
        desync => 'Display (desync)',
      };

  String toJson() => name;

  static VideoSyncMode fromJson(String? v) =>
      VideoSyncMode.values.firstWhere(
        (e) => e.name == v,
        orElse: () => audio,
      );
}

/// Temporal scaler used to upscale frames on slow hardware.
/// Maps to libmpv's `tscale` property. Default: [nearest].
enum TscaleMode {
  nearest,
  bilinear,
  oversample,
  spline36,
  lanczos;

  String get value => switch (this) {
        nearest => 'nearest',
        bilinear => 'bilinear',
        oversample => 'oversample',
        spline36 => 'spline36',
        lanczos => 'lanczos',
      };

  String get label => switch (this) {
        nearest => 'Nearest (default)',
        bilinear => 'Bilinear',
        oversample => 'Oversample',
        spline36 => 'Spline36',
        lanczos => 'Lanczos',
      };

  String toJson() => name;

  static TscaleMode fromJson(String? v) => TscaleMode.values.firstWhere(
        (e) => e.name == v,
        orElse: () => nearest,
      );
}

/// Frame drop mode. Maps to libmpv's `framedrop` property.
/// Default: [vo] — libmpv's upstream default (drop late frames at the video
/// output only; still decode them). fix394 review: the original enum used
/// `yes`, which is not a current mpv `framedrop` choice, and defaulted to
/// `no`, which is NOT the upstream default (so it silently disabled mpv's
/// normal VO frame-dropping on every open).
enum FrameDropMode {
  no,
  vo,
  decoder;

  String get value => switch (this) {
        no => 'no',
        vo => 'vo',
        decoder => 'decoder',
      };

  String get label => switch (this) {
        no => 'No (never drop)',
        vo => 'Video output (default)',
        decoder => 'Decoder',
      };

  String toJson() => name;

  static FrameDropMode fromJson(String? v) => FrameDropMode.values.firstWhere(
        (e) => e.name == v,
        orElse: () => vo,
      );
}

// fix394 review: the `TargetColorspace` enum (mapping to a `target-colorspace`
// property) was removed — no such libmpv property exists. The real option is
// `target-colorspace-hint` (a yes/no flag), with primaries/transfer set via
// `target-prim` / `target-trc`. Exposing a single 6-value "colorspace" knob
// was not implementable and would have errored for every non-`auto` choice.

/// Hardware decoder image format. Maps to libmpv's `hwdec-image-format`
/// property. [defaultFmt] returns null — engine should not setProperty,
/// letting libmpv pick the optimal format for the active hwdec mode.
/// Default: [defaultFmt].
enum HwdecImageFormat {
  defaultFmt,
  nv12,
  rgba,
  i420;

  String? get value => switch (this) {
        defaultFmt => null,
        nv12 => 'nv12',
        rgba => 'rgba',
        i420 => 'i420',
      };

  String get label => switch (this) {
        defaultFmt => 'Auto (default)',
        nv12 => 'NV12',
        rgba => 'RGBA',
        i420 => 'I420',
      };

  String toJson() => name;

  static HwdecImageFormat fromJson(String? v) =>
      HwdecImageFormat.values.firstWhere(
        (e) => e.name == v,
        orElse: () => defaultFmt,
      );
}

/// S/PDIF passthrough mode. Maps to libmpv's `audio-spdif` property.
/// Default: [no] — passthrough disabled, audio is decoded in software and
/// routed through `audio-channels`. NOTE: enabling passthrough on a
/// plain box→TV HDMI path will SILENCE audio unless the downstream device
/// is an AV receiver that can decode the passthrough codec.
enum AudioSpdifMode {
  no,
  ac3,
  eac3,
  dts,
  all;

  /// libmpv `audio-spdif` takes a comma-separated codec list; there is no
  /// literal `no` or `all` value (fix394 review). [no] therefore returns
  /// null — the engine must NOT set the property, leaving passthrough off
  /// (libmpv's default) — and [all] expands to the real codec list.
  String? get value => switch (this) {
        no => null,
        ac3 => 'ac3',
        eac3 => 'eac3',
        dts => 'dts',
        all => 'ac3,eac3,dts',
      };

  String get label => switch (this) {
        no => 'Off (default)',
        ac3 => 'AC3',
        eac3 => 'E-AC3',
        dts => 'DTS',
        all => 'All (AC3+E-AC3+DTS)',
      };

  String toJson() => name;

  static AudioSpdifMode fromJson(String? v) =>
      AudioSpdifMode.values.firstWhere(
        (e) => e.name == v,
        orElse: () => no,
      );
}
