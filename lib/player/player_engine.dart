import 'package:flutter/material.dart';

/// A single selectable audio or subtitle track exposed by a player engine.
class TrackInfo {
  final int index;
  final String label;
  const TrackInfo({required this.index, required this.label});
}

/// Abstract player engine interface.
///
/// Concrete implementations:
///   • [MpvEngine]  — media_kit / libmpv (MPEG-TS, RTMP, any format)
///   • [ExoEngine]  — ExoPlayer via video_player (HLS, DASH, MP4)
///
/// The [Player] widget owns one engine instance per playback session and
/// delegates all media operations through this interface.
abstract class PlayerEngine {
  // ── Video rendering ────────────────────────────────────────────────────────

  /// Returns the widget that renders the video surface.
  /// Must be called after the engine is constructed; the widget can be
  /// embedded anywhere in the build tree.
  Widget buildVideoView(BuildContext context);

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  /// Open [url] and start playback.
  /// [startPosition] is only honoured for VOD (seekable streams).
  /// [headers] are HTTP request headers forwarded to the stream origin.
  Future<void> open({
    required String url,
    Duration? startPosition,
    Map<String, String>? headers,
  });

  /// Release all native resources.  Must be called exactly once.
  Future<void> dispose();

  // ── Playback state streams ─────────────────────────────────────────────────

  /// Emits [true] while the player is in a rebuffering state.
  Stream<bool> get bufferingStream;

  /// Emits [true] when end-of-stream is reached (VOD finished).
  Stream<bool> get completedStream;

  /// Emits a non-empty string when a fatal playback error occurs.
  Stream<String> get errorStream;

  /// Current playback position, updated at most once per second.
  Stream<Duration> get positionStream;

  // ── Current state snapshots ────────────────────────────────────────────────

  Duration get position;

  // ── Track selection ────────────────────────────────────────────────────────

  /// Whether this engine can enumerate and switch audio/subtitle tracks.
  /// [ExoEngine] returns false because video_player exposes no track API.
  bool get supportsTrackSelection;

  List<TrackInfo> get subtitleTracks;
  List<TrackInfo> get audioTracks;

  Future<void> setSubtitleTrack(int index);
  Future<void> setAudioTrack(int index);

  // ── Fullscreen ─────────────────────────────────────────────────────────────

  // ── Volume ─────────────────────────────────────────────────────────────────

  /// Set playback volume. [volume] is 0.0 (muted) to 1.0 (full).
  Future<void> setVolume(double volume);

  // ── Fullscreen ─────────────────────────────────────────────────────────────

  /// Whether this engine controls its own fullscreen transition.
  /// MpvEngine uses media_kit_video's VideoState; ExoEngine delegates to the
  /// caller, which uses [SystemChrome] directly.
  bool get handlesOwnFullscreen;

  /// Request fullscreen entry (no-op if [handlesOwnFullscreen] is false).
  Future<void> enterFullscreen();

  /// Request fullscreen exit (no-op if [handlesOwnFullscreen] is false).
  Future<void> exitFullscreen();

  /// True when the engine is currently in fullscreen (always false when
  /// [handlesOwnFullscreen] is false).
  bool get isFullscreen;
}
