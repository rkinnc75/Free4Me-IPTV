import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/conn_timing.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/widgets/player_epg_now_label.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/channel_tile.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/channel_http_headers.dart';
import 'package:open_tv/models/playback_playlist.dart';
import 'package:open_tv/models/id_data.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/multi_view_layout.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/zoom_mode.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/player/cast_controller.dart';
import 'package:open_tv/player/overlay_player_controller.dart';
import 'package:open_tv/player/pip_controller.dart';
import 'package:open_tv/player/mpv_engine.dart';
import 'package:open_tv/player/player_engine.dart';
import 'package:open_tv/select_dialog.dart';

/// fix380: pure predicate extracted for unit testing. Mirrors
/// `MultiViewCell._isSeekProbeError` (lib/multi_view_cell.dart:393).
/// Returns true if [err] is the benign mpv seekability probe
/// ("Cannot seek in this stream." / "force-seekable=yes") that mpv
/// emits on non-seekable MPEG-TS livestreams. The probe is expected
/// during startup grace; after grace, the same string comes from
/// user-seek attempts and is also benign (just a user error) but
/// should not be logged per occurrence.
bool isSeekProbeError(String err) {
  return err.contains('Cannot seek in this stream') ||
      err.contains('force-seekable=yes');
}

class Player extends StatefulWidget {
  final Channel channel;
  final Settings settings;
  final Source? source;
  /// Overrides the channel's normal live URL (e.g. catchup / time-shift URL).
  /// When set, the pre-warm cache is bypassed.
  final String? overrideUrl;
  /// fix116: an already-open, already-playing engine to adopt instead of
  /// creating and opening a new one. Used by the swap path so the promoted
  /// channel's stream is never closed/reopened (which stalled ~10s on some
  /// streams). When non-null, initState adopts it and initAsync skips the
  /// open/_startPlayback step.
  final PlayerEngine? adoptEngine;
  /// fix397: the ordered list this stream was launched from (search results,
  /// a category, favorites, browse…) plus the playing index. When non-null and
  /// it has another playable channel, the player offers channel +/- (on-screen
  /// ▲/▼ and the remote CH+/CH− keys) to surf the list. Null = no surfing
  /// (e.g. launched from a context without a list, like a catchup URL).
  final PlaybackPlaylist? playlist;
  const Player({
    super.key,
    required this.channel,
    required this.settings,
    this.source,
    this.overrideUrl,
    this.adoptEngine,
    this.playlist,
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

class _PlayerState extends State<Player> with WidgetsBindingObserver {
  late PlayerEngine _engine;

  bool exiting = false;
  /// Guards onExit() against double-pop, independent of [exiting].
  /// [exiting] is set early by the max-reconnect path to silence engine
  /// listeners; using it as the onExit guard meant the back button was
  /// dead on the stuck buffering screen (fixed in fix90).
  bool _exitInvoked = false;
  /// fix110: tracks whether _engine has been disposed, so dispose() can
  /// avoid a double-dispose WITHOUT skipping disposal on the onExit path.
  /// (fix106.4 used `exiting` for this, but onExit sets exiting=true
  /// without disposing the engine — that left the engine alive and audio
  /// playing after back was pressed.)
  bool _engineDisposed = false;
  /// fix116: true when this Player adopted a pre-playing engine (swap).
  /// Skips the open/_startPlayback step.
  bool _adopted = false;
  // fix130: when true, build renders a plain black box instead of the
  // media_kit Video, unmounting the Texture so no stale frame composites
  // during exit teardown.
  bool _videoDetached = false;
  Orientation? _lastOrientation; // fix136: rotation logging
  // fix404: video-fit mode for the player surface (replaces the pre-fix404
  // `bool fill` two-state toggle). Cycles fit → stretch → crop on each tap
  // of the aspect-ratio icon. Session-only — resets to fit on app restart.
  // Multi-view cells inherit this mode via the engine (no per-cell override).
  ZoomMode _zoomMode = ZoomMode.fit;
  List<StreamSubscription<dynamic>> subscriptions = [];

  // fix397: channel +/- ("surf"). To avoid touching the playback state machine
  // (the channel is referenced ~55 places), a channel change re-launches a
  // fresh Player via pushReplacement rather than mutating in place. Rapid
  // presses are coalesced: each press advances [_surfTargetIndex] and shows the
  // target name in [_surfBanner]; the actual switch fires [_surfDebounce] after
  // the last press, so holding CH+ doesn't open every intermediate stream.
  int? _surfTargetIndex;
  String? _surfBanner;
  Timer? _surfTimer;
  final FocusNode _surfKeyFocus = FocusNode(debugLabel: 'playerChannelKeys');
  static const Duration _surfDebounce = Duration(milliseconds: 650);

  /// Subscriptions specifically tied to [_engine]'s streams (errorStream,
  /// bufferingStream, completedStream). Tracked separately from
  /// [subscriptions] so engine teardown can cancel exactly its own listeners.
  final List<StreamSubscription<dynamic>> _engineSubs = [];

  // Reconnect bookkeeping
  int _consecutiveOpenFailures = 0;
  /// fix112: whether the most recent engine error arrived "instantly"
  /// after open (within ~2s) — the signature of a provider refusing a
  /// concurrent connection on a connection-limited account.
  bool _lastFailureWasInstant = false;
  DateTime? _lastOpenAt;
  // fix96: open-failure limit now follows the user's maxReconnectAttempts
  // setting instead of a separate hardcoded 6. One knob controls both
  // failure modes (open() threw, and opened-then-dropped).
  // Counts every onDisconnect() call regardless of path (catches the async
  // error path that bypasses _consecutiveOpenFailures). Only reset after
  // the stream is confirmed stable for _stableThresholdSecs seconds — a
  // brief buffering=false right after open() does NOT count as "stable".
  int _totalReconnectAttempts = 0;

  Timer? _bufferingWatchdog;
  /// fix94: covers the gap between open() success and the first frame.
  /// A dead stream can return open-success then never emit any buffering
  /// event, so _bufferingWatchdog (armed only on buffering=true) never
  /// arms. This fires if no playback signal arrives in time.
  Timer? _startupWatchdog;
  Timer? _stableTimer;
  bool _isReconnecting = false;
  String? _bufferingState;
  // Suppresses false reconnect triggers during the first 3s after open().
  bool _startupGrace = false;
  // fix380: latched once the startup seek probe has been logged. Stops the
  // "suppressed seek probe error" log line from firing per user-seek (after
  // grace, every "Cannot seek" rejection was being mislabelled as a probe).
  bool _seekProbeLogged = false;

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
    WidgetsBinding.instance.addObserver(this); // fix136
    final adopt = widget.adoptEngine;
    if (adopt is MpvEngine) {
      // fix116: adopt the already-playing engine from the swap. No create,
      // no open — the stream stays live, avoiding the reopen stall.
      _engine = adopt;
      _adopted = true;
      AppLog.info(
        'Player: ADOPTED engine eid=${identityHashCode(adopt)}'
        ' channel="${widget.channel.name}"',
      );
    } else {
      _engine = MpvEngine(
        channel: widget.channel,
        settings: widget.settings,
        // fix357: live DVR buffer only for genuine live full-screen playback
        // (never catch-up; mini-player and multi-view construct elsewhere).
        dvrEligible: widget.overrideUrl == null,
      );
      AppLog.info(
        'Player: CREATED engine eid=${identityHashCode(_engine)}'
        ' channel="${widget.channel.name}"',
      );
    }
    // fix422: restore the user's last-chosen single-cell full-screen video
    // fit (fit/stretch/crop) so it opens in their preference, not always fit.
    _zoomMode = widget.settings.playerZoomMode;
    if (_engine is MpvEngine) {
      (_engine as MpvEngine).setZoomMode(_zoomMode.boxFit);
    }
    // Register so the overlay swap can pop this route and take over.
    OverlayPlayerController.instance.registerMain(
      widget.channel,
      widget.settings,
      widget.source,
      _engine,
    );
    // fix106: let the swap path halt this player synchronously before
    // pushReplacement so it cannot fire a background reconnect.
    OverlayPlayerController.instance.registerMainHalt(haltForSwap);
    // fix116: register detach callback so swap can hand the live engine off
    // to the overlay without disposing it.
    OverlayPlayerController.instance.registerMainDetach(detachForSwap);
    initAsync();
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
              // fix414: returning from PiP — give the stream a fresh set of
              // hardware-decode attempts in full-screen. While minimized we
              // never gave up and were on forced software decode; reset the
              // counter so the normal give-up/exit logic applies from scratch.
              _totalReconnectAttempts = 0;
              // Returned from PiP — re-enter fullscreen if not engine-managed.
              if (!_engine.handlesOwnFullscreen) _enterSystemFullscreen();
            }
          }),
        );
      }
    });

    if (_adopted) {
      // fix116: engine is already open and playing — just wire up its
      // lifecycle streams and ensure full volume. No _startPlayback.
      // fix126: give the adopted engine a fresh video key so the new
      // full-screen Video mounts a clean VideoState (own texture) rather
      // than reparenting the mini's State via the shared GlobalKey.
      if (_engine is MpvEngine) (_engine as MpvEngine).onAdopt();
      AppLog.info('Player: initAsync adopt path — skipping open'
          ' eid=${identityHashCode(_engine)}'
          ' channel="${widget.channel.name}"');
      _subscribeEngineStreams();
      AppLog.info('Player: re-subscribed engine streams (adopt)'
          ' eid=${identityHashCode(_engine)}');
      await _engine.setVolume(1.0);
      AppLog.info('Player: adopt volume=1.0 set'
          ' eid=${identityHashCode(_engine)}');
      return;
    }

    final channelId = widget.channel.id;
    final headers =
        channelId != null ? await Sql.getChannelHeaders(channelId) : null;
    final seconds = (widget.channel.mediaType == MediaType.movie &&
            channelId != null)
        ? await Sql.getPosition(channelId)
        : null;
    // fix345 (review CRIT-2): subscribe to the engine's streams BEFORE the
    // first open(). The engine's controllers are broadcast — any buffering or
    // liveness event emitted DURING open() was previously dropped because the
    // Player only subscribed after _startPlayback returned, which could
    // strand the startup watchdog on a healthy stream. _subscribeEngineStreams
    // is idempotent (cancels + re-adds), so the fallback/swap paths that call
    // it again are unaffected.
    _subscribeEngineStreams();
    await _startPlayback(
      seconds != null ? Duration(seconds: seconds) : null,
      headers: headers,
    );
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
      // fix380: log at most once per open() — the *startup* probe is the
      // one worth noting (it confirms the engine is probing seekability
      // correctly). Subsequent rejections are user-seek failures and were
      // being mislabelled as "suppressed seek probe error" — that label
      // was the source of the per-user-seek log flood. User-seek
      // failures are now silent (no log, no reconnect).
      if (isSeekProbeError(err)) {
        if (_startupGrace && !_seekProbeLogged) {
          _seekProbeLogged = true;
          AppLog.info(
            'Player: startup seek probe suppressed'
            ' channel="${widget.channel.name}"',
          );
        }
        return;
      }

      final isPermanent = err.contains('Failed to open') ||
          err.contains('404') ||
          err.contains('403') ||
          err.contains('Connection refused');
      // fix112: an instant "Failed to open" (within ~2s of the open call)
      // is the signature of a connection-limit rejection — the provider
      // refused because the single allowed connection is in use elsewhere
      // (another device, or this device's previous stream not yet released).
      final sinceOpen = _lastOpenAt == null
          ? Duration.zero
          : DateTime.now().difference(_lastOpenAt!);
      _lastFailureWasInstant = isPermanent &&
          err.contains('Failed to open') &&
          sinceOpen.inSeconds <= 2;
      AppLog.warn(
        'Player: engine error [${isPermanent ? "permanent" : "transient"}]'
        '${_lastFailureWasInstant ? " (instant — possible connection limit)" : ""}'
        ' — "$err" channel="${widget.channel.name}"',
      );
      // onDisconnect() is the single source of truth for incrementing
      // _totalReconnectAttempts — do not pre-increment here, which caused
      // the counter to jump by 2 per failure and exceed widget.settings.maxReconnectAttempts.
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
    // fix94: first buffering signal means the engine is alive — the
    // startup watchdog has done its job, hand off to the normal timers.
    if (_startupWatchdog != null) {
      _startupWatchdog!.cancel();
      _startupWatchdog = null;
      AppLog.info(
        'Player: startup watchdog cancelled (buffering=$buffering)'
        ' channel="${widget.channel.name}"',
      );
    }
    AppLog.info('Player: buffering=$buffering channel="${widget.channel.name}"');
    if (buffering) {
      _stableTimer?.cancel(); // stream is no longer stable
      if (mounted) {
        setState(() => _bufferingState = 'Buffering...');
        AppLog.info(
          'Player: overlay → "Buffering..." (grace=$_startupGrace)'
          ' channel="${widget.channel.name}"',
        );
      }
      // fix92: previously the watchdog was suppressed entirely during
      // _startupGrace. On reconnects, buffering=true arrives inside the
      // 500ms grace window, so the watchdog never armed and the player
      // waited ~31s for mpv's own TCP timeout on every cycle. Now we
      // always arm it; during grace we use a longer timeout so genuine
      // slow-starts aren't killed prematurely.
      if (widget.channel.mediaType == MediaType.livestream) {
        final base = widget.settings.bufferingWatchdogSecs;
        final watchdogSecs = _startupGrace ? base * 2 : base;
        _bufferingWatchdog?.cancel();
        _bufferingWatchdog = Timer(
          Duration(seconds: watchdogSecs),
          () => onDisconnect(reason: 'buffering watchdog'),
        );
        AppLog.info(
          'Player: watchdog armed ${watchdogSecs}s'
          ' (grace=$_startupGrace base=${base}s)'
          ' channel="${widget.channel.name}"',
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
            if (mounted) {
              setState(() => _startupGrace = false);
              AppLog.info(
                'Player: startup grace expired'
                ' (after ${widget.settings.startupGraceMs}ms)'
                ' channel="${widget.channel.name}"',
              );
            }
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
    // fix92: cancel any pending stable-timer so a late "stream stable"
    // callback can't zero the counter mid-give-up.
    if (_stableTimer != null) {
      AppLog.info(
        'Player: cancelled pending stable-timer on disconnect'
        ' (attempt $_totalReconnectAttempts)'
        ' channel="${widget.channel.name}"',
      );
    }
    _stableTimer?.cancel();
    _stableTimer = null;
    AppLog.warn(
      'Player: onDisconnect — attempt $_totalReconnectAttempts/${widget.settings.maxReconnectAttempts}'
      ' reconnecting=$_isReconnecting'
      ' openFailures=$_consecutiveOpenFailures'
      ' startupGrace=$_startupGrace'
      ' reason="$reason" channel="${widget.channel.name}"',
    );

    // fix414: never give up / pop to the menu while minimized to PiP — the
    // user is in another app and a transient drop should recover quietly.
    // Part 1 forces software decode so the re-open works in PiP; the give-up
    // and route-pop are deferred until the app returns to full-screen, where
    // the attempt counter is reset (see the PiP listener in initAsync).
    if (_totalReconnectAttempts >= widget.settings.maxReconnectAttempts &&
        !_inPipMode) {
      AppLog.warn(
        'Player: max reconnects reached — giving up on "${widget.channel.name}"',
      );
      // Record cooldown so fresh widget instances (user re-navigates to the
      // channel) don't immediately hammer a rate-limited provider again.
      final channelId = widget.channel.id;
      if (channelId != null) Player._recentGiveUps[channelId] = DateTime.now();

      // Stop background activity so late listener callbacks no-op.
      exiting = true;
      _bufferingWatchdog?.cancel();
      _bufferingWatchdog = null;
      _startupWatchdog?.cancel(); // fix94
      _startupWatchdog = null;
      _stableTimer?.cancel();
      _stableTimer = null;

      if (mounted) {
        // Show terminal message immediately so the overlay updates in the
        // brief window before onExit() completes the pop.
        // fix112: if every attempt failed instantly with "Failed to open",
        // this is almost certainly a connection-limit rejection, not a dead
        // stream. Tell the user something actionable.
        final connLimit = _lastFailureWasInstant;
        setState(() => _bufferingState = connLimit
            ? 'Stream unavailable — connection limit reached.'
            : 'Stream unavailable — too many failed attempts.');

        final channelName = widget.channel.name;
        final maxAttempts = widget.settings.maxReconnectAttempts;
        // Schedule the snackbar before popping so the post-frame callback
        // fires on the underlying route after the pop.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text(
                connLimit
                    ? '"$channelName" couldn\'t open — this provider may '
                      'allow only one stream at a time. Close other '
                      'devices/streams using this account and try again.'
                    : '"$channelName" failed to load after $maxAttempts '
                      'attempts — stream may be unavailable.',
              ),
              duration: const Duration(seconds: 6),
            ),
          );
        });
        // Exit via the same proven path as the back button. _exitInvoked
        // guards against a double-pop if the user also hits back.
        onExit();
      }
      return;
    }

    AppLog.info('Player: reconnect — $reason');
    if (mounted) {
      // fix414: in PiP the attempt counter intentionally exceeds maxAttempts
      // (we never give up while minimized), so show a plain "Reconnecting…"
      // rather than a confusing "Retrying 7/3…".
      setState(() => _bufferingState = _inPipMode
          ? 'Reconnecting…'
          : 'Retrying $_totalReconnectAttempts'
              '/${widget.settings.maxReconnectAttempts}…');
    }
    // fix112: back off longer after an instant "Failed to open" (likely a
    // connection-limit rejection) so the previous connection has time to
    // release before we retry. Ordinary transient drops keep the fast 1s.
    // fix414: in PiP we retry indefinitely (never give up), so use a calmer 5s
    // cadence to avoid hammering the network/battery on a genuinely dead feed.
    final backoff = _inPipMode
        ? const Duration(seconds: 5)
        : _lastFailureWasInstant
            ? const Duration(seconds: 3)
            : const Duration(seconds: 1);
    if (_lastFailureWasInstant) {
      AppLog.info(
        'Player: backing off ${backoff.inSeconds}s before retry'
        ' (instant failure — possible connection limit)'
        ' channel="${widget.channel.name}"',
      );
    }
    await Future.delayed(backoff);
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

  /// fix421: ensures the connection-setup timing probe runs once per
  /// user-initiated channel open, not on every reconnect.
  bool _connProbeDone = false;

  Future<void> _startPlayback(
    Duration? startPosition, {
    ChannelHttpHeaders? headers,
  }) async {
    _startupGrace = false; // Reset on every attempt (including retries)
    _seekProbeLogged = false; // fix380: one log per open() for the startup probe
    final timeout = Duration(seconds: widget.settings.openTimeoutSecs);
    while (true) {
      if (!mounted || exiting) return;
      _startupWatchdog?.cancel(); // fix94: clear before re-open
      try {
        final playbackUrl = _playbackUrl();
        // fix421: one-shot connection-setup timing (DNS/TCP/TLS) for this
        // channel open — diagnostic only, fire-and-forget, skipped on
        // reconnects so it runs once per user-initiated play.
        if (!_connProbeDone) {
          _connProbeDone = true;
          unawaited(ConnTiming.probe(playbackUrl));
        }
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
            // fix414: while minimized to PiP, MediaCodec can't re-init, so the
            // re-open would hang — force software decode for the reconnect so
            // it recovers in PiP. No-op for the initial open (never in PiP).
            forceSoftwareDecode: _inPipMode,
          );
        }

        _startupGrace = true;
        _lastOpenAt = DateTime.now(); // fix112
        await _engine
            .open(
              url: playbackUrl,
              startPosition: startPosition,
              headers: httpHeaders,
              isLive: widget.channel.mediaType ==
                  MediaType.livestream, // fix339
            )
            .timeout(
              timeout,
              onTimeout: () => throw TimeoutException(
                'engine.open() exceeded ${timeout.inSeconds}s',
              ),
            );

        _consecutiveOpenFailures = 0;
        AppLog.info(
          'Player: open() succeeded — engine=libmpv url="$playbackUrl"',
        );
        // fix366: the DVR buffer is enabled INSIDE open() (engine sets
        // _dvrActive late), but primaryButtonBar was already built during the
        // initial controls-theme render with dvrActive=false — so the
        // rewind/forward/back-to-live row never appeared on a stream that then
        // played without any further setState (1.32.4 on-device: DVR active,
        // only play/pause shown). Trigger one rebuild now that open() (and DVR
        // activation) has completed so the bar re-evaluates _engine.dvrActive.
        if (mounted && _engine.dvrActive) setState(() {});
        // fix94: arm a startup watchdog. If the stream opens but never
        // produces a frame / buffering event, mpv can sit ~30s on its
        // internal read timeout. Catch it sooner. Cancelled by the first
        // _onBufferingChanged event. Uses bufferingWatchdogSecs as the
        // duration — one knob for all stall scenarios.
        if (widget.channel.mediaType == MediaType.livestream) {
          final startupSecs = widget.settings.bufferingWatchdogSecs;
          _startupWatchdog?.cancel();
          _startupWatchdog = Timer(
            Duration(seconds: startupSecs),
            () {
              if (mounted && !exiting) {
                AppLog.warn(
                  'Player: startup watchdog fired after ${startupSecs}s'
                  ' — open succeeded but no frame'
                  ' channel="${widget.channel.name}"',
                );
                onDisconnect(reason: 'startup watchdog');
              }
            },
          );
          AppLog.info(
            'Player: startup watchdog armed ${startupSecs}s'
            ' channel="${widget.channel.name}"',
          );
        }
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
        AppLog.warn(
          'Player: open() failed'
          ' ($_consecutiveOpenFailures/${widget.settings.maxReconnectAttempts})'
          ' — $e — channel="${widget.channel.name}"',
        );
        if (_consecutiveOpenFailures >= widget.settings.maxReconnectAttempts) {
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
    WidgetsBinding.instance.removeObserver(this); // fix136
    // Pass our engine so that if a new Player already called registerMain
    // during a swap transition, we don't accidentally wipe its registration.
    OverlayPlayerController.instance.unregisterMain(_engine);
    unawaited(PipController.setPlaying(false));
    _bufferingWatchdog?.cancel();
    _startupWatchdog?.cancel(); // fix94
    _stableTimer?.cancel();
    _surfTimer?.cancel(); // fix397
    _surfKeyFocus.dispose(); // fix397
    for (final s in subscriptions) {
      s.cancel();
    }
    for (final s in _engineSubs) {
      s.cancel();
    }
    _engineSubs.clear();
    // fix110/116: dispose only if we still own the engine.
    if (!_engineDisposed) {
      AppLog.info('Player: dispose() disposing owned engine'
          ' eid=${identityHashCode(_engine)}'
          ' channel="${widget.channel.name}"');
      _engine.dispose();
      _engineDisposed = true;
    } else {
      AppLog.info('Player: dispose() SKIP engine dispose'
          ' (already disposed or handed off via swap)'
          ' eid=${identityHashCode(_engine)}'
          ' channel="${widget.channel.name}"');
    }
    super.dispose();
  }


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
        if (!mounted) return;
        setState(() {
          _isCasting = false;
          _castState = CastState.notConnected;
        });
        // Resume locally from Cast-reported position.
        // reapplyOptions() must precede open() since open() no longer
        if (_engine case final MpvEngine mpv) {
          await mpv.reapplyOptions(url: url);
        }
        await _engine.open(
          url: url,
          startPosition: resumePosition,
          isLive: widget.channel.mediaType == MediaType.livestream, // fix339
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


  // ===================== fix360 (re-applied fix364): DVR transport ========

  Future<void> _dvrSeekBy(Duration delta) async {
    if (!_engine.dvrActive) return;
    final target = _engine.position + delta;
    final clamped = target.isNegative ? Duration.zero : target;
    await _engine.seek(clamped);
    AppLog.info('Player: DVR seek ${delta.inSeconds}s -> ${clamped.inSeconds}s');
  }

  Future<void> _dvrGoLive() async {
    if (!_engine.dvrActive) return;
    await _engine.seek(const Duration(days: 1)); // mpv clamps to live edge
    if (!_engine.isPlaying) await _engine.play();
    AppLog.info('Player: DVR back to live edge');
  }

  Widget _dvrButton(IconData icon, String tip, VoidCallback onTap) => IconButton(
        icon: Icon(icon, color: Colors.white, size: 40),
        tooltip: tip,
        onPressed: onTap,
      );

  /// fix408: the transport controls, tiered for the bottom bar. Always shows the
  /// core (channel ▲/▼ when surfable, play/pause); adds rewind/forward/live only
  /// when DVR is active. VOD uses prev/play/next. The dvrActive branch re-reads
  /// correctly because the controls theme is keyed on dvrActive (fix367).
  List<Widget> _transportButtons() {
    if (widget.channel.mediaType != MediaType.livestream) {
      return const [
        MaterialSkipPreviousButton(),
        MaterialPlayOrPauseButton(iconSize: 40.0),
        MaterialSkipNextButton(),
      ];
    }
    final dvr = _engine.dvrActive;
    return [
      if (_canSurf)
        _dvrButton(Icons.keyboard_arrow_up, 'Channel up', () => _surf(-1)),
      if (dvr)
        _dvrButton(Icons.replay_10, 'Rewind 10s',
            () => _dvrSeekBy(const Duration(seconds: -10))),
      const MaterialPlayOrPauseButton(iconSize: 40.0),
      if (dvr) ...[
        _dvrButton(Icons.forward_10, 'Forward 10s',
            () => _dvrSeekBy(const Duration(seconds: 10))),
        _dvrButton(Icons.live_tv, 'Back to live', _dvrGoLive),
      ],
      if (_canSurf)
        _dvrButton(Icons.keyboard_arrow_down, 'Channel down', () => _surf(1)),
    ];
  }

  /// fix408: distribute bottom-bar items evenly across the row (equal gaps,
  /// first item hard-left, last hard-right — like spaceBetween). media_kit owns
  /// the Row, so even spacing is produced by inserting a Spacer between items.
  List<Widget> _spreadEvenly(List<Widget> items) {
    if (items.length <= 1) return items;
    final out = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) out.add(const Spacer());
      out.add(items[i]);
    }
    return out;
  }

  // ─── fix397: channel +/- (surf) ──────────────────────────────────────────

  /// True when the launching list has another playable channel to surf to.
  bool get _canSurf => (widget.playlist?.hasSurfableNeighbor ?? false);

  /// Advance the surf target by [direction] (+1 = down the list, -1 = up),
  /// show the target channel name, and (re)arm the debounce so the switch only
  /// fires once the user stops pressing. No-op if there's no list / neighbour.
  void _surf(int direction) {
    final pl = widget.playlist;
    if (pl == null || exiting || _exitInvoked) return;
    final base = _surfTargetIndex ?? pl.index;
    final next = pl.withIndex(base).neighborIndex(direction);
    if (next == null) return;
    setState(() {
      _surfTargetIndex = next;
      _surfBanner = pl.channels[next].name;
    });
    _surfTimer?.cancel();
    _surfTimer = Timer(_surfDebounce, _commitSurf);
  }

  /// Fire the pending channel switch: re-launch a fresh Player for the target
  /// channel via pushReplacement, carrying the same list with the new index so
  /// surfing continues. Reusing the launch path keeps the (heavily fixed)
  /// playback state machine untouched.
  Future<void> _commitSurf() async {
    final pl = widget.playlist;
    final target = _surfTargetIndex;
    if (!mounted || pl == null || target == null || exiting || _exitInvoked) {
      return;
    }
    final next = pl.channels[target];
    final nextId = next.id;
    AppLog.info('Player: channel surf -> "${next.name}" '
        '(index $target/${pl.channels.length}) channel="${widget.channel.name}"');
    // The active stream proves nothing about the next one; clear any stale
    // give-up cooldown so the fresh Player isn't blocked (mirrors swap).
    Player.clearCooldown(nextId);
    Source? src;
    try {
      src = await Sql.getSourceById(next.sourceId);
    } catch (e) {
      AppLog.warn('Player: surf getSourceById failed — $e');
    }
    if (!mounted || exiting || _exitInvoked) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => Player(
          channel: next,
          settings: widget.settings,
          source: src,
          playlist: pl.withIndex(target),
        ),
      ),
    );
  }

  /// Remote channel keys (Android TV CH+/CH−). Up = up the list, down = down.
  KeyEventResult _onChannelKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_canSurf) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.channelUp) {
      _surf(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.channelDown) {
      _surf(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// fix404: cycle through fit → stretch → crop → fit on each tap. The
  /// pre-fix404 implementation toggled between native-aspect and
  /// device-aspect via [MpvEngine.updateAspectRatio]; fix404 moves the
  /// decision to [MpvEngine.setZoomMode] (BoxFit on the Video widget),
  /// which gives us a true third state ("fill with crop" via
  /// BoxFit.cover) without the limits of an aspect-ratio override.
  void toggleZoom() {
    final engine = _engine;
    if (engine is! MpvEngine) return;
    final next = _zoomMode.next();
    setState(() => _zoomMode = next);
    engine.setZoomMode(next.boxFit);
    // fix422: persist so the next single-cell full-screen open restores it.
    widget.settings.playerZoomMode = next;
    unawaited(SettingsService.updateSettings(widget.settings));
  }


  /// Sends the current channel to the floating overlay and pops this route.
  Future<void> _minimizeToOverlay() async {
    await OverlayPlayerController.instance.startOverlay(
      widget.channel,
      widget.settings,
      widget.source,
    );
    if (mounted) onExit();
  }


  /// fix106: immediately halt all playback/reconnect activity for this
  /// player without navigating. Called by the swap path on the OUTGOING
  /// full-screen player so it cannot fire a background reconnect (which
  /// previously created phantom previewMode=false engines after a swap).
  ///
  /// Safe to call multiple times. Does NOT pop the route — pushReplacement
  /// handles route removal.
  Future<void> haltForSwap() async {
    AppLog.info('Player: haltForSwap channel="${widget.channel.name}"');
    exiting = true;                 // makes all listener callbacks no-op
    _exitInvoked = true;            // belt-and-suspenders against onExit
    _bufferingWatchdog?.cancel();
    _bufferingWatchdog = null;
    _startupWatchdog?.cancel();
    _startupWatchdog = null;
    _stableTimer?.cancel();
    _stableTimer = null;
    try {
      await _engine.dispose();
      _engineDisposed = true; // fix110
    } catch (e) {
      AppLog.warn('Player: haltForSwap dispose error — $e');
      _engineDisposed = true; // fix110: don't retry a failed dispose
    }
  }

  /// fix116: stop this player's reconnect/timers and RETURN its live engine
  /// for handoff to the overlay, WITHOUT disposing it. Mirrors haltForSwap
  /// but transfers ownership instead of tearing the engine down.
  MpvEngine? detachForSwap() {
    final e = _engine;
    AppLog.info('Player: detachForSwap eid=${identityHashCode(e)}'
        ' channel="${widget.channel.name}"'
        ' isMpv=${e is MpvEngine}');
    exiting = true;          // silence listener callbacks
    _exitInvoked = true;     // guard onExit double-pop
    _engineDisposed = true;  // CRITICAL: ownership moves to overlay; dispose()
                             // must NOT dispose the handed-off engine.
    AppLog.info('Player: detachForSwap set _engineDisposed=true'
        ' (engine handed off, will NOT be disposed by this widget)'
        ' eid=${identityHashCode(e)}');
    _bufferingWatchdog?.cancel();
    _bufferingWatchdog = null;
    _startupWatchdog?.cancel();
    _startupWatchdog = null;
    _stableTimer?.cancel();
    _stableTimer = null;
    for (final s in _engineSubs) {
      s.cancel();
    }
    _engineSubs.clear();
    if (e is MpvEngine) {
      AppLog.info('Player: detachForSwap returning engine'
          ' eid=${identityHashCode(e)}');
      return e;
    }
    AppLog.warn('Player: detachForSwap — engine not MpvEngine, returning null'
        ' (caller will reopen)');
    return null;
  }

  void onExit() async {
    if (_exitInvoked) return;
    _exitInvoked = true;
    exiting = true; // stops the reconnect loop at its next `exiting` check
    AppLog.info(
      'Player: onExit START channel="${widget.channel.name}"'
      ' reconnecting=$_isReconnecting engineDisposed=$_engineDisposed',
    );

    // fix130: unmount the Texture before pop/dispose so no stale frame
    // can composite during teardown.
    if (mounted) setState(() => _videoDetached = true);

    // fix118: POP FIRST — synchronously, before ANY await. The previous
    // code popped only after two `await SystemChrome` calls; if the widget
    // unmounted during those awaits (e.g. the mini was just closed and the
    // overlay teardown is interleaving), `if (mounted)` was false and the
    // pop was skipped — leaving a black screen with a dead back button
    // (force-close required). Capturing the Navigator and popping up front
    // makes navigation independent of everything that follows.
    final navigator = Navigator.of(context);
    AppLog.info('Player: onExit popping route'
        ' channel="${widget.channel.name}"');
    navigator.pop();
    if (_engine is MpvEngine) (_engine as MpvEngine).logSurface('onExit-after-pop');

    // fix124: the revealed route is Home, mounted as MaterialApp.home (the
    // root route). A RouteObserver never delivers didPopNext to the root
    // route, so fix120.1's Home.didPopNext can NEVER fire (confirmed: zero
    // occurrences in the 1.22.8+122 log) and Home is never prompted to
    // repaint — the compositor keeps the popped Player's black layer.
    // Force a repaint from HERE, the path the log proves runs every time:
    //   1) schedule a frame so the compositor re-rasterises the revealed tree
    //   2) mark the navigator's context subtree dirty so Home rebuilds
    WidgetsBinding.instance.scheduleFrame();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        // ignore: invalid_use_of_protected_member
        (navigator.context as Element).markNeedsBuild();
      } catch (e) {
        AppLog.warn('Player: onExit post-pop repaint skipped — $e');
      }
      WidgetsBinding.instance.scheduleFrame();
      AppLog.info('Player: onExit forced post-pop repaint of revealed route');
    });

    // Everything below is best-effort cleanup that must NOT block or
    // prevent the pop above. None of it needs the widget to still be
    // mounted or the route to still exist.
    unawaited(PipController.setPlaying(false));
    _bufferingWatchdog?.cancel();
    _bufferingWatchdog = null;
    _startupWatchdog?.cancel(); // fix94
    _startupWatchdog = null;
    _stableTimer?.cancel();
    _stableTimer = null;

    // Save movie resume position, bounded so a busy engine can't hang.
    if (widget.channel.mediaType == MediaType.movie) {
      final id = widget.channel.id;
      if (id != null) {
        try {
          await Sql.setPosition(id, _engine.position.inSeconds)
              .timeout(const Duration(seconds: 1));
        } catch (e) {
          AppLog.warn('Player: onExit setPosition skipped — $e');
        }
      }
    }

    // fix118: tear down the engine WITHOUT blocking. Fire-and-forget;
    // MpvEngine.dispose() is idempotent (guards a second call), so the
    // widget dispose() that follows the pop is safe even if this hasn't
    // completed. fix110's audio-stop requirement still holds — dispose
    // proceeds, audio stops a moment after the pop.
    if (!_engineDisposed) {
      _engineDisposed = true; // mark first so widget dispose() won't re-dispose
      unawaited(() async {
        try {
          if (_engine.handlesOwnFullscreen && _engine.isFullscreen) {
            await _engine.exitFullscreen();
          }
          await _engine.dispose();
          AppLog.info('Player: onExit engine disposed (async)');
        } catch (e) {
          AppLog.warn('Player: onExit async dispose error — $e');
        }
      }());
    }

    // Restore orientation / system UI last — engine-independent, and the
    // route is already gone so this can't block navigation.
    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (e) {
      AppLog.warn('Player: onExit SystemChrome restore error — $e');
    }
    AppLog.info('Player: onExit DONE channel="${widget.channel.name}"');
  }


  // fix136: DIAGNOSTIC ONLY — logs rotation, no engine/connection action.
  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!mounted) return;
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view.physicalSize;
    final orientation = size.width >= size.height
        ? Orientation.landscape
        : Orientation.portrait;
    if (orientation == _lastOrientation) return;
    final prev = _lastOrientation;
    _lastOrientation = orientation;
    AppLog.info(
      'Player: ROTATE ${prev?.name ?? 'init'} → ${orientation.name}'
      ' channel="${widget.channel.name}"'
      ' (no reconnect — layout only)',
    );
    if (_engine is MpvEngine) {
      (_engine as MpvEngine).logSurface('rotate-${orientation.name}');
    }
  }

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
      // fix397: ancestor Focus to catch the remote CH+/CH− keys (the video
      // controls take focus; unhandled channel keys bubble up to here). Only
      // channel keys are consumed — everything else is ignored so existing
      // d-pad / back handling is untouched.
      child: Focus(
        focusNode: _surfKeyFocus,
        // Never take focus itself — it only observes CH+/− keys that bubble up
        // from the focused video controls, so d-pad navigation is untouched.
        canRequestFocus: false,
        onKeyEvent: _onChannelKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              _buildVideoArea(),
              if (_bufferingState != null) _buildBufferingOverlay(),
              if (_surfBanner != null) _buildSurfBanner(),
            ],
          ),
        ),
      ),
    );
  }

  /// fix397: transient overlay showing the channel being surfed to while the
  /// debounce settles, so rapid CH+/− presses give immediate feedback before
  /// the stream actually switches.
  Widget _buildSurfBanner() => Positioned(
        top: 24,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.swap_vert, color: Colors.white, size: 22),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _surfBanner!,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _buildVideoArea() {
    if (_videoDetached) {
      return const ColoredBox(color: Colors.black, child: SizedBox.expand());
    }
    // libmpv path: use media_kit_video's full controls theme.
    // fix367: media_kit's controls state reads primaryButtonBar once at its own
    // mount and does NOT rebuild when the MaterialVideoControlsTheme inherited
    // widget changes. DVR activates INSIDE open() (after first mount), so the
    // transport bar (rewind/forward/back-to-live) never appeared even though
    // _engine.dvrActive was true and the parent rebuilt (fix360/364/366 all
    // failed for this reason). Keying the theme subtree on dvrActive forces
    // media_kit's controls to remount exactly once when DVR turns on, so they
    // re-read primaryButtonBar and render the transport row. Cheap: flips false
    // -> true a single time per playback.
    return MaterialVideoControlsTheme(
      key: ValueKey('mvct-dvr-${_engine.dvrActive}'),
      normal: _mpvThemeData(context),
      fullscreen: _mpvThemeData(context),
      child: _engine.buildVideoView(context),
    );
  }

  Widget _buildBufferingOverlay() {
    final message = _bufferingState!;
    // Cooldown / give-up states ("please wait …", "Unable to connect …") are
    // terminal — we are not actively buffering anymore. Show a Go Back button
    // so the user can leave the dead channel without going through system
    // back, and drop the spinner since nothing is in progress.
    final isTerminal = message.contains('please wait') ||
        message.startsWith('Unable to connect') ||
        message.startsWith('Stream unavailable');

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

  /// fix406: shift the centre control row (primaryButtonBar) down to just above
  /// the bottom icon row. media_kit hard-centres it with no theme knob, so each
  /// button is nudged with a Transform.translate; Spacers are left untouched so
  /// the horizontal flex layout is preserved.
  MaterialVideoControlsThemeData _mpvThemeData(BuildContext context) {
    // fix513: reverted fix423's barLift. Raising bottomButtonBarMargin.bottom
    // fed media_kit's subtitleVerticalShiftOffset, which insets the tap-to-show
    // Listener from the bottom — so the lift BOTH floated the bar up and grew
    // the tap-dead strip by the same amount (net ~doubled it). Back to baseline
    // edge-aligned margins; the wake-on-tap is handled app-side (fix514).
    return MaterialVideoControlsThemeData(
      speedUpOnLongPress: false,
      // fix409: control-bar auto-hide timeout (dev setting). 0 = keep until
      // dismissed (a far-future duration so media_kit never auto-hides).
      controlsHoverDuration: widget.settings.devControlsHideSecs <= 0
          ? const Duration(days: 1)
          : Duration(seconds: widget.settings.devControlsHideSecs),
      seekOnDoubleTap: widget.channel.mediaType != MediaType.livestream,
      displaySeekBar: widget.channel.mediaType != MediaType.livestream,
      seekBarMargin: const EdgeInsets.only(bottom: 60),
      seekBarThumbSize: 20,
      seekBarHeight: 10,
      seekGesture: widget.channel.mediaType != MediaType.livestream,
      // fix348 (1.27.0): live TV control panel decision — the panel stays
      // (back/cast/PiP, subtitles, zoom, mini-player are all useful live) and
      // play/pause stays (mpv's cache makes pause-resume work), but the
      // default centre SkipPrevious/SkipNext buttons are removed on live:
      // they are playlist controls and do nothing on a single live stream.
      // VOD keeps the package default. A 300s DVR-to-disk buffer (which would
      // make live seeking real) is deferred as a future feature.
      // fix408: centre bar cleared — transport moved to the bottom bar.
      primaryButtonBar: const [],
        topButtonBar: [
        IconButton(
          onPressed: onExit,
          icon: const Icon(Icons.arrow_back, color: Colors.white, size: 32),
        ),
        const SizedBox(width: 10),
        // fix406: keep the channel name from being squeezed out, then show the
        // current EPG programme (if any) in the remaining space to its right.
        Flexible(
          child: Text(
            widget.channel.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: PlayerEpgNowLabel(
            epgChannelId: widget.channel.epgChannelId,
            sourceId: widget.channel.sourceId,
          ),
        ),
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
      bottomButtonBar: _spreadEvenly([
        if (_engine.supportsTrackSelection) ...[
          IconButton(
            onPressed: openSubtitlesModal,
            icon:
                const Icon(Icons.subtitles, color: Colors.white, size: 32),
          ),
          IconButton(
            onPressed: openAudioModal,
            icon:
                const Icon(Icons.music_note, color: Colors.white, size: 32),
          ),
        ],
        IconButton(
          // fix405: revert to a static icon + generic tooltip. fix404
          // tried to swap icon + tooltip with the current ZoomMode so
          // the user could tell which of fit/stretch/crop was active,
          // but media_kit's MaterialVideoControlsTheme reads the
          // bottomButtonBar ONCE at mount and does not re-read it on
          // parent rebuilds (same class of bug fix367 hit on
          // primaryButtonBar for DVR). The icon was frozen on whatever
          // was captured at first mount, regardless of subsequent
          // _zoomMode changes. The 3-state cycle itself works — the
          // engine's setZoomMode call updates the video frame; only
          // the button affordance was lying. Revert to a const icon
          // and a generic "Aspect ratio" tooltip; the user discovers
          // the active mode by the visible frame change on tap.
          icon: const Icon(
            Icons.aspect_ratio_outlined,
            color: Colors.white,
            size: 32,
          ),
          tooltip: 'Aspect ratio',
          onPressed: toggleZoom,
        ),
        // fix408: transport controls merged into the bottom bar, distributed
        // evenly across the row by _spreadEvenly. Tiered via _transportButtons
        // (±10s / live only when DVR is active).
        ..._transportButtons(),
        // Mini-player button — hidden when multi-view is active.
        if (widget.channel.mediaType == MediaType.livestream &&
            widget.settings.multiViewLayout == MultiViewLayout.none) ...[
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
      ]),
    );
  }
}
