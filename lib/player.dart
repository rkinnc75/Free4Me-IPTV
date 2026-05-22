import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/channel_tile.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/channel_http_headers.dart';
import 'package:open_tv/models/engine_type.dart';
import 'package:open_tv/models/id_data.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/multi_view_layout.dart';
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

  /// Channels that recently hit max reconnects. Maps channel ID → DateTime
  /// when the give-up occurred. New Player widgets respect a cooldown before
  /// retrying, preventing rapid re-open loops when the provider is
  /// rate-limiting. Static so it persists across widget rebuilds.
  static final Map<int, DateTime> _recentGiveUps = {};
  static const Duration _giveUpCooldown = Duration(seconds: 60);

  /// Removes any active give-up cooldown entry for [channelId].
  ///
  /// Called before promoting an overlay (mini-player) channel to full screen,
  /// since the overlay's active playback proves the stream is live and any
  /// stale cooldown record from an earlier attempt would needlessly block
  /// the fresh full-screen Player. Idempotent and null-safe.
  static void clearCooldown(int? channelId) {
    if (channelId == null) return;
    if (_recentGiveUps.remove(channelId) != null) {
      AppLog.info('Player: cleared stale cooldown for channel id=$channelId');
    }
  }

  @override
  State<StatefulWidget> createState() => _PlayerState();
}

class _PlayerState extends State<Player> {
  // Reassignable so a mid-flight engine swap (ExoPlayer → libmpv fallback)
  // can replace the active engine without rebuilding the whole route.
  late EngineType _engineType;
  late PlayerEngine _engine;

  bool exiting = false;
  bool fill = false;
  List<StreamSubscription<dynamic>> subscriptions = [];

  /// Subscriptions specifically tied to [_engine]'s streams (errorStream,
  /// bufferingStream, completedStream). Tracked separately from
  /// [subscriptions] so we can cancel and re-subscribe when swapping engines
  /// mid-flight (e.g. ExoPlayer → libmpv fallback).
  final List<StreamSubscription<dynamic>> _engineSubs = [];

  /// True after a one-shot ExoPlayer → libmpv fallback has fired for this
  /// Player widget. Prevents an infinite swap loop if both engines fail.
  bool _exoFallbackTried = false;

  // Reconnect bookkeeping
  int _consecutiveOpenFailures = 0;
  static const int _maxOpenFailures = 6;
  // Counts every onDisconnect() call regardless of path (catches the async
  // error path that bypasses _consecutiveOpenFailures). Only reset after
  // the stream is confirmed stable for _stableThresholdSecs seconds — a
  // brief buffering=false right after open() does NOT count as "stable".
  int _totalReconnectAttempts = 0;
  static const int _maxReconnectAttempts = 6;

  Timer? _bufferingWatchdog;
  Timer? _stableTimer;
  bool _isReconnecting = false;
  String? _bufferingState;
  // Suppresses false reconnect triggers during the first 3s after open().
  bool _startupGrace = false;

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
    AppLog.info('Player: engine=$_engineType channel="${widget.channel.name}"');
    _engine = _createEngine(_engineType);
    // Register so the overlay swap can pop this route and take over.
    OverlayPlayerController.instance.registerMain(
      widget.channel,
      widget.settings,
      widget.source,
      _engine,
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
    // Check cross-session give-up cooldown before attempting playback.
    // When a channel hits max reconnects, a 60s cooldown is recorded in the
    // static _recentGiveUps map. If the user navigates away and back within
    // that window, a new widget instance would otherwise reset all state and
    // immediately hammer a rate-limited provider again.
    final giveUpChannelId = widget.channel.id;
    if (giveUpChannelId != null) {
      final gaveUp = Player._recentGiveUps[giveUpChannelId];
      if (gaveUp != null) {
        final elapsed = DateTime.now().difference(gaveUp);
        if (elapsed < Player._giveUpCooldown) {
          final remaining = (Player._giveUpCooldown - elapsed).inSeconds;
          AppLog.warn(
            'Player: cooldown active for "${widget.channel.name}"'
            ' — ${remaining}s remaining',
          );
          if (mounted) {
            setState(() => _bufferingState =
                'Stream unavailable — please wait ${remaining}s before retrying');
          }
          return;
        } else {
          // Cooldown expired — clear the record and allow a fresh attempt.
          Player._recentGiveUps.remove(giveUpChannelId);
          AppLog.info(
            'Player: cooldown expired for "${widget.channel.name}" — retrying',
          );
        }
      }
    }

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

    _subscribeEngineStreams();
    subscriptions.add(
      Connectivity().onConnectivityChanged.listen((results) {
        final hasNet =
            results.isNotEmpty && !results.contains(ConnectivityResult.none);
        if (hasNet && _isReconnecting) {
          AppLog.info('Player: network restored; reconnecting...');
          onDisconnect(reason: 'network restored');
        }
      }),
    );
  }

  /// Subscribe to the current [_engine]'s lifecycle streams. Safe to call
  /// after a mid-flight engine swap — cancels any prior engine subscriptions
  /// first.
  void _subscribeEngineStreams() {
    for (final s in _engineSubs) {
      s.cancel();
    }
    _engineSubs.clear();

    _engineSubs.add(_engine.completedStream.listen((completed) {
      if (!completed || _startupGrace) return;
      final delayMs = widget.settings.streamCompletedDelayMs;
      if (delayMs > 0) {
        Future.delayed(Duration(milliseconds: delayMs), () {
          if (mounted && !exiting && !_isReconnecting) {
            onDisconnect(reason: 'stream completed');
          }
        });
      } else {
        onDisconnect(reason: 'stream completed');
      }
    }));
    _engineSubs.add(_engine.errorStream.listen((err) {
      AppLog.warn('Player: engine error — $err');

      // Suppress the mpv seekability probe error unconditionally.
      // mpv probes seekability on every open() and MPEG-TS livestreams
      // always reject it with "Cannot seek in this stream." — the stream
      // plays fine regardless. This error is purely informational and
      // should never trigger a reconnect at any point during playback.
      // mpv emits two messages on every seek rejection:
      //   1. "Cannot seek in this stream."
      //   2. "You can force it with '--force-seekable=yes'."
      // Both arrive on errorStream — suppress both unconditionally.
      if (err.contains('Cannot seek in this stream') ||
          err.contains('force-seekable=yes')) {
        AppLog.info(
          'Player: suppressed seek probe error'
          ' channel="${widget.channel.name}"',
        );
        return;
      }

      final isPermanent = err.contains('Failed to open') ||
          err.contains('404') ||
          err.contains('403') ||
          err.contains('Connection refused');
      AppLog.warn(
        'Player: engine error [${isPermanent ? "permanent" : "transient"}]'
        ' — "$err" channel="${widget.channel.name}"',
      );
      // onDisconnect() is the single source of truth for incrementing
      // _totalReconnectAttempts — do not pre-increment here, which caused
      // the counter to jump by 2 per failure and exceed _maxReconnectAttempts.
      onDisconnect(reason: 'player error: $err');
    }));
    _engineSubs.add(_engine.bufferingStream.listen(_onBufferingChanged));
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
    AppLog.info('Player: buffering=$buffering channel="${widget.channel.name}"');
    if (buffering) {
      _stableTimer?.cancel(); // stream is no longer stable
      if (mounted) setState(() => _bufferingState = 'Buffering...');
      // During startup grace the indicator is shown but the watchdog is
      // suppressed — prevents reconnect loops while the stream stabilises.
      if (!_startupGrace && widget.channel.mediaType == MediaType.livestream) {
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

      // Expire startup grace 500ms after buffering=false. The mpv seek probe
      // fires at the same instant as buffering=false — delaying expiry ensures
      // the suppression guard in errorStream catches it regardless of event
      // delivery order between the two streams (separate native callbacks,
      // Dart delivery order not guaranteed within the same native event cycle).
      if (_startupGrace) {
        Future.delayed(
          Duration(milliseconds: widget.settings.startupGraceMs),
          () {
            if (mounted) setState(() => _startupGrace = false);
          },
        );
      }

      // Start a stability timer. Only if the stream is still playing after
      // _stableThresholdSecs do we reset the reconnect counters — this
      // prevents the brief buffering=false that follows every open() from
      // zeroing the counter before the async "Failed to open" fires.
      _stableTimer?.cancel();
      final stableSecs = widget.settings.stableThresholdSecs;
      _stableTimer = Timer(
        Duration(seconds: stableSecs),
        () {
          if (mounted && !exiting) {
            AppLog.info(
              'Player: stream stable for ${stableSecs}s'
              ' — resetting reconnect counters'
              ' channel="${widget.channel.name}"',
            );
            _totalReconnectAttempts = 0;
            _consecutiveOpenFailures = 0;
          }
        },
      );
    }
  }

  void onDisconnect({String reason = 'unknown'}) async {
    if (!mounted || exiting || _isReconnecting) return;
    if (widget.channel.mediaType != MediaType.livestream) return;

    // Set synchronously before any await so that a second onDisconnect call
    // arriving in the same event-loop tick is rejected by the guard above.
    _isReconnecting = true;
    _totalReconnectAttempts++;
    AppLog.warn(
      'Player: onDisconnect — attempt $_totalReconnectAttempts/$_maxReconnectAttempts'
      ' reconnecting=$_isReconnecting'
      ' openFailures=$_consecutiveOpenFailures'
      ' startupGrace=$_startupGrace'
      ' reason="$reason" channel="${widget.channel.name}"',
    );

    if (_totalReconnectAttempts >= _maxReconnectAttempts) {
      AppLog.warn(
        'Player: max reconnects reached — giving up on "${widget.channel.name}"',
      );
      // Record cooldown so fresh widget instances (user re-navigates to the
      // channel) don't immediately hammer a rate-limited provider again.
      final channelId = widget.channel.id;
      if (channelId != null) Player._recentGiveUps[channelId] = DateTime.now();

      // Stop all background activity so the watchdog, errorStream, and
      // completedStream listeners no-op — prevents automatic re-open after
      // give-up when a background timer fires.
      exiting = true;
      _bufferingWatchdog?.cancel();
      _bufferingWatchdog = null;
      _stableTimer?.cancel();
      _stableTimer = null;
      if (mounted) {
        setState(() => _bufferingState =
            'Stream unavailable — too many failed attempts. Try again shortly.');
      }
      return;
    }

    AppLog.info('Player: reconnect — $reason');
    if (mounted) setState(() => _bufferingState = 'Reconnecting...');
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted || exiting) {
      _isReconnecting = false;
      return;
    }
    final id = widget.channel.id;
    if (id == null) {
      _isReconnecting = false;
      return;
    }
    final headers = await Sql.getChannelHeaders(id);
    await _startPlayback(null, headers: headers);
    _isReconnecting = false;
  }

  Future<void> _startPlayback(
    Duration? startPosition, {
    ChannelHttpHeaders? headers,
  }) async {
    _startupGrace = false; // Reset on every attempt (including retries)
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

        _startupGrace = true;
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
        AppLog.info(
          'Player: open() succeeded — engine=$_engineType url="$playbackUrl"',
        );
        // Grace expires 500ms after buffering=false in _onBufferingChanged(),
        // not on a fixed timer anchored to open(). The seek probe fires
        // relative to buffering=false — anchoring to open() caused grace to
        // expire before the error arrived when buffering took >3s.
        unawaited(PipController.setPlaying(true));
        if (!_engine.handlesOwnFullscreen) {
          await _enterSystemFullscreen();
        }
        return;
      } catch (e) {
        _startupGrace = false;
        _consecutiveOpenFailures++;
        final errStr = e.toString();

        // One-shot ExoPlayer → libmpv fallback. ExoPlayer emits a generic
        // "Source error" / "VideoError" for streams whose codec or container
        // it cannot demux (most commonly IPTV MPEG-TS variants on Android TV
        // hardware where the codec/surface combination fails). Five more
        // retries on the same engine will not change that — switch to libmpv
        // immediately and let it try.
        if (!_exoFallbackTried &&
            _engineType == EngineType.exoplayer &&
            _isExoSourceError(errStr)) {
          _exoFallbackTried = true;
          AppLog.warn(
            'Player: ExoPlayer source error — falling back to libmpv'
            ' channel="${widget.channel.name}" — $errStr',
          );
          await _swapEngine(EngineType.libmpv);
          if (!mounted || exiting) return;
          _consecutiveOpenFailures = 0;
          continue;
        }

        AppLog.warn(
          'Player: open() failed ($_consecutiveOpenFailures/$_maxOpenFailures)'
          ' — $e — channel="${widget.channel.name}"',
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

  /// True for the family of ExoPlayer errors that mean "I can't play this
  /// stream's codec/container", as opposed to network failures or 4xx
  /// responses. We use these to trigger the libmpv fallback rather than
  /// burn through the open-retry budget on a fundamentally incompatible
  /// engine choice.
  bool _isExoSourceError(String err) {
    return err.contains('Source error') ||
        err.contains('VideoError') ||
        err.contains('ExoPlaybackException');
  }

  /// Mid-flight engine swap. Cancels the current engine's stream
  /// subscriptions, disposes it, instantiates [type], re-registers with the
  /// overlay controller, and re-subscribes to lifecycle streams. Triggers a
  /// rebuild so [_buildVideoArea] picks up the new engine widget.
  Future<void> _swapEngine(EngineType type) async {
    for (final s in _engineSubs) {
      await s.cancel();
    }
    _engineSubs.clear();
    await _engine.dispose();
    _engineType = type;
    _engine = _createEngine(type);
    OverlayPlayerController.instance.registerMain(
      widget.channel,
      widget.settings,
      widget.source,
      _engine,
    );
    _subscribeEngineStreams();
    if (mounted) setState(() {});
    AppLog.info('Player: swapped engine → $type');
  }

  @override
  void dispose() {
    // Pass our engine so that if a new Player already called registerMain
    // during a swap transition, we don't accidentally wipe its registration.
    OverlayPlayerController.instance.unregisterMain(_engine);
    unawaited(PipController.setPlaying(false));
    _bufferingWatchdog?.cancel();
    _stableTimer?.cancel();
    for (final s in subscriptions) {
      s.cancel();
    }
    for (final s in _engineSubs) {
      s.cancel();
    }
    _engineSubs.clear();
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
        // Resume locally from Cast-reported position.
        // reapplyOptions() must precede open() since open() no longer
        // calls _applyMpvOptions() internally (fix6).
        if (_engine case final MpvEngine mpv) {
          await mpv.reapplyOptions(url: url);
        }
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
      final id = widget.channel.id;
      if (id != null) {
        await Sql.setPosition(id, _engine.position.inSeconds);
      }
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
    if (_engineType == EngineType.exoplayer) {
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
                  if (_pipSupported &&
                      widget.settings.multiViewLayout ==
                          MultiViewLayout.none)
                    IconButton(
                      onPressed: () => PipController.enterPip(),
                      icon: const Icon(
                        Icons.picture_in_picture_alt,
                        color: Colors.white,
                        size: 28,
                      ),
                      tooltip: 'Picture-in-picture',
                    ),
                ],
              ),
            ),
            // Bottom bar — mini-player button (hidden when multi-view is
            // active; the overlay would float on top of the grid and serve
            // no useful purpose).
            if (widget.channel.mediaType == MediaType.livestream &&
                widget.settings.multiViewLayout == MultiViewLayout.none)
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8, right: 4),
                  child: IconButton(
                    onPressed: _minimizeToOverlay,
                    icon: const Icon(
                      Icons.picture_in_picture,
                      color: Colors.white,
                      size: 28,
                    ),
                    tooltip: 'Watch in mini-player',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBufferingOverlay() {
    final message = _bufferingState!;
    // Cooldown / give-up states ("please wait …", "Unable to connect …") are
    // terminal — we are not actively buffering anymore. Show a Go Back button
    // so the user can leave the dead channel without going through system
    // back, and drop the spinner since nothing is in progress.
    final isTerminal = message.contains('please wait') ||
        message.startsWith('Unable to connect');

    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isTerminal) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 10),
          ] else ...[
            const Icon(Icons.info_outline, color: Colors.white, size: 16),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Text(
              message,
              style: const TextStyle(color: Colors.white),
            ),
          ),
          if (isTerminal) ...[
            const SizedBox(width: 12),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 32),
              ),
              child: const Text('Go back'),
            ),
          ],
        ],
      ),
    );

    return Positioned(
      top: 24,
      right: 24,
      child: isTerminal ? card : IgnorePointer(child: card),
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
        if (_pipSupported &&
            widget.settings.multiViewLayout == MultiViewLayout.none)
          IconButton(
            onPressed: () => PipController.enterPip(),
            icon: const Icon(
              Icons.picture_in_picture_alt,
              color: Colors.white,
              size: 28,
            ),
            tooltip: 'Picture-in-picture',
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
        // Mini-player button — hidden when multi-view is active.
        if (widget.channel.mediaType == MediaType.livestream &&
            widget.settings.multiViewLayout == MultiViewLayout.none) ...[
          const Spacer(),
          IconButton(
            onPressed: _minimizeToOverlay,
            icon: const Icon(
              Icons.picture_in_picture,
              color: Colors.white,
              size: 32,
            ),
            tooltip: 'Watch in mini-player',
          ),
        ],
      ],
    );
  }
}
