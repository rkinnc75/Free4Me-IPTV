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
  final _playingCtrl = StreamController<bool>.broadcast(); // fix336

  Timer? _pollTimer;
  bool _wasBuffering = false;

  /// fix339: set by open(). Live streams MUST NOT emit completed: video_player
  /// reports a tiny non-zero duration for raw .ts live (sub-second / segment
  /// window — logged as duration=0s via inSeconds), so the old
  /// duration > zero guard passed and position >= duration was instantly true,
  /// firing "stream completed" in a loop. On 1.26.54 (after fix335 kept Exo
  /// alive on live) this restarted every 2x2 cell about once per second
  /// (164 completed events in a 5-minute S24 log).
  bool _isLive = false;

  /// fix335: one-shot guard — emit a single "playing" liveness signal the first
  /// time the controller reports initialized && playing, so the Player's
  /// startup watchdog cancels even when video_player never toggles isBuffering
  /// (observed on live .ts: Exo goes straight to playing, no buffering event,
  /// so the watchdog timed out at 15s and fell back to libmpv despite a healthy
  /// frame — SURFACE showed initialized=true playing=true size=1280x720).
  bool _signalledPlaying = false;


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
        // fix334: on the onn 4K Plus the controller is fully healthy
        // (initialized, real size, playing) yet the screen stays black until
        // something forces a relayout — the user found that pressing the cast
        // button made the picture appear. That is the Android video_player
        // first-frame stall: the platform texture is created but the first
        // frame is not pushed to the surface until a layout pass occurs.
        // _FirstFrameNudge forces exactly one post-frame relayout after mount,
        // reproducing the cast-button effect automatically.
        // fix340: the multi-view cell hosts this view in a
        // Stack(fit: StackFit.expand) — TIGHT constraints. Under tight
        // constraints AspectRatio cannot choose its size and is forced to
        // fill the cell, stretching 16:9 video into a tall portrait cell.
        // Center gives the AspectRatio loose constraints so it letterboxes
        // correctly (black bars from the ColoredBox behind). mpv's Video
        // widget letterboxes internally, which is why only Exo stretched.
        return _FirstFrameNudge(
          child: ColoredBox(
            color: Colors.black,
            child: Center(
              child: AspectRatio(
                aspectRatio: value.aspectRatio,
                child: VideoPlayer(ctrl),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Future<void> open({
    required String url,
    Duration? startPosition,
    Map<String, String>? headers,
    bool isLive = false, // fix339
  }) async {
    _isLive = isLive;
    AppLog.info('ExoEngine: open() url="$url" isLive=$isLive');
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
    await _playingCtrl.close();
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

  // fix336: transport surface for the VOD control bar.
  @override
  Duration get duration => _controller?.value.duration ?? Duration.zero;

  @override
  Stream<bool> get playingStream => _playingCtrl.stream;

  @override
  bool get isPlaying => _controller?.value.isPlaying ?? false;

  @override
  Future<void> pause() async {
    await _controller?.pause();
    _playingCtrl.add(false);
  }

  @override
  Future<void> play() async {
    await _controller?.play();
    _playingCtrl.add(true);
  }

  @override
  Future<void> seek(Duration position) async {
    final d = _controller?.value.duration ?? Duration.zero;
    if (d <= Duration.zero) return; // live / non-seekable
    var target = position;
    if (target < Duration.zero) target = Duration.zero;
    if (target > d) target = d;
    await _controller?.seekTo(target);
  }


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

    // End of stream for VOD only. fix339: NEVER for live (see _isLive) — and
    // even for unset callers require a real duration (>= 5s): raw .ts live
    // reports a tiny non-zero duration that position reaches instantly, which
    // looped "completed" restarts on every 2x2 cell.
    if (!_isLive &&
        !v.isPlaying &&
        v.isInitialized &&
        v.duration >= const Duration(seconds: 5) &&
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

    // fix335: live .ts streams can reach initialized && playing WITHOUT ever
    // emitting a buffering transition, so the Player's startup watchdog (which
    // only cancels on a buffering event) timed out and fell back to libmpv even
    // though Exo was rendering. Emit one buffering=false the first time we see
    // the engine actually playing — the watchdog's cancel path accepts any
    // buffering signal. One-shot so it doesn't fight the real buffering stream.
    if (!_signalledPlaying && v.isInitialized && v.isPlaying) {
      _signalledPlaying = true;
      if (AppLog.enabled) {
        AppLog.info('ExoEngine: first playing frame — signalling liveness');
      }
      _bufferingCtrl.add(false);
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final v = _controller?.value;
      if (v == null) return;
      if (v.position != Duration.zero) _positionCtrl.add(v.position);
      // fix335: also drive the one-shot liveness signal from the poll, in case
      // the controller reaches playing without firing another value-change
      // event (so the watchdog still cancels within ~1s of real playback).
      if (!_signalledPlaying && v.isInitialized && v.isPlaying) {
        _signalledPlaying = true;
        if (AppLog.enabled) {
          AppLog.info('ExoEngine: first playing frame (poll) — '
              'signalling liveness');
        }
        _bufferingCtrl.add(false);
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }
}

/// fix334: forces a single post-frame relayout after first mount so the
/// Android video_player platform texture pushes its first frame to the
/// surface. Without this, some boxes (onn 4K Plus) show audio-only black until
/// an unrelated relayout (e.g. opening the cast menu) happens to trigger it.
/// The nudge is a one-shot sub-pixel padding toggle on the next two frames;
/// it is imperceptible and runs once per mount.
class _FirstFrameNudge extends StatefulWidget {
  const _FirstFrameNudge({required this.child});
  final Widget child;

  @override
  State<_FirstFrameNudge> createState() => _FirstFrameNudgeState();
}

class _FirstFrameNudgeState extends State<_FirstFrameNudge> {
  double _pad = 0.001;
  Timer? _timer;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    // The texture attaches somewhere in the first few hundred ms after mount.
    // Toggle a sub-pixel pad a handful of times across that window to force a
    // relayout once the surface is ready, then stop. Imperceptible; one-shot.
    _timer = Timer.periodic(const Duration(milliseconds: 120), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _pad = _pad == 0.0 ? 0.001 : 0.0);
      if (++_ticks >= 5) {
        t.cancel();
        if (mounted) setState(() => _pad = 0.0);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: _pad),
      child: widget.child,
    );
  }
}
