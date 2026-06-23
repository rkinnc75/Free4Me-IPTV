import 'package:open_tv/backend/device_memory.dart';

/// fix240: single source of truth for the min/max of each tunable playback
/// setting. The settings_view.dart sliders and PlaybackAnalyzer.recommend()
/// must agree on these bounds — previously the analyzer clamped to its own
/// hardcoded numbers (e.g. liveCacheSecs up to 120) while the slider maxed at
/// 60, so it could recommend a value the user could not actually set. The
/// analyzer now clamps to these constants. (The sliders still use inline
/// literals for now; when they are migrated to reference this class the two
/// can never drift again. The values below MATCH the current sliders.)
class SettingBounds {
  const SettingBounds._();

  // liveCacheSecs — slider min 5, max 60.
  static const int liveCacheMin = 5;
  static const int liveCacheMax = 60;

  // devControlsHideSecs — slider min 0 (0 = keep until dismissed), max 30.
  static const int controlsHideMin = 0;
  static const int controlsHideMax = 30;

  // startupGraceMs — slider min 100, max 3000.
  static const int startupGraceMin = 100;
  static const int startupGraceMax = 3000;

  // bufferingWatchdogSecs — slider min 5, max 60.
  static const int bufferingWatchdogMin = 5;
  static const int bufferingWatchdogMax = 60;

  // openTimeoutSecs — slider min 5, max 60.
  static const int openTimeoutMin = 5;
  static const int openTimeoutMax = 60;

  // bufferSizeMB — slider min 16, max is device-dependent.
  static const int bufferSizeMin = 16;
  static int get bufferSizeMax => DeviceMemory.maxBufferSizeMb;

  // fix502: epgSearchHours — min 1h; max = the EPG forecast window in hours
  // (you can never search further ahead than the guide data extends).
  static const int epgSearchHoursMin = 1;
  static int epgSearchHoursMax(int epgForecastDays) => epgForecastDays * 24;
}
