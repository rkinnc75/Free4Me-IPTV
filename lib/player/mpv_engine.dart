import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkvideo;
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/device_detector.dart';
import 'package:open_tv/models/media_type.dart';
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

  MpvEngine({
    required this.channel,
    required this.settings,
    this.fullscreenOnOpen = true,
    this.previewMode = false,
  }) {
    _player.setPlaylistMode(mk.PlaylistMode.none);

    _subs.add(_player.stream.buffering.listen((v) => _bufferingCtrl.add(v)));
    _subs.add(_player.stream.completed.listen((v) => _completedCtrl.add(v)));
    _subs.add(_player.stream.error.listen((e) => _errorCtrl.add(e)));
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
    AppLog.info(
      'MpvEngine: dispose() eid=${identityHashCode(this)}'
      ' channel="${channel.name}"'
      ' previewMode=$previewMode',
    );

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


  @override
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
  // + landscape orientation), the same path ExoEngine uses. media_kit's
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
      await np.setProperty('hwdec', 'mediacodec-copy');
      AppLog.info('Player: hwdec=mediacodec-copy (preview) channel="${channel.name}"');
    } else if (previewMode && Platform.isIOS && s.hwDecode) {
      // videotoolbox supports concurrent decode sessions on iOS.
      await np.setProperty('hwdec', 'videotoolbox');
      AppLog.info('Player: hwdec=videotoolbox (preview) channel="${channel.name}"');
    } else if (previewMode) {
      // hwDecode disabled by user, or unsupported platform — fall back to CPU.
      await np.setProperty('hwdec', 'no');
      AppLog.info('Player: hwdec=no (preview fallback) channel="${channel.name}"');
    } else if (s.hwDecode && Platform.isAndroid) {
      // Android TV devices (Shield, Fire TV, Onn 4K, etc.) require
      // mediacodec-copy rather than mediacodec surface mode. In surface
      // mode, mediacodec binds directly to a SurfaceTexture — this fails
      // silently on Tegra X1 and similar Android TV SoCs, producing audio
      // with a black screen. mediacodec-copy decodes in hardware but copies
      // frames to CPU memory, bypassing the surface binding. Overhead is
      // negligible on TV-class hardware.
      final isTV = await DeviceDetector.isTV();
      final hwdecMode = isTV ? 'mediacodec-copy' : 'mediacodec';
      await np.setProperty('hwdec', hwdecMode);
      AppLog.info('Player: hwdec=$hwdecMode isTV=$isTV');
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
      await np.setProperty('force-seekable', 'no');

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
        await np.setProperty('demuxer-max-back-bytes', '0');
      }
    } else {
      await np.setProperty('cache-secs', s.vodCacheSecs.toString());
      final vodMB = previewMode ? s.miniDemuxerMaxMB * 2 : s.vodDemuxerMaxMB;
      await np.setProperty('demuxer-max-bytes', '${vodMB}MiB');
      await np.setProperty('demuxer-max-back-bytes', '64MiB');
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
}
