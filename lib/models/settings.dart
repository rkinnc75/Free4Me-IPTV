import 'package:open_tv/backend/device_memory.dart';
import 'package:open_tv/models/engine_type.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/multi_view_layout.dart';
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

  /// Milliseconds to hold the startup grace window after buffering=false
  /// before allowing seek errors and completion events to trigger a reconnect.
  /// Higher values help slower TV hardware (Onn 4K, Fire TV Stick) where the
  /// mpv seek probe arrives more than 500ms after buffering=false.
  /// Default: 500ms. Range: 100–3000ms.
  int startupGraceMs;

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

  // --- Stream scanner (v1.13.2) ---
  /// Maximum number of streams the radar scanner probes per run.
  /// Default 20, range 1–100. Higher counts take longer.
  int streamScanMaxCount;

  /// Per-stream timeout (seconds) for the scanner to validate that a URL
  /// is actually serving live media bytes. Default 8, range 3–30.
  int streamScanTimeoutSecs;

  // --- Playback reliability (v1.15) ---
  /// libmpv forward demuxer cache (MB) for the mini-player / overlay stream.
  /// Independently tunable from liveDemuxerMaxMB.
  /// Default is set from DeviceMemory.defaultMiniDemuxerMb at first run.
  int miniDemuxerMaxMB;

  /// libmpv bufferSize (MB) per player instance.
  /// Mini-player automatically uses half this value.
  /// Default is set from DeviceMemory.defaultBufferSizeMb at first run.
  /// Requires app restart to take effect (bufferSize is set at construction).
  int bufferSizeMB;

  /// Milliseconds to wait before reconnecting after a "stream completed"
  /// event. Gives the provider time to re-establish the TCP connection.
  /// 0 = reconnect immediately. Default: 2000ms. Range: 0–10000ms.
  int streamCompletedDelayMs;

  // --- Multi-view (v1.14) ---
  /// Which multi-view grid layout is active (or none).
  MultiViewLayout multiViewLayout;

  /// Persisted channel IDs for the 1×2 layout (2 cells), stored as a
  /// comma-separated string. Null entries are stored as empty string.
  String multiViewCells1x2;

  /// Persisted channel IDs for the 2×2 layout (4 cells).
  String multiViewCells2x2;

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
    this.startupGraceMs = 500,
    this.hwDecode = true,
    this.preWarmOnFocus = true,
    this.forcedEngine = EngineType.auto,
    this.debugLogging = false,
    this.epgAutoRefresh = true,
    this.epgRefreshHours = 24,
    this.epgRefreshHour = 3,
    this.epgPastDays = 1,
    this.epgForecastDays = 7,
    this.streamScanMaxCount = 20,
    this.streamScanTimeoutSecs = 8,
    this.miniDemuxerMaxMB = 32,
    this.bufferSizeMB = 128,
    this.streamCompletedDelayMs = 2000,
    this.multiViewLayout = MultiViewLayout.none,
    this.multiViewCells1x2 = ',',
    this.multiViewCells2x2 = ',,,',
  });

  List<MediaType> getMediaTypes() {
    return [
      if (showLivestreams) MediaType.livestream,
      if (showMovies) MediaType.movie,
      if (showSeries) MediaType.serie,
    ];
  }

  /// Returns a fresh [Settings] instance with all fields at their hardcoded
  /// defaults.
  ///
  /// Callers that drive a "reset" UX should preserve session-state fields
  /// (debug-logging toggle, multi-view layout, cell assignments) by copying
  /// them back from the user's current Settings before persisting — this
  /// factory itself does not branch on user state.
  factory Settings.defaults() => Settings();

  /// Returns a [Settings] instance with values recommended for the current
  /// device.
  ///
  /// [isTV] should come from `DeviceDetector.isTV()` and [layout] is the
  /// user's currently selected [MultiViewLayout]. The TV branches assume
  /// wired networking and slower mediacodec init (Tegra/older chipsets);
  /// the phone branches assume Wi-Fi and faster recovery. The 2×2 layout
  /// trims the per-cell mini demuxer cap to keep RAM headroom for four
  /// concurrent decoders.
  ///
  /// `DeviceMemory.init()` MUST have been called before invoking this.
  factory Settings.optimisedFor({
    required bool isTV,
    required MultiViewLayout layout,
  }) {
    final s = Settings();

    // Buffer / demuxer — DeviceMemory provides per-RAM defaults.
    s.bufferSizeMB = DeviceMemory.defaultBufferSizeMb;
    s.liveDemuxerMaxMB = DeviceMemory.defaultLiveDemuxerMb;
    s.vodDemuxerMaxMB = DeviceMemory.defaultLiveDemuxerMb + 64;
    s.miniDemuxerMaxMB = switch (layout) {
      MultiViewLayout.twoByTwo =>
          (DeviceMemory.defaultMiniDemuxerMb * 0.75).round().clamp(16, 256),
      _ => DeviceMemory.defaultMiniDemuxerMb,
    };

    // Cache seconds — TVs benefit from a longer read-ahead on wired
    // networks; phones recover faster from Wi-Fi handoffs with a smaller
    // cache.
    s.liveCacheSecs = isTV ? 45 : 30;
    s.vodCacheSecs = 60;

    // Retry / reconnect timing.
    s.openTimeoutSecs = isTV ? 20 : 12;
    s.bufferingWatchdogSecs = isTV ? 15 : 10;
    s.stableThresholdSecs = 15;
    s.startupGraceMs = isTV ? 1500 : 800;
    s.streamCompletedDelayMs = 2000;

    // Hardware decode is always recommended; the engine code routes TV
    // hardware to mediacodec-copy and preview cells to software decode
    // automatically (handled inside MpvEngine._applyMpvOptions).
    s.hwDecode = true;

    // Pre-warm — TVs benefit (D-pad-driven focus changes are deliberate);
    // phones less so (touch scrolling sweeps focus rapidly).
    s.preWarmOnFocus = isTV;

    // Stream scanner — TVs scan fewer streams with a longer per-stream
    // timeout; phones the opposite.
    s.streamScanMaxCount = isTV ? 15 : 20;
    s.streamScanTimeoutSecs = isTV ? 10 : 8;

    s.forcedEngine = EngineType.auto;

    // Low-latency mode disables back-buffer and tightens cache; on shaky
    // providers it produces more disconnects than it prevents.
    s.lowLatency = false;

    return s;
  }
}
