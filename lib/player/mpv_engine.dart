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
import 'package:open_tv/models/settings.dart';
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
  final bool previewMode;

  /// fix357: when true (full-screen Player, live, no catch-up override) the
  /// live DVR-to-disk buffer may be enabled per settings. Mini-player and
  /// multi-view cells never set this.
  final bool dvrEligible;

  // fix357: DVR runtime state.
  Directory? _dvrDir;
  Timer? _dvrGuard;
  int _dvrLastDirBytes = 0;
  bool _dvrActive = false;

  @override
  bool get dvrActive => _dvrActive; // fix360

  late final mk.Player _player = mk.Player(
    configuration: mk.PlayerConfiguration(
      // bufferSizeMB from settings; mini-player (previewMode) uses half.
      bufferSize: previewMode
          ? (settings.bufferSizeMB ~/ 2) * 1024 * 1024
          : settings.bufferSizeMB * 1024 * 1024,
      logLevel: mk.MPVLogLevel.warn,
    ),
  );
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
    this.dvrEligible = false,
  }) {
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
          if (!_disposed) logSurface('mid-playback+2s');
        });
      }
    }));
    _subs.add(_player.stream.completed.listen((v) => _completedCtrl.add(v)));
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

  @override
  Widget buildVideoView(BuildContext context) {
    return mkvideo.Video(
      key: _videoKey,
      controller: _controller,
    );
  }

  @override
  Future<void> open({
    required String url,
    Duration? startPosition,
    Map<String, String>? headers,
    bool isLive = false, // fix339: unused — mpv's completed is EOF-based
  }) async {
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
    //
    // force-seekable=no is also passed via extras so it survives mpv's
    // internal demuxer reset on open(). Setting it via setProperty() alone
    // is insufficient — mpv resets stream-level runtime properties when
    // initializing a new stream, wiping the value before the seek probe runs.
    final extras = channel.mediaType == MediaType.livestream
        ? const {'force-seekable': 'no'}
        : null;

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

    await _player.open(
      mk.Media(
        url,
        start: startPosition,
        httpHeaders: headers,
        extras: extras,
      ),
    );
    AppLog.info('MpvEngine: open() command sent channel="${channel.name}"');
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
    if (_player.state.duration <= Duration.zero) return;
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

  void updateAspectRatio(double ratio) {
    _videoKey.currentState?.update(aspectRatio: ratio);
  }


  Future<void> _applyMpvOptions({
    required String url,
    bool ignoreSsl = false,
  }) async {
    if (_player.platform is! mk.NativePlayer) return;
    final np = _player.platform as mk.NativePlayer;
    final s = settings;

    await np.setProperty('cache', 'yes');
    await np.setProperty('network-timeout', '30');

    if (ignoreSsl) {
      await np.setProperty('tls-verify', 'no');
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
    if (previewMode && Platform.isAndroid && s.hwDecode) {
      // fix314: Tegra/Shield corrupts colour with concurrent mediacodec-copy
      // (2×2 grid → rainbow planes). The multiViewDecode setting controls this:
      //   auto         → software on Tegra/Shield, mediacodec-copy elsewhere
      //   hardwareCopy → force mediacodec-copy (pre-fix314 behaviour)
      //   software     → force CPU decode
      final wantSoftware = switch (s.multiViewDecode) {
        MultiViewDecode.software => true,
        MultiViewDecode.hardwareCopy => false,
        MultiViewDecode.auto => await DeviceDetector.isTegra(),
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
      // Phone: mediacodec surface mode (hardware, zero-copy).
      // TV: software decode. fix164 — on low-RAM TV boxes (onn 4K Plus,
      // 2GB / Mali-G310) the mediacodec-copy GPU→CPU readback falls behind
      // the audio clock causing A/V desync. Software decode (hwdec=no)
      // keeps A/V in sync and cannot hit the surface-mode black-screen
      // failure (fix108). Preview/multi-view cells keep mediacodec-copy.
      final isTV = await DeviceDetector.isTV();
      final hwdecMode = isTV ? 'no' : 'mediacodec';
      await np.setProperty('hwdec', hwdecMode);
      AppLog.info('Player: hwdec=$hwdecMode isTV=$isTV (fix164)');
    } else if (s.hwDecode && Platform.isIOS) {
      await np.setProperty('hwdec', 'videotoolbox');
    } else {
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
        await np.setProperty('cache-dir', _dvrDir!.path);
        AppLog.info('MpvEngine: DVR enabled — window=${dvrBackMB ~/ 60}min'
            ' (${dvrBackMB}MiB back buffer, dir=${_dvrDir!.path})');
      } else {
        await np.setProperty('force-seekable', 'no');
      }

      // Back buffer disabled for all live branches: MPEG-TS and most IPTV
      // streams reject seeks, which mpv surfaces as a fatal player error
      // ("Cannot seek in this stream.") causing an immediate reconnect loop.
      // VOD keeps its back buffer for normal reverse-seek support.
      if (s.lowLatency) {
        await np.setProperty('profile', 'low-latency');
        await np.setProperty('demuxer-max-back-bytes', '0');
      } else {
        await np.setProperty('cache-secs', s.liveCacheSecs.toString());
        final liveMB = previewMode ? s.miniDemuxerMaxMB : s.liveDemuxerMaxMB;
        await np.setProperty('demuxer-max-bytes', '${liveMB}MiB');
        await np.setProperty(
            'demuxer-max-back-bytes', dvrBackMB > 0 ? '${dvrBackMB}MiB' : '0');
        if (dvrBackMB > 0) _startDvrGuard(dvrBackMB);
      }
    } else {
      await np.setProperty('cache-secs', s.vodCacheSecs.toString());
      final vodMB = previewMode ? s.miniDemuxerMaxMB * 2 : s.vodDemuxerMaxMB;
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

    final demuxerMB = channel.mediaType == MediaType.livestream
        ? (previewMode ? s.miniDemuxerMaxMB : s.liveDemuxerMaxMB)
        : (previewMode ? s.miniDemuxerMaxMB * 2 : s.vodDemuxerMaxMB);
    AppLog.info(
      'MpvEngine: options applied'
      ' channel="${channel.name}"'
      ' previewMode=$previewMode'
      ' demuxerMB=$demuxerMB'
      ' bufferSizeMB=${previewMode ? s.bufferSizeMB ~/ 2 : s.bufferSizeMB}'
      ' lowLatency=${s.lowLatency}',
    );
  }

  /// Re-apply options (e.g. after a reconnect that fetches fresh headers).
  Future<void> reapplyOptions({String? url, bool ignoreSsl = false}) async {
    await _applyMpvOptions(
      url: url ?? channel.url ?? '',
      ignoreSsl: ignoreSsl,
    );
  }

  // ===================== fix357: live DVR buffer =====================

  /// Conservative size estimate: ~8 Mbps live ≈ 60 MiB per minute.
  static const int _dvrEstMBPerMin = 60;

  /// Resolve the DVR window in MiB: the configured minutes, capped so the
  /// recording stops 5 minutes short of what free disk can hold. Returns 0
  /// (DVR disabled) when less than 5 minutes would fit or sizing fails.
  Future<int> _computeDvrWindowMB() async {
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory('${tmp.path}/free4me_dvr');
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
      final lines = (res.stdout as String).trim().split('\n');
      if (lines.length < 2) return null;
      final cols =
          lines.last.split(RegExp(r'\s+')).where((c) => c.isNotEmpty).toList();
      if (cols.length < 4) return null;
      final availKB = int.tryParse(cols[3]);
      if (availKB == null) return null;
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
      await for (final f in dir.list(followLinks: false)) {
        try {
          await f.delete(recursive: true);
        } catch (_) {}
      }
      AppLog.info('MpvEngine: DVR cache cleaned (${dir.path})');
    } catch (_) {}
  }
}
