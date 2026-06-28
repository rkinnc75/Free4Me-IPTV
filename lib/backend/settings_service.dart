import 'dart:collection';
import 'package:open_tv/models/zoom_mode.dart';

import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/device_memory.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/dev_mpv_options.dart' show
    VideoSyncMode, TscaleMode, FrameDropMode,
    HwdecImageFormat, AudioSpdifMode;
import 'package:open_tv/models/multi_view_layout.dart';
import 'package:open_tv/models/multi_view_decode.dart';
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
const vodPrebufferSecsProp = "vodPrebufferSecs"; // fix354
const dvrEnabledProp = "dvrEnabled"; // fix357
const audioDownmixStereoProp = "audioDownmixStereo"; // fix361
const dvrMinutesProp = "dvrMinutes"; // fix357
const vodDemuxerMaxMBProp = "vodDemuxerMaxMB";
const openTimeoutSecsProp = "openTimeoutSecs";
const bufferingWatchdogSecsProp = "bufferingWatchdogSecs";
const hwDecodeProp = "hwDecode";
const forceHwDecodeProp = "forceHwDecode";
const cap1080pOnLowRamProp = "cap1080pOnLowRam";
const tvHeroLivePreviewProp = "tvHeroLivePreview";
const preWarmOnFocusProp = "preWarmOnFocus";
const backgroundProcessingProp = "backgroundProcessing"; // fix318

// Reconnect stability (v1.11.9)
const stableThresholdSecsProp = "stableThresholdSecs";
const startupGraceMsProp = "startupGraceMs";

// EPG settings (v1.2)
const debugLoggingProp = "debugLogging";
const logUserPassProp = "logUserPass";
const epgAutoRefreshProp = "epgAutoRefresh";
const epgRefreshHoursProp = "epgRefreshHours";
const epgRefreshHourProp = "epgRefreshHour";
const epgPastDaysProp = "epgPastDays";
const epgForecastDaysProp = "epgForecastDays";
const epgSearchHoursProp = "epgSearchHours";

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
const multiViewStabilityBufferSecsProp = "multiViewStabilityBufferSecs"; // fix341
const maxReconnectAttemptsProp = "maxReconnectAttempts";

const contentTypeFilterProp = "contentTypeFilter";

const searchMethodProp = "searchMethod";

const safeModeProp = "safeMode";
const confirmToExitProp = "confirmToExit"; // fix587 (#23)

// fix394: Developer / libmpv advanced tunables.
const devDemuxerReadaheadSecsProp = "devDemuxerReadaheadSecs";
const devNetworkTimeoutSecsProp = "devNetworkTimeoutSecs";
const devTlsVerifyProp = "devTlsVerify";
const devVideoSyncProp = "devVideoSync";
const devVideoSyncMaxVideoChangeProp = "devVideoSyncMaxVideoChange";
const devTscaleProp = "devTscale";
const devFramedropProp = "devFramedrop";
const devInterpolationProp = "devInterpolation";
const devDebandProp = "devDeband";
// fix583: re-keyed (was "devCapFpsLowRam"). fix582 wired the force-30 cap that
// had been INERT since fix570 — but existing low-RAM installs had persisted the
// old default-true, so they suddenly capped to 30 fps. No persisted value of the
// inert setting reflects a real user choice, so re-keying orphans the old value
// → every install reloads at the new default (OFF). The wired toggle still binds
// to settings.devCapFpsLowRam; only its storage key changed.
const devCapFpsLowRamProp = "forceCapFps30LowRam_v2";
const devHwdecImageFormatProp = "devHwdecImageFormat";
const devAudioBufferSecsProp = "devAudioBufferSecs";
const devControlsHideSecsProp = "devControlsHideSecs";
const playerZoomModeProp = "playerZoomMode";
const devAudioSpdifProp = "devAudioSpdif";

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

  /// fix390: resolve the search method from the persisted string. On first
  /// run (no persisted value) on a low-RAM device (< 2300 MB, matching
  /// [ChannelSearchCache._minRamMbForCache]) the default is
  /// [SearchMethod.likeSubstring] instead of [SearchMethod.inMemory].
  ///
  /// Why (fix505): on a low-RAM device the in-memory cache is skipped
  /// (see `ChannelSearchCache.cacheSkipped`). fix390 picked `likeSubstring`
  /// to keep the visible setting honest, but on a huge catalogue (~1.15M
  /// channels, e.g. an onn 4K Plus) a leading-wildcard LIKE is a full-table
  /// scan (>1 s). `ftsPhrase` uses the index-backed `channels_fts` (fast +
  /// on-disk, not the skipped RAM cache) and makes `main.dart` reconcile the
  /// FTS triggers so the index stays fresh. The minor refresh write-cost is
  /// an accepted trade.
  ///
  /// A persisted value always wins — the auto-set only fires on first
  /// run. The threshold is exposed via the named arg so unit tests
  /// don't depend on [DeviceMemory.totalMb].
  static SearchMethod resolveSearchMethod(
    String? persisted, {
    int? totalMb,
    int lowRamThresholdMb = 2300,
  }) {
    if (persisted != null) {
      return SearchMethod.values.elementAtOrNull(int.tryParse(persisted) ?? 0) ??
          SearchMethod.inMemory;
    }
    final ram = totalMb ?? DeviceMemory.totalMb;
    // fix505: low-RAM default is the index-backed channels_fts path
    // (`ftsPhrase`), not the full-table-scan `likeSubstring` (fix390).
    if (ram > 0 && ram < lowRamThresholdMb) return SearchMethod.ftsPhrase;
    return SearchMethod.inMemory;
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
    var vodPre = settingsMap[vodPrebufferSecsProp];
    var dvrEn = settingsMap[dvrEnabledProp];
    var audioDmx = settingsMap[audioDownmixStereoProp];
    var dvrMin = settingsMap[dvrMinutesProp];
    var vodMB = settingsMap[vodDemuxerMaxMBProp];
    var openTimeout = settingsMap[openTimeoutSecsProp];
    var watchdog = settingsMap[bufferingWatchdogSecsProp];
    var hw = settingsMap[hwDecodeProp];
    var forceHw = settingsMap[forceHwDecodeProp];
    var renderCap = settingsMap[cap1080pOnLowRamProp];
    var heroLive = settingsMap[tvHeroLivePreviewProp];
    var prewarm = settingsMap[preWarmOnFocusProp];
    var bgProc = settingsMap[backgroundProcessingProp];
    var debugLog = settingsMap[debugLoggingProp];
    var logUserPass = settingsMap[logUserPassProp];
    var epgAuto = settingsMap[epgAutoRefreshProp];
    var epgHours = settingsMap[epgRefreshHoursProp];
    var epgHour = settingsMap[epgRefreshHourProp];
    var epgPast = settingsMap[epgPastDaysProp];
    var epgForecast = settingsMap[epgForecastDaysProp];
    var epgSearchHrs = settingsMap[epgSearchHoursProp];
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
    var mvStabilityBuffer = settingsMap[multiViewStabilityBufferSecsProp];
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
    if (vodPre != null) settings.vodPrebufferSecs = int.parse(vodPre);
    if (dvrEn != null) settings.dvrEnabled = dvrEn == 'true';
    if (audioDmx != null) settings.audioDownmixStereo = audioDmx == 'true';
    if (dvrMin != null) settings.dvrMinutes = int.parse(dvrMin);
    if (vodMB != null) settings.vodDemuxerMaxMB = int.parse(vodMB);
    if (openTimeout != null) settings.openTimeoutSecs = int.parse(openTimeout);
    if (watchdog != null) settings.bufferingWatchdogSecs = int.parse(watchdog);
    if (hw != null) settings.hwDecode = int.parse(hw) == 1;
    if (forceHw != null) settings.forceHwDecode = int.parse(forceHw) == 1;
    if (renderCap != null) {
      settings.cap1080pOnLowRam = int.parse(renderCap) == 1;
    }
    if (heroLive != null) {
      settings.tvHeroLivePreview = int.parse(heroLive) == 1;
    }
    if (prewarm != null) settings.preWarmOnFocus = int.parse(prewarm) == 1;
    if (bgProc != null) settings.backgroundProcessing = int.parse(bgProc) == 1;
    if (debugLog != null) settings.debugLogging = int.parse(debugLog) == 1;
    if (logUserPass != null) settings.logUserPass = int.parse(logUserPass) == 1;
    if (epgAuto != null) settings.epgAutoRefresh = int.parse(epgAuto) == 1;
    if (epgHours != null) settings.epgRefreshHours = int.parse(epgHours);
    if (epgHour != null) settings.epgRefreshHour = int.parse(epgHour);
    if (epgPast != null) settings.epgPastDays = int.parse(epgPast);
    if (epgForecast != null) settings.epgForecastDays = int.parse(epgForecast);
    if (epgSearchHrs != null) settings.epgSearchHours = int.parse(epgSearchHrs);
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
    if (mvStabilityBuffer != null) {
      settings.multiViewStabilityBufferSecs = int.parse(mvStabilityBuffer);
    }
    if (maxReconnect != null) {
      settings.maxReconnectAttempts = int.parse(maxReconnect);
    }

    final sm = settingsMap[searchMethodProp];
    final resolvedSm = resolveSearchMethod(sm);
    settings.searchMethod = resolvedSm;
    if (sm == null && resolvedSm == SearchMethod.ftsPhrase) {
      // fix505: first-run auto-set on low-RAM device. ftsPhrase is the
      // index-backed channels_fts path — fast on huge catalogues (~1.15M)
      // where likeSubstring (fix390) was a full-table scan. Logged so
      // support can confirm the search path on a 1.9 GB onn 4K Plus.
      AppLog.info(
        'Settings: searchMethod auto-set to ftsPhrase (low-RAM'
        ' device, totalMb=${DeviceMemory.totalMb})',
      );
    }

    final sm70 = settingsMap[safeModeProp];
    if (sm70 != null) settings.safeMode = int.parse(sm70) == 1;

    final cte = settingsMap[confirmToExitProp]; // fix587 (#23)
    if (cte != null) settings.confirmToExit = int.parse(cte) == 1;

    // fix394: Developer / libmpv advanced tunables. Each gate is
    // `prop != null` so a missing persisted value (older backup, or never
    // set) leaves the constructor default in place.
    final dvrSecs = settingsMap[devDemuxerReadaheadSecsProp];
    if (dvrSecs != null) {
      settings.devDemuxerReadaheadSecs = double.tryParse(dvrSecs) ?? 1.5;
    }
    final dnt = settingsMap[devNetworkTimeoutSecsProp];
    if (dnt != null) {
      settings.devNetworkTimeoutSecs = int.tryParse(dnt) ?? 30;
    }
    final dtv = settingsMap[devTlsVerifyProp];
    if (dtv != null) {
      settings.devTlsVerify = int.parse(dtv) == 1;
    }
    final dvs = settingsMap[devVideoSyncProp];
    if (dvs != null) {
      settings.devVideoSync = VideoSyncMode.fromJson(dvs);
    }
    final dvsmvc = settingsMap[devVideoSyncMaxVideoChangeProp];
    if (dvsmvc != null) {
      settings.devVideoSyncMaxVideoChange = double.tryParse(dvsmvc) ?? 1.0;
    }
    final dts = settingsMap[devTscaleProp];
    if (dts != null) {
      settings.devTscale = TscaleMode.fromJson(dts);
    }
    final dfd = settingsMap[devFramedropProp];
    if (dfd != null) {
      settings.devFramedrop = FrameDropMode.fromJson(dfd);
    }
    final di = settingsMap[devInterpolationProp];
    if (di != null) {
      settings.devInterpolation = int.parse(di) == 1;
    }
    final dcf = settingsMap[devCapFpsLowRamProp];
    if (dcf != null) {
      settings.devCapFpsLowRam = int.parse(dcf) == 1;
    }
    final ddb = settingsMap[devDebandProp];
    if (ddb != null) {
      settings.devDeband = int.parse(ddb) == 1;
    }
    final dhif = settingsMap[devHwdecImageFormatProp];
    if (dhif != null) {
      settings.devHwdecImageFormat = HwdecImageFormat.fromJson(dhif);
    }
    final dabs = settingsMap[devAudioBufferSecsProp];
    if (dabs != null) {
      settings.devAudioBufferSecs = double.tryParse(dabs) ?? 0.0;
    }
    final dchs = settingsMap[devControlsHideSecsProp];
    if (dchs != null) {
      settings.devControlsHideSecs = int.tryParse(dchs) ?? 3;
    }
    final pzm = settingsMap[playerZoomModeProp];
    if (pzm != null) {
      settings.playerZoomMode = ZoomMode.values.firstWhere(
          (m) => m.name == pzm,
          orElse: () => ZoomMode.fit);
    }
    final dasp = settingsMap[devAudioSpdifProp];
    if (dasp != null) {
      settings.devAudioSpdif = AudioSpdifMode.fromJson(dasp);
    }

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
    settingsMap[vodPrebufferSecsProp] = settings.vodPrebufferSecs.toString();
    settingsMap[dvrEnabledProp] = settings.dvrEnabled.toString();
    settingsMap[audioDownmixStereoProp] = settings.audioDownmixStereo.toString();
    settingsMap[dvrMinutesProp] = settings.dvrMinutes.toString();
    settingsMap[vodDemuxerMaxMBProp] = settings.vodDemuxerMaxMB.toString();
    settingsMap[openTimeoutSecsProp] = settings.openTimeoutSecs.toString();
    settingsMap[bufferingWatchdogSecsProp] =
        settings.bufferingWatchdogSecs.toString();
    settingsMap[hwDecodeProp] = (settings.hwDecode ? 1 : 0).toString();
    settingsMap[forceHwDecodeProp] =
        (settings.forceHwDecode ? 1 : 0).toString();
    settingsMap[cap1080pOnLowRamProp] =
        (settings.cap1080pOnLowRam ? 1 : 0).toString();
    settingsMap[tvHeroLivePreviewProp] =
        (settings.tvHeroLivePreview ? 1 : 0).toString();
    settingsMap[backgroundProcessingProp] =
        (settings.backgroundProcessing ? 1 : 0).toString();
    settingsMap[preWarmOnFocusProp] = (settings.preWarmOnFocus ? 1 : 0)
        .toString();
    settingsMap[debugLoggingProp] = (settings.debugLogging ? 1 : 0).toString();
    settingsMap[logUserPassProp] = (settings.logUserPass ? 1 : 0).toString();
    settingsMap[epgAutoRefreshProp] = (settings.epgAutoRefresh ? 1 : 0)
        .toString();
    settingsMap[epgRefreshHoursProp] = settings.epgRefreshHours.toString();
    settingsMap[epgRefreshHourProp] = settings.epgRefreshHour.toString();
    settingsMap[epgPastDaysProp] = settings.epgPastDays.toString();
    settingsMap[epgForecastDaysProp] = settings.epgForecastDays.toString();
    settingsMap[epgSearchHoursProp] = settings.epgSearchHours.toString();
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
    settingsMap[multiViewStabilityBufferSecsProp] =
        settings.multiViewStabilityBufferSecs.toString();
    settingsMap[maxReconnectAttemptsProp] =
        settings.maxReconnectAttempts.toString();
    settingsMap[contentTypeFilterProp] =
        settings.contentTypeFilter.index.toString();
    settingsMap[searchMethodProp] = settings.searchMethod.index.toString();
    settingsMap[safeModeProp] = (settings.safeMode ? 1 : 0).toString();
    settingsMap[confirmToExitProp] =
        (settings.confirmToExit ? 1 : 0).toString(); // fix587 (#23)

    // fix394: Developer / libmpv advanced tunables. Bools are stored as
    // 0/1 (matching the existing convention for `forceTVMode`,
    // `logUserPass`, etc.); doubles are stored as raw double strings;
    // enums as their `name` (so a re-read uses fromJson).
    settingsMap[devDemuxerReadaheadSecsProp] =
        settings.devDemuxerReadaheadSecs.toString();
    settingsMap[devNetworkTimeoutSecsProp] =
        settings.devNetworkTimeoutSecs.toString();
    settingsMap[devTlsVerifyProp] =
        (settings.devTlsVerify ? 1 : 0).toString();
    settingsMap[devVideoSyncProp] = settings.devVideoSync.toJson();
    settingsMap[devVideoSyncMaxVideoChangeProp] =
        settings.devVideoSyncMaxVideoChange.toString();
    settingsMap[devTscaleProp] = settings.devTscale.toJson();
    settingsMap[devFramedropProp] = settings.devFramedrop.toJson();
    settingsMap[devInterpolationProp] =
        (settings.devInterpolation ? 1 : 0).toString();
    settingsMap[devDebandProp] =
        (settings.devDeband ? 1 : 0).toString();
    settingsMap[devCapFpsLowRamProp] =
        (settings.devCapFpsLowRam ? 1 : 0).toString();
    settingsMap[devHwdecImageFormatProp] =
        settings.devHwdecImageFormat.toJson();
    settingsMap[devAudioBufferSecsProp] =
        settings.devAudioBufferSecs.toString();
    settingsMap[devControlsHideSecsProp] =
        settings.devControlsHideSecs.toString();
    settingsMap[playerZoomModeProp] = settings.playerZoomMode.name;
    settingsMap[devAudioSpdifProp] = settings.devAudioSpdif.toJson();

    await Sql.updateSettings(settingsMap);
    // fix212: keep FTS triggers in sync with the chosen search method.
    // Idempotent: drops triggers for non-FTS methods, (re)creates+rebuilds
    // for FTS methods. Cheap when already in the right state.
    await Sql.reconcileFtsTriggers(
      settings.searchMethod == SearchMethod.ftsAnd ||
          settings.searchMethod == SearchMethod.ftsPhrase,
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
