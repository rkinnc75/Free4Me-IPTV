import 'package:flutter/material.dart';

/// A single selectable audio or subtitle track exposed by a player engine.
class TrackInfo {
  final int index;
  final String label;
  const TrackInfo({required this.index, required this.label});
}

/// Abstract player engine interface.
///
/// Concrete implementation: [MpvEngine] — media_kit / libmpv (MPEG-TS,
/// HLS, DASH, MP4, RTMP — any format). fix350: ExoPlayer removed; the
/// interface is retained as the engine seam (handoff/adoption typing).
///
/// The [Player] widget owns one engine instance per playback session and
/// delegates all media operations through this interface.
abstract class PlayerEngine {

  /// Returns the widget that renders the video surface.
  /// Must be called after the engine is constructed; the widget can be
  /// embedded anywhere in the build tree.
  Widget buildVideoView(BuildContext context);


  /// Open [url] and start playback.
  /// [startPosition] is only honoured for VOD (seekable streams).
  /// [headers] are HTTP request headers forwarded to the stream origin.
  Future<void> open({
    required String url,
    Duration? startPosition,
    Map<String, String>? headers,
    bool isLive = false, // fix339: live streams must not emit completed
  });

  /// Release all native resources.  Must be called exactly once.
  Future<void> dispose();


  /// Emits [true] while the player is in a rebuffering state.
  Stream<bool> get bufferingStream;

  /// Emits [true] when end-of-stream is reached (VOD finished).
  Stream<bool> get completedStream;

  /// Emits a non-empty string when a fatal playback error occurs.
  Stream<String> get errorStream;

  /// Current playback position, updated at most once per second.
  Stream<Duration> get positionStream;


  Duration get position;

  /// fix336: total media duration for VOD (zero for live). Drives the seek
  /// slider (zero for live streams).
  Duration get duration;

  /// fix336: emits the playing/paused state so the transport bar stays in sync.
  Stream<bool> get playingStream;

  /// fix336: whether playback is currently un-paused.
  bool get isPlaying;

  /// fix336: pause playback (no-op if already paused / unsupported).
  Future<void> pause();

  /// fix336: resume playback (no-op if already playing).
  Future<void> play();

  /// fix336: seek to [position] (VOD only; no-op on live/non-seekable).
  Future<void> seek(Duration position);


  /// Whether this engine can enumerate and switch audio/subtitle tracks.
  bool get supportsTrackSelection;

  List<TrackInfo> get subtitleTracks;
  List<TrackInfo> get audioTracks;

  Future<void> setSubtitleTrack(int index);
  Future<void> setAudioTrack(int index);



  /// Set playback volume. [volume] is 0.0 (muted) to 1.0 (full).
  Future<void> setVolume(double volume);


  /// Whether this engine controls its own fullscreen transition.
  /// MpvEngine uses media_kit_video's VideoState; it delegates to the
  /// caller, which uses [SystemChrome] directly.
  bool get handlesOwnFullscreen;

  /// fix360/re-fix364: true when a live DVR-to-disk buffer is active (fix357).
  /// Only then is live seeking (rewind/FF/back-to-live) meaningful.
  bool get dvrActive => false;

  /// Request fullscreen entry (no-op if [handlesOwnFullscreen] is false).
  Future<void> enterFullscreen();

  /// Request fullscreen exit (no-op if [handlesOwnFullscreen] is false).
  Future<void> exitFullscreen();

  /// True when the engine is currently in fullscreen (always false when
  /// [handlesOwnFullscreen] is false).
  bool get isFullscreen;
}
