import 'package:open_tv/backend/device_memory.dart';
import 'package:open_tv/models/engine_type.dart';
import 'package:open_tv/models/engine_preference.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/multi_view_layout.dart';
import 'package:open_tv/models/multi_view_decode.dart';
import 'package:open_tv/models/view_type.dart';

/// Content-type filter for the All tab in the bottom navigation bar.
/// Cycles through states so the user can quickly limit searches to a
/// single content type without going into Settings.
enum ContentTypeFilter { all, live, movies, series }

/// Controls how channel name search queries are executed.
enum SearchMethod {
  /// FTS5 trigram phrase. Substring match,
  /// phrase ordering verified. Slowest on large datasets.
  ftsTrigram,

  /// FTS5 trigram AND — same index, no phrase ordering. ~2x faster
  /// for multi-word queries. Single words identical to ftsTrigram.
  ftsAnd,

  /// LIKE substring scan — no FTS index. Simple string comparison.
  /// May outperform FTS trigram on very large posting lists.
  likeSubstring,

  /// In-memory — channel names loaded into RAM on refresh. Zero
  /// disk I/O during search. Fastest option; uses ~2.5MB RAM for
  /// 54k channels.
  inMemory,
}

class Settings {
  ViewType defaultView;
  bool refreshOnStart;
  bool showLivestreams;
  bool lowLatency;
  bool showMovies;
  bool showSeries;
  bool forceTVMode;

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

  /// Global engine override. [EngineType.auto] means let EnginePicker decide.
  /// fix315: superseded for the global setting by [enginePreference]; kept for
  /// per-channel/source override compatibility and backup round-trips.
  EngineType forcedEngine;

  /// fix315: global engine preference with explicit primary + fallback order.
  /// Replaces the old global "Auto" with libmpv→Exo (default), Exo→libmpv,
  /// libmpv-only, or Exo-only.
  EnginePreference enginePreference;

  bool debugLogging;

  bool epgAutoRefresh;
  int epgRefreshHours;
  int epgRefreshHour;
  int epgPastDays;
  int epgForecastDays;

  /// Maximum number of streams the radar scanner probes per run.
  /// Default 20, range 1–100. Higher counts take longer.
  int streamScanMaxCount;

  /// Per-stream timeout (seconds) for the scanner to validate that a URL
  /// is actually serving live media bytes. Default 8, range 3–30.
  int streamScanTimeoutSecs;

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

  /// Maximum number of attempts before the app gives up on a stream.
  ///
  /// Covers BOTH failure modes (fix96):
  ///   • open() throwing before it connects (open failures)
  ///   • a stream that opened then dropped, stalled, or never produced
  ///     a frame (reconnects / watchdog / startup-watchdog)
  ///
  /// Default: 3. Range: 1–10.
  ///
  /// Full-screen: maps to the reconnect counter and the open-failure
  ///   counter in Player.
  /// Multi-view:  maps to MultiViewCell's transient-retry budget.
  int maxReconnectAttempts;

  /// Which multi-view grid layout is active (or none).
  MultiViewLayout multiViewLayout;
  /// fix314: decode mode for multi-view preview cells (Tegra/Shield colour fix).
  MultiViewDecode multiViewDecode;

  /// Persisted channel IDs for the 1×2 layout (2 cells), stored as a
  /// comma-separated string. Null entries are stored as empty string.
  String multiViewCells1x2;

  /// Persisted channel IDs for the 2×2 layout (4 cells).
  String multiViewCells2x2;

  /// When `true`, opening the multi-view screen restores the channels
  /// from the last session for the current layout. When `false`, the
  /// screen opens with all cells empty (ready for the user to assign).
  ///
  /// Default `true` to preserve historical behaviour. Channel IDs are
  /// still persisted regardless — flipping this back to `true` will
  /// restore the channels that were active before the toggle.
  bool multiViewAutoRestoreChannels;

  /// Active content-type filter for the All tab. Persisted so the user's
  /// preferred filter (e.g. Live-only on a large multi-type source) survives
  /// app restarts. Defaults to [ContentTypeFilter.all].
  ContentTypeFilter contentTypeFilter;

  /// Which search implementation to use for channel name queries.
  /// Default: [SearchMethod.inMemory] — fastest; served by ChannelSearchCache
  SearchMethod searchMethod;

  /// When true, channels and categories whose name or group name contains
  /// any term from [safeModeBlocklist] are excluded from all views.
  bool safeMode;

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
    this.enginePreference = EnginePreference.libmpvExo,
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
    this.maxReconnectAttempts = 3,
    this.multiViewLayout = MultiViewLayout.none,
    this.multiViewDecode = MultiViewDecode.auto,
    this.multiViewCells1x2 = ',',
    this.multiViewCells2x2 = ',,,',
    this.multiViewAutoRestoreChannels = true,
    this.contentTypeFilter = ContentTypeFilter.all,
    this.searchMethod = SearchMethod.inMemory,
    this.safeMode = false,
  });

  /// Returns the [MediaType] list for the current content-type filter.
  /// When a specific filter is active (Live/Movies/Series), returns only
  /// that type — provided its show-toggle is enabled. Falls back to all
  /// enabled types if the filtered type has been toggled off.
  List<MediaType> getMediaTypes() {
    switch (contentTypeFilter) {
      case ContentTypeFilter.live:
        if (showLivestreams) return [MediaType.livestream];
        break;
      case ContentTypeFilter.movies:
        if (showMovies) return [MediaType.movie];
        break;
      case ContentTypeFilter.series:
        if (showSeries) return [MediaType.serie];
        break;
      case ContentTypeFilter.all:
        break;
    }
    return [
      if (showLivestreams) MediaType.livestream,
      if (showMovies) MediaType.movie,
      if (showSeries) MediaType.serie,
    ];
  }

  /// Content-type filter states available given the current show-toggles.
  /// All is included only when more than one type is enabled (so there's
  /// something to contrast against). Used by BottomNav to build the cycle.
  List<ContentTypeFilter> availableContentFilters() {
    final enabledCount = (showLivestreams ? 1 : 0) +
        (showMovies ? 1 : 0) +
        (showSeries ? 1 : 0);
    return [
      if (enabledCount > 1) ContentTypeFilter.all,
      if (showLivestreams) ContentTypeFilter.live,
      if (showMovies) ContentTypeFilter.movies,
      if (showSeries) ContentTypeFilter.series,
    ];
  }

  /// Returns the next filter in the cycle, wrapping around.
  ContentTypeFilter nextContentFilter() {
    final available = availableContentFilters();
    if (available.length <= 1) {
      return available.isEmpty ? ContentTypeFilter.all : available.first;
    }
    final idx = available.indexOf(contentTypeFilter);
    return available[(idx + 1) % available.length];
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
    s.maxReconnectAttempts = 3;

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
    s.enginePreference = EnginePreference.libmpvExo;
    s.multiViewAutoRestoreChannels = true;

    // Low-latency mode disables back-buffer and tightens cache; on shaky
    // providers it produces more disconnects than it prevents.
    s.lowLatency = false;

    return s;
  }
}

/// Terms matched case-insensitively against channel group_name and name
/// to identify adult content when safeMode is enabled.
///
/// Imported by sql.dart, channel_search_cache.dart, and settings_view.dart
/// so all filtering uses a single source of truth.
const safeModeBlocklist = [
  'xxx',
  '18+',
  'erotic',
  'porn',
  'x-rated',
];
