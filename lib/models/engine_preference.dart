import 'package:open_tv/models/engine_type.dart';

/// Global player-engine preference (fix315). Replaces the old "Auto" global
/// option with explicit primary + fallback ordering.
///
/// `.primary` is the engine tried first (used by EnginePicker today).
/// `.fallback` is the engine to switch to if the primary fails to render
/// (consumed by the runtime decode-fallback added in fix316). When there is no
/// fallback the field equals `.primary`.
///
/// [libmpvExo]  — libmpv first, fall back to ExoPlayer. DEFAULT (the old
///                "Auto" behaviour: libmpv for MPEG-TS/RTMP, Exo otherwise).
/// [exoLibmpv]  — ExoPlayer first, fall back to libmpv.
/// [libmpvOnly] — libmpv only, no fallback.
/// [exoOnly]    — ExoPlayer only, no fallback.
enum EnginePreference {
  libmpvExo,
  exoLibmpv,
  libmpvOnly,
  exoOnly;

  String toJson() => name;

  /// Deserialise. Old saved value 'auto' (and anything unknown) maps to the
  /// default [libmpvExo], which preserves the previous Auto behaviour.
  static EnginePreference fromJson(String? v) => switch (v) {
        'exoLibmpv' => exoLibmpv,
        'libmpvOnly' => libmpvOnly,
        'exoOnly' => exoOnly,
        _ => libmpvExo,
      };

  EngineType get primary => switch (this) {
        libmpvExo || libmpvOnly => EngineType.libmpv,
        exoLibmpv || exoOnly => EngineType.exoplayer,
      };

  EngineType get fallback => switch (this) {
        libmpvExo => EngineType.exoplayer,
        exoLibmpv => EngineType.libmpv,
        libmpvOnly => EngineType.libmpv,
        exoOnly => EngineType.exoplayer,
      };

  bool get hasFallback =>
      this == libmpvExo || this == exoLibmpv;

  String get label => switch (this) {
        libmpvExo => 'libmpv → ExoPlayer',
        exoLibmpv => 'ExoPlayer → libmpv',
        libmpvOnly => 'libmpv only',
        exoOnly => 'ExoPlayer only',
      };
}
