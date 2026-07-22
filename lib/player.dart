import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/conn_timing.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/models/device_detector.dart';
import 'package:open_tv/player/tv_osd/action_button.dart'; // fix715 (Phase 4 OSD)
import 'package:open_tv/player/tv_osd/channel_bar.dart'; // fix716 (Phase 4 OSD)
import 'package:open_tv/player/tv_osd/info_bar.dart'; // fix714 (Phase 4 OSD)
import 'package:open_tv/widgets/player_channel_name_label.dart';
import 'package:open_tv/backend/recording_actions.dart';
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
import 'package:open_tv/player/seek_acceleration.dart';
import 'package:open_tv/player/mpv_engine.dart';
import 'package:open_tv/player/debug_stats_overlay.dart';
import 'package:open_tv/player/player_engine.dart';
import 'package:open_tv/player/player_key_action.dart';
import 'package:open_tv/select_dialog.dart';
import 'package:open_tv/tv/theme/f4_motion.dart'; // fix731 OSD fade
import 'package:open_tv/tv/theme/f4_tokens.dart'; // fix731 token scrim

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

/// fix566: errors for the `vf` (video-filter) option are NEVER fatal to
/// playback. `vf` is set ONLY by the low-RAM 30 fps OUTPUT cap (fix565), a pure
/// optimisation. On libmpv builds where the cap filter cannot be created — a
/// bare `fps=30` name that doesn't resolve without the lavfi bridge, or a
/// libavfilter without the `fps` filter — mpv emits an error-level message
/// ("Option vf: fps doesn't exist." / "could not create filter") that was
/// reaching errorStream and forcing a spurious reconnect on every open (onn 4K
/// Plus field log, v2.0.65). Treat it like the seek probe: log, never
/// reconnect. The stream keeps playing uncapped, which is the correct fallback.
bool isVfOptionError(String err) {
  return err.contains('Option vf') || err.contains('could not create filter');
}

/// fix742: mpv's "Could not open codec." is emitted when ONE decoder in the
/// candidate list fails to open — most commonly the hwdec probe
/// (h264_mediacodec rejecting an interlaced/odd-profile stream, e.g. 1080i
/// regional-sports feeds). mpv then falls back to the next candidate
/// (ultimately software) ON ITS OWN and playback proceeds. Treating this
/// error as an immediate disconnect made the app tear down a session that had
/// already recovered, re-probe hwdec on the reopen, fail identically, and
/// burn all reconnect attempts on a perfectly decodable stream (S938U field
/// log 2026-07-13, "YES Network": three error → sw-fallback → first-frame →
/// app-teardown cycles, then "max reconnects reached").
bool isCodecOpenError(String err) {
  return err.contains('Could not open codec');
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

  /// fix727: an armed sleep-timer's wall-clock fire time, threaded across a
  /// channel surf (pushReplacement → fresh Player) so the sleep timer keeps
  /// counting down instead of resetting. Null = no timer armed. Only the surf
  /// path sets it; every other launch site defaults to null.
  final DateTime? sleepDeadline;
  const Player({
    super.key,
    required this.channel,
    required this.settings,
    this.source,
    this.overrideUrl,
    this.adoptEngine,
    this.playlist,
    this.sleepDeadline,
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

  // fix576/fix577: D-pad transport on TV. The player Focus holds focus so the
  // remote arrows map directly to channel/seek and OK toggles play/pause +
  // reveals the control bars. media_kit 2.0.1 has no public show-controls API
  // (visibility is private, tap-driven), so OK reveals the bars by synthesizing
  // a centre tap — exactly like a screen tap — and media_kit auto-hides them.
  // (fix576's keyed-remount + visibleOnMount approach did NOT show them
  // on-device — media_kit preserves the controls state across the theme
  // remount — so fix577 replaced it with the tap.)
  //
  // fix580 (Mode B): on TV+live, OK opens a CUSTOM focusable control overlay
  // the D-pad navigates (a native Flutter FocusTraversalGroup of IconButtons —
  // the proven tv_top_tab_bar pattern — NOT media_kit's bars, which can't host
  // focus nav: that was the reverted fix578). _tvMode is resolved at RUNTIME
  // (leanback / no-touch / forceTVMode) so it engages on auto-detected TV boxes
  // regardless of launch path. _closeOverlay is the SOLE writer of
  // _navMode=false and ALWAYS reclaims _surfKeyFocus — the keystone against the
  // fix578 dead-D-pad regression.
  bool _tvMode = false;
  bool _navMode = false;
  Timer? _overlayHideTimer;
  static const Duration _overlayAutoHide = Duration(seconds: 8);
  // fix727 (mock §4.6): sleep timer. When >0 a one-shot Timer pauses playback
  // and exits the player after _sleepMinutes; the OSD bedtime icon fills while
  // armed. Cancelled on re-selection ("Off"), on a new selection, and in
  // dispose() so it can never fire onto a torn-down State. _sleepDeadline is the
  // wall-clock fire time, carried across channel-surf (pushReplacement builds a
  // fresh Player) so the timer survives surfing — the point of "sleep to live TV"
  // (adversarial-review finding 2).
  Timer? _sleepTimer;
  int _sleepMinutes = 0;
  DateTime? _sleepDeadline;
  // fix732 (mock §4.7): channel-zap shutter. Starts opaque on a fresh play so
  // the black-load period reads as a clean zap, fades out (F4Motion.shutter) on
  // first-frame; an adopted (already-playing) engine skips it. _shutterTimeout
  // is the dead-engine fallback so it can never stick.
  bool _showShutter = true;
  Timer? _shutterTimeout;
  // fix735 (Peer2 watchdog→silent-resync): reopen the live stream when the
  // engine reports sustained A/V desync (a fresh open resets avsync to ~0). A
  // resync that HOLDS (>3min synced) is a legit slow-drift correction — keep
  // doing it indefinitely; resyncs that recur fast (<3min) mean the reopen is
  // NOT helping (intrinsic PTS) → give up after a few strikes so we never
  // reopen-loop. This is the ONLY recovery for a desynced-but-advancing stream
  // (invisible to the buffering/startup watchdogs).
  DateTime? _lastAvsyncResync;
  int _avsyncResyncStrikes = 0;
  bool _avsyncGaveUp = false; // fix735 (review): sticky give-up (a fresh tune resets)
  // fix580: first-focus target inside the overlay. autofocus is NOT enough —
  // _surfKeyFocus already holds primary focus in the same FocusScope, so an
  // autofocus request would be dropped (FocusManager only honors autofocus when
  // the scope has no focused child). _openOverlay explicitly requestFocus()es
  // this node post-frame; that gap is exactly what dead-ended fix577/578.
  final FocusNode _overlayFirstFocus =
      FocusNode(debugLabel: 'tvOverlayFirstFocus');

  // fix649: transient ±seconds indicator for ◀/▶ transport seeks. Consecutive
  // presses accumulate (net signed seconds) while the chip is visible; it
  // clears shortly after the last press. Purely visual — the seeks themselves
  // happen in _seekBy.
  int _skipIndicatorSecs = 0;
  Timer? _skipIndicatorTimer;
  static const Duration _skipIndicatorHold = Duration(milliseconds: 900);

  // fix651: ◀/▶ hold-to-seek. Key repeats accelerate through the ladder in
  // seek_acceleration.dart, and the actual engine.seek is COALESCED — deltas
  // accumulate and flush at most once per [_seekFlushEvery] — so a held key
  // on a weak box (onn: every KeyRepeat previously awaited a full mpv seek)
  // cannot flood the engine with seek requests.
  int _seekRepeatCount = 0;
  Duration _pendingSeek = Duration.zero;
  Timer? _seekFlushTimer;
  static const Duration _seekFlushEvery = Duration(milliseconds: 250);

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
  // fix747: silent-stall watchdog. _bufferingWatchdog only arms on a
  // buffering=true event, but a live feed can wedge — the demuxer starves at
  // cache=0 and playback freezes on one frame with NO buffering signal (the
  // onn "frozen frame for 25 min" freeze) while mpv still reports playing.
  // This periodic timer catches that class by watching the playback position
  // stop advancing while the engine still claims to be playing.
  Timer? _stallWatchdog;
  Duration? _stallLastPos;
  DateTime? _stallLastAdvanceAt;
  bool _enginePlaying = false;
  // fix753: true only while a pause WE asked for is in effect (user toggle,
  // cast handoff, sleep timer, overlay handoff; DVR resume and user resume
  // clear it, and every open() clears it). This is the PRIMARY stall
  // discriminator. Five theories of sensor-based discrimination (mpv `pause`,
  // `eof`, demuxTime progress, cacheSpeed==0, cache depth) were each tested
  // against field data and falsified — during the measured wedge mpv SETS
  // pause=yes itself with a FULL 95s buffer, and a settled user pause is
  // sensor-identical to the wedge. Intent is the only reliable separator, and
  // its coverage is exhaustive: this app has no MediaSession/audio_service/
  // headset-button handling, so nothing outside these call sites can request
  // a pause (verified 2026-07-14; an incoming ringing call does not stop
  // playback at all on the S938U).
  bool _pauseRequested = false;
  // fix753: only accumulate stall time while the app is foregrounded — an
  // ANSWERED call (the one OS-pause case field data could not capture) takes
  // the app inactive/backgrounded, so gating on resumed closes that class
  // without enumerating pause causes.
  bool _lifecycleResumed = true;
  // A live position frozen this long, while playing and not buffering, is a
  // dead feed (normal live playback advances ~1s/s) → reconnect.
  static const int _stallWatchdogSecs = 15;
  // finding 28: true once playback has meaningfully started this session (first
  // buffering=false). Gates the movie resume-position save so a failed/aborted
  // open can't overwrite a good stored position with 0.
  bool _playbackStartedThisSession = false;
  String? _bufferingState;
  // Suppresses false reconnect triggers during the first 3s after open().
  bool _startupGrace = false;
  // fix380: latched once the startup seek probe has been logged. Stops the
  // "suppressed seek probe error" log line from firing per user-seek (after
  // grace, every "Cannot seek" rejection was being mislabelled as a probe).
  bool _seekProbeLogged = false;

  // fix566: latched once the vf-cap error has been logged for this open()
  // (mirrors _seekProbeLogged) so a per-frame/per-retry error storm can't flood
  // the log. Reset alongside _seekProbeLogged at the top of each open.
  bool _vfErrorLogged = false;

  // fix742: pending escalation window after a codec-open error — mpv gets a
  // short grace to complete its own hw→sw decoder fallback before the error
  // becomes a disconnect. Cancelled by the first decoded frame.
  Timer? _codecFallbackTimer;
  // fix742: latched once a frame has decoded this open() — any later
  // codec-open error is a stale/duplicate probe failure, purely informational.
  bool _codecFallbackConfirmed = false;
  bool _codecErrorLogged = false; // one log per open(), mirrors _vfErrorLogged

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

  // finding 18: true when the most recent (re)open was forced to software
  // decode (only happens while minimized to PiP). On PiP exit we restore
  // hardware decode at runtime rather than leaving the stream on permanent
  // software decode (black-with-audio on Tegra full-screen).
  bool _lastOpenForcedSoftware = false;

  // finding 20: set true when a livestream has exhausted its retries / given
  // up (the retry loop hit maxReconnectAttempts, or the onDisconnect reconnect
  // tail failed) and the player is now idle awaiting a network restore. The
  // connectivity listener restarts playback directly (onDisconnect would be
  // rejected by its own !_isReconnecting-and-guards path).
  bool _awaitingNetwork = false;

  // finding 21: open-generation guard. Each _startPlayback entry bumps the
  // generation; any older retry loop aborts at its next await when it sees a
  // stale generation, so a second open (errorStream during the retry loop,
  // network-restore, cast-resume) can't stack a concurrent loop.
  int _openGeneration = 0;
  bool _startInFlight = false;

  // finding 32: virtual seek base for coalesced hold-to-seek. Successive
  // flushes during a burst add to the intended target rather than the engine's
  // possibly-stale position, so held seeks land at the chip total. Reset when
  // the skip chip clears.
  Duration? _virtualSeekBase;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // fix136
    // fix727: re-arm a sleep timer carried across a channel surf. Post-frame so
    // _scheduleSleep's setState is legal (setState is disallowed during
    // initState); a one-frame arm delay is nothing on a minutes-scale timer.
    final deadline = widget.sleepDeadline;
    if (deadline != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scheduleSleep(deadline);
      });
    }
    // fix580: resolve TV-ness SYNCHRONOUSLY at build time (mirrors main.dart
    // routing) so the custom D-pad overlay engages from the first frame on
    // auto-detected leanback boxes — not only when the user forced TV mode, and
    // regardless of which screen launched the player. main.dart resolves
    // isTV()/hasTouchScreen() at startup, so their caches are populated before
    // any Player opens; reading the cache avoids the async window where OK would
    // briefly take the media_kit-bars path (the verified-bad surface). The async
    // fallback only runs in the unlikely event the cache is not yet seeded.
    final cachedTv = DeviceDetector.isTvCached;
    final cachedTouch = Utils.hasTouchScreenCached;
    if (widget.settings.forceTVMode ||
        cachedTv == true ||
        cachedTouch == false) {
      _tvMode = true;
    } else if (cachedTv == null || cachedTouch == null) {
      unawaited(() async {
        final isTv = await DeviceDetector.isTV();
        final touch = await Utils.hasTouchScreen();
        if (mounted && (isTv || !touch)) setState(() => _tvMode = true);
      }());
    }
    final adopt = widget.adoptEngine;
    if (adopt is MpvEngine) {
      // fix116: adopt the already-playing engine from the swap. No create,
      // no open — the stream stays live, avoiding the reopen stall.
      _engine = adopt;
      _adopted = true;
      _showShutter = false; // fix732: adopted engine is already rendering
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
              // finding 18: if the last (re)open in PiP was forced to software
              // decode, restore hardware decode at runtime (no reopen) so
              // full-screen playback isn't stuck black-with-audio on Tegra.
              if (_lastOpenForcedSoftware && _engine is MpvEngine) {
                unawaited((_engine as MpvEngine).setHardwareDecode(true));
                _lastOpenForcedSoftware = false;
              }
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
      // finding 19: the adopted (mini→full-screen promoted) engine was opened
      // with previewMode settings — upgrade it to full-screen configuration at
      // runtime (no reopen) so DVR eligibility, live demuxer buffer, and
      // full-screen hwdec routing all apply. DVR only genuinely activates if
      // the stream supports it; the eligibility gate is simply opened.
      if (_engine is MpvEngine) {
        await (_engine as MpvEngine).promoteToFullScreen(
          dvrEligible: widget.channel.mediaType == MediaType.livestream,
        );
      }
      // finding 29: the adopt path returns before the normal connectivity
      // block, so it never got the network-restore listener; and _lastOpenAt
      // was left null (only _startPlayback sets it), making the first error be
      // misclassified as "instant" (sinceOpen treats null as 0). Seed both.
      _lastOpenAt = DateTime.now();
      _subscribeConnectivity();
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
    _subscribeConnectivity();
  }

  /// finding 29: the connectivity listener, extracted so BOTH the adopt path
  /// and the normal open path wire it (the adopt branch used to return before
  /// this ran). Added to [subscriptions] so dispose cancels it.
  void _subscribeConnectivity() {
    subscriptions.add(
      Connectivity().onConnectivityChanged.listen((results) {
        final hasNet =
            results.isNotEmpty && !results.contains(ConnectivityResult.none);
        // finding 20: restart directly on network restore after a give-up.
        // The old code called onDisconnect(reason: 'network restored') under
        // `hasNet && _isReconnecting`, but that is the exact complement of
        // onDisconnect's own !_isReconnecting guard — it was a guaranteed
        // no-op. Track an explicit idle-after-failure state (_awaitingNetwork)
        // and restart _startPlayback with the open-generation guard (#21) so it
        // can't stack on a sleeping loop. Livestream only.
        if (hasNet &&
            widget.channel.mediaType == MediaType.livestream &&
            !exiting &&
            !_isReconnecting &&
            _awaitingNetwork) {
          AppLog.info('Player: network restored; restarting playback...');
          _awaitingNetwork = false;
          _totalReconnectAttempts = 0;
          _consecutiveOpenFailures = 0;
          unawaited(() async {
            // Re-fetch per-channel headers (getChannelHeaders can throw on a
            // locked db during a concurrent refresh) — do not silently drop
            // headers on restart.
            ChannelHttpHeaders? h;
            try {
              final id = widget.channel.id;
              h = id != null ? await Sql.getChannelHeaders(id) : null;
            } catch (e) {
              AppLog.warn('Player: network-restore header fetch failed — $e'
                  ' channel="${widget.channel.name}"');
            }
            await _startPlayback(null, headers: h);
          }());
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
      // finding 30: no unconditional entry log — suppressed seek/vf probe
      // errors must stay silent (fix380 intent); a real error is logged once
      // at the classified site below.
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

      // fix566: a failed `vf` set (the low-RAM 30 fps cap) is never fatal —
      // the stream plays fine uncapped. Suppress it so it can't trigger a
      // reconnect (it did on every open on the onn 4K Plus, v2.0.65 log).
      if (isVfOptionError(err)) {
        if (_startupGrace && !_vfErrorLogged) {
          _vfErrorLogged = true;
          AppLog.info(
            'Player: vf cap error suppressed (filter unsupported on this'
            ' build; playback continues uncapped) — "$err"'
            ' channel="${widget.channel.name}"',
          );
        }
        return;
      }

      // fix742: "Could not open codec." — mpv retries the next decoder in its
      // candidate list (hwdec → software) by itself; the error is only fatal
      // if NO decoder ends up producing video. Give that fallback a short
      // window instead of disconnecting a session that is about to recover
      // (and that DID recover, three times, in the field log that motivated
      // this fix). If no frame arrives in time, escalate to the normal
      // disconnect path with the original reason.
      if (isCodecOpenError(err)) {
        if (_codecFallbackConfirmed) return; // video already up this open()
        if (!_codecErrorLogged) {
          _codecErrorLogged = true;
          AppLog.info(
            'Player: codec-open error — awaiting mpv decoder fallback (2s)'
            ' channel="${widget.channel.name}"',
          );
        }
        _codecFallbackTimer ??= Timer(const Duration(seconds: 2), () {
          _codecFallbackTimer = null;
          if (!mounted || exiting || _exitInvoked || _isReconnecting) return;
          if (_codecFallbackConfirmed) return;
          AppLog.warn(
            'Player: codec-open error — no decoded frame within fallback'
            ' window, reconnecting channel="${widget.channel.name}"',
          );
          onDisconnect(reason: 'player error: Could not open codec');
        });
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
      // finding 15: VOD terminal-failure path. onDisconnect returns early for
      // non-livestream anyway (it only reconnects live), so a VOD error would
      // otherwise vanish silently. Surface a terminal message instead and do
      // NOT set _isReconnecting.
      if (widget.channel.mediaType != MediaType.livestream) {
        if (mounted) {
          setState(() =>
              _bufferingState = 'Unable to play — ${Error.friendlyMessage(err)}');
        }
        return;
      }
      // onDisconnect() is the single source of truth for incrementing
      // _totalReconnectAttempts — do not pre-increment here, which caused
      // the counter to jump by 2 per failure and exceed widget.settings.maxReconnectAttempts.
      onDisconnect(reason: 'player error: $err');
    }));
    _engineSubs.add(_engine.bufferingStream.listen(_onBufferingChanged));
    // fix747: track mpv's play/pause state so the stall watchdog never fires
    // on a legitimately user-paused (or DVR-paused) live stream — during a
    // silent stall mpv keeps reporting playing=true.
    _engineSubs.add(_engine.playingStream.listen((p) => _enginePlaying = p));
    // fix732 (mock §4.7): clear the channel-zap shutter the moment the first
    // decoded frame renders. A fallback timer clears it regardless so a dead /
    // signal-less engine can never leave a stuck black shutter.
    _engineSubs.add(_engine.firstFrameStream.listen((_) {
      // fix742: a decoded frame proves the decoder chain works — cancel any
      // pending codec-fallback escalation for this open().
      // fix743: if this open saw a hw-probe codec-open error and the frame we
      // just got is the CONFIRMATION of mpv's software fallback, persist the
      // URL so future opens skip the doomed probe (30-day TTL, invalidated on
      // app update — see Sql.isHwdecBlocklisted). Gated on hardware having
      // actually been requested for this open (never on the 'no' path).
      final eng = _engine;
      if (_codecErrorLogged &&
          !_codecFallbackConfirmed &&
          eng is MpvEngine &&
          eng.appliedHwdecMode != null &&
          eng.appliedHwdecMode != 'no') {
        final url = widget.channel.url;
        if (url != null && url.isNotEmpty) {
          unawaited(Sql.addHwdecBlocklist(url));
        }
      }
      _codecFallbackConfirmed = true;
      _codecFallbackTimer?.cancel();
      _codecFallbackTimer = null;
      _clearShutter();
    }));
    // fix735: sustained A/V desync → silent resync (reopen). See _onAvsyncDesync.
    _engineSubs.add(_engine.desyncStream.listen(_onAvsyncDesync));
    if (_showShutter) {
      _shutterTimeout = Timer(const Duration(seconds: 4), _clearShutter);
    }
  }

  /// fix732: fade out the zap shutter (one-shot; cancels the fallback).
  void _clearShutter() {
    _shutterTimeout?.cancel();
    _shutterTimeout = null;
    if (mounted && _showShutter) setState(() => _showShutter = false);
  }

  /// fix735: react to a sustained A/V desync from the engine watchdog by
  /// reopening the stream (a fresh open resets avsync to ~0 — device-verified).
  /// Backoff: a resync that HOLDS >3min is a legit slow-drift correction (reset
  /// strikes, keep correcting); resyncs recurring <3min apart mean the reopen
  /// isn't helping (intrinsic PTS) → after 3 strikes give up and keep playing
  /// (log only), so a broken feed degrades to a no-op instead of reopen-looping.
  void _onAvsyncDesync(double avsync) {
    // fix735 (review): also bail while casting (local engine paused) and once
    // we've given up (sticky — a fresh tune / channel change is a new Player).
    if (!mounted ||
        exiting ||
        _exitInvoked ||
        _isReconnecting ||
        _isCasting ||
        _avsyncGaveUp) {
      return;
    }
    final now = DateTime.now();
    if (_lastAvsyncResync != null) {
      final since = now.difference(_lastAvsyncResync!);
      if (since < const Duration(seconds: 30)) return; // debounce overlaps
      if (since < const Duration(minutes: 3)) {
        _avsyncResyncStrikes++;
      } else {
        _avsyncResyncStrikes = 0; // previous resync held → drift, keep fixing
      }
    }
    if (_avsyncResyncStrikes >= 3) {
      // fix735 (review): TERMINAL give-up — a broken-PTS feed's reopen never
      // holds, so stop retrying for this Player's life (avoids a perpetual
      // throttled reopen-loop of black flashes); a fresh tune resets it.
      _avsyncGaveUp = true;
      AppLog.warn('Player: avsync watchdog giving up (sticky) — resync not '
          'holding (intrinsic PTS?) avsync=${avsync.toStringAsFixed(1)}s');
      return;
    }
    _lastAvsyncResync = now;
    AppLog.info('Player: avsync watchdog → resync '
        '(avsync=${avsync.toStringAsFixed(1)}s strikes=$_avsyncResyncStrikes) '
        'channel="${widget.channel.name}"');
    onDisconnect(reason: 'avsync watchdog');
  }

  /// fix747: (re)arm the silent-stall watchdog. Samples the playback position
  /// every few seconds; if a live stream's position stops advancing while the
  /// engine still reports playing and isn't buffering, the feed has silently
  /// wedged (no buffering event ever fired) → reconnect. Cancelled on
  /// buffering, reconnect, and dispose; re-armed on the next buffering=false.
  void _startStallWatchdog() {
    _stallWatchdog?.cancel();
    _stallLastPos = _engine.position;
    _stallLastAdvanceAt = DateTime.now();
    _stallWatchdog =
        Timer.periodic(const Duration(seconds: 3), _checkStall);
  }

  void _checkStall(Timer _) {
    // Keep the baseline fresh whenever steady progress isn't expected, so a
    // pause / buffering / grace window can never be mistaken for a stall.
    //
    // fix753: mpv's playing flag is NOT a bail condition — the measured S938U
    // wedge reports playing=false AND pause=yes (mpv self-pauses at a provider
    // PTS discontinuity with a full buffer), so bailing on either would make
    // this watchdog structurally blind to the exact failure it exists for
    // (fix747's original defect). The exemptions are INTENT and CONTEXT:
    // a pause we requested, DVR (frozen position is normal while scrubbing),
    // and the app not being foregrounded (an answered call / backgrounding
    // legitimately halts playback without any pause request of ours).
    if (!mounted ||
        exiting ||
        _exitInvoked ||
        _isReconnecting ||
        _isCasting ||
        _startupGrace ||
        _bufferingState != null ||
        _pauseRequested ||
        !_lifecycleResumed ||
        _engine.dvrActive) {
      _stallLastPos = _engine.position;
      _stallLastAdvanceAt = DateTime.now();
      return;
    }
    final pos = _engine.position;
    // fix753 (measured constraint): ANY position change — forward OR backward,
    // including the provider PTS resets that jump to negative values
    // (ABC30: 36002ms → -10031ms) — counts as progress and refreshes the
    // baseline. Only a truly unchanged position accumulates stall time; the
    // measured wedge is exactly frozen (2136ms constant for minutes).
    if (_stallLastPos == null || pos != _stallLastPos) {
      _stallLastPos = pos;
      _stallLastAdvanceAt = DateTime.now();
      return;
    }
    final frozenFor =
        DateTime.now().difference(_stallLastAdvanceAt ?? DateTime.now());
    if (frozenFor.inSeconds >= _stallWatchdogSecs) {
      unawaited(_confirmAndFireStall(pos, frozenFor));
    }
  }

  /// fix753: firing-time heuristic. cacheSpeed==0 is NOT a wedge discriminator
  /// (a settled pause also reads 0 once its buffer fills, and the measured
  /// wedge holds a FULL 95s buffer) — but during the first seconds of any
  /// unflagged pause the demuxer is still topping up (speed > 0), so this
  /// check delays a false fire long enough for the intent/lifecycle gates to
  /// be the real protection. A null read (property unavailable / engine
  /// disposed) is NON-confirming: never fire on missing data.
  Future<void> _confirmAndFireStall(Duration pos, Duration frozenFor) async {
    String? speed;
    final eng = _engine;
    if (eng is MpvEngine) {
      speed = await eng.readCacheSpeed();
    }
    // Re-validate after the await — the world may have moved.
    if (!mounted ||
        exiting ||
        _exitInvoked ||
        _isReconnecting ||
        _pauseRequested ||
        !_lifecycleResumed ||
        _stallWatchdog == null) {
      return;
    }
    if (_engine.position != pos) return; // advanced during the read
    if (speed == null || speed != '0') {
      // Data still flowing (or unreadable) — hold fire, keep accumulating.
      return;
    }
    AppLog.warn(
      'Player: stall watchdog → reconnect — live position frozen at '
      '${pos.inSeconds}s for ${frozenFor.inSeconds}s with no buffering '
      'signal enginePlaying=$_enginePlaying cacheSpeed=$speed (fix753) '
      'channel="${widget.channel.name}"',
    );
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
    onDisconnect(reason: 'stall watchdog');
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
      // fix747: buffering=true means mpv KNOWS it stalled — _bufferingWatchdog
      // owns recovery from here; stand the silent-stall watchdog down until
      // playback resumes (buffering=false re-arms it).
      _stallWatchdog?.cancel();
      _stallWatchdog = null;
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
      } else {
        // finding 15: VOD buffering watchdog. A stalled VOD open that emits
        // buffering=true and never buffering=false would otherwise wedge on
        // "Buffering..." forever (onDisconnect is live-only). Arm a longer
        // watchdog whose callback surfaces a terminal message — never
        // reconnects, never sets _isReconnecting.
        final base = widget.settings.bufferingWatchdogSecs;
        final watchdogSecs = base * 3;
        _bufferingWatchdog?.cancel();
        _bufferingWatchdog = Timer(
          Duration(seconds: watchdogSecs),
          () {
            if (mounted && !exiting) {
              setState(() =>
                  _bufferingState = 'Unable to play — stream stalled');
            }
          },
        );
        AppLog.info(
          'Player: VOD buffering watchdog armed ${watchdogSecs}s'
          ' channel="${widget.channel.name}"',
        );
      }
    } else {
      _bufferingWatchdog?.cancel();
      _bufferingWatchdog = null;
      // finding 28: first buffering=false means playback actually started —
      // now a movie resume-position save is safe.
      _playbackStartedThisSession = true;
      if (mounted) setState(() => _bufferingState = null);
      // fix747: playback is (re)flowing — arm the silent-stall watchdog for
      // live streams so a later wedge with no buffering event is still caught.
      if (widget.channel.mediaType == MediaType.livestream) {
        _startStallWatchdog();
      }

      // Expire startup grace 500ms after buffering=false. The mpv seek probe
      // fires at the same instant as buffering=false — delaying expiry ensures
      // the suppression guard in errorStream catches it regardless of event
      // delivery order between the two streams (separate native callbacks,
      // Dart delivery order not guaranteed within the same native event cycle).
      if (_startupGrace) {
        // finding 31: capture the open generation (finding 21) so a stale
        // grace-expiry callback from a PREVIOUS open can't clear the NEXT
        // open's grace early (it had no timer handle / cancellation before).
        final graceGen = _openGeneration;
        Future.delayed(
          Duration(milliseconds: widget.settings.startupGraceMs),
          () {
            if (mounted && graceGen == _openGeneration) {
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
    // finding 23: while casting the local engine is paused; a buffering/error
    // event from that pause must NOT trigger a reconnect.
    if (!mounted || exiting || _isReconnecting || _isCasting) return;
    if (widget.channel.mediaType != MediaType.livestream) return;

    // Set synchronously before any await so that a second onDisconnect call
    // arriving in the same event-loop tick is rejected by the guard above.
    _isReconnecting = true;
    _totalReconnectAttempts++;
    // fix747: stand the silent-stall watchdog down for the reconnect; it
    // re-arms on the next buffering=false once playback flows again.
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
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
      // finding 21: surface the in-flight-open state for diagnostics.
      ' startInFlight=$_startInFlight'
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
    // finding 16: always clear _isReconnecting, even if getChannelHeaders
    // (a bare db read, throws on 'database is locked' during a concurrent
    // refresh) or _startPlayback throws — otherwise the flag sticks true
    // forever and every future disconnect / network-restore is rejected,
    // wedging the player.
    try {
      final headers = await Sql.getChannelHeaders(id);
      await _startPlayback(null, headers: headers);
    } catch (e) {
      AppLog.warn('Player: reconnect tail failed — $e'
          ' channel="${widget.channel.name}"');
      // finding 20: a failed reconnect tail leaves the player idle — arm the
      // network-restore restart (livestream only).
      if (widget.channel.mediaType == MediaType.livestream) {
        _awaitingNetwork = true;
      }
    } finally {
      _isReconnecting = false;
    }
  }

  /// fix421: ensures the connection-setup timing probe runs once per
  /// user-initiated channel open, not on every reconnect.
  bool _connProbeDone = false;

  /// fix760: one-shot — the bounded wait for an in-flight tap-down prewarm
  /// only applies to the initial user-initiated open, never to reconnects
  /// (by then the cache is either warm or expired and mpv should just go).
  bool _prewarmWaitDone = false;

  /// fix659: one-shot — landscape lock is applied BEFORE the first open() so
  /// the decoder never initializes against the portrait/unsettled surface.
  bool _preOpenFullscreenDone = false;

  Future<void> _startPlayback(
    Duration? startPosition, {
    ChannelHttpHeaders? headers,
  }) async {
    // finding 21: open-generation guard. Bumping the generation on every entry
    // makes any prior retry loop (still sleeping in a backoff, or about to
    // re-open after a hung open()) abort at its next await — so an errorStream
    // event during the initial retry loop, a network-restore restart, or a
    // cast-resume can't spawn a second concurrent open loop against the engine.
    final myGen = ++_openGeneration;
    _startInFlight = true;
    _startupGrace = false; // Reset on every attempt (including retries)
    _seekProbeLogged = false; // fix380: one log per open() for the startup probe
    _vfErrorLogged = false; // fix566: one vf-cap-error log per open()
    _codecFallbackTimer?.cancel(); // fix742: fresh fallback window per open()
    _codecFallbackTimer = null;
    _codecFallbackConfirmed = false;
    _codecErrorLogged = false;
    // fix753: a fresh open (zap/reconnect) is always an intent to PLAY — clear
    // any stale pause intent so the stall watchdog can never be left disabled
    // by a pause that belonged to a previous channel/session. (Adopt-path
    // note: promote-to-fullscreen adopts an engine WITHOUT open(), so this
    // reset does not run there; the flag construct-initialises to false, and
    // an engine adopted mid-stability-pause will therefore be reconnected by
    // the watchdog after the threshold — acceptable, and today the only
    // recovery an orphaned stability pause has.)
    _pauseRequested = false;
    final timeout = Duration(seconds: widget.settings.openTimeoutSecs);
    try {
    while (true) {
      if (!mounted || exiting) return;
      if (myGen != _openGeneration) return; // finding 21: superseded
      _startupWatchdog?.cancel(); // fix94: clear before re-open
      try {
        // fix760: if a tap-down prewarm (ChannelTile) is still resolving the
        // redirect chain, give it a short, bounded head-start window before
        // reading the URL — otherwise the resolution races this open and
        // usually loses. When it lands in time, _playbackUrl() returns the
        // pre-resolved URL and mpv skips the redirect walk entirely.
        // Not free at worst: if the resolver does NOT finish within the bound,
        // mpv (its own native network stack — it can't reuse the Dart-warmed
        // connection) walks the redirects itself, so a timeout adds up to the
        // bound with no gain. The bound is kept short (150 ms) because tap-down
        // already gives a ~100–300 ms head start before this runs, so the
        // common wins land during that head start regardless — 150 ms only has
        // to catch resolutions that finish just after _startPlayback begins,
        // while halving the worst-case waste vs a 300 ms bound.
        if (!_prewarmWaitDone) {
          _prewarmWaitDone = true;
          final chId = widget.channel.id;
          if (widget.overrideUrl == null && chId != null) {
            final pending = ChannelTile.pendingPrewarm(chId);
            if (pending != null) {
              await pending
                  .timeout(const Duration(milliseconds: 150))
                  .catchError((_) => null);
              // finding 21 hygiene: an await opened a superseding window.
              if (myGen != _openGeneration) return;
            }
          }
        }
        final playbackUrl = _playbackUrl();
        // fix421: one-shot connection-setup timing (DNS/TCP/TLS) for this
        // channel open — diagnostic only, fire-and-forget, skipped on
        // reconnects so it runs once per user-initiated play.
        if (!_connProbeDone) {
          _connProbeDone = true;
          unawaited(ConnTiming.probe(playbackUrl));
        }
        // fix659: rotate FIRST. On the very first play after app launch the
        // phone is still settling portrait→landscape while open() runs, so
        // mediacodec opened against a NULL/portrait surface and had to
        // re-open once the landscape surface arrived — discarding the initial
        // cache fill and thrashing 'Enter buffering' for the whole session
        // (20 stalls on stream 1 vs 0 on streams 2/3 of the same URL in the
        // 2026-07-06 sms938u log). Lock landscape and let one frame lay out
        // BEFORE the first open() so the decoder binds the final surface
        // once. One-shot per Player: reconnect iterations skip it (the
        // orientation is already locked), and the post-open call at the
        // success site remains as a harmless idempotent re-assert. Skipped in
        // PiP (can't rotate) and for engines that manage their own
        // fullscreen, mirroring the existing post-open condition.
        // fix760: the rotate/relayout wait (fix659) and the mpv option
        // application are independent — options need no surface, the surface
        // needs no options — so run them CONCURRENTLY instead of serially.
        // Both still complete before open(), which is the ordering that
        // actually matters (fix659: landscape surface before open; engine
        // contract: options applied before open).
        final preOpen = <Future<void>>[];
        if (!_preOpenFullscreenDone &&
            !_inPipMode &&
            !_engine.handlesOwnFullscreen) {
          _preOpenFullscreenDone = true;
          preOpen.add(() async {
            try {
              await _enterSystemFullscreen();
              // Give the relayout one frame to land so the video surface
              // attaches at its final (landscape) size before open().
              await WidgetsBinding.instance.endOfFrame;
            } catch (e) {
              AppLog.warn(
                  'Player: pre-open fullscreen failed (non-fatal) — $e');
            }
          }());
        }
        final httpHeaders = headers != null
            ? {
                if (headers.referrer != null) 'Referer': headers.referrer!,
                if (headers.httpOrigin != null) 'Origin': headers.httpOrigin!,
                if (headers.userAgent != null) 'User-Agent': headers.userAgent!,
              }
            : null;

        if (_engine case final MpvEngine mpv) {
          preOpen.add(mpv.reapplyOptions(
            url: playbackUrl,
            ignoreSsl: _isIgnoreSsl(headers),
            // fix414: while minimized to PiP, MediaCodec can't re-init, so the
            // re-open would hang — force software decode for the reconnect so
            // it recovers in PiP. No-op for the initial open (never in PiP).
            forceSoftwareDecode: _inPipMode,
          ));
          // finding 18: remember whether this open was forced to software so
          // PiP-exit can restore hardware decode (otherwise the stream stays on
          // software decode forever — black-with-audio on Tegra full-screen).
          _lastOpenForcedSoftware = _inPipMode;
        }
        if (preOpen.isNotEmpty) await Future.wait(preOpen);

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

        // finding 21: a newer _startPlayback superseded us while open() was in
        // flight (e.g. a hung open resolving after a fresh open started). Abort
        // so we don't clobber the winning loop's state with this stale open.
        if (myGen != _openGeneration) return;
        _consecutiveOpenFailures = 0;
        _awaitingNetwork = false; // finding 20: healthy open clears idle state
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
        } else {
          // finding 15: VOD startup watchdog. If open() succeeds but no frame /
          // buffering event ever arrives (a dead VOD URL that resolved on
          // command acceptance), this is the only reliable catch — surface a
          // terminal message rather than reconnecting.
          final startupSecs = widget.settings.bufferingWatchdogSecs * 3;
          _startupWatchdog?.cancel();
          _startupWatchdog = Timer(
            Duration(seconds: startupSecs),
            () {
              if (mounted && !exiting) {
                AppLog.warn(
                  'Player: VOD startup watchdog fired after ${startupSecs}s'
                  ' — open succeeded but no frame'
                  ' channel="${widget.channel.name}"',
                );
                setState(() =>
                    _bufferingState = 'Unable to play — stream stalled');
              }
            },
          );
          AppLog.info(
            'Player: VOD startup watchdog armed ${startupSecs}s'
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
          // finding 20: retries exhausted — mark idle-awaiting-network so a
          // later connectivity restore restarts playback (livestream only).
          if (widget.channel.mediaType == MediaType.livestream) {
            _awaitingNetwork = true;
          }
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
        // finding 21: superseded during the backoff sleep — abort so the
        // stale loop doesn't re-open on top of the winning loop.
        if (myGen != _openGeneration) return;
      }
    }
    } finally {
      // finding 21: only clear the in-flight flag if WE are still the current
      // generation — a newer loop that superseded us owns the flag now.
      if (myGen == _openGeneration) _startInFlight = false;
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
    _stallWatchdog?.cancel(); // fix747
    _stableTimer?.cancel();
    _surfTimer?.cancel(); // fix397
    _overlayHideTimer?.cancel(); // fix580
    _sleepTimer?.cancel(); // fix727
    _shutterTimeout?.cancel(); // fix732
    _codecFallbackTimer?.cancel(); // fix742
    _skipIndicatorTimer?.cancel(); // fix649
    _seekFlushTimer?.cancel(); // fix651
    _overlayFirstFocus.dispose(); // fix580
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

    // finding 17: the first guard is now `_isCasting` only (was
    // `_castState == connected || _isCasting`). A connected-but-not-casting
    // session must fall through to the startCast block below; the old OR made
    // that state wrongly offer "Stop" and left startCast unreachable dead code.
    if (_isCasting) {
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
        // finding 22: resume locally through _startPlayback so per-channel
        // HTTP headers / ignoreSsl / open timeout / watchdogs are all applied
        // uniformly — the old bare reapplyOptions(url)+open dropped headers and
        // had no timeout. getChannelHeaders is a bare db read (no internal
        // catch) so wrap the whole resume in try/catch.
        try {
          final cid = widget.channel.id;
          final resumeHeaders =
              cid != null ? await Sql.getChannelHeaders(cid) : null;
          await _startPlayback(resumePosition, headers: resumeHeaders);
        } catch (e) {
          AppLog.warn('Player: cast-stop resume failed — $e'
              ' channel="${widget.channel.name}"');
          if (mounted) {
            setState(() => _bufferingState = 'Couldn\'t resume playback');
          }
        }
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

    // Connected but not casting — begin casting
    try {
      final ok = await CastController.startCast(
        url: url,
        title: widget.channel.name,
        contentType: CastController.mimeTypeFor(url),
      );
      if (ok && mounted) {
        // finding 23: stop the local engine before marking casting, so a
        // maxConnections=1 provider frees the slot for the receiver and there
        // is no double playback. PlayerEngine exposes only pause() (no stop()),
        // so use pause() — the minimum safe form. The engine's error/buffering
        // handlers are guarded by _isCasting below so pausing can't trigger a
        // spurious reconnect.
        try {
          _pauseRequested = true; // fix753: intentional pause (cast handoff)
          await _engine.pause();
        } catch (_) {}
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

  /// fix651: queue a transport seek. The FIRST request in an idle window is
  /// applied immediately (a single tap feels instant); while the flush timer
  /// is live, further deltas accumulate and land together on the next
  /// [_seekFlushEvery] tick — ONE engine.seek per tick regardless of the
  /// key-repeat rate. The skip chip updates per request, so feedback stays
  /// per-press even while the engine seek is batched.
  void _requestSeek(Duration delta) {
    if (!_canSeekTransport) return;
    _noteSkip(delta);
    _pendingSeek += delta;
    if (_seekFlushTimer != null) return;
    _flushPendingSeek();
    _seekFlushTimer = Timer.periodic(_seekFlushEvery, (_) {
      if (_pendingSeek == Duration.zero) {
        _seekFlushTimer?.cancel();
        _seekFlushTimer = null;
      } else {
        _flushPendingSeek();
      }
    });
  }

  void _flushPendingSeek() {
    final delta = _pendingSeek;
    _pendingSeek = Duration.zero;
    if (delta == Duration.zero) return;
    unawaited(_seekBy(delta));
  }

  /// fix649: shared ◀/▶ transport seek — live-DVR AND VOD (was `_dvrSeekBy`,
  /// gated on dvrActive only, which left LEFT/RIGHT dead on TV movies/series).
  /// Clamps to [0, duration]; duration unknown/0 → only the zero floor (mpv
  /// clamps the live edge itself). fix651: callers go through [_requestSeek]
  /// (which owns the skip chip + coalescing); this only performs the seek.
  Future<void> _seekBy(Duration delta) async {
    if (!_canSeekTransport) return;
    // finding 32: accumulate from a virtual base across a burst so successive
    // coalesced flushes don't each read the engine's possibly-stale position
    // (which lags the prior seek on a slow box), making held seeks land short.
    // The base seeds from the live position at the first flush of a burst and
    // advances to each computed target; it resets to null when the skip chip
    // clears (see _noteSkip), so the next independent burst re-seeds live.
    final base = _virtualSeekBase ?? _engine.position;
    var target = base + delta;
    if (target.isNegative) target = Duration.zero;
    final dur = _engine.duration;
    if (dur > Duration.zero && target > dur) target = dur;
    _virtualSeekBase = target; // next flush accumulates from here
    await _engine.seek(target);
    AppLog.info(
        'Player: transport seek ${delta.inSeconds}s -> ${target.inSeconds}s');
  }

  /// fix649: record a ◀/▶ seek in the on-screen skip chip. Accumulates the
  /// net signed seconds across rapid presses, then clears after
  /// [_skipIndicatorHold] of inactivity.
  void _noteSkip(Duration delta) {
    if (!mounted) return;
    _skipIndicatorTimer?.cancel();
    setState(() => _skipIndicatorSecs += delta.inSeconds);
    _skipIndicatorTimer = Timer(_skipIndicatorHold, () {
      // finding 32: burst ended — reset the virtual seek base so the next
      // independent seek re-seeds from the live engine position.
      _virtualSeekBase = null;
      if (mounted) setState(() => _skipIndicatorSecs = 0);
    });
  }

  /// fix649: the centered "+30 s" / "−10 s" chip shown while ◀/▶ seeks land.
  Widget _buildSkipIndicator() {
    final secs = _skipIndicatorSecs;
    final label = secs > 0 ? '+$secs s' : '−${secs.abs()} s';
    final icon = secs > 0 ? Icons.fast_forward : Icons.fast_rewind;
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 28),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _dvrGoLive() async {
    if (!_engine.dvrActive) return;
    await _engine.seek(const Duration(days: 1)); // mpv clamps to live edge
    if (!_engine.isPlaying) {
      _pauseRequested = false; // fix753: resumed (DVR)
      await _engine.play();
    }
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
      // finding 33: the media_kit Skip buttons are inert — the engine opens a
      // single Media with PlaylistMode.none, so there is no media_kit playlist
      // to skip. Use the app's own _surf (prev/next in the launch playlist),
      // gated on _canSurf; with no playlist only play/pause shows (no dead
      // buttons). +1 = down the list = "next" (matches the live branch).
      return [
        if (_canSurf)
          _dvrButton(Icons.skip_previous, 'Previous', () => _surf(-1)),
        const MaterialPlayOrPauseButton(iconSize: 40.0),
        if (_canSurf)
          _dvrButton(Icons.skip_next, 'Next', () => _surf(1)),
      ];
    }
    final dvr = _engine.dvrActive;
    return [
      if (_canSurf)
        _dvrButton(Icons.keyboard_arrow_up, 'Channel up', () => _surf(-1)),
      if (dvr)
        _dvrButton(Icons.replay_10, 'Rewind 10s',
            () => _requestSeek(const Duration(seconds: -10))),
      const MaterialPlayOrPauseButton(iconSize: 40.0),
      if (dvr) ...[
        _dvrButton(Icons.forward_10, 'Forward 10s',
            () => _requestSeek(const Duration(seconds: 10))),
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

  /// fix649: transport-seek availability for the ◀/▶ keys and overlay
  /// buttons. Live uses the DVR window ([PlayerEngine.dvrActive]); VOD
  /// (movies/series) is seekable by nature — the engine's existing
  /// seek-probe/grace handling absorbs the rare non-seekable VOD stream.
  bool get _canSeekTransport =>
      _engine.dvrActive || widget.channel.mediaType != MediaType.livestream;

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
    // finding 24: surfing away via pushReplacement disposes this Player without
    // running onExit, so persist a movie's resume position here first (same
    // finding-28 guard so a not-started/near-zero position can't clobber it).
    if (widget.channel.mediaType == MediaType.movie) {
      final curId = widget.channel.id;
      final pos = _engine.position.inSeconds;
      if (curId != null && _playbackStartedThisSession && pos > 5) {
        try {
          await Sql.setPosition(curId, pos)
              .timeout(const Duration(seconds: 1));
        } catch (e) {
          AppLog.warn('Player: surf setPosition skipped — $e');
        }
      }
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
          sleepDeadline: _sleepDeadline, // fix727: keep the sleep timer running
        ),
      ),
    );
  }

  /// Remote channel keys (Android TV CH+/CH−). Up = up the list, down = down.
  /// fix576: toggle play/pause (used by D-pad OK / center).
  Future<void> _togglePlayPause() async {
    if (_engine.isPlaying) {
      _pauseRequested = true; // fix753: intentional pause (user)
      await _engine.pause();
    } else {
      _pauseRequested = false; // fix753: user resumed
      // fix652: optional rewind on resume — VOD only. A paused live-DVR
      // stream is already behind the live edge by the pause length, so a
      // further skip back would just double the lag.
      final n = widget.settings.devSkipBackOnResumeSecs;
      if (n > 0 &&
          widget.channel.mediaType != MediaType.livestream &&
          _engine.position > Duration(seconds: n)) {
        await _engine.seek(_engine.position - Duration(seconds: n));
      }
      await _engine.play();
    }
  }

  /// fix577: reveal the control bars by synthesizing a tap at the video centre.
  /// media_kit 2.0.1 toggles its bars on tap (private state, no public API), so
  /// this shows them exactly like a screen tap; media_kit then auto-hides them
  /// after controlsHoverDuration. (fix576's keyed-remount + visibleOnMount did
  /// not work on-device — the controls state survives the theme remount.)
  void _revealControls() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final centre = box.localToGlobal(box.size.center(Offset.zero));
    const pointer = 0xF4EE; // arbitrary synthetic pointer id
    final binding = GestureBinding.instance;
    binding.handlePointerEvent(
        PointerDownEvent(pointer: pointer, position: centre));
    binding.handlePointerEvent(
        PointerUpEvent(pointer: pointer, position: centre));
  }

  // ─── fix580: custom focusable TV control overlay (Mode B) ────────────────

  void _resetOverlayHideTimer() {
    _overlayHideTimer?.cancel();
    _overlayHideTimer = Timer(_overlayAutoHide, _closeOverlay);
  }

  void _openOverlay() {
    if (_navMode || !mounted) return;
    setState(() => _navMode = true);
    _resetOverlayHideTimer();
    // Move focus INTO the overlay explicitly — autofocus is dropped because
    // _surfKeyFocus already holds focus in this scope. Post-frame so the
    // button is mounted. Without this the D-pad is dead until auto-hide
    // (the fix577/578 on-device failure).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _navMode) _overlayFirstFocus.requestFocus();
    });
  }

  /// The SOLE writer of `_navMode = false`. ALWAYS reclaims the player Focus so
  /// the D-pad direct-map resumes — the keystone against the fix578 regression
  /// where a stuck nav flag left the entire D-pad dead. Every exit path (Back,
  /// auto-hide, surface-changing action) routes through here.
  void _closeOverlay() {
    _overlayHideTimer?.cancel();
    if (!_navMode || !mounted) return;
    setState(() => _navMode = false);
    _surfKeyFocus.requestFocus();
  }

  /// A focusable overlay button. Keeps the overlay alive (resets auto-hide) and
  /// runs [onTap]. media_kit's Material* buttons are deliberately NOT used —
  /// they are not focusable and read media_kit's controller context, which is
  /// absent under NoVideoControls.
  // fix715 (Phase 4 OSD unit 2): route through OsdActionButton so the button
  // gets the Peer2 focus lift (scale-up) on top of the accent ring the global
  // iconButtonTheme already draws (fix707). Trigger + focus behavior unchanged
  // (Option B). onInteract preserves the old onPressed → _resetOverlayHideTimer.
  Widget _ovlButton(IconData icon, String tip, VoidCallback onTap,
          {FocusNode? focusNode}) =>
      OsdActionButton(
        icon: icon,
        tip: tip,
        onTap: onTap,
        onInteract: _resetOverlayHideTimer,
        focusNode: focusNode,
      );

  Future<void> _openSubtitlesFromOverlay() async {
    _overlayHideTimer?.cancel(); // don't hide under the dialog
    await openSubtitlesModal();
    if (mounted && _navMode) _resetOverlayHideTimer();
  }

  Future<void> _openAudioFromOverlay() async {
    _overlayHideTimer?.cancel();
    await openAudioModal();
    if (mounted && _navMode) _resetOverlayHideTimer();
  }

  // fix727 (mock §4.6): playback-speed picker. Presets per the mock; the same
  // SelectDialog the track pickers use, so it inherits the glass theme + D-pad
  // traversal + the auto-hide-cancel wrapper. Only shown on VOD (the button gate
  // is `!live && tracks`); the setState refreshes the button's rate label.
  static const List<double> _speedPresets = [
    0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0,
  ];
  Future<void> _openSpeedFromOverlay() async {
    _overlayHideTimer?.cancel();
    final current = _engine.playbackRate;
    // nearest preset index so the active speed is pre-highlighted
    var selected = 3; // 1.0×
    for (var i = 0; i < _speedPresets.length; i++) {
      if ((_speedPresets[i] - current).abs() <
          (_speedPresets[selected] - current).abs()) {
        selected = i;
      }
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => SelectDialog(
        title: 'Playback speed',
        selectedId: selected,
        action: (id) async {
          await _engine.setRate(_speedPresets[id]);
          if (context.mounted) Navigator.of(context).pop();
          if (mounted) setState(() {}); // refresh the OSD speed affordance
        },
        data: [
          for (var i = 0; i < _speedPresets.length; i++)
            IdData(
                id: i,
                data: _speedPresets[i] == 1.0
                    ? 'Normal (1.0×)'
                    : '${_speedPresets[i]}×'),
        ],
      ),
    );
    if (mounted && _navMode) _resetOverlayHideTimer();
  }

  // fix727 (mock §4.6): sleep-timer picker. "Off" cancels; a duration arms a
  // one-shot Timer that pauses playback then exits the player. Same SelectDialog
  // pattern; 0 = Off is pre-highlighted when idle.
  static const List<int> _sleepPresets = [0, 15, 30, 45, 60, 90];
  Future<void> _openSleepTimerFromOverlay() async {
    _overlayHideTimer?.cancel();
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => SelectDialog(
        title: 'Sleep timer',
        selectedId: _sleepMinutes,
        action: (id) async {
          _armSleepTimer(id);
          if (context.mounted) Navigator.of(context).pop();
        },
        data: [
          for (final m in _sleepPresets)
            IdData(id: m, data: m == 0 ? 'Off' : '$m minutes'),
        ],
      ),
    );
    if (mounted && _navMode) _resetOverlayHideTimer();
  }

  /// Arm (or with [minutes] == 0, cancel) the sleep timer from a user pick.
  /// Records the wall-clock deadline so a channel surf can carry it forward.
  void _armSleepTimer(int minutes) {
    if (minutes <= 0) {
      _sleepTimer?.cancel();
      _sleepTimer = null;
      _sleepDeadline = null;
      if (mounted) setState(() => _sleepMinutes = 0);
      return;
    }
    _scheduleSleep(DateTime.now().add(Duration(minutes: minutes)));
  }

  /// Schedule the one-shot sleep fire for wall-clock [deadline]. Shared by a
  /// fresh user pick and by initState re-arming across a channel surf. On fire:
  /// dismiss any OSD dialog sitting above the player route (else onExit would
  /// pop the DIALOG, not the player, wedging it — adversarial-review finding 1),
  /// pause the engine, then route through the guarded [onExit].
  void _scheduleSleep(DateTime deadline) {
    _sleepTimer?.cancel();
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      _sleepTimer = null;
      _sleepDeadline = null;
      if (mounted) setState(() => _sleepMinutes = 0);
      return;
    }
    _sleepDeadline = deadline;
    _sleepTimer = Timer(remaining, () async {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) {
        // an OSD picker (or other dialog) is on top — drop it to the player
        Navigator.of(context).popUntil((r) => r == route);
      }
      try {
        _pauseRequested = true; // fix753: intentional pause (sleep timer)
        await _engine.pause();
      } catch (_) {}
      if (mounted) onExit();
    });
    // round up for the icon label; ensures a sub-minute residual still reads ≥1
    final mins = (remaining.inSeconds / 60).ceil();
    if (mounted) setState(() => _sleepMinutes = mins);
  }

  /// finding 34: the overlay Cast action opens a device picker / stop dialog.
  /// Cancel the auto-hide timer while it's pending so _closeOverlay can't fire
  /// mid-dialog and yank D-pad focus out from under the picker (mirrors the
  /// subtitles/audio wrappers, which the plain Cast button did not).
  Future<void> _onCastFromOverlay() async {
    _overlayHideTimer?.cancel();
    await _onCastTap();
    if (mounted && _navMode) _resetOverlayHideTimer();
  }

  /// fix650: position/duration progress row for the TV overlay. Display-only —
  /// seeking stays on the ◀/▶ keys and rewind/forward buttons; a focusable
  /// slider would need its own key handling and steal D-pad LEFT/RIGHT from
  /// the overlay's focus traversal. Hidden while the engine reports no
  /// duration (plain live without a DVR window).
  Widget _buildOverlayProgress() {
    String fmt(Duration d) {
      final h = d.inHours;
      final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return h > 0 ? '$h:$m:$s' : '$m:$s';
    }

    return StreamBuilder<Duration>(
      stream: _engine.positionStream,
      initialData: _engine.position,
      builder: (context, snap) {
        final pos = snap.data ?? Duration.zero;
        final dur = _engine.duration;
        if (dur <= Duration.zero) return const SizedBox.shrink();
        final frac = (pos.inMilliseconds / dur.inMilliseconds)
            .clamp(0.0, 1.0)
            .toDouble();
        // fix714: no bottom padding — this row now lives inside the Info Bar's
        // padded glass card, so the card's own spacing governs (was
        // EdgeInsets.only(bottom: 8), which double-padded inside the card).
        return Padding(
          padding: EdgeInsets.zero,
          child: Row(
            children: [
              Text(fmt(pos), style: const TextStyle(color: Colors.white)),
              const SizedBox(width: 12),
              Expanded(
                child: LinearProgressIndicator(
                  value: frac,
                  minHeight: 4,
                  backgroundColor: Colors.white24,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Text(fmt(dur), style: const TextStyle(color: Colors.white)),
            ],
          ),
        );
      },
    );
  }

  /// The TV control overlay: a native Flutter [FocusTraversalGroup] of
  /// focusable [IconButton]s the D-pad navigates geometrically (arrows →
  /// DirectionalFocusIntent, OK → activate — the same path the TV browse UI
  /// already uses). Built only when [_navMode], single-cell full-screen —
  /// live AND VOD since fix650 (VOD previously fell back to media_kit's bars,
  /// which cannot host D-pad focus).
  Widget _buildTvOverlay() {
    final engine = _engine;
    final dvr = engine.dvrActive;
    final live = widget.channel.mediaType == MediaType.livestream;
    final seekable = _canSeekTransport; // fix650: DVR or VOD
    final tracks = engine.supportsTrackSelection;
    final tokens = F4.of(context); // fix731: token scrim

    final topBar = Row(
      children: [
        _ovlButton(Icons.arrow_back, 'Back', onExit),
        const Spacer(),
        // fix714 (Phase 4 OSD unit 1): the channel name + NOW/NEXT EPG moved out
        // of the flat top bar into the bottom Info Bar (Peer2 anatomy). The top
        // bar keeps just Back + Cast/PiP.
        if (_castSupported)
          // finding 34: route through the dialog-aware wrapper so the 8s
          // auto-hide timer is cancelled while the cast dialog is open.
          _ovlButton(_castIcon, _isCasting ? 'Stop casting' : 'Cast',
              _onCastFromOverlay),
        if (_pipSupported)
          _ovlButton(Icons.picture_in_picture_alt, 'Picture-in-picture',
              () => PipController.enterPip()),
      ],
    );

    // Play/Pause autofocuses (first-focus) and rebuilds reactively from the
    // engine's playing stream (no media_kit frozen-state problem here).
    final playPause = StreamBuilder<bool>(
      stream: engine.playingStream,
      initialData: engine.isPlaying,
      builder: (context, snap) {
        final playing = snap.data ?? engine.isPlaying;
        return _ovlButton(
          playing ? Icons.pause : Icons.play_arrow,
          playing ? 'Pause' : 'Play',
          _togglePlayPause,
          focusNode: _overlayFirstFocus,
        );
      },
    );

    final bottomBar = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (tracks) ...[
          _ovlButton(Icons.subtitles, 'Subtitles', _openSubtitlesFromOverlay),
          _ovlButton(Icons.music_note, 'Audio', _openAudioFromOverlay),
        ],
        if (_canSurf)
          _ovlButton(Icons.keyboard_arrow_up, 'Channel up', () => _surf(-1)),
        if (seekable)
          _ovlButton(Icons.replay_10, 'Rewind 10s',
              () => _requestSeek(const Duration(seconds: -10))),
        playPause,
        if (seekable)
          _ovlButton(Icons.forward_10, 'Forward 10s',
              () => _requestSeek(const Duration(seconds: 10))),
        if (dvr)
          _ovlButton(Icons.live_tv, 'Back to live', _dvrGoLive),
        if (_canSurf)
          _ovlButton(Icons.keyboard_arrow_down, 'Channel down', () => _surf(1)),
        _ovlButton(Icons.aspect_ratio_outlined, 'Aspect ratio', toggleZoom),
        // fix727 (mock §4.6): playback speed — VOD only. Live (incl. DVR-active)
        // is excluded: 2.0× would burn a DVR buffer to the live edge and 0.25×
        // fall behind it. `tracks` (supportsTrackSelection) is the MpvEngine
        // proxy — the only engine that implements setRate. The label shows the
        // active rate so the OSD reflects state; _openSpeedFromOverlay's setState
        // refreshes it (adversarial-review findings 3/4).
        if (!live && tracks)
          _ovlButton(
              Icons.speed,
              engine.playbackRate == 1.0
                  ? 'Playback speed'
                  : 'Playback speed (${engine.playbackRate}×)',
              _openSpeedFromOverlay),
        // finding 107: hide mini-player entry on TV/D-pad (controls not focusable)
        // finding 35: also gate on livestream to match the touch-bar bottomBar
        // gate — the mini-player (and its overlay engine) is a live-only path;
        // offering it on VOD hands off a movie with no resume/handoff support.
        if (!_tvMode && widget.channel.mediaType == MediaType.livestream)
          _ovlButton(
              Icons.picture_in_picture, 'Mini-player', _minimizeToOverlay),
        // fix727 (mock §4.6): sleep timer — the last Actions Bar entry. Filled
        // bedtime icon while armed so the OSD shows it is running.
        _ovlButton(
            _sleepMinutes > 0 ? Icons.bedtime : Icons.bedtime_outlined,
            _sleepMinutes > 0 ? 'Sleep timer ($_sleepMinutes min)' : 'Sleep timer',
            _openSleepTimerFromOverlay),
      ],
    );

    // fix731 (mock §4.6/§5): the OSD is always mounted and fades in/out via
    // AnimatedOpacity (crossIn/crossOut on the easeOut decel curve) instead of
    // snapping mount↔unmount. While hidden it is focus- and pointer-excluded so
    // the _navMode D-pad model is byte-unchanged (Opacity(0) also skips paint,
    // so no per-frame cost on the onn). The scrim is the token panelSlate at the
    // playerMenu (0.6) alpha → transparent middle, replacing the static black54.
    final scrim = tokens.colors.panelSlate
        .withValues(alpha: tokens.scrim.playerMenu);
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !_navMode,
        child: ExcludeFocus(
          excluding: !_navMode,
          child: AnimatedOpacity(
            opacity: _navMode ? 1.0 : 0.0,
            duration: _navMode ? F4Motion.crossIn : F4Motion.crossOut,
            curve: F4Motion.easeOut,
            child: FocusTraversalGroup(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [scrim, Colors.transparent, scrim],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            children: [
              topBar,
              const Spacer(),
              // fix716 (Phase 4 OSD unit 3): Peer2 Channel Bar — a display-only
              // surf-context strip (current group, tuned channel highlighted),
              // above the Info Bar. Only when there's a surfable group. It's
              // IgnorePointer/non-focusable, so the D-pad/_navMode model is
              // untouched (Option B); ▲▼ still surfs and a fresh Player at the
              // new index re-centers it.
              if (_canSurf && widget.playlist != null) ...[
                PlayerChannelBar(playlist: widget.playlist!),
                const SizedBox(height: 8),
              ],
              // fix714 (Phase 4 OSD unit 1): Peer2 bottom Info Bar — channel
              // logo + name + NOW programme + the seek-progress row (moved here
              // from the top bar + the old standalone progress row), on a token
              // glass card. The action buttons stay below, unchanged.
              PlayerInfoBar(
                channel: widget.channel,
                engine: engine,
                live: live,
                progress: seekable ? _buildOverlayProgress() : null,
                active: _navMode, // fix731: pause EPG poll while OSD hidden
              ),
              const SizedBox(height: 8),
              bottomBar,
            ],
          ),
              ), // Container
            ), // FocusTraversalGroup
          ), // AnimatedOpacity
        ), // ExcludeFocus
      ), // IgnorePointer
    ); // Positioned
  }

  /// fix576: player key handling. On TV the player Focus holds focus, so the
  /// remote D-pad maps directly: ▲/CH+ = channel up, ▼/CH− = channel down,
  /// ◀/▶ = seek −/+10s when seeking is available (live DVR or VOD — fix649),
  /// OK/center = play-pause + reveal the control bars. Unhandled keys (Back
  /// etc.) are ignored so they bubble to the PopScope / normal handling.
  KeyEventResult _onPlayerKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // fix580: while the custom overlay is open, its FocusTraversalGroup owns the
    // D-pad — return ignored so arrows traverse the bar buttons and OK activates
    // the focused one; just keep the overlay alive (reset auto-hide on each key,
    // incl. KeyRepeat so a held arrow does not expire mid-hold).
    if (_navMode) {
      _resetOverlayHideTimer();
      return KeyEventResult.ignored;
    }
    final action = playerKeyAction(
      event.logicalKey,
      canSurf: _canSurf,
      canSeek: _canSeekTransport,
    );
    switch (action) {
      case PlayerKeyAction.channelUp:
        _surf(-1);
        return KeyEventResult.handled;
      case PlayerKeyAction.channelDown:
        _surf(1);
        return KeyEventResult.handled;
      case PlayerKeyAction.seekBack:
      case PlayerKeyAction.seekForward:
        // fix651: repeats (held key) walk up the acceleration ladder; a fresh
        // KeyDown resets it. Deltas go through the coalescer, not straight to
        // the engine.
        _seekRepeatCount =
            event is KeyRepeatEvent ? _seekRepeatCount + 1 : 0;
        final step = seekStepSeconds(
          repeatCount: _seekRepeatCount,
          duration: widget.channel.mediaType == MediaType.livestream
              ? Duration.zero // DVR window length is unreliable → conservative
              : _engine.duration,
        );
        _requestSeek(Duration(
            seconds: action == PlayerKeyAction.seekBack ? -step : step));
        return KeyEventResult.handled;
      case PlayerKeyAction.playPauseReveal:
        // finding 25: act only on the initial press — a held OK fires KeyRepeat
        // events, which otherwise thrash play/pause and re-activate the focused
        // button. Consume repeats as handled without acting.
        if (event is! KeyDownEvent) return KeyEventResult.handled;
        _togglePlayPause();
        // fix580: TV single-cell → open the custom focusable overlay; phone →
        // media_kit's own bars via the synth tap. fix650 dropped the LIVE-only
        // gate: TV+VOD used media_kit's bars, which can't host D-pad focus
        // (the reverted fix578 problem), so VOD now gets the same overlay —
        // with a position/duration row.
        // finding 26: DECISION — dropped the persisted multiViewLayout==none
        // clause (mirrors fix653 for the stats panel). It read the persisted
        // grid-size setting, not the current view, so merely having a 2x2
        // layout configured routed every single-cell TV play to the
        // (non-focusable) media_kit bars instead of the focusable overlay,
        // leaving the D-pad dead. This Player IS a single full-screen cell, so
        // the focusable overlay is always the right control surface here.
        if (_tvMode) {
          _openOverlay();
        } else {
          _revealControls();
        }
        return KeyEventResult.handled;
      case PlayerKeyAction.none:
        return KeyEventResult.ignored;
    }
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
    // finding 27: the overlay opens its OWN connection to the same channel.
    // On a maxConnections=1 provider the mini-player then double-reads the
    // stream slot (this full-screen engine hasn't been released yet) and the
    // mini tile fails to open / shows a frozen black tile. The correct fix is
    // an engine handoff (detach/adopt, like _swap), but that needs an
    // OverlayPlayerController.adoptFullScreenEngine entry point (a second
    // file, out of scope here). MINIMUM safe fix in player.dart: pause the
    // local engine BEFORE startOverlay so the provider slot is freed for the
    // mini's open (a brief re-buffer on the mini is acceptable vs. a dead
    // tile). PlayerEngine exposes only pause() (no stop()).
    try {
      _pauseRequested = true; // fix753: intentional pause (overlay handoff)
      await _engine.pause();
    } catch (_) {}
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
    _stallWatchdog?.cancel(); // fix747: symmetry with the other swap cancels
    _stallWatchdog = null;
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
    _stallWatchdog?.cancel(); // fix747: symmetry with the other swap cancels
    _stallWatchdog = null;
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
    // finding 28: only when playback actually started AND we're past 5s — a
    // failed/aborted open (position 0, or a brief spurious nonzero) must not
    // overwrite a good stored resume point with ~0.
    if (widget.channel.mediaType == MediaType.movie) {
      final id = widget.channel.id;
      final pos = _engine.position.inSeconds;
      if (id != null && _playbackStartedThisSession && pos > 5) {
        try {
          await Sql.setPosition(id, pos)
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


  // finding 24: persist a movie's resume position when the app is backgrounded
  // or killed (onExit doesn't run on a swipe-away / process death). Paused +
  // movie + started-and-past-5s only (finding-28 guard), kept cheap.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // fix753: the stall watchdog only accumulates while foregrounded. An
    // ANSWERED phone call (the one OS-pause case field data could not
    // capture — a RINGING call was measured to not stop playback at all)
    // takes the app inactive/paused; without this gate that would read as an
    // unexplained freeze and reconnect a legitimately-halted stream.
    _lifecycleResumed = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.paused &&
        widget.channel.mediaType == MediaType.movie) {
      final id = widget.channel.id;
      final pos = _engine.position.inSeconds;
      if (id != null && _playbackStartedThisSession && pos > 5) {
        unawaited(Sql.setPosition(id, pos));
      }
    }
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
      // fix580: Back closes the TV overlay first (returns to direct-map) and
      // only leaves the player when the overlay is not open.
      onPopInvokedWithResult: (didPop, result) {
        if (_navMode) {
          _closeOverlay();
        } else {
          onExit();
        }
      },
      // fix397/fix576: the player Focus catches the remote D-pad + CH keys.
      // fix576 made it hold focus (autofocus) so D-pad arrows map directly to
      // channel/seek and OK toggles play-pause + reveals the bars on TV — the
      // previous bubble-only observer never saw the arrows. Unhandled keys
      // (Back etc.) are still ignored so they bubble to the PopScope.
      child: Focus(
        focusNode: _surfKeyFocus,
        autofocus: true,
        onKeyEvent: _onPlayerKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              _buildVideoArea(),
              // fix732 (mock §4.7): channel-zap shutter — a black cover over the
              // fresh-play black-load, fading out (F4Motion.shutter, easeOut) on
              // first-frame so the zap reads clean instead of a raw black flash.
              // Above the video, below the buffering spinner / banner / OSD.
              _buildZapShutter(),
              if (_bufferingState != null) _buildBufferingOverlay(),
              if (_surfBanner != null) _buildSurfBanner(),
              // fix649: ±seconds chip for ◀/▶ transport seeks.
              if (_skipIndicatorSecs != 0) _buildSkipIndicator(),
              // fix564: live playback-stats panel (top-right), full-screen
              // player, shown when debug logging is on. Also writes each
              // snapshot to the report log for offline review. fix653: no
              // longer gated on multiViewLayout == none — that clause read the
              // PERSISTED grid-size setting, not the current view, so merely
              // having a 2x2 layout configured hid the panel on every
              // single-cell play (from a tile AND from a maximized cell).
              // This Player IS a single full-screen cell; it's pure UI (no
              // engine), so it's safe even for a maximized-from-grid play. The
              // multi-view grid's own compact per-cell overlays stay mounted
              // (still streaming, just not painted) beneath the pushed Player.
              if (widget.settings.debugLogging && _engine is MpvEngine)
                DebugStatsOverlay(engine: _engine as MpvEngine),
              // fix580: custom focusable TV control overlay (Mode B).
              // fix731: always mounted so it can fade in/out (AnimatedOpacity);
              // it self-hides (opacity 0 + focus/pointer excluded) when !_navMode.
              _buildTvOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  /// fix732 (mock §4.7): the channel-zap shutter — a full-bleed black cover that
  /// masks the fresh-play black-load and fades out over F4Motion.shutter on
  /// first-frame. Always mounted (so it can fade); IgnorePointer + Opacity(0)
  /// when cleared, so it never blocks input or paints. The existing buffering
  /// spinner + surf banner render above it.
  Widget _buildZapShutter() => Positioned.fill(
        child: IgnorePointer(
          child: AnimatedOpacity(
            opacity: _showShutter ? 1.0 : 0.0,
            duration: F4Motion.shutter,
            curve: F4Motion.easeOut,
            child: const ColoredBox(color: Colors.black),
          ),
        ),
      );

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
    // fix580: on TV + single-cell + live, suppress media_kit's own (non-
    // focusable, tap-driven) controls — the custom focusable overlay
    // (_buildTvOverlay) is the control surface there. No MaterialVideoControlsTheme
    // wrapper / dvr-keyed remount: that read-once workaround is only for
    // media_kit's bars. Phone/touch and VOD keep the media_kit path below.
    // finding 26: DECISION — dropped the persisted multiViewLayout==none clause
    // (mirrors fix653/the _onPlayerKey gate). It read the persisted grid-size
    // setting, so a configured 2x2 layout made every single-cell TV live play
    // fall through to media_kit's own (non-focusable) bars instead of letting
    // the custom focusable overlay own the control surface.
    if (_tvMode && widget.channel.mediaType == MediaType.livestream) {
      return _engine.buildVideoView(context, suppressControls: true);
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
        // fix575: the name now carries the stream-info ("720p H.264") appended
        // once known — replacing the separate PlayerStreamInfoLabel that the
        // Expanded EPG label below squeezed off-screen.
        Flexible(
          child: PlayerChannelNameLabel(
            channelName: widget.channel.name,
            engine: _engine,
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
        // fix670: Record now — live streams only. Quick duration picker then a
        // background capture of the current channel.
        if (widget.channel.mediaType == MediaType.livestream &&
            widget.overrideUrl == null)
          IconButton(
            onPressed: () =>
                RecordingActions.recordNow(context, widget.channel),
            icon: const Icon(
              Icons.fiber_manual_record,
              color: Colors.redAccent,
              size: 28,
            ),
            tooltip: 'Record now',
          ),
        // fix653: dropped the multiViewLayout == none clause — it read the
        // persisted grid-size setting, hiding PiP on every single-cell play
        // once a layout was ever configured (see the stats-panel note above).
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
        // fix653 NOTE: deliberately still gated on multiViewLayout == none.
        // Flipping this like the stats panel/PiP is NOT safe: multi-view and
        // the mini-player are mutually exclusive by design (multi_view_screen
        // calls stopOverlay on entry), so minimizing a cell maximized from the
        // grid and returning would double-read the same .ts URL (see the
        // _promoteToFullScreen comment) — a "Failed to open" churn or a second
        // audible copy. Reachable-from-a-tile single-cell playback is the
        // common case, but this gate can't distinguish it from a maximized
        // cell, so the button stays gated until that UX is designed (fix654).
        // finding 107: also hide on TV/D-pad (mini-player controls not focusable)
        if (widget.channel.mediaType == MediaType.livestream &&
            widget.settings.multiViewLayout == MultiViewLayout.none &&
            !_tvMode) ...[
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
