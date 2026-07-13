import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkvideo;
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/device_detector.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/multi_view_decode.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/player/hwdec_routing.dart';
import 'package:open_tv/player/hwdec_decode_state.dart';
import 'package:open_tv/player/player_engine.dart';

/// libmpv-backed engine via media_kit.
///
/// Handles MPEG-TS, RTMP, and essentially any format ffmpeg supports.
/// Owns the [VideoState] key so it can enter/exit fullscreen natively.
class MpvEngine implements PlayerEngine {
  final Channel channel;
  final Settings settings;
  /// When false, [open] skips the fullscreen-entry call. Set to false for
  /// the overlay (mini-player) so it never steals fullscreen.
  final bool fullscreenOnOpen;
  /// When true, uses a reduced buffer (32 MB) suitable for multi-view cells.
  /// Full-screen players use 256 MB. Hardware decoding is also disabled in
  /// preview mode to avoid surface-binding contention when multiple cells
  /// share the same hardware decoder pool.
  // finding 19: made mutable (was final) so promoteToFullScreen() can upgrade
  // an adopted mini-player engine to full-screen config without a reopen. The
  // constructor still initializes it; only the promotion path mutates it.
  bool previewMode;

  /// fix623: true for multi-view grid CELLS (not the mini-player PiP). Cells
  /// still set previewMode=true so they keep the multi-view decode handling
  /// (the Tegra/Shield rainbow + onn low-RAM texture-contention paths in the
  /// hwdec block are keyed on previewMode and must stay), but for BUFFERING they
  /// should behave like the full player: use the full livestream demuxer cap
  /// (liveDemuxerMaxMB) and honor the low-RAM 30fps cap, instead of the tiny
  /// mini-player values (miniDemuxerMaxMB=16, cap disabled). Without this a cell
  /// was capped at ~16MB of demux (~40s of a 3.5Mbit/s stream — the observed
  /// ceiling) no matter the user's "Livestream cache/demuxer max" settings.
  final bool multiViewMode;

  /// fix357: when true (full-screen Player, live, no catch-up override) the
  /// live DVR-to-disk buffer may be enabled per settings. Mini-player and
  /// multi-view cells never set this.
  // finding 19: made mutable (was final) so promoteToFullScreen() can open the
  // DVR-eligibility gate on an adopted engine.
  bool dvrEligible;

  // fix357: DVR runtime state.
  Directory? _dvrDir;
  Timer? _dvrGuard;
  int _dvrLastDirBytes = 0;
  bool _dvrActive = false;

  // finding 102: set from open()'s isLive param; suppresses forwarding of
  // mpv's spurious completed=true (EOF-at-TS-boundary) on live streams so the
  // documented "live must not emit completed" contract is actually honoured.
  bool _isLive = false;

  /// fix743: the hwdec mode actually applied for the current FULL-SCREEN
  /// open ('no' when the persisted blocklist skipped the probe; null until a
  /// full-screen options pass runs — preview branches never set it). Lets the
  /// player gate blocklist WRITES on hardware having actually been requested.
  String? appliedHwdecMode;

  /// fix396: periodic decode heartbeat (full-screen + debug logging only).
  /// The Shield black-screen log had "12 s of silence" — no position lines —
  /// which is the smoking gun for a stalled playhead. This logs cheap CACHED
  /// state (no native round-trip) every few seconds so the export shows
  /// whether position advances and whether a frame size is present.
  Timer? _diagHeartbeat;
  Duration _lastHeartbeatPos = Duration.zero;

  // fix735 (Peer2 watchdog→silent-resync, inverted for mpv): the diag heartbeat
  // above is debug-gated; this ALWAYS-ON, live-only watchdog samples `avsync`
  // and signals [desyncStream] when a playing/advancing/non-buffering stream has
  // drifted past threshold for a sustained window. Peer2's buffering watchdog
  // can't see this (position keeps advancing, paused-for-cache=no) and ExoPlayer
  // exposes no avsync — monitoring it is an mpv advantage. Verified on the onn:
  // a fresh open resets avsync to ~0, so the player's reopen resyncs.
  Timer? _avsyncWatchdog;
  int _desyncTicks = 0;
  Duration _lastAvsyncPos = Duration.zero;
  final _desyncCtrl = StreamController<double>.broadcast();
  static const double _desyncThresholdSecs = 3.0;
  static const int _desyncSustainTicks = 3; // 3 × 6s ≈ 18s sustained

  @override
  bool get dvrActive => _dvrActive; // fix364: was missing — UI read the
  // interface default (false), so the DVR transport bar never showed even
  // though the engine had DVR fully active (1.32.3 screenshot bug).

  // finding 99: injectable seam. Production passes nothing and gets the real
  // native Player built with the exact bufferSize/logLevel logic below; tests
  // inject a fake exposing broadcast controllers so MpvEngine lifecycle
  // (dispose, sub cleanup, post-dispose event guards) is testable without a
  // native mpv. Assigned in the constructor body before any _player use.
  final mk.Player _player;
  late final mkvideo.VideoController _controller =
      mkvideo.VideoController(_player);
  // fix130: stable key — one texture per player handle; fix126's per-adopt
  // recreation orphaned the native texture. The texture is freed by
  // Player.dispose() release[] callbacks (confirmed from media_kit source).
  final GlobalKey<mkvideo.VideoState> _videoKey =
      GlobalKey<mkvideo.VideoState>();

  // Stream controllers that mirror the media_kit streams.
  final _bufferingCtrl = StreamController<bool>.broadcast();
  final _completedCtrl = StreamController<bool>.broadcast();
  final _errorCtrl = StreamController<String>.broadcast();
  final _positionCtrl = StreamController<Duration>.broadcast();
  // fix515: one-shot-per-play friendly stream-info label ("720p H.264") for
  // the single-cell full-screen top bar; broadcast so a late subscriber
  // (e.g. after an engine-swap re-render) doesn't crash, though in practice
  // there's at most one event per play.
  final _streamInfoCtrl = StreamController<String>.broadcast();
  // fix732 (mock §4.7): fires once when the first real decoded frame is sized
  // (dwidth 0→WxH), so the player can fade out the channel-zap shutter.
  final _firstFrameCtrl = StreamController<void>.broadcast();
  // fix522: latch the last label so a late subscriber can seed from it.
  String? _lastStreamInfo;

  final List<StreamSubscription<dynamic>> _subs = [];

  /// Idempotency guard. dispose() can fire multiple times in a multi-view
  /// session because Flutter defers widget disposal — the second and later
  /// calls would otherwise try to close already-closed StreamControllers
  /// and dispose an already-disposed native mpv instance.
  bool _disposed = false;

  /// fix331: one-shot guard so the mid-playback surface probe logs once per
  /// engine (not on every buffering toggle).
  bool _midPlaybackProbed = false;

  /// fix338: set once this engine has emitted ANY error, so the +4s
  /// texture-attach check does not pile a second error onto a cell that is
  /// already being restarted by a provider open-failure.
  bool _emittedError = false;

  /// fix345 (review CRIT-2): one-shot — emit a single liveness buffering=false
  /// the first time mpv reports actually playing (fix335 pattern).
  /// mpv's own buffering events are broadcast and can fire during open(),
  /// before the Player has subscribed (events dropped); a healthy live stream
  /// may then never toggle buffering again, stranding the startup watchdog
  /// into a false fallback. Belt to the fix345 subscribe-before-open change.
  bool _signalledPlaying = false;

  /// fix337: serialize VideoController platform initialization across ALL
  /// engine instances. The Shield log proved that when four 2x2 cells create
  /// their controllers in the same frame, two of the four texture
  /// registrations never complete (SURFACE probes: textureId null with
  /// playerWH known — decoding but no texture => black cell, in EVERY 2x2
  /// session, with allocated texture ids skipping numbers). Initializing one
  /// controller at a time removes the race.
  static Future<void> _textureInitChain = Future.value();

  MpvEngine({
    required this.channel,
    required this.settings,
    this.fullscreenOnOpen = true,
    this.previewMode = false,
    this.multiViewMode = false,
    this.dvrEligible = false,
    // finding 99: test-only injection seam. Omitted in production → the real
    // native Player is built with the exact bufferSize/logLevel logic that was
    // previously inline on the `late final _player` initializer.
    @visibleForTesting mk.Player? player,
  }) : _player = player ??
            mk.Player(
              configuration: mk.PlayerConfiguration(
                // bufferSizeMB from settings; mini-player PiP uses half.
                // fix623: multi-view cells use the full size like the main
                // player.
                bufferSize: (previewMode && !multiViewMode)
                    ? (settings.bufferSizeMB ~/ 2) * 1024 * 1024
                    : settings.bufferSizeMB * 1024 * 1024,
                // fix396: surface libmpv's own decode/vo/demuxer messages. The
                // full-screen engine goes verbose when debug logging is on (the
                // black-screen investigation needs hwdec/vo/decoder init
                // messages, which mpv emits at `v`); preview cells and
                // non-debug stay at warn so multi-view sessions aren't flooded.
                // Routed to AppLog via stream.log.
                logLevel: (!previewMode && settings.debugLogging)
                    ? mk.MPVLogLevel.v
                    : mk.MPVLogLevel.warn,
              ),
            ) {
    _player.setPlaylistMode(mk.PlaylistMode.none);

    _subs.add(_player.stream.buffering.listen((v) {
      _bufferingCtrl.add(v);
      // fix331: capture the texture/rect WHILE playing. Existing SURFACE traces
      // fire at rotate-init (texture not yet attached → null) and at exit, so a
      // black-screen-with-audio session never logged the surface state during
      // playback. When buffering clears (a frame should be visible), probe the
      // surface once after a short delay. textureId=null/rect=null here ==
      // texture never attached; non-null with playerWH=0x0 == attached but mpv
      // reported no video size; non-null with a real rect == surface is fine
      // and the black screen is elsewhere (e.g. compositing).
      if (!v && !_midPlaybackProbed && !_disposed) {
        _midPlaybackProbed = true;
        Future.delayed(const Duration(seconds: 2), () {
          if (!_disposed) {
            logSurface('mid-playback+2s');
            // fix396: pair the surface probe with libmpv's decode state so a
            // black-frame session shows both halves (texture + decode) at once.
            if (!previewMode) unawaited(logDecodeState('mid-playback+2s'));
          }
        });
      }
    }));
    // finding 102: on a live stream, mpv can emit completed=true at a spurious
    // EOF (e.g. a TS-segment boundary). The interface contract is that live
    // streams must not surface completed, so drop true events while _isLive.
    // VOD (isLive=false) forwarding is unchanged.
    _subs.add(_player.stream.completed.listen((v) {
      if (_isLive && v) return;
      _completedCtrl.add(v);
    }));
    _subs.add(_player.stream.playing.listen((playing) {
      // fix345: emit on EVERY transition to playing (not one-shot) — the
      // Player arms its startup watchdog after open(), so a one-shot signal
      // fired during open() could be consumed pre-arm (the exact bug
      // fix342 closed in cells). mpv's playing stream only fires on
      // transitions, so this cannot spam.
      if (playing && !_disposed) {
        if (!_signalledPlaying) {
          _signalledPlaying = true;
          if (AppLog.enabled) {
            AppLog.info('MpvEngine: first playing — signalling liveness');
          }
        }
        _bufferingCtrl.add(false);
      }
    }));
    _subs.add(_player.stream.error.listen(_emitError));
    _subs.add(_player.stream.position.listen((p) => _positionCtrl.add(p)));

    // fix396: route libmpv's own log messages into AppLog so a black-screen
    // session carries native decode/vo/demuxer diagnostics in the export.
    // Volume is governed by the configured logLevel above (warn unless this is
    // the full-screen engine with debug logging on). warn/fatal → warn; the
    // rest → info. Prefix `[mpv:<level>] <component>:` so it's greppable.
    _subs.add(_player.stream.log.listen((l) {
      if (_disposed) return;
      final line = '[mpv:${l.level}] ${l.prefix}: ${l.text.trim()}';
      if (l.level == 'warn' || l.level == 'fatal' || l.level == 'error') {
        AppLog.warn(line);
      } else {
        AppLog.info(line);
      }
    }));

    // fix116.5g: engine-identity tag so every engine can be followed
    // end-to-end through create → detach → adopt → dispose in logs.
    AppLog.info('MpvEngine: created eid=${identityHashCode(this)}'
        ' channel="${channel.name}" previewMode=$previewMode');
  }


  /// fix126: called by Player when this engine is adopted into a new Player
  /// (swap handoff). Recreates the video key so the adopted Video mounts a
  /// fresh VideoState with its own texture registration; the old mini
  /// VideoState then disposes normally and unregisters its texture.
  /// fix130: NO-OP (was fix126.2 per-adopt key recreation — reverted).
  /// One texture per Player handle (android_video_controller _controllers[handle]);
  /// recreating the key orphans the native texture. Texture freed by dispose().
  /// Retained for the call site in player.dart + surface tracing.
  void onAdopt() {
    AppLog.info('MpvEngine: onAdopt (no-op; same controller/texture)'
        ' eid=${identityHashCode(this)}');
  }

  /// finding 18: the full-screen (non-preview) routed hwdec property value for
  /// this device, mirroring the else-if chain in [_applyMpvOptions]. Returns
  /// 'no' when the user disabled hw decode or the platform is unsupported.
  /// Factored out so [setHardwareDecode] can restore the SAME mode that open()
  /// would have used, without re-opening the stream.
  Future<String> _routedFullscreenHwdec() async {
    final s = settings;
    if (s.hwDecode && Platform.isAndroid) {
      final isTV = await DeviceDetector.isTV();
      final isTegra = await DeviceDetector.isTegra();
      final isLowRam = await DeviceDetector.isLowRamDevice();
      return androidFullscreenHwdec(
        isTegra: isTegra,
        isLowRam: isLowRam,
        isTV: isTV,
        forceHardware: s.forceHwDecode, // fix505: advanced override
      );
    } else if (s.hwDecode && Platform.isIOS) {
      return 'videotoolbox';
    }
    return 'no';
  }

  /// finding 18: switch hwdec at runtime WITHOUT re-opening the stream. Used
  /// when returning from PiP after an in-PiP reconnect forced software decode
  /// (fix414) left playback permanently on `hwdec=no` — which is a black frame
  /// on Tegra full-screen. mpv accepts a runtime hwdec property change; on:true
  /// restores the full-screen routed mode, on:false forces software.
  Future<void> setHardwareDecode(bool on) async {
    if (_disposed || _player.platform is! mk.NativePlayer) return;
    final np = _player.platform as mk.NativePlayer;
    final mode = on ? await _routedFullscreenHwdec() : 'no';
    await np.setProperty('hwdec', mode);
    AppLog.info('MpvEngine: setHardwareDecode($on) hwdec=$mode'
        ' eid=${identityHashCode(this)} channel="${channel.name}"');
  }

  /// finding 19: upgrade an adopted (promoted mini-player) engine to
  /// full-screen configuration WITHOUT re-opening the stream, so the seamless
  /// handoff is preserved. Flips the internal previewMode/dvrEligible state so
  /// subsequent reconnects also use full-screen routing, then applies the
  /// runtime-settable full-screen live properties (buffer/demuxer cap + routed
  /// hwdec). DVR only genuinely activates if the stream supports it, but the
  /// eligibility gate is now open.
  Future<void> promoteToFullScreen({required bool dvrEligible}) async {
    // Flip internal state first so any later reapplyOptions/reconnect uses the
    // full-screen branches.
    previewMode = false;
    this.dvrEligible = dvrEligible;
    if (_disposed || _player.platform is! mk.NativePlayer) return;
    final np = _player.platform as mk.NativePlayer;
    final s = settings;
    // Full-screen live demuxer cap (was the tiny mini-player value while in
    // preview mode). Mirrors the live branch in [_applyMpvOptions].
    await np.setProperty('demuxer-max-bytes', '${s.liveDemuxerMaxMB}MiB');
    // NOTE: bufferSize is a construction-time PlayerConfiguration value and is
    // not runtime-settable via a single property; the runtime demuxer cap above
    // is what actually governs buffering depth for a live stream, so raising it
    // to the full-screen live value is the effective buffer upgrade. Left the
    // back-buffer untouched (DVR manages it when it activates).
    // Route hwdec to the full-screen mode for this device.
    final hwdec = await _routedFullscreenHwdec();
    await np.setProperty('hwdec', hwdec);
    AppLog.info('MpvEngine: promoteToFullScreen(dvrEligible=$dvrEligible)'
        ' demuxerMaxMB=${s.liveDemuxerMaxMB} hwdec=$hwdec'
        ' eid=${identityHashCode(this)} channel="${channel.name}"');
    // fix735 (review): the adopt/promote path never calls open(), so start the
    // A/V-desync watchdog here too — else a mini→full-screen promoted live
    // stream would have no drift protection until its first reconnect.
    _startAvsyncWatchdog();
  }

  @override
  Widget buildVideoView(BuildContext context, {bool suppressControls = false}) {
    return mkvideo.Video(
      key: _videoKey,
      controller: _controller,
      // fix404: BoxFit routes the texture through media_kit's FittedBox.
      // contain = letterbox (fit), fill = stretch (stretch), cover = crop.
      // The Player toggles this via [setZoomMode].
      fit: _zoomFit,
      // fix580: NoVideoControls (== null) renders no built-in controls layer —
      // the app draws its own focusable overlay on TV+live (Mode B).
      controls:
          suppressControls ? mkvideo.NoVideoControls : mkvideo.AdaptiveVideoControls,
    );
  }

  @override
  Future<void> open({
    required String url,
    Duration? startPosition,
    Map<String, String>? headers,
    bool isLive = false, // fix339 / finding 102: suppress completed on live
  }) async {
    _isLive = isLive; // finding 102
    AppLog.info(
      'MpvEngine: open()'
      ' url="$url"'
      ' previewMode=$previewMode'
      ' startPosition=${startPosition == null ? '<live>' : '${startPosition.inSeconds}s'}',
    );
    // Options must be applied via reapplyOptions() BEFORE calling open().
    // Calling _applyMpvOptions() here would set mpv properties on the
    // still-active previous stream, triggering a demuxer reset and seek
    // probe on non-seekable MPEG-TS livestreams → "Cannot seek in this stream."
    // fix363/LOW-1: removed the Media.extras={'force-seekable':'no'} map —
    // media_kit 1.2.6 does not forward Media.extras to libmpv, so it was a
    // no-op. force-seekable is set authoritatively in _applyMpvOptions (live
    // branch: 'no' normally, 'yes' under DVR), which is what actually takes.
    // fix337: force controller creation NOW, one engine at a time, and give
    // its platform init a head start before opening the stream. See
    // _textureInitChain. Holding the lock briefly (max 1.5s) prevents the
    // concurrent-create race; the longer no-texture check runs un-locked
    // below.
    final prevInit = _textureInitChain;
    final initDone = Completer<void>();
    _textureInitChain = initDone.future;
    try {
      await prevInit;
      final c = _controller; // forces lazy creation, serialized
      await _waitForTextureId(c, const Duration(milliseconds: 1500));
    } finally {
      initDone.complete();
    }

    // fix699: the locked 1.5s wait is often too short — the platform texture
    // typically attaches ~2–2.7s in. Opening with a still-null surface makes
    // mediacodec bind a NULL surface; when the texture then arrives mpv does a
    // vo=null→vo=gpu switch that forces a full mediacodec reconfigure + ~2s
    // content replay (a big chunk of the observed ~7s first-open on a slow 1080p
    // source). Wait up to ~1.5s MORE for the texture so open() binds the real
    // surface on the FIRST init. This runs UN-LOCKED (initDone already completed,
    // so it never stalls a concurrent engine create), completes early the instant
    // the texture attaches, and is bounded — if the controller is genuinely slow
    // (fix352: ~25% attach >4s) it just falls through to today's null-surface
    // path (no regression). `_controller` is `late final` → same cached instance.
    if (!previewMode) {
      await _waitForTextureId(_controller, const Duration(milliseconds: 1500));
    }

    await _player.open(
      mk.Media(
        url,
        start: startPosition,
        httpHeaders: headers,
      ),
    );
    AppLog.info('MpvEngine: open() command sent channel="${channel.name}"');
    // fix396: capture libmpv's actual decode/display state for the
    // black-screen investigation. Once right after the open command (initial
    // negotiation) and once at +3s (frames should be flowing by then — if
    // decoded=WxH is non-zero but the screen is black, the failure is the
    // render/texture path, not decode). Full-screen engine only; best-effort.
    if (!previewMode) {
      unawaited(logDecodeState('post-open'));
      _observeFirstFrame();
      Future.delayed(const Duration(seconds: 3), () {
        if (!_disposed) unawaited(logDecodeState('+3s'));
      });
      if (settings.debugLogging) _startDiagHeartbeat();
      _startAvsyncWatchdog(); // fix735 (live-only; self-gates)
    }
    // fix130: do NOT call media_kit enterFullscreen() — it pushes a hidden
    // second route onto the root navigator (a full Video on this controller)
    // that the app swap pop+push does not account for, causing a route desync
    // and orphaned Video black layer. App drives fullscreen via
    // _enterSystemFullscreen() (handlesOwnFullscreen=false path).

    // fix338: don't fire the texture check if this engine already emitted an
    // error (e.g. a provider open-failure already restarting the cell) — that
    // caused a double restart on the same cell (provider-fail + texture-fail).
    // fix352: late-attach grace. S24 logs (2026-06-12) showed ~25% of solo
    // controller creations register their platform texture LATE (>4s) while
    // decode and audio run fine — and the old 4s hard fail then interrupted a
    // healthy stream with a reconnect that did nothing except wait out the
    // registration (the same controller attached on its own moments later).
    // New behaviour: listen for the id; log attach latency whenever it lands;
    // WARN at 4s but keep waiting; only emit the restart error if the texture
    // is still missing at 8s. Re-opens on an already-attached controller skip
    // all of this.
    if (_controller.id.value == null && !_disposed) {
      final attachSw = Stopwatch()..start();
      void Function()? unlisten;
      void onAttach() {
        if (_controller.id.value == null) return;
        AppLog.info('MpvEngine: texture attached'
            ' latency=${attachSw.elapsedMilliseconds}ms'
            ' channel="${channel.name}" previewMode=$previewMode');
        unlisten?.call();
      }
      unlisten = () {
        unlisten = null;
        try {
          _controller.id.removeListener(onAttach);
        } catch (_) {
          // Controller may already be disposed with the engine — fine.
        }
      };
      _controller.id.addListener(onAttach);
      Future.delayed(const Duration(seconds: 4), () {
        if (_disposed || _emittedError) return;
        if (_controller.id.value == null) {
          AppLog.warn('MpvEngine: texture not attached 4s after open —'
              ' extending grace to 8s (decode may be running) (fix352)'
              ' channel="${channel.name}" previewMode=$previewMode');
        }
      });
      Future.delayed(const Duration(seconds: 8), () {
        unlisten?.call();
        if (_disposed || _emittedError) return;
        if (_controller.id.value == null) {
          AppLog.warn('MpvEngine: TEXTURE-ATTACH-FAILED'
              ' — no texture 8s after open (decode may be running);'
              ' emitting error to trigger restart'
              ' channel="${channel.name}" previewMode=$previewMode');
          _emitError('video texture failed to attach');
        }
      });
    }
  }

  /// fix338: single error sink that records that an error was emitted (so the
  /// texture-attach check can self-gate) and forwards to the stream.
  void _emitError(String e) {
    _emittedError = true;
    if (!_errorCtrl.isClosed) _errorCtrl.add(e);
  }

  /// fix337: resolve when [c]'s platform texture id becomes non-null, or
  /// after [timeout] — whichever is first. Never throws.
  Future<void> _waitForTextureId(
      mkvideo.VideoController c, Duration timeout) async {
    if (c.id.value != null) return;
    final completer = Completer<void>();
    void onChange() {
      if (c.id.value != null && !completer.isCompleted) completer.complete();
    }

    c.id.addListener(onChange);
    try {
      await completer.future.timeout(timeout, onTimeout: () {});
    } finally {
      c.id.removeListener(onChange);
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    // media_kit uses a 0–100 scale
    await _player.setVolume(volume * 100);
  }

  // fix727 (mock §4.6): playback-speed passthrough. media_kit's setRate maps to
  // mpv's `speed` property; we cache the last value so the OSD can show the
  // active preset. Chrome-only addition — no engine/reconnect logic touched.
  double _rate = 1.0;
  @override
  double get playbackRate => _rate;
  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
    await _player.setRate(rate);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      if (AppLog.enabled) {
        AppLog.info(
          'MpvEngine: dispose() called twice — ignoring'
          ' channel="${channel.name}"',
        );
      }
      return;
    }
    _disposed = true;
    _dvrGuard?.cancel(); // fix357
    _diagHeartbeat?.cancel(); // fix396
    _avsyncWatchdog?.cancel(); // fix735
    if (_dvrActive) unawaited(_cleanupDvrDir()); // fix357
    AppLog.info(
      'MpvEngine: dispose() eid=${identityHashCode(this)}'
      ' channel="${channel.name}"'
      ' previewMode=$previewMode',
    );

    // fix188: mute then stop BEFORE teardown so libmpv audio does not outlive
    // the async native dispose (~5s of lingering audio on multi-view exit,
    // onn 4K Plus). setVolume(0) silences immediately; stop() halts decode and
    // unloads the current media before the controller close + Player.dispose()
    // below. Both are guarded — a teardown race must never throw out of
    // dispose(). Player.setVolume(double) and Player.stop() are verified on
    // media_kit 1.2.6. No volume restore: this instance is being destroyed.
    try {
      await _player.setVolume(0);
      await _player.stop();
    } catch (e) {
      AppLog.info('MpvEngine: dispose() mute/stop skipped ($e)'
          ' eid=${identityHashCode(this)}');
    }

    // fix130: no manual exitFullscreen()/vid=no here. media_kit releases
    // the texture via Player.dispose() release[] callbacks
    // (VideoOutputManager.Dispose, keyed by player handle — confirmed in
    // media_kit source). The fix126 pokes fought media_kit's internal
    // --vid/--vo/--wid surface state machine. Just cancel mirror-stream
    // subs and dispose the player.
    for (final s in _subs) {
      await s.cancel();
    }
    await _bufferingCtrl.close();
    await _completedCtrl.close();
    await _errorCtrl.close();
    await _positionCtrl.close();
    await _streamInfoCtrl.close();
    await _firstFrameCtrl.close(); // fix732
    await _desyncCtrl.close(); // fix735
    await _player.dispose();
    AppLog.info('MpvEngine: dispose() player disposed (surface released by media_kit)'
        ' eid=${identityHashCode(this)}');
  }


  @override
  Stream<bool> get bufferingStream => _bufferingCtrl.stream;
  @override
  Stream<bool> get completedStream => _completedCtrl.stream;
  @override
  Stream<String> get errorStream => _errorCtrl.stream;
  @override
  Stream<Duration> get positionStream => _positionCtrl.stream;
  @override
  Stream<String> get streamInfoStream => _streamInfoCtrl.stream;

  @override
  Stream<void> get firstFrameStream => _firstFrameCtrl.stream; // fix732

  /// fix735: emits the avsync value (seconds) when a live full-screen stream has
  /// been A/V-desynced beyond threshold for a sustained window. The player
  /// reopens to resync (a fresh open resets avsync to ~0).
  @override
  Stream<double> get desyncStream => _desyncCtrl.stream;

  @override
  String? get lastStreamInfo => _lastStreamInfo;

  @override
  Duration get position => _player.state.position;

  // fix336: transport surface for interface parity.
  @override
  Duration get duration => _player.state.duration;

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  bool get isPlaying => _player.state.playing;

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> seek(Duration position) async {
    // finding 98: gate the duration<=0 early-return on !_dvrActive so live-DVR
    // transport seeks reach mpv (force-seekable=yes lets it seek the disk-backed
    // demuxer cache without a reported duration). VOD/non-DVR-live still skip.
    if (!_dvrActive && _player.state.duration <= Duration.zero) return;
    await _player.seek(position);
  }


  @override
  bool get supportsTrackSelection => true;

  @override
  List<TrackInfo> get subtitleTracks => _player.state.tracks.subtitle
      .asMap()
      .entries
      .map(
        (e) => TrackInfo(
          index: e.key,
          label: e.value.language != null
              ? '${e.value.language} - ${e.value.id}'
              : e.value.id,
        ),
      )
      .toList();

  @override
  List<TrackInfo> get audioTracks => _player.state.tracks.audio
      .asMap()
      .entries
      .map(
        (e) => TrackInfo(
          index: e.key,
          label: e.value.title ?? e.value.language ?? e.value.id,
        ),
      )
      .toList();

  @override
  Future<void> setSubtitleTrack(int index) async {
    _player.setSubtitleTrack(_player.state.tracks.subtitle[index]);
  }

  @override
  Future<void> setAudioTrack(int index) async {
    _player.setAudioTrack(_player.state.tracks.audio[index]);
  }


  /// fix130 (130.4): surface diagnostics using the typed API.
  /// _controller.id.value = platform texture id (null = not attached).
  /// _controller.rect.value = Rect of the rendered area (null = invisible).
  void logSurface(String where) {
    try {
      final tex = _controller.id.value;
      final r = _controller.rect.value;
      AppLog.info('MpvEngine: SURFACE[$where] eid=${identityHashCode(this)}'
          ' textureId=$tex'
          ' rect=${r == null ? 'null' : '${r.width.toInt()}x${r.height.toInt()}'}'
          ' playerWH=${_player.state.width}x${_player.state.height}'
          ' previewMode=$previewMode disposed=$_disposed');
    } catch (e) {
      AppLog.warn('MpvEngine: SURFACE[$where] log failed — $e');
    }
  }

  /// fix396: read libmpv's ACTUAL decode/display state and log one line. This
  /// is the key signal for the Shield black-screen: it shows what hardware
  /// decoder libmpv really selected (`hwdec-current` — vs what we *requested*
  /// via `hwdec`), whether frames are actually being decoded (`width/height`)
  /// and sized for display (`dwidth/dheight`), the active video output
  /// (`current-vo`), and frame/drop rates. Interpretation:
  ///   - hwdec-current empty/"no" while we set mediacodec-copy → HW decode did
  ///     NOT engage (decode path issue).
  ///   - decoded=0x0 → nothing is decoding at all (demuxer/codec/network).
  ///   - decoded=1920x1080 but the screen is black → decode is FINE; the
  ///     failure is the render/texture/VO path (media_kit ↔ Flutter texture).
  /// All reads are best-effort (getProperty throws if disposed/uninitialised).
  Future<void> logDecodeState(String tag) async {
    if (_disposed || _player.platform is! mk.NativePlayer) return;
    final np = _player.platform as mk.NativePlayer;
    Future<String> g(String p) async {
      try {
        return await np.getProperty(p);
      } catch (_) {
        return '?';
      }
    }
    try {
      final results = await Future.wait([
        g('hwdec-current'), // 0 what HW decoder actually engaged
        g('video-codec'), //   1 e.g. "h264 (High)"
        g('video-format'), //  2 e.g. "h264"
        g('width'), //         3 decoded frame width
        g('height'), //        4 decoded frame height
        g('dwidth'), //        5 display width
        g('dheight'), //       6 display height
        g('current-vo'), //    7 active video output
        g('estimated-vf-fps'),// 8 rendered fps
        g('frame-drop-count'), // 9 VO drops
        g('decoder-frame-drop-count'), // 10 decoder drops
        g('hwdec'), //         11 what we requested
      ]);
      // fix403: annotate the raw hwdec-current with a settled/transient label
      // so a first-frame "no" (mpv decodes the first frame in software while
      // mediacodec spins up) cannot be misread as a permanent software fallback.
      final decodeState = hwdecDecodeState(
          tag: tag, req: results[11], current: results[0]);
      AppLog.info('MpvEngine: DECODE[$tag] eid=${identityHashCode(this)}'
          ' hwdec-req="${results[11]}" hwdec-current="${results[0]}"'
          ' decodeState="$decodeState"'
          ' codec="${results[1]}" fmt="${results[2]}"'
          ' decoded=${results[3]}x${results[4]} display=${results[5]}x${results[6]}'
          ' vo="${results[7]}" vfFps="${results[8]}"'
          ' voDrop="${results[9]}" decDrop="${results[10]}"'
          ' channel="${channel.name}" previewMode=$previewMode');
    } catch (e) {
      AppLog.warn('MpvEngine: DECODE[$tag] read failed — $e');
    }
  }

  /// fix564: read a live snapshot of playback stats for the debug overlay
  /// (top-right, single-cell full-screen only) and the report log. Pure read —
  /// every getProperty is guarded; returns {} if the platform player isn't a
  /// ready NativePlayer. Keys are raw libmpv property names so the caller can
  /// format/colour them. `estimated-vf-fps` falling below `container-fps`, a
  /// climbing `decoder-frame-drop-count`, or a large `avsync` are the headline
  /// stutter signals; `hwdec-current` empty/"no" means software decode.
  Future<Map<String, String>> readPlaybackStats() async {
    if (_disposed || _player.platform is! mk.NativePlayer) return const {};
    final np = _player.platform as mk.NativePlayer;
    Future<String> g(String p) async {
      try {
        return await np.getProperty(p);
      } catch (_) {
        return '';
      }
    }

    const keys = <String>[
      'hwdec', // requested
      'hwdec-current', // actually engaged ('' / 'no' = software)
      'video-codec',
      'estimated-vf-fps', // rendered fps
      'container-fps', // source fps
      'frame-drop-count', // VO drops (late frames)
      'decoder-frame-drop-count', // decoder can't keep up — the stutter signal
      'avsync', // A/V desync, seconds
      'video-bitrate', // bits/s
      'demuxer-cache-duration', // seconds buffered ahead
      'paused-for-cache', // 'yes' while rebuffering
      'width',
      'height',
      'framedrop', // active frame-drop mode (no/vo/decoder) — "drop video"
      'video-sync', // active A/V sync mode (audio/display-*) — "sync audio"
    ];
    try {
      final values = await Future.wait(keys.map(g));
      return {for (var i = 0; i < keys.length; i++) keys[i]: values[i]};
    } catch (_) {
      return const {};
    }
  }

  /// fix396: start the decode heartbeat. Cheap (cached `_player.state`), every
  /// 4 s, full-screen + debug only. Flags a stalled playhead (position not
  /// advancing) and missing frame size — the exact pattern the Shield log
  /// showed as 12 s of silence. Self-cancels on dispose.
  void _startDiagHeartbeat() {
    _diagHeartbeat?.cancel();
    _lastHeartbeatPos = Duration.zero;
    _diagHeartbeat = Timer.periodic(const Duration(seconds: 4), (t) {
      if (_disposed) {
        t.cancel();
        return;
      }
      try {
        final st = _player.state;
        final advanced = st.position != _lastHeartbeatPos;
        _lastHeartbeatPos = st.position;
        final stalled = !advanced && st.playing && !st.buffering;
        final line = 'MpvEngine: HEARTBEAT pos=${st.position.inMilliseconds}ms'
            ' advanced=$advanced frame=${st.width}x${st.height}'
            ' playing=${st.playing} buffering=${st.buffering}'
            ' dvrActive=$_dvrActive channel="${channel.name}"';
        // A playing, non-buffering stream whose position is frozen is the
        // black-screen-with-audio stall — surface it as a warning.
        if (stalled) {
          AppLog.warn('$line STALLED(pos frozen while playing)');
        } else {
          AppLog.info(line);
        }
      } catch (_) {
        // state read should never throw, but never let the timer crash.
      }
    });
  }

  /// fix735: A/V-desync watchdog (live full-screen only). Every 6s, on a
  /// PLAYING, ADVANCING, non-buffering, not-paused-for-cache stream, reads
  /// `avsync`; if |avsync| exceeds threshold for [_desyncSustainTicks]
  /// consecutive ticks it signals [desyncStream] (the player reopens to
  /// resync). Frozen/buffering streams are the buffering watchdog's job — the
  /// advancing+playing gate is exactly what distinguishes a desynced-BUT-live
  /// stream (invisible to every existing watchdog) from a stall.
  void _startAvsyncWatchdog() {
    if (channel.mediaType != MediaType.livestream) return; // live only
    _avsyncWatchdog?.cancel();
    _desyncTicks = 0;
    _lastAvsyncPos = Duration.zero;
    _avsyncWatchdog = Timer.periodic(const Duration(seconds: 6), (t) async {
      if (_disposed) {
        t.cancel();
        return;
      }
      if (_player.platform is! mk.NativePlayer) return;
      try {
        final st = _player.state;
        final advancing = st.position > _lastAvsyncPos;
        _lastAvsyncPos = st.position;
        if (!st.playing || st.buffering || !advancing) {
          _desyncTicks = 0;
          return;
        }
        final np = _player.platform as mk.NativePlayer;
        if (await np.getProperty('paused-for-cache') == 'yes') {
          _desyncTicks = 0;
          return;
        }
        final avs = double.tryParse(await np.getProperty('avsync')) ?? 0.0;
        if (avs.abs() > _desyncThresholdSecs) {
          _desyncTicks++;
          if (_desyncTicks >= _desyncSustainTicks) {
            _desyncTicks = 0;
            AppLog.warn('MpvEngine: A/V desync ${avs.toStringAsFixed(1)}s '
                'sustained — signalling resync channel="${channel.name}"');
            if (!_desyncCtrl.isClosed) _desyncCtrl.add(avs);
          }
        } else {
          _desyncTicks = 0;
        }
      } catch (_) {
        // never let the watchdog crash playback
      }
    });
  }

  /// fix515: format mpv's `dheight` + `video-codec` into a short, friendly
  /// label for the single-cell full-screen top bar (e.g. "720p H.264").
  /// Returns null when [dheight] isn't a real decoded size yet (0/empty/'?',
  /// or unparsable) — the caller should leave the bar blank rather than show
  /// a "0x0" placeholder while the first frame is still arriving (the same
  /// guard [_observeFirstFrame] already uses for `dwidth`).
  ///
  /// Height-tier mapping is deliberately coarse (matches common marketing
  /// labels) rather than literal: 2160→"4K", 1080→"1080p", 720→"720p", else
  /// the raw "WxH". This also surfaces provider mislabeling for free — a
  /// channel named "4K" that's actually delivering 720p shows "720p" here.
  /// [rawCodec] is mpv's `video-codec` string (e.g. "h264 (High)"); only the
  /// codec name before any parenthetical is used and mapped to a friendly
  /// name (h264→H.264, hevc→H.265), falling back to an uppercased raw token
  /// for anything else mpv reports.
  static String? formatStreamInfo(String dheight, String rawCodec) {
    final h = int.tryParse(dheight);
    if (h == null || h <= 0) return null;
    final String resTier;
    if (h >= 2000) {
      resTier = '4K';
    } else if (h >= 1000) {
      resTier = '1080p';
    } else if (h >= 700) {
      resTier = '720p';
    } else {
      resTier = '${h}p';
    }
    final codecToken = rawCodec.split('(').first.trim().toLowerCase();
    final String codecLabel;
    switch (codecToken) {
      case 'h264':
        codecLabel = 'H.264';
        break;
      case 'hevc':
      case 'h265':
        codecLabel = 'H.265';
        break;
      case '':
      case '?':
        return resTier; // codec unknown — still show the resolution alone.
      default:
        codecLabel = codecToken.toUpperCase();
    }
    return '$resTier $codecLabel';
  }

  /// fix396: one-shot — observe libmpv's `dwidth` so the log records the exact
  /// moment the first decoded frame is sized (0 → WxH). If audio plays but
  /// this never fires, decode is stalled; if it fires with a real size yet
  /// the screen stays black, the render/texture path is at fault.
  /// fix515: also samples `dheight` + `video-codec` at this same moment to
  /// publish [streamInfoStream] for the single-cell top bar — piggybacking
  /// on this existing one-shot hook rather than adding a second observer.
  /// Best-effort throughout.
  bool _observedFirstFrame = false;
  void _observeFirstFrame() {
    if (_observedFirstFrame || _disposed) return;
    if (_player.platform is! mk.NativePlayer) return;
    _observedFirstFrame = true;
    final np = _player.platform as mk.NativePlayer;
    final sw = Stopwatch()..start();
    np.observeProperty('dwidth', (value) async {
      if (_disposed) return;
      AppLog.info('MpvEngine: FIRST-FRAME dwidth=$value'
          ' at=${sw.elapsedMilliseconds}ms channel="${channel.name}"');
      // Pair it with a full decode-state snapshot the first time a real size
      // lands, so we capture hwdec-current + vo at the moment video appears.
      if (value != '0' && value.isNotEmpty && value != '?') {
        // fix732: real first frame landed — let the player clear the zap shutter
        if (!_firstFrameCtrl.isClosed) _firstFrameCtrl.add(null);
        unawaited(logDecodeState('first-frame'));
        // fix515: sample dheight + codec at this same verified-real moment
        // and publish a friendly label for the top bar. Best-effort: a
        // property-read failure here must never affect playback, so any
        // error just leaves the bar blank (no event emitted).
        unawaited(_publishStreamInfo());
      }
    }).catchError((Object _) {});
  }

  /// fix515: read `dheight` + `video-codec` and emit a formatted label on
  /// [streamInfoStream] for the single-cell full-screen top bar. Called once
  /// from [_observeFirstFrame] after `dwidth` confirms a real decoded frame
  /// has landed (guards against sampling mid-glitch garbage on a stream with
  /// decode errors).
  /// fix516: fix515 shipped with NO logging in this function — a real device
  /// report of the label never appearing left no way to tell whether this
  /// ran, what it read, or where it stopped, from the log alone. Every
  /// branch now logs, so the next report is diagnosable without guessing.
  Future<void> _publishStreamInfo() async {
    if (_disposed || _player.platform is! mk.NativePlayer) {
      AppLog.info('MpvEngine: STREAMINFO skip — disposed=$_disposed'
          ' nativePlayer=${_player.platform is mk.NativePlayer}'
          ' channel="${channel.name}"');
      return;
    }
    final np = _player.platform as mk.NativePlayer;
    try {
      final dheight = await np.getProperty('dheight');
      final codec = await np.getProperty('video-codec');
      if (_disposed) {
        AppLog.info('MpvEngine: STREAMINFO disposed mid-read'
            ' channel="${channel.name}"');
        return;
      }
      final label = formatStreamInfo(dheight, codec);
      AppLog.info('MpvEngine: STREAMINFO dheight="$dheight" codec="$codec"'
          ' label=${label == null ? "null" : '"$label"'}'
          ' channel="${channel.name}"');
      if (label != null && !_streamInfoCtrl.isClosed) {
        _lastStreamInfo = label; // fix522: latch before broadcast
        _streamInfoCtrl.add(label);
        AppLog.info('MpvEngine: STREAMINFO emitted "$label"'
            ' hasListener=${_streamInfoCtrl.hasListener}'
            ' channel="${channel.name}"');
      } else if (label != null) {
        AppLog.info('MpvEngine: STREAMINFO NOT emitted — controller closed'
            ' channel="${channel.name}"');
      }
    } catch (e) {
      AppLog.warn('MpvEngine: STREAMINFO read/emit failed — $e'
          ' channel="${channel.name}"');
    }
  }

  // fix130: false — app drives fullscreen via _enterSystemFullscreen() (immersive
  // + landscape orientation). media_kit's
  // enterFullscreen() pushes a hidden second root-navigator route with a second
  // Video on this controller; that orphaned route was the black-screen root cause.
  @override
  bool get handlesOwnFullscreen => false;

  @override
  Future<void> enterFullscreen() async {}

  @override
  Future<void> exitFullscreen() async {}

  @override
  bool get isFullscreen => false;


  int? get videoWidth => _player.state.width;
  int? get videoHeight => _player.state.height;

  // fix404: current BoxFit for the Video widget. Default BoxFit.contain
  // (the media_kit default) preserves the pre-fix404 two-state toggle
  // (where `fill=false` → letterbox). The Player state drives this via
  // [setZoomMode]; [buildVideoView] reads it on each rebuild.
  BoxFit _zoomFit = BoxFit.contain;
  BoxFit get zoomFit => _zoomFit;

  void updateAspectRatio(double ratio) {
    // fix404: kept for backwards compatibility (Player previously called
    // this to flip between videoAspect / deviceAspect). The fix404 toggle
    // uses [setZoomMode] directly; aspect-ratio override is no longer
    // needed because BoxFit on the Video widget fully controls render.
    _videoKey.currentState?.update(aspectRatio: ratio);
  }

  /// fix404: set the render fit for the Video widget. Rebuilds the
  /// surface so the new BoxFit takes effect on the next frame.
  void setZoomMode(BoxFit fit) {
    if (_zoomFit == fit) return;
    _zoomFit = fit;
    _videoKey.currentState?.update(fit: fit);
  }


  Future<void> _applyMpvOptions({
    required String url,
    bool ignoreSsl = false,
    bool forceSoftwareDecode = false, // fix414: reconnect while minimized/PiP
  }) async {
    if (_player.platform is! mk.NativePlayer) return;
    final np = _player.platform as mk.NativePlayer;
    final s = settings;

    await np.setProperty('cache', 'yes');
    // fix394: network-timeout now honours Settings.devNetworkTimeoutSecs
    // (default 30, matching libmpv upstream). Per-source ignoreSsl still
    // wins for tls-verify (see the block below).
    await np.setProperty(
        'network-timeout', s.devNetworkTimeoutSecs.toString());

    // fix361: downmix multichannel audio to stereo when enabled (default).
    // Repeated 'Error decoding audio' on E-AC3 5.1 feeds (onn 4K / YES
    // Network, 2026-06-13) clears when the audio is downmixed and decoded in
    // software rather than pushed multichannel into a path the device can't
    // render. NOTE: the cold-eyes suggestion of audio-spdif passthrough was
    // NOT used — it requires a capable AV receiver downstream and would
    // SILENCE audio on a plain box->TV HDMI path. Downmix-to-stereo is the
    // safe direction (works on every output) and is a user-toggle, default ON.
    if (s.audioDownmixStereo) {
      await np.setProperty('audio-channels', 'stereo');
      await np.setProperty('ad-lavc-downmix', 'yes');
    }

    // fix398: tls-verify honours Settings.devTlsVerify, which now defaults
    // to false (off) — IPTV providers commonly serve HTTPS with self-signed
    // certs. The per-channel `ignoreSsl` (from import headers) STILL wins and
    // forces tls-verify=no unconditionally — do not invert this.
    if (ignoreSsl) {
      await np.setProperty('tls-verify', 'no');
    } else {
      await np.setProperty('tls-verify', s.devTlsVerify ? 'yes' : 'no');
    }

    if (url.contains('.m3u8')) {
      await np.setProperty('hls-bitrate', s.lowLatency ? 'min' : 'max');
    }

    // Preview mode (overlay + multi-view cells): use HARDWARE decode but in
    // copy mode. fix108: pure software decode (hwdec=no) stalled/failed
    // silently on these MPEG-TS/H.264 streams — the overlay opened but never
    // rendered (black + spinner), while the same URL played fine full-screen.
    // mediacodec-copy decodes in hardware and copies frames to CPU memory,
    // bypassing the SurfaceTexture binding that causes contention when
    // multiple players share the decoder pool. This is the same mode used for
    // Android TV (line below) and is safe for concurrent preview windows.
    if (forceSoftwareDecode) {
      // fix414: a reconnect firing while the app is minimized to PiP cannot
      // re-configure the MediaCodec hardware decoder — Android denies codec
      // re-init without a foreground surface, so the re-open hangs in
      // "initializing" (pos=0, frame=null) and the watchdog eventually gives up
      // and pops to the menu (sms938u 2026-06-21 log; the same stream
      // reconnected fine full-screen seconds earlier). Software decode
      // (libavcodec) needs no MediaCodec/foreground and re-inits fine in PiP.
      // The caller passes forceSoftwareDecode=_inPipMode on reconnect.
      await np.setProperty('hwdec', 'no');
      AppLog.info('Player: hwdec=no (fix414: forced — reconnect while minimized)'
          ' channel="${channel.name}"');
    } else if (previewMode && Platform.isAndroid && s.hwDecode) {
      // fix314: Tegra/Shield corrupts colour with concurrent mediacodec-copy
      // (2×2 grid → rainbow planes). The multiViewDecode setting controls this:
      //   auto         → software on Tegra/Shield, mediacodec-copy elsewhere
      //   hardwareCopy → force mediacodec-copy (pre-fix314 behaviour)
      //   software     → force CPU decode
      // fix361: 'auto' now also picks software decode on low-RAM TV boxes
      // (onn 4K Plus, ~1925MB / Amlogic). With 4 mediacodec-copy pipelines the
      // SoC times out allocating video textures (TEXTURE-ATTACH-FAILED x3 in
      // the 2026-06-13 onn 2×2 log); software decode for preview tiles avoids
      // the shared GPU texture contention. Phones/large-RAM TVs keep
      // mediacodec-copy.
      final wantSoftware = switch (s.multiViewDecode) {
        MultiViewDecode.software => true,
        MultiViewDecode.hardwareCopy => false,
        MultiViewDecode.auto =>
          await DeviceDetector.isTegra() || await DeviceDetector.isLowRamDevice(),
      };
      if (wantSoftware) {
        await np.setProperty('hwdec', 'no');
        AppLog.info('Player: hwdec=no (preview, multiViewDecode='
            '${s.multiViewDecode.name}) channel="${channel.name}"');
      } else {
        await np.setProperty('hwdec', 'mediacodec-copy');
        AppLog.info('Player: hwdec=mediacodec-copy (preview, multiViewDecode='
            '${s.multiViewDecode.name}) channel="${channel.name}"');
      }
    } else if (previewMode && Platform.isIOS && s.hwDecode) {
      // videotoolbox supports concurrent decode sessions on iOS.
      await np.setProperty('hwdec', 'videotoolbox');
      AppLog.info('Player: hwdec=videotoolbox (preview) channel="${channel.name}"');
    } else if (previewMode) {
      // hwDecode disabled by user, or unsupported platform — fall back to CPU.
      await np.setProperty('hwdec', 'no');
      AppLog.info('Player: hwdec=no (preview fallback) channel="${channel.name}"');
    } else if (s.hwDecode && Platform.isAndroid) {
      // fix395: full-screen Android decode routing. See androidFullscreenHwdec
      // (lib/player/hwdec_routing.dart) for the per-device rationale.
      //
      // fix164 had `isTV ? 'no' : 'mediacodec'` — it forced SOFTWARE decode on
      // EVERY Android TV, but the intent (and the fix164 comment) was only the
      // low-RAM onn 4K Plus. On capable TVs (Shield/Tegra X1) software decode
      // starves the video pipeline: audio plays, no frames render, black screen
      // (free4me_log-shieldandroidtv-20260617). The working reference app uses
      // ExoPlayer = hardware MediaCodec, which is exactly mediacodec-copy here.
      // Tegra is matched first so RAM misdetection can't force it to software.
      final isTV = await DeviceDetector.isTV();
      final isTegra = await DeviceDetector.isTegra();
      final isLowRam = await DeviceDetector.isLowRamDevice();
      var hwdecMode = androidFullscreenHwdec(
        isTegra: isTegra,
        isLowRam: isLowRam,
        isTV: isTV,
        forceHardware: s.forceHwDecode, // fix505: advanced override
      );
      // fix743: persisted probe blocklist — this URL recently failed the hw
      // probe on this app version and mpv's software fallback was confirmed
      // by a decoded frame (fix742 latch). Skip the doomed probe entirely so
      // reconnects and later tunes of the channel start faster.
      // forceHwDecode bypasses the blocklist (manual escape hatch); TTL and
      // app-version checks live in Sql.isHwdecBlocklisted.
      var blocklistHit = false;
      final chUrl = channel.url;
      if (hwdecMode != 'no' &&
          !s.forceHwDecode &&
          chUrl != null &&
          chUrl.isNotEmpty) {
        blocklistHit = await Sql.isHwdecBlocklisted(chUrl);
        if (blocklistHit) hwdecMode = 'no';
      }
      appliedHwdecMode = hwdecMode;
      await np.setProperty('hwdec', hwdecMode);
      AppLog.info('Player: hwdec=$hwdecMode isTV=$isTV isTegra=$isTegra '
          'isLowRam=$isLowRam forceHw=${s.forceHwDecode}'
          '${blocklistHit ? ' blocklist=hit (fix743)' : ''} (fix395/505)');
    } else if (s.hwDecode && Platform.isIOS) {
      appliedHwdecMode = 'videotoolbox'; // fix743
      await np.setProperty('hwdec', 'videotoolbox');
    } else {
      appliedHwdecMode = 'no'; // fix743
      await np.setProperty('hwdec', 'no');
    }

    if (channel.mediaType == MediaType.livestream) {
      // Declare stream non-seekable upfront. Without this, mpv probes
      // seekability by attempting a seek during demuxer init — MPEG-TS
      // livestreams reject it, surfacing "Cannot seek in this stream." as a
      // player error and triggering an unnecessary reconnect on every open.
      // (mpv even reports the fix itself: "You can force it with
      //  '--force-seekable=yes'." — the inverse, 'no', suppresses the probe.)
      // fix357: live DVR buffer (full-screen single view only). Records the
      // incoming stream to a disk-backed cache (stream-copy — the original
      // codec untouched; re-encoding on these devices is not feasible, so
      // bit-identical copy IS the most space-efficient viable option) and
      // makes the window seekable, so pause builds a cushion and brief
      // drops can play through it.
      final dvrBackMB = (dvrEligible &&
              !previewMode &&
              settings.dvrEnabled)
          ? await _computeDvrWindowMB()
          : 0;
      if (dvrBackMB > 0) {
        _dvrActive = true;
        await np.setProperty('force-seekable', 'yes');
        await np.setProperty('cache-on-disk', 'yes');
        // fix399: mpv renamed `cache-dir` to `demuxer-cache-dir` (the old
        // name logs a deprecation warning and is slated for removal).
        await np.setProperty('demuxer-cache-dir', _dvrDir!.path);
        AppLog.info('MpvEngine: DVR enabled — window=${dvrBackMB ~/ 60}min'
            ' (${dvrBackMB}MiB back buffer, dir=${_dvrDir!.path})');
      } else {
        // fix380: with force-seekable=no, the user's seek-bar interaction
        // (if it ever reaches mpv despite the property) produces a
        // "Cannot seek in this stream." error which the player side
        // suppresses — see lib/player.dart errorStream handler, where
        // the suppression log is now latched to fire once per open()
        // (during startup grace) instead of per-seek.
        await np.setProperty('force-seekable', 'no');
      }

      // Back buffer disabled for all live branches: MPEG-TS and most IPTV
      // streams reject seeks, which mpv surfaces as a fatal player error
      // ("Cannot seek in this stream.") causing an immediate reconnect loop.
      // VOD keeps its back buffer for normal reverse-seek support.
      if (s.lowLatency && dvrBackMB <= 0) {
        // Low latency only when DVR is NOT active — DVR needs the back buffer.
        await np.setProperty('profile', 'low-latency');
        await np.setProperty('demuxer-max-back-bytes', '0');
      } else {
        // fix370/MED-1: DVR active wins over low-latency. Previously
        // s.lowLatency zeroed demuxer-max-back-bytes while _dvrActive stayed
        // true, so the transport controls appeared but rewind/back-to-live had
        // no buffer to seek in. When DVR is on we keep its back buffer (and
        // skip the low-latency profile, which is fundamentally at odds with a
        // multi-minute disk buffer).
        if (s.lowLatency && dvrBackMB > 0) {
          AppLog.info('MpvEngine: low-latency suppressed — DVR buffer active');
        }
        await np.setProperty('cache-secs', s.liveCacheSecs.toString());
        // fix623: mini-player PiP uses the tiny cap; multi-view cells + full
        // player use the real livestream demuxer cap.
        final liveMB = (previewMode && !multiViewMode)
            ? s.miniDemuxerMaxMB
            : s.liveDemuxerMaxMB;
        await np.setProperty('demuxer-max-bytes', '${liveMB}MiB');
        await np.setProperty(
            'demuxer-max-back-bytes', dvrBackMB > 0 ? '${dvrBackMB}MiB' : '0');
        if (dvrBackMB > 0) _startDvrGuard(dvrBackMB);
      }
      // fix700: opt-in live pre-buffer (default OFF via livePrebufferSecs=0, so
      // the fix354 "live keeps the default behaviour" is unchanged unless the
      // user enables it). When on, mpv holds/refills to livePrebufferSecs of
      // cache before (re)starting live playback — converting the sub-second
      // rebuffer thrashing seen on an under-delivering or concurrently-recorded
      // feed (bug: A3000/Trex YES stutter + watch-while-recording contention)
      // into fewer, longer refills, at the cost of a small pause at the live
      // edge (hence default-off). Skipped under DVR (its buffer semantics differ).
      if (s.livePrebufferSecs > 0 && dvrBackMB <= 0) {
        // fix700: force cache-pause on — the live low-latency profile above sets
        // cache-pause=no, which would otherwise make the two properties below a
        // silent no-op when Low-latency is also enabled.
        await np.setProperty('cache-pause', 'yes');
        await np.setProperty('cache-pause-initial', 'yes');
        await np.setProperty('cache-pause-wait', s.livePrebufferSecs.toString());
      }
    } else {
      await np.setProperty('cache-secs', s.vodCacheSecs.toString());
      final vodMB = (previewMode && !multiViewMode)
          ? s.miniDemuxerMaxMB * 2
          : s.vodDemuxerMaxMB;
      await np.setProperty('demuxer-max-bytes', '${vodMB}MiB');
      await np.setProperty('demuxer-max-back-bytes', '64MiB');
      // fix354: VOD pre-buffer. Providers that deliver files at/below the
      // realtime bitrate (Dino /series/, S24 2026-06-12 log: stall/refill
      // every 2-5s forever) never let the cache get ahead with mpv's default
      // 1s resume threshold. cache-pause-initial holds playback until
      // cache-pause-wait seconds are buffered, and every underrun likewise
      // refills to that level before resuming — converting continuous
      // micro-stutter into one short startup pause plus rare, well-spaced
      // refills. VOD only; live keeps the default behaviour (a long
      // cache-pause-wait at the live edge would just freeze the picture).
      if (s.vodPrebufferSecs > 0) {
        await np.setProperty('cache-pause-initial', 'yes');
        await np.setProperty(
            'cache-pause-wait', s.vodPrebufferSecs.toString());
      }
    }

    // fix394: Developer / libmpv advanced tunables. Every field defaults
    // to libmpv's upstream value, so when the user hasn't touched the
    // Developer section this block is effectively a no-op. The sentinel
    // enums (`hwdec-image-format` defaultFmt, `audio-spdif` no) skip the
    // setProperty call entirely so libmpv keeps its own default.
    // (fix394 review: removed setProperty calls for demuxer-cache-wait,
    // demuxer-max-wait-keepalive, demuxer-backward-buffer-secs,
    // demuxer-dont-buffer-secs and target-colorspace — those property
    // names are either the wrong type or do not exist in libmpv.)
    await np.setProperty('demuxer-readahead-secs',
        s.devDemuxerReadaheadSecs.toString());
    await np.setProperty('video-sync', s.devVideoSync.value);
    await np.setProperty('video-sync-max-video-change',
        s.devVideoSyncMaxVideoChange.toString());
    await np.setProperty('tscale', s.devTscale.value);
    // fix571: low-RAM / weak-GPU Android (e.g. onn 4K Plus, software decode)
    // judders with libmpv's default framedrop=vo on high-fps streams — every
    // frame reaches the upload-bound VO, which drops 500–850/min (visible
    // stutter, confirmed by on-device sweep). framedrop=decoder sheds frames
    // before the upload stage and held 0 VO drops. Gate it to low-RAM so
    // capable devices keep mpv's safer upstream `vo`; an explicit `no`/`decoder`
    // still wins, and a `vo` setting on low-RAM is auto-upgraded to `decoder`.
    final lowRamFramedrop = Platform.isAndroid &&
        s.devFramedrop.value == 'vo' &&
        await DeviceDetector.isLowRamDevice();
    final framedropMode = lowRamFramedrop ? 'decoder' : s.devFramedrop.value;
    await np.setProperty('framedrop', framedropMode);
    await np.setProperty('interpolation', s.devInterpolation ? 'yes' : 'no');
    await np.setProperty('deband', s.devDeband ? 'yes' : 'no');
    // fix582 (#2): 60→30 fps OUTPUT cap. fix565–570 wanted this via an mpv `vf`
    // frame-rate filter but the BUNDLED libmpv had NO `fps`/`select`/`framestep`
    // filter (a missing lavfi filter makes mpv deselect the video track → a
    // black-screen stall), so fix570 hard-disabled it. The custom LGPL-max
    // libmpv now bundled (vnext, via dependency_overrides) DOES include `fps`
    // (and all non-GPL filters) — verified on-device (vfFps=30, voDrop=0) on the
    // libmpv-lgplmax-verify branch. So the cap is re-enabled, OPT-IN via
    // devCapFpsLowRam (default OFF: framedrop=decoder already holds full-rate
    // 0-drop on low-RAM, so the cap is mainly for boxes that still judder).
    // Form `lavfi=[fps=fps=30]` (no commas to escape); player.dart's
    // isVfOptionError suppression (fix566) stays as cover.
    // fix623: the cap is gated off for the mini-player PiP, but multi-view
    // cells SHOULD honor it. So allow it whenever this isn't the mini-player.
    // fix624: the low-RAM device gate was removed — when devCapFpsLowRam is
    // enabled it now forces 30 fps on ANY device (the flag is the opt-in; the
    // `fps` filter works regardless of RAM). Previously the setting silently
    // did nothing on non-low-RAM hardware.
    final capFps = !(previewMode && !multiViewMode) && s.devCapFpsLowRam;
    await np.setProperty('vf', capFps ? r'lavfi=[fps=fps=30]' : '');
    if (s.devHwdecImageFormat.value != null) {
      await np.setProperty(
          'hwdec-image-format', s.devHwdecImageFormat.value!);
    }
    await np.setProperty(
        'audio-buffer', s.devAudioBufferSecs.toString());
    final spdif = s.devAudioSpdif.value;
    if (spdif != null) {
      await np.setProperty('audio-spdif', spdif);
    }

    final demuxerMB = channel.mediaType == MediaType.livestream
        ? ((previewMode && !multiViewMode) ? s.miniDemuxerMaxMB : s.liveDemuxerMaxMB)
        : ((previewMode && !multiViewMode) ? s.miniDemuxerMaxMB * 2 : s.vodDemuxerMaxMB);
    AppLog.info(
      'MpvEngine: options applied'
      ' channel="${channel.name}"'
      ' previewMode=$previewMode'
      ' multiViewMode=$multiViewMode'
      ' demuxerMB=$demuxerMB'
      ' bufferSizeMB=${(previewMode && !multiViewMode) ? s.bufferSizeMB ~/ 2 : s.bufferSizeMB}'
      ' lowLatency=${s.lowLatency}'
      ' netTimeoutSecs=${s.devNetworkTimeoutSecs}'
      ' tlsVerify=${ignoreSsl ? "no(source)" : (s.devTlsVerify ? "yes" : "no")}'
      ' videoSync=${s.devVideoSync.value}'
      ' tscale=${s.devTscale.value}'
      ' framedrop=${s.devFramedrop.value}->$framedropMode'
      ' capFps30=$capFps'
      ' audioSpdif=${s.devAudioSpdif.value ?? "off"}',
    );
  }

  /// Re-apply options (e.g. after a reconnect that fetches fresh headers).
  Future<void> reapplyOptions({
    String? url,
    bool ignoreSsl = false,
    bool forceSoftwareDecode = false, // fix414
  }) async {
    await _applyMpvOptions(
      url: url ?? channel.url ?? '',
      ignoreSsl: ignoreSsl,
      forceSoftwareDecode: forceSoftwareDecode,
    );
  }

  // ===================== fix357: live DVR buffer =====================

  /// Conservative size estimate: ~8 Mbps live ≈ 60 MiB per minute.
  static const int _dvrEstMBPerMin = 60;

  // finding 100/101: orphan sweep — a crash/power-cut mid-DVR otherwise strands
  // the disk cache (up to ~5.4 GB). Per-engine _cleanupDvrDir (fix363) only runs
  // in this engine's dispose(), so a hard kill leaks the subdir forever.
  /// Delete every stale per-engine DVR subdir under {tmp}/free4me_dvr. Any dir
  /// present at app startup belongs to a dead engine (subdirs are named by
  /// identityHashCode and only live while their engine is alive in THIS
  /// process; there is no cross-process concurrency for this app), so at boot
  /// they are all dead — do NOT try to distinguish live vs dead by name.
  static Future<void> sweepOrphanedDvrDirs() async {
    try {
      final tmp = await getTemporaryDirectory();
      final root = Directory('${tmp.path}/free4me_dvr');
      if (!await root.exists()) return;
      await for (final e in root.list(followLinks: false)) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
      AppLog.info('MpvEngine: swept orphaned DVR cache dirs');
    } catch (_) {}
  }

  /// Resolve the DVR window in MiB: the configured minutes, capped so the
  /// recording stops 5 minutes short of what free disk can hold. Returns 0
  /// (DVR disabled) when less than 5 minutes would fit or sizing fails.
  Future<int> _computeDvrWindowMB() async {
    try {
      final tmp = await getTemporaryDirectory();
      // fix363/MED-1: per-engine subdir so a previous engine's async
      // _cleanupDvrDir can never unlink THIS engine's in-use cache file
      // (rapid full-screen A->Back->B both pointed demuxer-cache-dir at one shared
      // free4me_dvr; A's teardown wiped B's live window). identityHashCode is
      // unique per live engine instance.
      final dir = Directory(
          '${tmp.path}/free4me_dvr/e${identityHashCode(this)}');
      // fix359: do NOT create the dir or set _dvrDir yet — a low-disk return 0
      // below would leave an empty free4me_dvr behind (cleanup only runs when
      // _dvrActive). Size first; commit the dir only once the window is > 0.
      var minutes = settings.dvrMinutes.clamp(5, 90);
      final freeMB = await _dfAvailableMB(tmp.path);
      if (freeMB != null) {
        final fitMinutes = (freeMB ~/ _dvrEstMBPerMin) - 5; // 5-min margin
        if (fitMinutes < minutes) {
          AppLog.warn('MpvEngine: DVR window capped by disk —'
              ' requested=${settings.dvrMinutes}min fit=${fitMinutes}min'
              ' (free=${freeMB}MB, est=${_dvrEstMBPerMin}MB/min)');
          minutes = fitMinutes;
        }
      }
      if (minutes < 5) {
        AppLog.warn('MpvEngine: DVR disabled — under 5 minutes of disk'
            ' headroom available');
        return 0;
      }
      // fix359: window committed — now create the cache dir and record it.
      if (!await dir.exists()) await dir.create(recursive: true);
      _dvrDir = dir;
      return minutes * _dvrEstMBPerMin;
    } catch (e) {
      AppLog.warn('MpvEngine: DVR sizing failed — disabled ($e)');
      return 0;
    }
  }

  /// Available MB on the filesystem holding [path] via toybox `df -k`
  /// (present on Android 6+). Null when unavailable/unparseable.
  Future<int?> _dfAvailableMB(String path) async {
    try {
      final res = await Process.run('df', ['-k', path]);
      if (res.exitCode != 0) return null;
      // fix363/LOW-4: df wraps a long source/device name onto its own line,
      // so the data row can be split across two physical lines. Join all
      // post-header output and take the 1k-blocks/used/avail numeric triplet:
      // Filesystem 1K-blocks Used Available Use% Mounted. Available is the
      // 3rd numeric token. Scanning numerics is robust to the wrap and to
      // extra leading columns.
      final lines = (res.stdout as String).trim().split('\n');
      if (lines.length < 2) return null;
      final tokens = lines
          .skip(1)
          .join(' ')
          .split(RegExp(r'\s+'))
          .where((c) => c.isNotEmpty)
          .toList();
      final nums = <int>[];
      for (final t in tokens) {
        final n = int.tryParse(t);
        if (n != null) nums.add(n);
      }
      // Expect at least [1K-blocks, used, available]; Available is index 2.
      if (nums.length < 3) return null;
      final availKB = nums[2];
      return availKB ~/ 1024;
    } catch (_) {
      return null;
    }
  }

  /// Every 60 s: measure the DVR cache's real growth rate and free disk; if
  /// free space falls under 5 minutes' worth, freeze the back buffer at its
  /// current size (stop growing) rather than filling the disk.
  void _startDvrGuard(int backMB) {
    _dvrGuard?.cancel();
    _dvrGuard = Timer.periodic(const Duration(seconds: 60), (t) async {
      if (_disposed) {
        t.cancel();
        return;
      }
      try {
        final dirBytes = await _dvrDirBytes();
        final grewMB = ((dirBytes - _dvrLastDirBytes) / (1024 * 1024)).round();
        _dvrLastDirBytes = dirBytes;
        final ratePerMin = grewMB > 0 ? grewMB : _dvrEstMBPerMin;
        final freeMB = await _dfAvailableMB(_dvrDir!.path);
        if (AppLog.enabled) {
          AppLog.info('MpvEngine: DVR guard — cache=${dirBytes ~/ 1048576}MB'
              ' rate=${ratePerMin}MB/min free=${freeMB ?? -1}MB');
        }
        if (freeMB != null && freeMB < 5 * ratePerMin) {
          final frozenMB = (dirBytes ~/ 1048576).clamp(64, 1 << 20);
          if (_player.platform is mk.NativePlayer) {
            await (_player.platform as mk.NativePlayer)
                .setProperty('demuxer-max-back-bytes', '${frozenMB}MiB');
          }
          AppLog.warn('MpvEngine: DVR frozen at ${frozenMB}MiB —'
              ' free disk under 5-minute margin');
          t.cancel();
        }
      } catch (e) {
        AppLog.warn('MpvEngine: DVR guard error — $e');
      }
    });
  }

  Future<int> _dvrDirBytes() async {
    final dir = _dvrDir;
    if (dir == null || !await dir.exists()) return 0;
    var total = 0;
    await for (final f in dir.list(recursive: true, followLinks: false)) {
      if (f is File) {
        try {
          total += await f.length();
        } catch (_) {}
      }
    }
    return total;
  }

  /// Best-effort wipe of the DVR cache directory on engine teardown (mpv
  /// removes its own temp files on clean close; this covers unclean paths).
  Future<void> _cleanupDvrDir() async {
    final dir = _dvrDir;
    if (dir == null) return;
    try {
      // fix363/MED-1: delete only THIS engine's subdir — never siblings.
      if (await dir.exists()) await dir.delete(recursive: true);
      AppLog.info('MpvEngine: DVR cache cleaned (${dir.path})');
    } catch (_) {}
  }
}
