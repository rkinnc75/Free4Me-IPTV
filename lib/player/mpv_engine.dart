import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkvideo;
import 'package:open_tv/models/channel.dart';
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

  late final mk.Player _player = mk.Player(
    configuration: const mk.PlayerConfiguration(
      bufferSize: 256 * 1024 * 1024,
      logLevel: mk.MPVLogLevel.warn,
    ),
  );
  late final mkvideo.VideoController _controller =
      mkvideo.VideoController(_player);
  final GlobalKey<mkvideo.VideoState> _videoKey =
      GlobalKey<mkvideo.VideoState>();

  // Stream controllers that mirror the media_kit streams.
  final _bufferingCtrl = StreamController<bool>.broadcast();
  final _completedCtrl = StreamController<bool>.broadcast();
  final _errorCtrl = StreamController<String>.broadcast();
  final _positionCtrl = StreamController<Duration>.broadcast();

  final List<StreamSubscription<dynamic>> _subs = [];

  MpvEngine({
    required this.channel,
    required this.settings,
    this.fullscreenOnOpen = true,
  }) {
    _player.setPlaylistMode(mk.PlaylistMode.none);

    _subs.add(_player.stream.buffering.listen((v) => _bufferingCtrl.add(v)));
    _subs.add(_player.stream.completed.listen((v) => _completedCtrl.add(v)));
    _subs.add(_player.stream.error.listen((e) => _errorCtrl.add(e)));
    _subs.add(_player.stream.position.listen((p) => _positionCtrl.add(p)));
  }

  // ── PlayerEngine ───────────────────────────────────────────────────────────

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
    // Options must be applied via reapplyOptions() BEFORE calling open().
    // Calling _applyMpvOptions() here would set mpv properties on the
    // still-active previous stream, triggering a demuxer reset and seek
    // probe on non-seekable MPEG-TS livestreams → "Cannot seek in this stream."
    await _player.open(
      mk.Media(
        url,
        start: startPosition,
        httpHeaders: headers,
      ),
    );
    if (fullscreenOnOpen) await _videoKey.currentState?.enterFullscreen();
  }

  @override
  Future<void> setVolume(double volume) async {
    // media_kit uses a 0–100 scale
    await _player.setVolume(volume * 100);
  }

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _bufferingCtrl.close();
    await _completedCtrl.close();
    await _errorCtrl.close();
    await _positionCtrl.close();
    await _player.dispose();
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
  Duration get position => _player.state.position;

  // ── Track selection ────────────────────────────────────────────────────────

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

  // ── Fullscreen ─────────────────────────────────────────────────────────────

  @override
  bool get handlesOwnFullscreen => true;

  @override
  Future<void> enterFullscreen() async {
    await _videoKey.currentState?.enterFullscreen();
  }

  @override
  Future<void> exitFullscreen() async {
    await _videoKey.currentState?.exitFullscreen();
  }

  @override
  bool get isFullscreen => _videoKey.currentState?.isFullscreen() ?? false;

  // ── Video dimensions (used by toggleZoom in player.dart) ──────────────────

  int? get videoWidth => _player.state.width;
  int? get videoHeight => _player.state.height;

  void updateAspectRatio(double ratio) {
    _videoKey.currentState?.update(aspectRatio: ratio);
  }

  // ── mpv option application ─────────────────────────────────────────────────

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

    if (s.hwDecode && Platform.isAndroid) {
      await np.setProperty('hwdec', 'mediacodec');
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
        await np.setProperty('demuxer-max-bytes', '${s.liveDemuxerMaxMB}MiB');
        await np.setProperty('demuxer-max-back-bytes', '0');
      }
    } else {
      await np.setProperty('cache-secs', s.vodCacheSecs.toString());
      await np.setProperty('demuxer-max-bytes', '${s.vodDemuxerMaxMB}MiB');
      await np.setProperty('demuxer-max-back-bytes', '64MiB');
    }
  }

  /// Re-apply options (e.g. after a reconnect that fetches fresh headers).
  Future<void> reapplyOptions({String? url, bool ignoreSsl = false}) async {
    await _applyMpvOptions(
      url: url ?? channel.url ?? '',
      ignoreSsl: ignoreSsl,
    );
  }
}
