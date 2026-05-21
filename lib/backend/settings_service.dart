import 'dart:collection';

import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/engine_type.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:package_info_plus/package_info_plus.dart';

const defaultView = "defaultView";
const refreshOnStart = "refreshOnStart";
const showLivestreams = "showLivestreams";
const showMovies = "showMovies";
const showSeries = "showSeries";
const lastSeenVersion = "lastSeenVersion";
const lastLogClearedVersion = "lastLogClearedVersion";
const forceTvMode = "forceTVMode";
const lowLatencyProp = "streamCaching";

// New keys added by Free4Me-IPTV fork
const liveCacheSecsProp = "liveCacheSecs";
const liveDemuxerMaxMBProp = "liveDemuxerMaxMB";
const vodCacheSecsProp = "vodCacheSecs";
const vodDemuxerMaxMBProp = "vodDemuxerMaxMB";
const openTimeoutSecsProp = "openTimeoutSecs";
const bufferingWatchdogSecsProp = "bufferingWatchdogSecs";
const hwDecodeProp = "hwDecode";
const preWarmOnFocusProp = "preWarmOnFocus";

// Engine override (v1.4)
const forcedEngineProp = "forcedEngine";

// Reconnect stability (v1.11.9)
const stableThresholdSecsProp = "stableThresholdSecs";
const startupGraceMsProp = "startupGraceMs";

// EPG settings (v1.2)
const debugLoggingProp = "debugLogging";
const epgAutoRefreshProp = "epgAutoRefresh";
const epgRefreshHoursProp = "epgRefreshHours";
const epgRefreshHourProp = "epgRefreshHour";
const epgPastDaysProp = "epgPastDays";
const epgForecastDaysProp = "epgForecastDays";

// Stream scanner (v1.13.2)
const streamScanMaxCountProp = "streamScanMaxCount";
const streamScanTimeoutSecsProp = "streamScanTimeoutSecs";

class SettingsService {
  /// Module-level cache. Loaded on first call; updated in-place on writes.
  /// Avoids repeated SQLite hits on every channel tap.
  static Settings? _cached;

  /// Get settings, reading from SQLite the first time and caching after.
  static Future<Settings> getSettings() async {
    if (_cached != null) return _cached!;
    _cached = await _readFromDb();
    return _cached!;
  }

  /// Synchronous accessor for code paths that must NOT block on IO
  /// (e.g. channel tile play handler). Returns null if not yet loaded.
  static Settings? get cached => _cached;

  /// Force a re-read from the DB. Useful after external mutation.
  static Future<Settings> reload() async {
    _cached = await _readFromDb();
    return _cached!;
  }

  static Future<Settings> _readFromDb() async {
    var settingsMap = await Sql.getSettings();
    var settings = Settings();
    var view = settingsMap[defaultView];
    var refresh = settingsMap[refreshOnStart];
    var live = settingsMap[showLivestreams];
    var movies = settingsMap[showMovies];
    var series = settingsMap[showSeries];
    var forceTV = settingsMap[forceTvMode];
    var lowLatency = settingsMap[lowLatencyProp];

    var liveSecs = settingsMap[liveCacheSecsProp];
    var liveMB = settingsMap[liveDemuxerMaxMBProp];
    var vodSecs = settingsMap[vodCacheSecsProp];
    var vodMB = settingsMap[vodDemuxerMaxMBProp];
    var openTimeout = settingsMap[openTimeoutSecsProp];
    var watchdog = settingsMap[bufferingWatchdogSecsProp];
    var hw = settingsMap[hwDecodeProp];
    var prewarm = settingsMap[preWarmOnFocusProp];
    var debugLog = settingsMap[debugLoggingProp];
    var epgAuto = settingsMap[epgAutoRefreshProp];
    var epgHours = settingsMap[epgRefreshHoursProp];
    var epgHour = settingsMap[epgRefreshHourProp];
    var epgPast = settingsMap[epgPastDaysProp];
    var epgForecast = settingsMap[epgForecastDaysProp];
    var forcedEngine = settingsMap[forcedEngineProp];
    var stableThreshold = settingsMap[stableThresholdSecsProp];
    var startupGrace = settingsMap[startupGraceMsProp];
    var scanMaxCount = settingsMap[streamScanMaxCountProp];
    var scanTimeout = settingsMap[streamScanTimeoutSecsProp];

    if (view != null) {
      settings.defaultView = ViewType.values[int.parse(view)];
    }
    if (refresh != null) settings.refreshOnStart = int.parse(refresh) == 1;
    if (live != null) settings.showLivestreams = int.parse(live) == 1;
    if (movies != null) settings.showMovies = int.parse(movies) == 1;
    if (series != null) settings.showSeries = int.parse(series) == 1;
    if (forceTV != null) settings.forceTVMode = int.parse(forceTV) == 1;
    if (lowLatency != null) settings.lowLatency = int.parse(lowLatency) == 1;

    if (liveSecs != null) settings.liveCacheSecs = int.parse(liveSecs);
    if (liveMB != null) settings.liveDemuxerMaxMB = int.parse(liveMB);
    if (vodSecs != null) settings.vodCacheSecs = int.parse(vodSecs);
    if (vodMB != null) settings.vodDemuxerMaxMB = int.parse(vodMB);
    if (openTimeout != null) settings.openTimeoutSecs = int.parse(openTimeout);
    if (watchdog != null) settings.bufferingWatchdogSecs = int.parse(watchdog);
    if (hw != null) settings.hwDecode = int.parse(hw) == 1;
    if (prewarm != null) settings.preWarmOnFocus = int.parse(prewarm) == 1;
    if (debugLog != null) settings.debugLogging = int.parse(debugLog) == 1;
    if (epgAuto != null) settings.epgAutoRefresh = int.parse(epgAuto) == 1;
    if (epgHours != null) settings.epgRefreshHours = int.parse(epgHours);
    if (epgHour != null) settings.epgRefreshHour = int.parse(epgHour);
    if (epgPast != null) settings.epgPastDays = int.parse(epgPast);
    if (epgForecast != null) settings.epgForecastDays = int.parse(epgForecast);
    if (forcedEngine != null) {
      settings.forcedEngine = EngineType.fromJson(forcedEngine);
    }
    if (stableThreshold != null) {
      settings.stableThresholdSecs = int.parse(stableThreshold);
    }
    if (startupGrace != null) {
      settings.startupGraceMs = int.parse(startupGrace);
    }
    if (scanMaxCount != null) {
      settings.streamScanMaxCount = int.parse(scanMaxCount);
    }
    if (scanTimeout != null) {
      settings.streamScanTimeoutSecs = int.parse(scanTimeout);
    }

    return settings;
  }

  static Future<void> updateSettings(Settings settings) async {
    HashMap<String, String> settingsMap = HashMap();
    settingsMap[defaultView] = settings.defaultView.index.toString();
    settingsMap[refreshOnStart] = (settings.refreshOnStart ? 1 : 0).toString();
    settingsMap[showLivestreams] = (settings.showLivestreams ? 1 : 0)
        .toString();
    settingsMap[showMovies] = (settings.showMovies ? 1 : 0).toString();
    settingsMap[showSeries] = (settings.showSeries ? 1 : 0).toString();
    settingsMap[forceTvMode] = (settings.forceTVMode ? 1 : 0).toString();
    settingsMap[lowLatencyProp] = (settings.lowLatency ? 1 : 0).toString();

    settingsMap[liveCacheSecsProp] = settings.liveCacheSecs.toString();
    settingsMap[liveDemuxerMaxMBProp] = settings.liveDemuxerMaxMB.toString();
    settingsMap[vodCacheSecsProp] = settings.vodCacheSecs.toString();
    settingsMap[vodDemuxerMaxMBProp] = settings.vodDemuxerMaxMB.toString();
    settingsMap[openTimeoutSecsProp] = settings.openTimeoutSecs.toString();
    settingsMap[bufferingWatchdogSecsProp] =
        settings.bufferingWatchdogSecs.toString();
    settingsMap[hwDecodeProp] = (settings.hwDecode ? 1 : 0).toString();
    settingsMap[preWarmOnFocusProp] = (settings.preWarmOnFocus ? 1 : 0)
        .toString();
    settingsMap[debugLoggingProp] = (settings.debugLogging ? 1 : 0).toString();
    settingsMap[epgAutoRefreshProp] = (settings.epgAutoRefresh ? 1 : 0)
        .toString();
    settingsMap[epgRefreshHoursProp] = settings.epgRefreshHours.toString();
    settingsMap[epgRefreshHourProp] = settings.epgRefreshHour.toString();
    settingsMap[epgPastDaysProp] = settings.epgPastDays.toString();
    settingsMap[epgForecastDaysProp] = settings.epgForecastDays.toString();
    settingsMap[forcedEngineProp] = settings.forcedEngine.toJson();
    settingsMap[stableThresholdSecsProp] =
        settings.stableThresholdSecs.toString();
    settingsMap[startupGraceMsProp] = settings.startupGraceMs.toString();
    settingsMap[streamScanMaxCountProp] =
        settings.streamScanMaxCount.toString();
    settingsMap[streamScanTimeoutSecsProp] =
        settings.streamScanTimeoutSecs.toString();

    await Sql.updateSettings(settingsMap);
    _cached = settings; // keep the in-memory copy in sync
  }

  static Future<void> updateLastSeenVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    HashMap<String, String> lastSeenMap = HashMap();
    lastSeenMap[lastSeenVersion] = packageInfo.version;
    await Sql.updateSettings(lastSeenMap);
  }

  static Future<String?> shouldShowWhatsNew() async {
    final String version = (await PackageInfo.fromPlatform()).version;
    return (await Sql.getSettings())[lastSeenVersion] != version
        ? version
        : null;
  }

  /// Clears the debug log file the first time the app boots on a new version.
  ///
  /// Idempotent: tracks the cleared-for version in [lastLogClearedVersion],
  /// so subsequent launches on the same build do not touch the log again.
  /// Safe to call regardless of whether file logging is currently enabled —
  /// [AppLog.clearLog] handles both states.
  static Future<void> maybeRotateLogOnVersionChange() async {
    final String version = (await PackageInfo.fromPlatform()).version;
    final settingsMap = await Sql.getSettings();
    if (settingsMap[lastLogClearedVersion] == version) return;

    await AppLog.clearLog();
    AppLog.info(
      'Free4Me-IPTV $version — log cleared on version change',
    );
    final HashMap<String, String> update = HashMap();
    update[lastLogClearedVersion] = version;
    await Sql.updateSettings(update);
  }
}
