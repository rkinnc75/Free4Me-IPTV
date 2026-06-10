import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/player/player_engine.dart';
import 'package:video_player/video_player.dart';

/// ExoPlayer-backed engine via the video_player package.
///
/// Best for HLS (.m3u8), DASH (.mpd), and plain MP4/MKV files.
/// Does NOT support audio/subtitle track selection (video_player API
/// limitation); [supportsTrackSelection] returns false.
///
/// Fullscreen is handled by the [Player] widget via SystemChrome since
/// video_player has no built-in fullscreen controller.
class ExoEngine implements PlayerEngine {
  VideoPlayerController? _controller;

  final _bufferingCtrl = StreamController<bool>.broadcast();
  final _completedCtrl = StreamController<bool>.broadcast();
  final _errorCtrl = StreamController<String>.broadcast();
  final _positionCtrl = StreamController<Duration>.broadcast();

  Timer? _pollTimer;
  bool _wasBuffering = false;


  @override
  Widget buildVideoView(BuildContext context) {
    final ctrl = _controller;
    if (ctrl == null) {
      return const ColoredBox(color: Colors.black);
    }
    // fix332: buildVideoView is called from Player.build, which only rebuilds
    // on its own setState (overlay/buffering). open() initializes the
    // controller asynchronously AFTER this view is first built, so on some
    // boxes (onn 4K Plus) no setState happened once isInitialized flipped true
    // and the VideoPlayer widget was never mounted — audio played but the
    // screen stayed on the black ColoredBox. Listen to the controller directly
    // so this view rebuilds itself the moment initialization completes,
    // independent of Player's setState.
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: ctrl,
      builder: (context, value, _) {
        if (!value.isInitialized) {
          return const ColoredBox(color: Colors.black);
        }
        return AspectRatio(
          aspectRatio: value.aspectRatio,
          child: VideoPlayer(ctrl),
        );
      },
    );
  }

  @override
  Future<void> open({
    required String url,
    Duration? startPosition,
    Map<String, String>? headers,
  }) async {
    AppLog.info('ExoEngine: open() url="$url"');
    await _controller?.dispose();

    _controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: headers ?? const {},
    );

    await _controller!.initialize();

    AppLog.info(
      'ExoEngine: initialised'
      ' duration=${_controller!.value.duration.inSeconds}s'
      ' size=${_controller!.value.size}',
    );
    // fix332: parity with the mpv mid-playback surface probe — log the view
    // state shortly after init so a black-screen-with-audio session on
    // ExoPlayer is diagnosable (size=0x0 / not initialized vs a real size).
    Future.delayed(const Duration(seconds: 2), () {
      final v = _controller?.value;
      if (v == null) return;
      AppLog.info('ExoEngine: SURFACE[mid-playback+2s]'
          ' initialized=${v.isInitialized}'
          ' size=${v.size.width.toInt()}x${v.size.height.toInt()}'
          ' playing=${v.isPlaying} buffering=${v.isBuffering}');
    });

    if (startPosition != null && startPosition > Duration.zero) {
      await _controller!.seekTo(startPosition);
    }

    _controller!.addListener(_onValueChanged);
    await _controller!.play();

    _startPolling();
  }

  @override
  Future<void> dispose() async {
    AppLog.info('ExoEngine: dispose()');
    _stopPolling();
    _controller?.removeListener(_onValueChanged);
    await _controller?.dispose();
    _controller = null;
    await _bufferingCtrl.close();
    await _completedCtrl.close();
    await _errorCtrl.close();
    await _positionCtrl.close();
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
  Duration get position => _controller?.value.position ?? Duration.zero;


  @override
  bool get supportsTrackSelection => false;

  @override
  List<TrackInfo> get subtitleTracks => const [];
  @override
  List<TrackInfo> get audioTracks => const [];

  @override
  Future<void> setSubtitleTrack(int index) async {}
  @override
  Future<void> setAudioTrack(int index) async {}


  @override
  Future<void> setVolume(double volume) async {
    await _controller?.setVolume(volume);
  }


  @override
  bool get handlesOwnFullscreen => false;

  @override
  Future<void> enterFullscreen() async {}
  @override
  Future<void> exitFullscreen() async {}

  @override
  bool get isFullscreen => false;


  void _onValueChanged() {
    final v = _controller?.value;
    if (v == null) return;

    // Error
    if (v.hasError) {
      AppLog.warn('ExoEngine: error — "${v.errorDescription}"');
      _errorCtrl.add(v.errorDescription ?? 'ExoPlayer error');
    }

    // End of stream for VOD only. Live HLS streams report duration == zero;
    // skip in that case to avoid false reconnect loops.
    if (!v.isPlaying &&
        v.isInitialized &&
        v.duration > Duration.zero &&
        v.position >= v.duration) {
      AppLog.info('ExoEngine: stream completed');
      _completedCtrl.add(true);
    }

    // Buffering: video_player emits isBuffering directly
    if (v.isBuffering != _wasBuffering) {
      _wasBuffering = v.isBuffering;
      if (AppLog.enabled) AppLog.info('ExoEngine: buffering=${v.isBuffering}');
      _bufferingCtrl.add(v.isBuffering);
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final pos = _controller?.value.position;
      if (pos != null) _positionCtrl.add(pos);
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }
}
