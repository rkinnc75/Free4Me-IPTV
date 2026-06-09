import 'dart:collection';

import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/device_memory.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/engine_type.dart';
import 'package:open_tv/models/multi_view_layout.dart';
import 'package:open_tv/models/multi_view_decode.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/engine_preference.dart';
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
const backgroundProcessingProp = "backgroundProcessing"; // fix318

// Engine override (v1.4)
const forcedEngineProp = "forcedEngine";
const enginePreferenceProp = "enginePreference"; // fix315

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

// Multi-view (v1.14)
const multiViewLayoutProp = "multiViewLayout";
const multiViewDecodeProp = "multiViewDecode"; // fix314
const multiViewCells1x2Prop = "multiViewCells1x2";
const multiViewCells2x2Prop = "multiViewCells2x2";
const multiViewAutoRestoreChannelsProp = "multiViewAutoRestoreChannels";

// Playback reliability (v1.15)
const miniDemuxerMaxMBProp = "miniDemuxerMaxMB";
const bufferSizeMBProp = "bufferSizeMB";
const streamCompletedDelayMsProp = "streamCompletedDelayMs";
const maxReconnectAttemptsProp = "maxReconnectAttempts";

const contentTypeFilterProp = "contentTypeFilter";

const searchMethodProp = "searchMethod";

const safeModeProp = "safeMode";

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
    var bgProc = settingsMap[backgroundProcessingProp];
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
    var mvLayout = settingsMap[multiViewLayoutProp];
    var mvCells1x2 = settingsMap[multiViewCells1x2Prop];
    var mvCells2x2 = settingsMap[multiViewCells2x2Prop];
    var mvAutoRestore = settingsMap[multiViewAutoRestoreChannelsProp];
    var miniDemuxer = settingsMap[miniDemuxerMaxMBProp];
    var bufferSize = settingsMap[bufferSizeMBProp];
    var streamCompletedDelay = settingsMap[streamCompletedDelayMsProp];
    var maxReconnect = settingsMap[maxReconnectAttemptsProp];

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
    if (bgProc != null) settings.backgroundProcessing = int.parse(bgProc) == 1;
    if (debugLog != null) settings.debugLogging = int.parse(debugLog) == 1;
    if (epgAuto != null) settings.epgAutoRefresh = int.parse(epgAuto) == 1;
    if (epgHours != null) settings.epgRefreshHours = int.parse(epgHours);
    if (epgHour != null) settings.epgRefreshHour = int.parse(epgHour);
    if (epgPast != null) settings.epgPastDays = int.parse(epgPast);
    if (epgForecast != null) settings.epgForecastDays = int.parse(epgForecast);
    if (forcedEngine != null) {
      settings.forcedEngine = EngineType.fromJson(forcedEngine);
    }
    // fix315: global engine preference (primary + fallback order).
    final enginePref = settingsMap[enginePreferenceProp];
    if (enginePref != null) {
      settings.enginePreference = EnginePreference.fromJson(enginePref);
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
    if (mvLayout != null) {
      settings.multiViewLayout = MultiViewLayout.fromJson(mvLayout);
    }
    // fix314: multi-view decode mode.
    final mvDecode = settingsMap[multiViewDecodeProp];
    if (mvDecode != null) {
      settings.multiViewDecode = MultiViewDecode.fromJson(mvDecode);
    }
    if (mvCells1x2 != null) settings.multiViewCells1x2 = mvCells1x2;
    if (mvCells2x2 != null) settings.multiViewCells2x2 = mvCells2x2;
    if (mvAutoRestore != null) {
      settings.multiViewAutoRestoreChannels = int.parse(mvAutoRestore) == 1;
    }

    // Playback reliability — fall back to RAM-aware defaults on first run.
    if (miniDemuxer != null) {
      settings.miniDemuxerMaxMB = int.parse(miniDemuxer);
    } else {
      settings.miniDemuxerMaxMB = DeviceMemory.defaultMiniDemuxerMb;
    }
    if (bufferSize != null) {
      settings.bufferSizeMB = int.parse(bufferSize);
    } else {
      settings.bufferSizeMB = DeviceMemory.defaultBufferSizeMb;
    }
    if (streamCompletedDelay != null) {
      settings.streamCompletedDelayMs = int.parse(streamCompletedDelay);
    }
    if (maxReconnect != null) {
      settings.maxReconnectAttempts = int.parse(maxReconnect);
    }

    final sm = settingsMap[searchMethodProp];
    if (sm != null) {
      settings.searchMethod = SearchMethod.values
              .elementAtOrNull(int.tryParse(sm) ?? 0) ??
          SearchMethod.inMemory;
    }

    final sm70 = settingsMap[safeModeProp];
    if (sm70 != null) settings.safeMode = int.parse(sm70) == 1;

    final ctfRaw = settingsMap[contentTypeFilterProp];
    if (ctfRaw != null) {
      final idx = int.tryParse(ctfRaw) ?? 0;
      final parsed = ContentTypeFilter.values.elementAtOrNull(idx)
          ?? ContentTypeFilter.all;
      // Validate: if the saved filter's type has since been disabled, reset.
      final available = settings.availableContentFilters();
      settings.contentTypeFilter =
          available.contains(parsed) ? parsed : ContentTypeFilter.all;
    }

    AppLog.info(
      'Settings: loaded'
      ' bufferSizeMB=${settings.bufferSizeMB}'
      ' liveDemuxerMaxMB=${settings.liveDemuxerMaxMB}'
      ' miniDemuxerMaxMB=${settings.miniDemuxerMaxMB}'
      ' stableThresholdSecs=${settings.stableThresholdSecs}'
      ' startupGraceMs=${settings.startupGraceMs}'
      ' streamCompletedDelayMs=${settings.streamCompletedDelayMs}'
      ' maxReconnectAttempts=${settings.maxReconnectAttempts}'
      ' multiViewLayout=${settings.multiViewLayout.name}'
      ' multiViewCells1x2="${settings.multiViewCells1x2}"'
      ' multiViewCells2x2="${settings.multiViewCells2x2}"'
      ' multiViewAutoRestoreChannels=${settings.multiViewAutoRestoreChannels}',
    );
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
    settingsMap[backgroundProcessingProp] =
        (settings.backgroundProcessing ? 1 : 0).toString();
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
    settingsMap[enginePreferenceProp] = settings.enginePreference.toJson(); // fix315
    settingsMap[stableThresholdSecsProp] =
        settings.stableThresholdSecs.toString();
    settingsMap[startupGraceMsProp] = settings.startupGraceMs.toString();
    settingsMap[streamScanMaxCountProp] =
        settings.streamScanMaxCount.toString();
    settingsMap[streamScanTimeoutSecsProp] =
        settings.streamScanTimeoutSecs.toString();
    settingsMap[multiViewLayoutProp] = settings.multiViewLayout.toJson();
    settingsMap[multiViewDecodeProp] = settings.multiViewDecode.toJson(); // fix314
    settingsMap[multiViewCells1x2Prop] = settings.multiViewCells1x2;
    settingsMap[multiViewCells2x2Prop] = settings.multiViewCells2x2;
    settingsMap[multiViewAutoRestoreChannelsProp] =
        (settings.multiViewAutoRestoreChannels ? 1 : 0).toString();
    settingsMap[miniDemuxerMaxMBProp] = settings.miniDemuxerMaxMB.toString();
    settingsMap[bufferSizeMBProp] = settings.bufferSizeMB.toString();
    settingsMap[streamCompletedDelayMsProp] =
        settings.streamCompletedDelayMs.toString();
    settingsMap[maxReconnectAttemptsProp] =
        settings.maxReconnectAttempts.toString();
    settingsMap[contentTypeFilterProp] =
        settings.contentTypeFilter.index.toString();
    settingsMap[searchMethodProp] = settings.searchMethod.index.toString();
    settingsMap[safeModeProp] = (settings.safeMode ? 1 : 0).toString();

    await Sql.updateSettings(settingsMap);
    // fix212: keep FTS triggers in sync with the chosen search method.
    // Idempotent: drops triggers for non-FTS methods, (re)creates+rebuilds
    // for FTS methods. Cheap when already in the right state.
    await Sql.reconcileFtsTriggers(
      settings.searchMethod == SearchMethod.ftsAnd ||
          settings.searchMethod == SearchMethod.ftsTrigram,
    );
    _cached = settings; // keep the in-memory copy in sync
    AppLog.info(
      'Settings: saved'
      ' multiViewLayout=${settings.multiViewLayout.name}'
      ' multiViewCells1x2="${settings.multiViewCells1x2}"'
      ' multiViewCells2x2="${settings.multiViewCells2x2}"'
      ' multiViewAutoRestoreChannels=${settings.multiViewAutoRestoreChannels}',
    );
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
    // fix180: also wipe Analyze/Suggest history so suggestions aren't biased
    // by pre-upgrade sessions. Same once-per-version trigger as the log clear.
    await Sql.clearPlaybackMetrics();
    AppLog.info(
      'Free4Me-IPTV $version — log + playback metrics cleared on version change',
    );
    final HashMap<String, String> update = HashMap();
    update[lastLogClearedVersion] = version;
    await Sql.updateSettings(update);
  }
}
