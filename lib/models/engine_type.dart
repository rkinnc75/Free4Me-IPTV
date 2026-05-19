/// Which media engine to use for a given stream.
///
/// [auto]      — let [EnginePicker] decide based on URL and source type.
/// [libmpv]    — always use media_kit / libmpv (best for MPEG-TS, RTMP).
/// [exoplayer] — always use ExoPlayer (best for HLS, DASH, MP4).
enum EngineType {
  auto,
  libmpv,
  exoplayer;

  /// Serialise to the string stored in DB / settings.
  String toJson() => name;

  /// Deserialise; returns [auto] for unrecognised strings.
  static EngineType fromJson(String? v) => switch (v) {
        'libmpv' => libmpv,
        'exoplayer' => exoplayer,
        _ => auto,
      };

  String get label => switch (this) {
        auto => 'Auto (recommended)',
        libmpv => 'libmpv (MPEG-TS / RTMP)',
        exoplayer => 'ExoPlayer (HLS / DASH / MP4)',
      };
}
