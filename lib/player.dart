import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/channel_tile.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/channel_http_headers.dart';
import 'package:open_tv/models/engine_type.dart';
import 'package:open_tv/models/id_data.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/player/cast_controller.dart';
import 'package:open_tv/player/engine_picker.dart';
import 'package:open_tv/player/overlay_player_controller.dart';
import 'package:open_tv/player/pip_controller.dart';
import 'package:open_tv/player/exo_engine.dart';
import 'package:open_tv/player/mpv_engine.dart';
import 'package:open_tv/player/player_engine.dart';
import 'package:open_tv/select_dialog.dart';

class Player extends StatefulWidget {
  final Channel channel;
  final Settings settings;
  final Source? source;
  /// Overrides the channel's normal live URL (e.g. catchup / time-shift URL).
  /// When set, the pre-warm cache is bypassed and ExoPlayer is never auto-selected.
  final String? overrideUrl;
  const Player({
    super.key,
    required this.channel,
    required this.settings,
    this.source,
    this.overrideUrl,
  });
  @override
  State<StatefulWidget> createState() => _PlayerState();
}

class _PlayerState extends State<Player> {
  late final EngineType _engineType;
  late final PlayerEngine _engine;

  bool exiting = false;
  bool fill = false;
  List<StreamSubscription<dynamic>> subscriptions = [];

  // Reconnect bookkeeping
  int _consecutiveOpenFailures = 0;
  static const int _maxOpenFailures = 6;
  Timer? _bufferingWatchdog;
  bool _isReconnecting = false;
  String? _bufferingState;

  // Cast state
  // True only when Play Services are present AND the stream format is
  // supported by the Default Media Receiver (HLS, DASH, MP4).
  // MPEG-TS, RTMP, and other formats are not castable — icon stays hidden.
  bool _castSupported = false;
  CastState _castState = CastState.unavailable;
  bool _isCasting = false;

  // PiP state
  bool _pipSupported = false;
  bool _inPipMode = false;

  @override
  void initState() {
    super.initState();
    _engineType = _pickEngine();
    _engine = _createEngine(_engineType);
    // Register so the overlay swap can pop this route and take over.
    OverlayPlayerController.instance.registerMain(
      widget.channel,
      widget.settings,
      widget.source,
    );
    initAsync();
  }

  EngineType _pickEngine() {
    // If there is a catchup override URL, always use libmpv so the full
    // feature set (seek, subtitles) is available for VOD-style playback.
    if (widget.overrideUrl != null) return EngineType.libmpv;
    return EnginePicker.pick(
      channel: widget.channel,
      settings: widget.settings,
      source: widget.source,
      url: widget.channel.url,
    );
  }

  PlayerEngine _createEngine(EngineType type) {
    return switch (type) {
      EngineType.exoplayer => ExoEngine(),
      _ => MpvEngine(channel: widget.channel, settings: widget.settings),
    };
  }

  Future<void> initAsync() async {
    // Check Cast + PiP availability in parallel with playback startup.
    final streamUrl = widget.overrideUrl ?? widget.channel.url ?? '';
    CastController.isAvailable().then((avail) {
      if (!mounted) return;
      final castable = avail && CastController.isCastable(streamUrl);
      setState(() => _castSupported = castable);
      if (avail) {
        CastController.getState().then((s) {
          if (!mounted) return;
          setState(() => _castState = s);
        });
      }
    });

    PipController.isSupported().then((supported) {
      if (!mounted) return;
      setState(() => _pipSupported = supported);
      if (supported) {
        subscriptions.add(
          PipController.pipModeStream.listen((inPip) {
            if (!mounted) return;
            setState(() => _inPipMode = inPip);
            if (!inPip) {
              // Returned from PiP — re-enter fullscreen if not engine-managed.
              if (!_engine.handlesOwnFullscreen) _enterSystemFullscreen();
            }
          }),
        );
      }
    });

    final channelId = widget.channel.id;
    final headers =
        channelId != null ? await Sql.getChannelHeaders(channelId) : null;
    final seconds = (widget.channel.mediaType == MediaType.movie &&
            channelId != null)
        ? await Sql.getPosition(channelId)
        : null;
    await _startPlayback(
      seconds != null ? Duration(seconds: seconds) : null,
      headers: headers,
    );

    subscriptions.add(
      _engine.completedStream.listen((completed) {
        if (completed) onDisconnect(reason: 'stream completed');
      }),
    );
    subscriptions.add(
      _engine.errorStream.listen((err) {
        debugPrint('player error: $err');
        onDisconnect(reason: 'player error: $err');
      }),
    );
    subscriptions.add(
      _engine.bufferingStream.listen(_onBufferingChanged),
    );
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

  String _playbackUrl() {
    if (widget.overrideUrl != null) return widget.overrideUrl!;
    final id = widget.channel.id;
    if (id != null) {
      final warmed = ChannelTile.prewarmedUrl(id);
      if (warmed != null) return warmed;
    }
    final url = widget.channel.url;
    if (url == null || url.isEmpty) {
      throw StateError('Channel "${widget.channel.name}" has no playback URL');
    }
    return url;
  }

  bool _isIgnoreSsl(ChannelHttpHeaders? headers) {
    final v = headers?.ignoreSSL;
    if (v == null) return false;
    return v == '1' || v.toLowerCase() == 'true';
  }

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
    final headers = await Sql.getChannelHeaders(widget.channel.id!);
    await _startPlayback(null, headers: headers);
    _isReconnecting = false;
  }

  Future<void> _startPlayback(
    Duration? startPosition, {
    ChannelHttpHeaders? headers,
  }) async {
    final timeout = Duration(seconds: widget.settings.openTimeoutSecs);
    while (true) {
      if (!mounted || exiting) return;
      try {
        final playbackUrl = _playbackUrl();
        final httpHeaders = headers != null
            ? {
                if (headers.referrer != null) 'Referer': headers.referrer!,
                if (headers.httpOrigin != null) 'Origin': headers.httpOrigin!,
                if (headers.userAgent != null) 'User-Agent': headers.userAgent!,
              }
            : null;

        if (_engine case final MpvEngine mpv) {
          await mpv.reapplyOptions(
            url: playbackUrl,
            ignoreSsl: _isIgnoreSsl(headers),
          );
        }

        await _engine
            .open(
              url: playbackUrl,
              startPosition: startPosition,
              headers: httpHeaders,
            )
            .timeout(
              timeout,
              onTimeout: () => throw TimeoutException(
                'engine.open() exceeded ${timeout.inSeconds}s',
              ),
            );

        _consecutiveOpenFailures = 0;
        unawaited(PipController.setPlaying(true));
        if (!_engine.handlesOwnFullscreen) {
          await _enterSystemFullscreen();
        }
        return;
      } catch (e) {
        _consecutiveOpenFailures++;
        debugPrint(
          'Playback failed ($_consecutiveOpenFailures/$_maxOpenFailures): $e',
        );
        if (_consecutiveOpenFailures >= _maxOpenFailures) {
          if (mounted) {
            setState(
              () => _bufferingState =
                  'Unable to connect — ${Error.friendlyMessage(e)}',
            );
          }
          return;
        }
        final backoff = (_consecutiveOpenFailures * 1).clamp(1, 5);
        await Future.delayed(Duration(seconds: backoff));
      }
    }
  }

  Future<void> _enterSystemFullscreen() async {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    OverlayPlayerController.instance.unregisterMain();
    PipController.setPlaying(false);
    _bufferingWatchdog?.cancel();
    for (final s in subscriptions) {
      s.cancel();
    }
    _engine.dispose();
    super.dispose();
  }

  // ── Cast ───────────────────────────────────────────────────────────────────

  Future<void> _onCastTap() async {
    if (!_castSupported) return;

    final url = _playbackUrl();

    if (_castState == CastState.connected || _isCasting) {
      // Already casting — offer to stop
      final stop = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Stop casting?'),
          content: const Text(
            'This will stop casting and resume local playback.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Stop'),
            ),
          ],
        ),
      );
      if (stop == true) {
        final resumePosition = await CastController.getPosition();
        await CastController.stopCast();
        setState(() {
          _isCasting = false;
          _castState = CastState.notConnected;
        });
        // Resume locally from Cast-reported position
        await _engine.open(
          url: url,
          startPosition: resumePosition,
        );
      }
      return;
    }

    if (_castState != CastState.connected) {
      // Show device picker first; user connects, then they tap Cast again.
      await CastController.showDevicePicker();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Select a device, then tap the Cast button again to cast.'),
          ),
        );
      }
      // Refresh state after picker closes
      final newState = await CastController.getState();
      if (mounted) setState(() => _castState = newState);
      return;
    }

    // Connected — begin casting
    try {
      final ok = await CastController.startCast(
        url: url,
        title: widget.channel.name,
        contentType: CastController.mimeTypeFor(url),
      );
      if (ok && mounted) {
        setState(() => _isCasting = true);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cast session not ready — try again.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cast error: $e')),
        );
      }
    }
  }

  IconData get _castIcon {
    if (_isCasting) return Icons.cast_connected;
    if (_castState == CastState.noDevices) return Icons.cast_outlined;
    return Icons.cast;
  }

  // ── Track selection ────────────────────────────────────────────────────────

  Future<void> openSubtitlesModal() async {
    final tracks = _engine.subtitleTracks;
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => SelectDialog(
        title: 'Select subtitles',
        action: (id) async {
          await _engine.setSubtitleTrack(id);
          if (context.mounted) Navigator.of(context).pop();
        },
        data: tracks
            .map((t) => IdData(id: t.index, data: t.label))
            .toList(),
      ),
    );
  }

  Future<void> openAudioModal() async {
    final tracks = _engine.audioTracks;
    await showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => SelectDialog(
        title: 'Select audio',
        action: (id) async {
          await _engine.setAudioTrack(id);
          if (context.mounted) Navigator.of(context).pop();
        },
        data: tracks
            .map((t) => IdData(id: t.index, data: t.label))
            .toList(),
      ),
    );
  }

  // ── Zoom toggle (mpv only) ─────────────────────────────────────────────────

  void toggleZoom() {
    final engine = _engine;
    if (engine is! MpvEngine) return;
    final mpv = engine;
    final w = mpv.videoWidth;
    final h = mpv.videoHeight;
    if (w == null || h == null || w == 0 || h == 0) return;
    final videoAspectRatio = w / h;
    final deviceAspectRatio = MediaQuery.of(context).size.aspectRatio;
    mpv.updateAspectRatio(fill ? videoAspectRatio : deviceAspectRatio);
    setState(() => fill = !fill);
  }

  // ── Mini-player ────────────────────────────────────────────────────────────

  /// Sends the current channel to the floating overlay and pops this route.
  Future<void> _minimizeToOverlay() async {
    await OverlayPlayerController.instance.startOverlay(
      widget.channel,
      widget.settings,
      widget.source,
    );
    if (mounted) onExit();
  }

  // ── Exit ───────────────────────────────────────────────────────────────────

  void onExit() async {
    if (exiting) return;
    exiting = true;
    unawaited(PipController.setPlaying(false));
    _bufferingWatchdog?.cancel();
    if (widget.channel.mediaType == MediaType.movie) {
      await Sql.setPosition(
        widget.channel.id!,
        _engine.position.inSeconds,
      );
    }
    if (_engine.handlesOwnFullscreen && _engine.isFullscreen) {
      await _engine.exitFullscreen();
    }
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (mounted) Navigator.of(context).pop();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // In PiP mode: render only the video — no controls, no overlays, no gestures.
    if (_inPipMode) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox.expand(
          child: _engine.buildVideoView(context),
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) => onExit(),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            _buildVideoArea(),
            if (_bufferingState != null) _buildBufferingOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoArea() {
    if (_engineType == EngineType.exoplayer ||
        (_engineType == EngineType.auto &&
            _engine is ExoEngine)) {
      // ExoPlayer path: plain video widget + our own controls overlay
      return Stack(
        children: [
          Center(child: _engine.buildVideoView(context)),
          _buildExoControls(),
        ],
      );
    }

    // libmpv path: use media_kit_video's full controls theme
    return MaterialVideoControlsTheme(
      normal: _mpvThemeData(context),
      fullscreen: _mpvThemeData(context),
      child: _engine.buildVideoView(context),
    );
  }

  /// Minimal controls overlay for the ExoPlayer path (no media_kit_video).
  Widget _buildExoControls() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {},
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Top bar
            Container(
              color: Colors.black54,
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    onPressed: onExit,
                    icon: const Icon(
                      Icons.arrow_back,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.channel.name,
                      style: const TextStyle(color: Colors.white),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_castSupported)
                    IconButton(
                      onPressed: _onCastTap,
                      icon: Icon(_castIcon, color: Colors.white, size: 28),
                      tooltip: _isCasting ? 'Stop casting' : 'Cast to TV',
                    ),
                  if (_pipSupported)
                    IconButton(
                      onPressed: () => PipController.enterPip(),
                      icon: const Icon(
                        Icons.picture_in_picture_alt,
                        color: Colors.white,
                        size: 28,
                      ),
                      tooltip: 'Picture-in-picture',
                    ),
                  if (widget.channel.mediaType == MediaType.livestream)
                    IconButton(
                      onPressed: _minimizeToOverlay,
                      icon: const Icon(
                        Icons.picture_in_picture,
                        color: Colors.white,
                        size: 28,
                      ),
                      tooltip: 'Watch in mini-player',
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBufferingOverlay() {
    return Positioned(
      top: 24,
      right: 24,
      child: IgnorePointer(
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
    );
  }

  MaterialVideoControlsThemeData _mpvThemeData(BuildContext context) {
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
        const Spacer(),
        if (_castSupported)
          IconButton(
            onPressed: _onCastTap,
            icon: Icon(_castIcon, color: Colors.white, size: 28),
            tooltip: _isCasting ? 'Stop casting' : 'Cast to TV',
          ),
        if (_pipSupported)
          IconButton(
            onPressed: () => PipController.enterPip(),
            icon: const Icon(
              Icons.picture_in_picture_alt,
              color: Colors.white,
              size: 28,
            ),
            tooltip: 'Picture-in-picture',
          ),
        if (widget.channel.mediaType == MediaType.livestream)
          IconButton(
            onPressed: _minimizeToOverlay,
            icon: const Icon(
              Icons.picture_in_picture,
              color: Colors.white,
              size: 28,
            ),
            tooltip: 'Watch in mini-player',
          ),
      ],
      bottomButtonBar: [
        if (_engine.supportsTrackSelection) ...[
          IconButton(
            onPressed: openSubtitlesModal,
            icon:
                const Icon(Icons.subtitles, color: Colors.white, size: 32),
          ),
          const SizedBox(width: 20),
          IconButton(
            onPressed: openAudioModal,
            icon:
                const Icon(Icons.music_note, color: Colors.white, size: 32),
          ),
          const SizedBox(width: 20),
        ],
        IconButton(
          icon: const Icon(
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
