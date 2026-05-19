import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/channel_http_headers.dart';
import 'package:open_tv/models/id_data.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkvideo;
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/channel_tile.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/select_dialog.dart';

class Player extends StatefulWidget {
  final Channel channel;
  final Settings settings;
  const Player({super.key, required this.channel, required this.settings});
  @override
  State<StatefulWidget> createState() => _PlayerState();
}

class _PlayerState extends State<Player> {
  // Pre-allocate a generous demuxer buffer up front. mpv won't allocate
  // more than this at runtime, so this is the effective ceiling.
  late mk.Player player = mk.Player(
    configuration: const mk.PlayerConfiguration(
      bufferSize: 256 * 1024 * 1024, // 256 MiB ceiling
      logLevel: mk.MPVLogLevel.warn,
    ),
  );
  late mkvideo.VideoController videoController = mkvideo.VideoController(
    player,
  );
  late final GlobalKey<VideoState> key = GlobalKey<VideoState>();
  bool exiting = false;
  bool fill = false;
  List<StreamSubscription> subscriptions = [];

  // Reconnect bookkeeping
  int _consecutiveOpenFailures = 0;
  static const int _maxOpenFailures = 6;
  Timer? _bufferingWatchdog;
  bool _isReconnecting = false;
  String? _bufferingState; // 'show' overlay text

  @override
  void initState() {
    super.initState();
    initAsync();
  }

  Future<void> initAsync() async {
    player.setPlaylistMode(mk.PlaylistMode.none);
    final headers = await Sql.getChannelHeaders(widget.channel.id!);
    await setMpvOptions(headers: headers);
    final seconds = widget.channel.mediaType == MediaType.movie
        ? await Sql.getPosition(widget.channel.id!)
        : null;
    await _startPlayback(seconds != null ? Duration(seconds: seconds) : null);

    // FIX (Tier 1, #2): listen to all relevant streams, not just completed.
    subscriptions.add(
      player.stream.completed.listen((completed) {
        if (completed) onDisconnect(reason: 'stream completed');
      }),
    );
    subscriptions.add(
      player.stream.error.listen((err) {
        debugPrint('player error: $err');
        onDisconnect(reason: 'player error: $err');
      }),
    );
    subscriptions.add(
      player.stream.buffering.listen(_onBufferingChanged),
    );

    // Tier 3, #16: reconnect when network returns.
    subscriptions.add(
      Connectivity().onConnectivityChanged.listen((results) {
        final hasNet =
            results.isNotEmpty && !results.contains(ConnectivityResult.none);
        if (hasNet && _isReconnecting) {
          debugPrint('Network restored; reconnecting...');
          onDisconnect(reason: 'network restored');
        }
      }),
    );
  }

  bool _isIgnoreSsl(ChannelHttpHeaders? headers) {
    final v = headers?.ignoreSSL;
    if (v == null) return false;
    return v == '1' || v.toLowerCase() == 'true';
  }

  String _playbackUrl() {
    final id = widget.channel.id;
    if (id != null) {
      final warmed = ChannelTile.prewarmedUrl(id);
      if (warmed != null) return warmed;
    }
    return widget.channel.url!;
  }

  Future<void> setMpvOptions({ChannelHttpHeaders? headers}) async {
    if (player.platform is! mk.NativePlayer) return;
    final np = player.platform as mk.NativePlayer;

    final s = widget.settings;

    // Always enable mpv's stream cache.
    await np.setProperty('cache', 'yes');
    // Be tolerant of slow IPTV origins.
    await np.setProperty('network-timeout', '30');

    if (_isIgnoreSsl(headers)) {
      await np.setProperty('tls-verify', 'no');
    }

    final url = _playbackUrl();
    if (url.contains('.m3u8')) {
      if (s.lowLatency) {
        await np.setProperty('hls-bitrate', 'min');
      } else {
        await np.setProperty('hls-bitrate', 'max');
      }
    }

    // Tier 3, #17: hardware decoding via Android MediaCodec.
    if (s.hwDecode) {
      await np.setProperty('hwdec', 'mediacodec');
    } else {
      await np.setProperty('hwdec', 'no');
    }

    if (widget.channel.mediaType == MediaType.livestream) {
      if (s.lowLatency) {
        // Existing behavior: shrink buffering for minimum delay.
        await np.setProperty('profile', 'low-latency');
      } else {
        await np.setProperty('cache-secs', s.liveCacheSecs.toString());
        await np.setProperty(
          'demuxer-max-bytes',
          '${s.liveDemuxerMaxMB}MiB',
        );
        await np.setProperty('demuxer-max-back-bytes', '32MiB');
      }
    } else {
      // VOD: bigger forward + moderate back buffer for scrubbing.
      await np.setProperty('cache-secs', s.vodCacheSecs.toString());
      await np.setProperty(
        'demuxer-max-bytes',
        '${s.vodDemuxerMaxMB}MiB',
      );
      await np.setProperty('demuxer-max-back-bytes', '64MiB');
    }
  }

  /// Buffering watchdog: if we stay in buffering state for longer than
  /// settings.bufferingWatchdogSecs on a livestream, force a reconnect.
  void _onBufferingChanged(bool buffering) {
    if (!mounted || exiting) return;
    if (buffering) {
      if (mounted) setState(() => _bufferingState = 'Buffering...');
      if (widget.channel.mediaType == MediaType.livestream) {
        _bufferingWatchdog?.cancel();
        _bufferingWatchdog = Timer(
          Duration(seconds: widget.settings.bufferingWatchdogSecs),
          () => onDisconnect(reason: 'buffering watchdog'),
        );
      }
    } else {
      _bufferingWatchdog?.cancel();
      _bufferingWatchdog = null;
      if (mounted) setState(() => _bufferingState = null);
    }
  }

  void onDisconnect({String reason = 'unknown'}) async {
    if (!mounted || exiting || _isReconnecting) return;
    if (widget.channel.mediaType != MediaType.livestream) return;
    _isReconnecting = true;
    debugPrint('Live stream reconnect ($reason)...');
    if (mounted) setState(() => _bufferingState = 'Reconnecting...');
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted || exiting) {
      _isReconnecting = false;
      return;
    }
    await _startPlayback(null);
    _isReconnecting = false;
  }

  Future<void> _startPlayback(Duration? startPosition) async {
    final timeout = Duration(seconds: widget.settings.openTimeoutSecs);
    while (true) {
      if (!mounted || exiting) return;
      try {
        final headers = await Sql.getChannelHeaders(widget.channel.id!);
        await setMpvOptions(headers: headers);
        final playbackUrl = _playbackUrl();
        // FIX (Tier 1, #1): wrap open in a timeout so we never hang.
        await player
            .open(
              mk.Media(
                playbackUrl,
                start: startPosition,
                httpHeaders: headers != null
                    ? {
                        if (headers.referrer != null) "Referer": headers.referrer!,
                        if (headers.httpOrigin != null)
                          "Origin": headers.httpOrigin!,
                        if (headers.userAgent != null)
                          "User-Agent": headers.userAgent!,
                      }
                    : null,
              ),
            )
            .timeout(
              timeout,
              onTimeout: () => throw TimeoutException(
                'player.open() exceeded ${timeout.inSeconds}s',
              ),
            );
        _consecutiveOpenFailures = 0;
        await key.currentState?.enterFullscreen();
        return;
      } catch (e) {
        _consecutiveOpenFailures++;
        debugPrint(
          "Playback failed ($_consecutiveOpenFailures/$_maxOpenFailures): $e",
        );
        if (_consecutiveOpenFailures >= _maxOpenFailures) {
          if (mounted) {
            setState(
              () => _bufferingState =
                  'Unable to connect — ${Error.friendlyMessage(e)}',
            );
          }
          return; // bail out; user can press back
        }
        // Exponential-ish backoff capped at 5s
        final backoff = (_consecutiveOpenFailures * 1).clamp(1, 5);
        await Future.delayed(Duration(seconds: backoff));
      }
    }
  }

  @override
  void dispose() {
    _bufferingWatchdog?.cancel();
    for (final s in subscriptions) s.cancel();
    player.dispose();
    super.dispose();
  }

  Future<void> openSubtitlesModal() async {
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => SelectDialog(
        title: "Select subtitles",
        action: (id) async {
          player.setSubtitleTrack(player.state.tracks.subtitle[id]);
          Navigator.of(context).pop();
        },
        data: player.state.tracks.subtitle
            .asMap()
            .entries
            .map(
              (entry) => IdData(
                id: entry.key,
                data: entry.value.language != null
                    ? "${entry.value.language} - ${entry.value.id}"
                    : entry.value.id,
              ),
            )
            .toList(),
      ),
    );
  }

  Future<void> openAudioModal() async {
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => SelectDialog(
        title: "Select audio",
        action: (id) async {
          player.setAudioTrack(player.state.tracks.audio[id]);
          Navigator.of(context).pop();
        },
        data: player.state.tracks.audio
            .asMap()
            .entries
            .map(
              (entry) => IdData(
                id: entry.key,
                data:
                    entry.value.title ?? entry.value.language ?? entry.value.id,
              ),
            )
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        onExit();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            MaterialVideoControlsTheme(
              normal: getThemeData(context),
              fullscreen: getThemeData(context),
              child: Video(
                key: key,
                controller: videoController,
                onExitFullscreen: () async => onExit(),
              ),
            ),
            // Buffering / reconnecting overlay
            if (_bufferingState != null)
              Positioned(
                top: 24,
                right: 24,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _bufferingState!,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void onExit() async {
    if (exiting) return;
    exiting = true;
    _bufferingWatchdog?.cancel();
    if (widget.channel.mediaType == MediaType.movie) {
      // Tier 3, #19: actually await the position write before pop.
      await Sql.setPosition(
        widget.channel.id!,
        player.state.position.inSeconds,
      );
    }
    if (key.currentState?.isFullscreen() ?? false) {
      await key.currentState!.exitFullscreen();
    }
    if (mounted) Navigator.of(context).pop();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void toggleZoom() {
    final w = player.state.width;
    final h = player.state.height;
    if (w == null || h == null || w == 0 || h == 0) return;
    final videoAspectRatio = w / h;
    final deviceAspectRatio = MediaQuery.of(context).size.aspectRatio;
    key.currentState?.update(
      aspectRatio: fill ? videoAspectRatio : deviceAspectRatio,
    );
    setState(() {
      fill = !fill;
    });
  }

  MaterialVideoControlsThemeData getThemeData(BuildContext context) {
    return MaterialVideoControlsThemeData(
      speedUpOnLongPress: false,
      seekOnDoubleTap: widget.channel.mediaType != MediaType.livestream,
      displaySeekBar: widget.channel.mediaType != MediaType.livestream,
      seekBarMargin: const EdgeInsets.only(bottom: 60),
      seekBarThumbSize: 20,
      seekBarHeight: 10,
      seekGesture: widget.channel.mediaType != MediaType.livestream,
      topButtonBar: [
        IconButton(
          onPressed: onExit,
          icon: const Icon(Icons.arrow_back, color: Colors.white, size: 32),
        ),
        const SizedBox(width: 10),
        Text(widget.channel.name),
      ],
      bottomButtonBar: [
        IconButton(
          onPressed: openSubtitlesModal,
          icon: const Icon(Icons.subtitles, color: Colors.white, size: 32),
        ),
        SizedBox(width: 20),
        IconButton(
          onPressed: openAudioModal,
          icon: const Icon(Icons.music_note, color: Colors.white, size: 32),
        ),
        SizedBox(width: 20),
        IconButton(
          icon: Icon(
            Icons.aspect_ratio_outlined,
            color: Colors.white,
            size: 32,
          ),
          onPressed: toggleZoom,
        ),
      ],
    );
  }
}
