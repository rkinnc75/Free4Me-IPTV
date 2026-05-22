import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/engine_type.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/source.dart';

/// Determines which [EngineType] to use for a given playback context.
///
/// Resolution order (first non-auto wins):
///   1. Channel-level override  (`channel.engineOverride`)
///   2. Global settings override (`settings.forcedEngine`)
///   3. Source-level default    (`source?.defaultEngine`)
///   4. URL heuristic           (HLS / DASH / MP4 → ExoPlayer, else libmpv)
class EnginePicker {
  const EnginePicker._();

  static EngineType pick({
    required Channel channel,
    required Settings settings,
    Source? source,
    String? url,
  }) {
    // 1. Per-channel override
    final chanOverride = channel.engineOverride;
    if (chanOverride != null && chanOverride != EngineType.auto) {
      AppLog.info(
        'EnginePicker: channel-override → ${chanOverride.name}'
        ' channel="${channel.name}"',
      );
      return chanOverride;
    }

    // 2. Global override
    if (settings.forcedEngine != EngineType.auto) {
      AppLog.info(
        'EnginePicker: global-override → ${settings.forcedEngine.name}'
        ' channel="${channel.name}"',
      );
      return settings.forcedEngine;
    }

    // 3. Source-level default
    final srcDefault = source?.defaultEngine;
    if (srcDefault != null && srcDefault != EngineType.auto) {
      AppLog.info(
        'EnginePicker: source-default → ${srcDefault.name}'
        ' channel="${channel.name}"',
      );
      return srcDefault;
    }

    // 4. URL heuristic
    final u = (url ?? channel.url ?? '').toLowerCase();
    if (u.contains('.m3u8') || u.contains('.mpd') || u.endsWith('.mp4')) {
      AppLog.info(
        'EnginePicker: url-heuristic → ${EngineType.exoplayer.name}'
        ' channel="${channel.name}"'
        ' url="$u"',
      );
      return EngineType.exoplayer;
    }

    AppLog.info(
      'EnginePicker: url-heuristic → ${EngineType.libmpv.name}'
      ' channel="${channel.name}"'
      ' url="$u"',
    );
    return EngineType.libmpv;
  }
}
