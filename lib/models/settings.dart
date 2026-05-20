import 'package:open_tv/models/engine_type.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/view_type.dart';

class Settings {
  ViewType defaultView;
  bool refreshOnStart;
  bool showLivestreams;
  bool lowLatency;
  bool showMovies;
  bool showSeries;
  bool forceTVMode;

  // --- Free4Me-IPTV: buffer tuning ---
  /// libmpv cache read-ahead in seconds for live streams.
  int liveCacheSecs;

  /// libmpv forward demuxer cache (MB) for live streams.
  int liveDemuxerMaxMB;

  /// libmpv cache read-ahead in seconds for VOD (movies/series).
  int vodCacheSecs;

  /// libmpv forward demuxer cache (MB) for VOD.
  int vodDemuxerMaxMB;

  /// Open() timeout in seconds before retry.
  int openTimeoutSecs;

  /// Reconnect after this many seconds of sustained buffering on livestreams.
  int bufferingWatchdogSecs;

  /// Seconds of uninterrupted playback required before the reconnect counter
  /// is reset. A brief buffering=false right after open() does not count.
  int stableThresholdSecs;

  /// Enable hardware decoding via Android mediacodec.
  bool hwDecode;

  /// Pre-warm channel URL (HEAD request) when a tile receives focus.
  bool preWarmOnFocus;

  // --- Engine (v1.4) ---
  /// Global engine override. [EngineType.auto] means let EnginePicker decide.
  EngineType forcedEngine;

  // --- Debug ---
  bool debugLogging;

  // --- EPG settings (v1.2) ---
  bool epgAutoRefresh;
  int epgRefreshHours;
  int epgRefreshHour;
  int epgPastDays;
  int epgForecastDays;

  Settings({
    this.defaultView = ViewType.all,
    this.refreshOnStart = false,
    this.showLivestreams = true,
    this.lowLatency = false,
    this.showMovies = true,
    this.showSeries = true,
    this.forceTVMode = false,
    this.liveCacheSecs = 20,
    this.liveDemuxerMaxMB = 150,
    this.vodCacheSecs = 60,
    this.vodDemuxerMaxMB = 256,
    this.openTimeoutSecs = 15,
    this.bufferingWatchdogSecs = 12,
    this.stableThresholdSecs = 30,
    this.hwDecode = true,
    this.preWarmOnFocus = true,
    this.forcedEngine = EngineType.auto,
    this.debugLogging = false,
    this.epgAutoRefresh = true,
    this.epgRefreshHours = 24,
    this.epgRefreshHour = 3,
    this.epgPastDays = 1,
    this.epgForecastDays = 7,
  });

  List<MediaType> getMediaTypes() {
    return [
      if (showLivestreams) MediaType.livestream,
      if (showMovies) MediaType.movie,
      if (showSeries) MediaType.serie,
    ];
  }
}
