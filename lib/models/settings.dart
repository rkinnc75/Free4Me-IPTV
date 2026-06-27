import 'package:open_tv/backend/device_memory.dart';
import 'package:open_tv/models/dev_mpv_options.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/multi_view_layout.dart';
import 'package:open_tv/models/multi_view_decode.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/models/zoom_mode.dart';

/// Content-type filter for the All tab in the bottom navigation bar.
/// Cycles through states so the user can quickly limit searches to a
/// single content type without going into Settings.
enum ContentTypeFilter { all, live, movies, series }

/// Controls how channel name search queries are executed.
enum SearchMethod {
  /// FTS5 word-prefix phrase (unicode61, fix519): matches the whole query as
  /// one quoted phrase against the channels_fts index, so word order is
  /// preserved. (Was a trigram substring index before fix519.)
  ftsPhrase,

  /// FTS5 word-prefix AND — same unicode61 index, splits the query on
  /// whitespace and requires every word (as a prefix); no phrase ordering.
  /// ~2x faster for multi-word queries. Single words identical to ftsPhrase.
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

  /// fix354: seconds of cache mpv must fill before VOD playback starts (and
  /// before resuming after an underrun). 0 disables the pre-buffer pause.
  int vodPrebufferSecs;

  /// fix357: live DVR-to-disk buffer (full-screen single view only).
  bool dvrEnabled;

  /// fix361: downmix multichannel audio (E-AC3/AC3 5.1) to stereo. Default ON.
  /// On TV boxes whose HDMI/codec path can't render multichannel E-AC3 the
  /// stream throws repeated 'Error decoding audio' (onn 4K, YES Network,
  /// 2026-06-13). Stereo downmix decodes in software and plays everywhere.
  bool audioDownmixStereo;

  /// fix357: DVR window length in minutes (5–90, steps of 5).
  int dvrMinutes;

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
  /// fix505: advanced override — force hardware decode even on a low-RAM box
  /// (bypasses the low-RAM→software routing). Default false.
  bool forceHwDecode;
  /// fix506: allow the native 1080p render cap on low-RAM 4K boxes (auto-applied
  /// by MainActivity when the device qualifies). Default true; set false to keep
  /// rendering at native 4K. Pushed to the native SharedPref; applies at launch.
  bool cap1080pOnLowRam;

  /// fix510: opt-in always-live video preview in the TV Live-guide hero. On
  /// capable boxes the hero is live by default; on low-RAM boxes (Onn/Amlogic)
  /// it is art-first unless this is true. TV-only; phone code never reads it.
  bool tvHeroLivePreview;

  /// Pre-warm channel URL (HEAD request) when a tile receives focus.
  bool preWarmOnFocus;
  /// fix318: keep long operations (source refresh) running in an Android
  /// foreground service so they survive the user switching away. Default off
  /// until validated on-device. Android-only; ignored elsewhere.
  bool backgroundProcessing;

  bool debugLogging;

  /// fix374: when true, log source usernames/passwords verbatim (developer's
  /// own testing). Default false -> credentials are redacted in the log.
  bool logUserPass;

  bool epgAutoRefresh;
  int epgRefreshHours;
  int epgRefreshHour;
  int epgPastDays;
  int epgForecastDays;
  /// fix502: forward-only look-ahead window (hours) for "what's on" EPG search.
  /// Clamped to [SettingBounds.epgSearchHoursMin, epgForecastDays*24] at use.
  int epgSearchHours;

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

  /// fix341: optional multi-view stability buffer (seconds). When > 0, each
  /// cell pauses for this long after opening so mpv's cache accumulates a
  /// cushion; playback then runs that far behind live and plays THROUGH brief
  /// provider connection drops instead of stalling. 0 = off (live edge).
  int multiViewStabilityBufferSecs;

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

  // ─── fix394: Developer / libmpv advanced tunables ────────────────────────
  // Defaults match libmpv upstream exactly so the Developer section is a
  // no-op until the user opts in. See lib/models/dev_mpv_options.dart for
  // the enum definitions and value-string mappings.

  /// libmpv `demuxer-readahead-secs` (seconds). Default 1.5.
  double devDemuxerReadaheadSecs;

  // fix394 review: removed devDemuxerCacheWaitSecs, devDemuxerMaxWaitKeepaliveSecs,
  // devDemuxerBackwardBufferSecs, devDemuxerDontBufferSecs. `demuxer-cache-wait`
  // is a yes/no flag (not a seconds value), and `demuxer-max-wait-keepalive`,
  // `demuxer-backward-buffer-secs` and `demuxer-dont-buffer-secs` are not real
  // libmpv properties — setting them errored on every stream open.

  /// libmpv `network-timeout` (seconds). Default 30.
  int devNetworkTimeoutSecs;

  /// libmpv `tls-verify`. Defaults to false (off): certificate verification
  /// is disabled by default because many IPTV providers serve HTTPS with
  /// self-signed certs. The per-channel `ignoreSsl` (read from import
  /// headers) still forces tls-verify=no regardless of this toggle.
  bool devTlsVerify;

  /// libmpv `video-sync` mode. Default [VideoSyncMode.audio].
  VideoSyncMode devVideoSync;

  /// libmpv `video-sync-max-video-change` (ratio). Default 1.0.
  double devVideoSyncMaxVideoChange;

  /// libmpv `tscale` (temporal scaler). Default [TscaleMode.nearest].
  TscaleMode devTscale;

  /// libmpv `framedrop` mode. Default [FrameDropMode.vo]; the engine
  /// auto-upgrades `vo` to `decoder` on low-RAM Android (see dev_mpv_options).
  FrameDropMode devFramedrop;

  /// libmpv `interpolation` (motion-compensated frame interpolation).
  /// Default false.
  bool devInterpolation;

  /// libmpv `deband` (debanding filter). Default false.
  bool devDeband;

  /// fix565: on low-RAM Android boxes (onn 4K Plus / Amlogic + Mali-G310) cap
  /// video OUTPUT to 30 fps via a `vf=fps=30` filter. The fix564 overlay proved
  /// 60 fps 1080p stutters there because each frame misses the vsync deadline
  /// at the texture-upload stage (VO drops ~13–50/sec) while the decoder stays
  /// idle (dec 0); halving the upload rate clears the judder with perfect A/V
  /// sync. No effect on 30 fps content or on non-low-RAM devices. Default true
  /// (applies on low-RAM only).
  bool devCapFpsLowRam;

  // fix394 review: removed devTargetColorspace — no `target-colorspace`
  // libmpv property exists (the real option is the `target-colorspace-hint`
  // yes/no flag plus `target-prim`/`target-trc`).

  /// libmpv `hwdec-image-format`. Default [HwdecImageFormat.defaultFmt] —
  /// the engine does NOT call setProperty for `defaultFmt`, letting
  /// libmpv pick the format for the active hwdec mode.
  HwdecImageFormat devHwdecImageFormat;

  /// libmpv `audio-buffer` (seconds). Default 0.2 (libmpv upstream = 200 ms).
  double devAudioBufferSecs;

  /// fix409: seconds the player's top + bottom control bars stay visible after
  /// a tap before auto-hiding (media_kit controlsHoverDuration). 0 = keep until
  /// dismissed. Default 3 (media_kit's stock value).
  int devControlsHideSecs;

  /// fix422: the user's last-chosen single-cell full-screen video fit
  /// (fit / stretch / crop). Restored on the next full-screen open.
  ZoomMode playerZoomMode;

  /// libmpv `audio-spdif` (S/PDIF passthrough). Default [AudioSpdifMode.no].
  /// Enabling passthrough on a box→TV HDMI path will SILENCE audio
  /// unless the downstream device is an AV receiver that can decode
  /// the passthrough codec.
  AudioSpdifMode devAudioSpdif;
  // ─── end fix394 Developer block ──────────────────────────────────────────

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
    this.vodPrebufferSecs = 15,
    this.dvrEnabled = false,
    this.audioDownmixStereo = true,
    this.dvrMinutes = 5,
    this.vodDemuxerMaxMB = 256,
    this.openTimeoutSecs = 15,
    this.bufferingWatchdogSecs = 12,
    this.stableThresholdSecs = 30,
    this.startupGraceMs = 500,
    this.hwDecode = true,
    this.forceHwDecode = false,
    this.cap1080pOnLowRam = true,
    this.tvHeroLivePreview = false,
    this.preWarmOnFocus = true,
    this.backgroundProcessing = false,
    this.debugLogging = false,
    this.logUserPass = false,
    this.epgAutoRefresh = true,
    this.epgRefreshHours = 24,
    this.epgRefreshHour = 3,
    this.epgPastDays = 1,
    this.epgForecastDays = 7,
    this.epgSearchHours = 3,
    this.streamScanMaxCount = 20,
    this.streamScanTimeoutSecs = 8,
    this.miniDemuxerMaxMB = 32,
    this.bufferSizeMB = 128,
    this.streamCompletedDelayMs = 2000,
    this.multiViewStabilityBufferSecs = 0,
    this.maxReconnectAttempts = 3,
    this.multiViewLayout = MultiViewLayout.none,
    this.multiViewDecode = MultiViewDecode.auto,
    this.multiViewCells1x2 = ',',
    this.multiViewCells2x2 = ',,,',
    this.multiViewAutoRestoreChannels = true,
    this.contentTypeFilter = ContentTypeFilter.all,
    this.searchMethod = SearchMethod.inMemory,
    this.safeMode = false,

    // fix394: Developer / libmpv advanced tunables — defaults match libmpv
    // upstream exactly. See lib/models/dev_mpv_options.dart.
    this.devDemuxerReadaheadSecs = 1.5,
    this.devNetworkTimeoutSecs = 30,
    this.devTlsVerify = false,
    this.devVideoSync = VideoSyncMode.audio,
    this.devVideoSyncMaxVideoChange = 1.0,
    this.devTscale = TscaleMode.nearest,
    this.devFramedrop = FrameDropMode.vo,
    this.devInterpolation = false,
    this.devDeband = false,
    this.devCapFpsLowRam = true,
    this.devHwdecImageFormat = HwdecImageFormat.defaultFmt,
    this.devAudioBufferSecs = 0.2,
    this.devControlsHideSecs = 3,
    this.playerZoomMode = ZoomMode.fit,
    this.devAudioSpdif = AudioSpdifMode.no,
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
    s.vodPrebufferSecs = 15;
    s.dvrEnabled = false;
    s.audioDownmixStereo = true;
    s.dvrMinutes = 5;

    // Retry / reconnect timing.
    s.openTimeoutSecs = isTV ? 20 : 12;
    s.bufferingWatchdogSecs = isTV ? 15 : 10;
    s.stableThresholdSecs = 15;
    s.startupGraceMs = isTV ? 1500 : 800;
    s.streamCompletedDelayMs = 2000;
    s.multiViewStabilityBufferSecs = 0;
    s.maxReconnectAttempts = 3;

    // Hardware decode is always recommended; the engine code routes TV
    // hardware to mediacodec-copy and preview cells to software decode
    // automatically (handled inside MpvEngine._applyMpvOptions).
    s.hwDecode = true;
    s.forceHwDecode = false; // fix505: advanced override off by default
    s.cap1080pOnLowRam = true; // fix506: render cap allowed by default
    s.tvHeroLivePreview = false; // fix510: live hero opt-in (capable boxes ON via _liveOk)

    // Pre-warm — TVs benefit (D-pad-driven focus changes are deliberate);
    // phones less so (touch scrolling sweeps focus rapidly).
    s.preWarmOnFocus = isTV;

    // Stream scanner — TVs scan fewer streams with a longer per-stream
    // timeout; phones the opposite.
    s.streamScanMaxCount = isTV ? 15 : 20;
    s.streamScanTimeoutSecs = isTV ? 10 : 8;

    s.multiViewAutoRestoreChannels = true;

    // Low-latency mode disables back-buffer and tightens cache; on shaky
    // providers it produces more disconnects than it prevents.
    s.lowLatency = false;

    // fix394: Developer / libmpv advanced tunables — defaults match libmpv
    // upstream exactly. The 18 new fields are identical for TV and phone
    // (no isTV branching; PAL/50Hz is a future fix once a PAL device is
    // reported with an A/V issue).
    s.devDemuxerReadaheadSecs = 1.5;
    s.devNetworkTimeoutSecs = 30;
    s.devTlsVerify = false;
    s.devVideoSync = VideoSyncMode.audio;
    s.devVideoSyncMaxVideoChange = 1.0;
    s.devTscale = TscaleMode.nearest;
    s.devFramedrop = FrameDropMode.vo;
    s.devInterpolation = false;
    s.devDeband = false;
    s.devCapFpsLowRam = true;
    s.devHwdecImageFormat = HwdecImageFormat.defaultFmt;
    s.devAudioBufferSecs = 0.2;
    s.devControlsHideSecs = 3;
    s.devAudioSpdif = AudioSpdifMode.no;

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
  // fix524 (owner request): bracketed adult category tag, the literal word
  // "adult", and the "Brazzers" brand (substring matches "brazzers"). Matching
  // is case-insensitive substring on channel name OR group (Channel.nameIsAdult
  // + the safeModeGroupClause LIKE). NOTE: "adult" also matches "Adult Swim" —
  // accepted per owner request; revisit if that legit channel must show.
  '[xx]',
  'adult',
  'brazzer',
];
