import 'dart:async';

import 'package:flutter/material.dart';
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

  // ── PlayerEngine ───────────────────────────────────────────────────────────

  @override
  Widget buildVideoView(BuildContext context) {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    return AspectRatio(
      aspectRatio: ctrl.value.aspectRatio,
      child: VideoPlayer(ctrl),
    );
  }

  @override
  Future<void> open({
    required String url,
    Duration? startPosition,
    Map<String, String>? headers,
  }) async {
    await _controller?.dispose();

    _controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: headers ?? const {},
    );

    await _controller!.initialize();

    if (startPosition != null && startPosition > Duration.zero) {
      await _controller!.seekTo(startPosition);
    }

    _controller!.addListener(_onValueChanged);
    await _controller!.play();

    _startPolling();
  }

  @override
  Future<void> dispose() async {
    _stopPolling();
    _controller?.removeListener(_onValueChanged);
    await _controller?.dispose();
    _controller = null;
    await _bufferingCtrl.close();
    await _completedCtrl.close();
    await _errorCtrl.close();
    await _positionCtrl.close();
  }

  // ── Streams ────────────────────────────────────────────────────────────────

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

  // ── Track selection — not supported ───────────────────────────────────────

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

  // ── Volume ─────────────────────────────────────────────────────────────────

  @override
  Future<void> setVolume(double volume) async {
    await _controller?.setVolume(volume);
  }

  // ── Fullscreen — delegated to caller ──────────────────────────────────────

  @override
  bool get handlesOwnFullscreen => false;

  @override
  Future<void> enterFullscreen() async {}
  @override
  Future<void> exitFullscreen() async {}

  @override
  bool get isFullscreen => false;

  // ── Internal ───────────────────────────────────────────────────────────────

  void _onValueChanged() {
    final v = _controller?.value;
    if (v == null) return;

    // Error
    if (v.hasError) {
      _errorCtrl.add(v.errorDescription ?? 'ExoPlayer error');
    }

    // End of stream for VOD only. Live HLS streams report duration == zero;
    // skip in that case to avoid false reconnect loops.
    if (!v.isPlaying &&
        v.isInitialized &&
        v.duration > Duration.zero &&
        v.position >= v.duration) {
      _completedCtrl.add(true);
    }

    // Buffering: video_player emits isBuffering directly
    if (v.isBuffering != _wasBuffering) {
      _wasBuffering = v.isBuffering;
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
