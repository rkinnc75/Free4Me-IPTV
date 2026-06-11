import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/channel_picker_screen.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/channel_http_headers.dart';
import 'package:open_tv/models/engine_type.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/player.dart';
import 'package:open_tv/player/engine_picker.dart';
import 'package:open_tv/player/exo_engine.dart';
import 'package:open_tv/player/mpv_engine.dart';
import 'package:open_tv/player/player_engine.dart';
import 'package:open_tv/widgets/now_next_strip.dart';

/// fix250: D-pad select/menu intent that opens a cell's options menu (or, on
/// an empty cell, the channel picker). Lets TV remotes reach functionality
/// that was previously only available via touch long-press.
class _CellMenuIntent extends Intent {
  const _CellMenuIntent();
}

/// A single cell in the multi-view grid.
///
/// - Empty:    centred "+" button opens the channel picker.
/// - Loading:  spinner while the engine initialises.
/// - Playing:  live video with focus border, channel badge, volume icon.
/// - Error:    broken-image icon with a retry button.
///
/// Audio:      only the focused cell plays at full volume; others are muted.
/// Focus tap:  single-tap gives audio focus to this cell.
/// Full-screen: double-tap promotes the cell to a full-screen [Player].
class MultiViewCell extends StatefulWidget {
  const MultiViewCell({
    super.key,
    required this.cellIndex,
    required this.channel,
    required this.settings,
    required this.source,
    required this.sourceIds,
    required this.isFocused,
    required this.onFocusTap,
    required this.onChannelPicked,
    required this.onCloseCell,
  });

  /// Zero-based index of this cell in the grid — used in log messages.
  final int cellIndex;
  final Channel? channel;
  final Settings settings;
  final Source? source;

  /// Enabled source IDs — forwarded to the channel picker.
  final List<int> sourceIds;

  final bool isFocused;
  final VoidCallback onFocusTap;
  final ValueChanged<Channel> onChannelPicked;
  /// Called when the user chooses "Close cell" from the long-press menu.
  final VoidCallback onCloseCell;

  @override
  State<MultiViewCell> createState() => _MultiViewCellState();
}

class _MultiViewCellState extends State<MultiViewCell> {
  PlayerEngine? _engine;
  bool _error = false;
  bool _loading = false;

  /// Shown in the loading overlay during transient retries.
  /// Null when not retrying — reverts the cell to a plain spinner.
  String? _retryMessage;

  /// Used to cancel an in-flight open() if the channel changes before it
  /// completes.
  int _openGeneration = 0;

  /// Stream subscriptions held against the current engine. Tracked so we
  /// can cancel them explicitly in [_disposeEngine] — relying solely on
  /// engine.dispose() to close the underlying StreamControllers leaks
  /// listeners if dispose() ever throws or is skipped.
  final List<StreamSubscription<dynamic>> _engineSubs = [];

  /// fix342: single place to disarm the startup watchdog.
  void _cancelStartupWatchdog() {
    _startupWatchdog?.cancel();
    _startupWatchdog = null;
  }

  /// fix341: budget of same-engine quick re-opens after a provider EOF drop
  /// (keeps the last frame on screen instead of dispose -> spinner -> new
  /// engine). Resets on a fresh start and after 15s of stable playback.
  int _quickReopens = 0;
  static const _maxQuickReopens = 8;

  /// fix341: headers used for the current stream, cached so a quick re-open
  /// does not need another DB read.
  Map<String, String>? _lastHttpHeaders;

  /// Per-cell transient retry counter. Resets to 0 on a fresh
  /// [_startEngine] call and on 15 s of stable playback after an error.
  int _transientRetries = 0;

  /// Per-cell transient retry budget, drawn from [Settings.maxReconnectAttempts].
  /// A 3-second cadence between retries gives a healthy stream time to
  /// recover during provider edge cycling. The 15-second stable-playback
  /// counter (see bufferingStream listener) resets the count to zero, so
  /// a truly-dead channel still hits the error UI promptly.
  DateTime? _lastErrorAt;

  /// Timestamp of the last transient-retry counter increment. Used to
  /// debounce duplicate burst errors (mpv routinely emits ECONNRESET
  /// twice in the same event tick — without this, a single TCP reset
  /// burns two retries).
  DateTime? _lastTransientIncrementAt;

  /// Last buffering value emitted to the log — used to filter duplicate
  /// `buffering=false` events that media_kit can re-emit immediately after
  /// open() completes (Issue 6).
  bool? _lastBufferingState;

  /// Set when an EOF-driven retry has been scheduled for the current
  /// engine generation. End-of-stream surfaces in BOTH `errorStream`
  /// (as "End of file") and `completedStream` (as `done == true`) for
  /// the same event — without this flag, both listeners would schedule
  /// a retry, and the second would burn a transient-retry budget slot
  /// before being short-circuited by the generation token. The flag is
  /// reset whenever the engine is (re)started or disposed.
  bool _eofRetryScheduled = false;
  /// fix94: covers open-success → first-frame gap in the cell, mirroring
  /// the player's startup watchdog. Dead streams open but never decode.
  Timer? _startupWatchdog;

  /// fix246: after the fast transient retries are exhausted, a cell that
  /// dropped mid-session (provider cut the stream after 20–60 min, common
  /// for long multi-view sessions) used to stay dead until manual retry.
  /// We now attempt a bounded SLOW recovery: up to [_recoverySlowMax]
  /// re-opens at [_recoverySlowInterval] apart. The slow cadence is gentle
  /// on the provider's connection budget (important with a 4-connection
  /// account and four cells). After these are exhausted the cell shows the
  /// error UI for good. Cancelled on dispose / channel change.
  Timer? _recoveryTimer;
  int _recoverySlowRetries = 0;
  static const int _recoverySlowMax = 5;
  static const Duration _recoverySlowInterval = Duration(seconds: 60);

  /// fix250: whether the empty-cell "+" button currently has D-pad focus
  /// (drives its highlight ring).
  bool _addButtonFocused = false;

  @override
  void initState() {
    super.initState();
    if (widget.channel != null) _startEngine(widget.channel!);
  }

  @override
  void didUpdateWidget(MultiViewCell old) {
    super.didUpdateWidget(old);
    if (widget.channel != old.channel && widget.channel != null) {
      _disposeEngine();
      _startEngine(widget.channel!);
    }
    if (widget.isFocused != old.isFocused) {
      AppLog.info(
        'MultiViewCell: focus → ${widget.isFocused ? "FOCUSED" : "muted"}'
        ' cell=${widget.cellIndex}'
        ' channel="${widget.channel?.name ?? 'empty'}"',
      );
      _engine?.setVolume(widget.isFocused ? 1.0 : 0.0);
    }
  }

  @override
  void dispose() {
    _recoveryTimer?.cancel(); // fix246
    _recoveryTimer = null;
    _disposeEngine();
    super.dispose();
  }

  /// fix246: schedule one slow recovery attempt [_recoverySlowInterval] from
  /// now. Increments the slow-retry counter and shows a waiting message. If
  /// the channel changes or the cell is disposed before it fires, the
  /// generation token / timer cancel makes it a no-op. On the attempt it
  /// re-opens via _startEngine(isRetry: true) so the fast-retry counter is
  /// preserved; if that attempt also fails the error handler re-enters this
  /// scheduler until [_recoverySlowMax] is reached, then surfaces the error.
  void _scheduleSlowRecovery(Channel ch, int generation) {
    if (!mounted || generation != _openGeneration) return;
    _recoverySlowRetries++;
    final attempt = _recoverySlowRetries;
    final secs = _recoverySlowInterval.inSeconds;
    AppLog.info(
      'MultiViewCell: slow recovery $attempt/$_recoverySlowMax'
      ' in ${secs}s cell=${widget.cellIndex}'
      ' channel="${ch.name}"',
    );
    if (mounted) {
      setState(() {
        _retryMessage = 'Reconnecting (waiting ${secs}s)…';
        _loading = true;
        _error = false;
      });
    }
    // Dispose the dead engine now so it isn't holding a provider connection
    // open while we wait (matters with a small max_connections budget).
    _disposeEngine();
    _recoveryTimer?.cancel();
    _recoveryTimer = Timer(_recoverySlowInterval, () {
      if (!mounted) return;
      AppLog.info(
        'MultiViewCell: slow recovery attempt $attempt/$_recoverySlowMax'
        ' cell=${widget.cellIndex} channel="${ch.name}"',
      );
      if (mounted) setState(() => _retryMessage = null);
      // Reset the fast-retry counter so this attempt gets a full fast budget
      // again, but keep the slow-retry counter (carried in the field).
      _transientRetries = 0;
      _startEngine(ch, isRetry: true);
    });
  }

  void _disposeEngine() {
    AppLog.info(
      'MultiViewCell: disposing engine'
      ' cell=${widget.cellIndex}'
      ' channel="${widget.channel?.name ?? 'empty'}"',
    );
    _openGeneration++;
    for (final s in _engineSubs) {
      unawaited(s.cancel());
    }
    _engineSubs.clear();
    final e = _engine;
    _engine = null;
    _lastBufferingState = null;
    _lastTransientIncrementAt = null;
    _eofRetryScheduled = false;
    _startupWatchdog?.cancel(); // fix94
    _startupWatchdog = null;
    if (e != null) {
      // dispose() is async; we fire-and-forget since the widget is gone.
      // Wrap with .catchError so a native dispose failure (rare but possible)
      // is at least visible in the log instead of being silently swallowed.
      unawaited(e.dispose().catchError((Object err) {
        AppLog.warn(
          'MultiViewCell: dispose error'
          ' cell=${widget.cellIndex}'
          ' error=$err',
        );
      }));
    }
  }

  /// Returns true if [err] looks like a transient condition worth retrying.
  ///
  /// Multi-view cells routinely see all of these resolve on a single retry
  /// — they fire when the provider's edge cycles a connection, a codec
  /// race loses during concurrent opens, or mpv hits a brief decoder
  /// hiccup mid-stream. Treating these as permanent in the cell is
  /// stricter than mpv itself: mpv emits "Error decoding audio." and then
  /// continues playback; mpv emits "Failed to open" and then on the next
  /// `open()` succeeds. The cell aligns with mpv's view here.
  ///
  /// Truly-dead channels still hit the error UI within ~15 s once the
  /// transient retry budget is exhausted (see [widget.settings.maxReconnectAttempts]).
  static bool _isTransientError(String err) {
    return
        // Network-layer
        err.contains('0xffffff92') ||        // ETIMEDOUT (FFmpeg)
        err.contains('0xffffff99') ||        // ECONNRESET (FFmpeg)
        err.contains('ffurl_read') ||        // any FFmpeg URL read failure
        err.contains('ETIMEDOUT') ||
        err.contains('Connection timed out') ||
        err.contains('Connection reset') ||
        // Format/codec/open patterns that look final but recover on retry
        err.contains('Failed to recognize file format') ||
        err.contains('Failed to open') ||
        err.contains('Error decoding audio') ||
        err.contains('Error decoding video') ||
        err.contains('Could not open codec') ||
        err.contains('End of file') ||
        // HTTP-layer transient (5xx). Match conservatively so 4xx (auth /
        // permanent) doesn't slip in by accident.
        err.contains('HTTP error 5') ||
        err.contains('Server returned 5') ||
        // fix338: the texture-attach failure (fix337) recovers on restart like
        // the others — treat it as transient so it draws on the 3s-cadence
        // retry budget instead of forcing an immediate permanent restart that
        // hammered a connection-limited provider.
        err.contains('video texture failed to attach');
  }

  /// Decodes the `ignoreSSL` text column (string '1' / 'true' / null) into
  /// a bool. Mirrors the same helper in `lib/player.dart` so cells and the
  /// full-screen player interpret the value identically.
  static bool _ignoreSslFromHeaders(ChannelHttpHeaders? headers) {
    final v = headers?.ignoreSSL;
    if (v == null) return false;
    return v == '1' || v.toLowerCase() == 'true';
  }

  /// Returns true if [err] is the benign "Cannot seek" probe that mpv
  /// reports on non-seekable MPEG-TS livestreams. These are not real
  /// failures and must never cause the cell to enter the error state.
  static bool _isSeekProbeError(String err) {
    return err.contains('Cannot seek in this stream') ||
        err.contains('force-seekable=yes');
  }

  /// [isRetry] = true preserves the transient retry counter so repeated
  /// failures accumulate toward the max. Fresh starts (new channel, manual
  /// Retry button) use the default false to reset the budget.
  Future<void> _startEngine(Channel ch, {bool isRetry = false}) async {
    final generation = ++_openGeneration;
    if (!isRetry) {
      _transientRetries = 0;
      _quickReopens = 0; // fix341

      _lastTransientIncrementAt = null;
      // fix246: a genuinely fresh start (new channel / user retry) clears the
      // slow-recovery budget and cancels any pending slow-recovery attempt.
      _recoverySlowRetries = 0;
      _recoveryTimer?.cancel();
      _recoveryTimer = null;
    }
    _lastErrorAt = null;
    _lastBufferingState = null;
    _eofRetryScheduled = false;

    // Resolve which engine to use through the same picker the main player
    // uses — so per-channel and per-source overrides are honoured here too.
    final pickedType = EnginePicker.pick(
      channel: ch,
      settings: widget.settings,
      source: widget.source,
      url: ch.url,
    );
    AppLog.info(
      'MultiViewCell: starting engine'
      ' cell=${widget.cellIndex}'
      ' channel="${ch.name}"'
      ' url="${ch.url ?? '<none>'}"'
      ' engine=${pickedType.name}'
      ' previewMode=true'
      ' generation=$generation',
    );
    if (mounted) setState(() { _loading = true; _error = false; });

    PlayerEngine engine = pickedType == EngineType.exoplayer
        ? ExoEngine()
        : MpvEngine(
            channel: ch,
            settings: widget.settings,
            fullscreenOnOpen: false,
            previewMode: true,
          );

    // Pull channel HTTP headers once and reuse below for both
    // reapplyOptions() (ignoreSsl) and open() (UA/Referer/Origin).
    // Without these the cell hits the provider with mpv's generic UA,
    // which some edges treat aggressively (shorter keepalive, faster idle
    final channelId = ch.id;
    final ChannelHttpHeaders? chHeaders =
        channelId != null ? await Sql.getChannelHeaders(channelId) : null;
    if (!mounted || generation != _openGeneration) {
      unawaited(engine.dispose().catchError((Object e) {
        AppLog.warn('MultiViewCell: dispose error after stale headers — $e');
      }));
      return;
    }

    // Apply mpv runtime options BEFORE open(), matching the full-screen
    // Player at lib/player.dart. Without this the cell runs on mpv stock
    // defaults (cache-secs=10, no network-timeout, default UA) instead of
    // the app-tuned values (liveCacheSecs=45, network-timeout=30,
    // miniDemuxerMaxMB for the demuxer cap, etc.).
    if (engine is MpvEngine) {
      await engine.reapplyOptions(
        url: ch.url ?? '',
        ignoreSsl: _ignoreSslFromHeaders(chHeaders),
      );
      if (!mounted || generation != _openGeneration) {
        unawaited(engine.dispose().catchError((Object e) {
          AppLog.warn('MultiViewCell: dispose error after stale opts — $e');
        }));
        return;
      }
    }

    // Volume after options, before open(). First audio packet then plays
    // at the correct level with the correct mpv config in place.
    await engine.setVolume(widget.isFocused ? 1.0 : 0.0);

    // Subscribe to engine streams. Subscriptions are stored in
    // [_engineSubs] so [_disposeEngine] can cancel them explicitly.
    _engineSubs.add(engine.errorStream.listen((err) {
      // 1. Seek probe — always suppress. mpv emits this when probing
      //    seekability on non-seekable livestreams. It is not a failure.
      if (_isSeekProbeError(err)) {
        if (AppLog.enabled) {
          AppLog.info(
            'MultiViewCell: suppressed seek probe'
            ' cell=${widget.cellIndex}'
            ' channel="${ch.name}"',
          );
        }
        return;
      }

      final transient = _isTransientError(err);
      _lastErrorAt = DateTime.now();

      AppLog.warn(
        'MultiViewCell: engine error'
        ' [${transient ? "transient" : "permanent"}]'
        ' cell=${widget.cellIndex}'
        ' channel="${ch.name}"'
        ' retries=$_transientRetries/${widget.settings.maxReconnectAttempts}'
        ' error="$err"',
      );

      if (!mounted || generation != _openGeneration) return;

      // 1b. End-of-stream surfaces in BOTH errorStream ("End of file")
      //     and completedStream (`done == true`) for the same event.
      //     Whichever listener fires first schedules the retry and sets
      //     [_eofRetryScheduled]; the other suppresses to avoid burning
      //     a transient-retry budget slot on a duplicate signal.
      if (err.contains('End of file')) {
        if (_eofRetryScheduled) return;
        _eofRetryScheduled = true;
        final delayMs = widget.settings.streamCompletedDelayMs;
        AppLog.info(
          'MultiViewCell: EOF via errorStream'
          ' cell=${widget.cellIndex}'
          ' channel="${ch.name}"'
          ' — retrying in ${delayMs}ms',
        );
        Future.delayed(Duration(milliseconds: delayMs), () {
          if (mounted && generation == _openGeneration && !_error) {
            _disposeEngine();
            _startEngine(ch);
          }
        });
        return;
      }

      // 2. Transient — retry up to N times with a short delay.
      if (transient && _transientRetries < widget.settings.maxReconnectAttempts) {
        // mpv routinely emits two transient errors in the same event
        // tick (e.g. ECONNRESET + the subsequent read failure). Debounce
        // so a single network event doesn't burn two retries.
        final now = DateTime.now();
        if (_lastTransientIncrementAt != null &&
            now.difference(_lastTransientIncrementAt!).inMilliseconds < 500) {
          return; // duplicate burst, already counted
        }
        _lastTransientIncrementAt = now;
        _transientRetries++;
        final attempt = _transientRetries;
        final maxAttempts = widget.settings.maxReconnectAttempts;
        if (mounted) {
          setState(() {
            _retryMessage = 'Retrying $attempt/$maxAttempts…';
            _loading = true;
            _error = false;
          });
        }
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && generation == _openGeneration) {
            AppLog.info(
              'MultiViewCell: retry $attempt/$maxAttempts'
              ' cell=${widget.cellIndex}'
              ' channel="${ch.name}"',
            );
            if (mounted) setState(() => _retryMessage = null);
            _disposeEngine();
            _startEngine(ch, isRetry: true); // fix90: preserve counter
          }
        });
        return;
      }

      // 3. Permanent or retries exhausted — surface the error UI AND
      //    dispose the engine. Without disposal, the failed engine keeps
      //    its TCP connection open and continues emitting buffering,
      //    seek-probe, and completed events into the subscriptions until
      //    the user manually intervenes (sometimes 10+ minutes later).
      //    With a 4-connection provider account, two leaked cells silently
      //    consume half the budget and break further retries.
      //
      //    mpv can also emit the same permanent error twice in a frame
      //    (observed: "Could not open codec." fired twice from cell 2).
      //    Guard so we only dispose / setState once.
      if (_error) return;
      // fix246: fast retries exhausted. Before surfacing the permanent error
      // UI, attempt a bounded SLOW recovery (up to _recoverySlowMax re-opens
      // at _recoverySlowInterval). This self-heals long sessions where the
      // provider drops a stream after 20–60 min. Only start the slow phase
      // for transient errors; genuine permanent errors (auth/4xx/codec) go
      // straight to the error UI.
      if (transient && _recoverySlowRetries < _recoverySlowMax) {
        _scheduleSlowRecovery(ch, generation);
        return;
      }
      setState(() { _error = true; _loading = false; });
      _disposeEngine();
    }));

    _engineSubs.add(engine.completedStream.listen((done) {
      if (!done) return;
      // De-duplicate with the errorStream EOF branch — same event, two
      // signals. First listener through schedules the retry.
      if (_eofRetryScheduled) return;
      _eofRetryScheduled = true;
      final delayMs = widget.settings.streamCompletedDelayMs;
      AppLog.info(
        'MultiViewCell: stream completed'
        ' cell=${widget.cellIndex}'
        ' channel="${ch.name}"'
        ' — retrying in ${delayMs}ms',
      );
      // Single silent retry — honours the user's streamCompletedDelayMs
      // setting (same as full-screen Player).
      Future.delayed(Duration(milliseconds: delayMs), () async {
        if (!(mounted && generation == _openGeneration && !_error)) return;
        // fix341 layer 1: quick re-open on the SAME engine. Disposing the
        // engine blanks the cell (spinner) for several seconds on every
        // provider connection-cycle (observed: Dino max_connections=1 drops
        // each cell every ~25-30s). Re-opening on the live engine keeps the
        // last frame on screen, shrinking the visible artifact to the
        // reconnect time. Budgeted; falls back to the full restart path on
        // failure or budget exhaustion (replenished after 15s stable).
        final eng = _engine;
        if (eng != null && _quickReopens < _maxQuickReopens) {
          _quickReopens++;
          _eofRetryScheduled = false;
          AppLog.info(
            'MultiViewCell: quick re-open (same engine, $_quickReopens/'
            '$_maxQuickReopens) cell=${widget.cellIndex} channel="${ch.name}"',
          );
          try {
            await eng.open(
                url: ch.url ?? '', headers: _lastHttpHeaders, isLive: true);
            // fix345 (review CRIT-1): a quick re-open can succeed at the
            // protocol level yet never produce a frame (connection-limited
            // providers serving a stalled/black slate). The startup watchdog
            // was cancelled long ago and the fix337 texture check cannot
            // catch it (the texture is already attached) — without a probe
            // this is a silent frozen cell. Re-arm a bounded liveness check:
            // position must ADVANCE within 8s, else fall back to the full
            // budgeted restart path (which the logs prove recovers).
            final p0 = eng.position;
            Future.delayed(const Duration(seconds: 8), () {
              if (!mounted ||
                  generation != _openGeneration ||
                  _error ||
                  !identical(_engine, eng)) {
                return;
              }
              if (eng.position <= p0) {
                AppLog.warn(
                  'MultiViewCell: quick re-open produced no progress'
                  ' (position ${p0.inSeconds}s -> ${eng.position.inSeconds}s)'
                  ' — full restart cell=${widget.cellIndex}',
                );
                _disposeEngine();
                _startEngine(ch, isRetry: true);
              }
            });
            return;
          } catch (e) {
            AppLog.warn('MultiViewCell: quick re-open failed — $e;'
                ' falling back to full restart cell=${widget.cellIndex}');
          }
        }
        if (mounted && generation == _openGeneration && !_error) {
          _disposeEngine();
          _startEngine(ch);
        }
      });
    }));

    _engineSubs.add(engine.bufferingStream.listen((buffering) {
      // fix94: first buffering signal means the engine is alive.
      if (_startupWatchdog != null) {
        _cancelStartupWatchdog();
      }
      // Reset the transient retry counter after 15 s of stable playback.
      if (!buffering &&
          _lastErrorAt != null &&
          DateTime.now().difference(_lastErrorAt!).inSeconds > 15) {
        _transientRetries = 0;
        _recoverySlowRetries = 0; // fix246: recovered & stable → fresh budget
        _quickReopens = 0; // fix341: stable again → fresh quick-reopen budget
        _lastErrorAt = null;
      }

      // Only log distinct state transitions to keep logs uncluttered when
      // media_kit re-emits the same value.
      if (buffering == _lastBufferingState) return;
      _lastBufferingState = buffering;
      if (AppLog.enabled) {
        AppLog.info(
          'MultiViewCell: buffering=$buffering'
          ' cell=${widget.cellIndex}'
          ' channel="${ch.name}"',
        );
      }
    }));

    final httpHeaders = chHeaders == null
        ? null
        : <String, String>{
            if (chHeaders.referrer != null) 'Referer': chHeaders.referrer!,
            if (chHeaders.httpOrigin != null) 'Origin': chHeaders.httpOrigin!,
            if (chHeaders.userAgent != null) 'User-Agent': chHeaders.userAgent!,
          };

    final bufferSecs = widget.settings.multiViewStabilityBufferSecs;
    // fix94: arm startup watchdog — if no frame arrives, force a
    // transient error so the retry/give-up path runs instead of
    // waiting ~30s for mpv's internal timeout.
    // fix342: armed BEFORE engine.open() (was after). ExoPlayer auto-plays
    // during open(), so its one-shot liveness signal (fix335) could arrive
    // before the watchdog existed and be consumed — the watchdog then fired
    // on a healthy stream (every Exo cell with the stability buffer; a
    // latent race on all paths). Arming first makes the race impossible:
    // any liveness/buffering event now lands after arm and cancels via
    // _cancelStartupWatchdog. The generation guard keeps a fire during a
    // slow open() safe (stale generations are ignored).
    // fix341: while the stability-buffer pause is active the cell is
    // intentionally not rendering frames — extend the watchdog past the
    // buffer window so it can't fire mid-pause and trigger a bogus retry.
    final startupSecs = widget.settings.bufferingWatchdogSecs +
        ((!isRetry && bufferSecs > 0) ? bufferSecs : 0);
    _startupWatchdog?.cancel();
    _startupWatchdog = Timer(
      Duration(seconds: startupSecs),
      () {
        if (mounted && generation == _openGeneration && !_error) {
          AppLog.warn(
            'MultiViewCell: startup watchdog fired after ${startupSecs}s'
            ' — open succeeded but no frame'
            ' cell=${widget.cellIndex}'
            ' channel="${ch.name}"',
          );
          // Drive the same retry/give-up path a transient error would.
          if (_transientRetries < widget.settings.maxReconnectAttempts) {
            _transientRetries++;
            final attempt = _transientRetries;
            final maxAttempts = widget.settings.maxReconnectAttempts;
            setState(() {
              _retryMessage = 'Retrying $attempt/$maxAttempts…';
              _loading = true;
              _error = false;
            });
            _disposeEngine();
            _startEngine(ch, isRetry: true);
          } else {
            setState(() {
              _error = true;
              _loading = false;
              _retryMessage = null;
            });
            _disposeEngine();
          }
        }
      },
    );
    AppLog.info(
      'MultiViewCell: startup watchdog armed ${startupSecs}s'
      ' cell=${widget.cellIndex}'
      ' channel="${ch.name}"',
    );

    try {
      // fix339: multi-view is live-TV-only — suppress Exo completed loops.
      _lastHttpHeaders = httpHeaders; // fix341: cache for quick re-open
      await engine.open(url: ch.url ?? '', headers: httpHeaders, isLive: true);
    } catch (err) {
      AppLog.warn(
        'MultiViewCell: open() threw'
        ' cell=${widget.cellIndex}'
        ' channel="${ch.name}"'
        ' error=$err',
      );
      if (!mounted || generation != _openGeneration) {
        unawaited(engine.dispose().catchError((Object e) {
          AppLog.warn('MultiViewCell: dispose error after stale open — $e');
        }));
        return;
      }
      setState(() { _error = true; _loading = false; });
      unawaited(engine.dispose().catchError((Object e) {
        AppLog.warn('MultiViewCell: dispose error after open() throw — $e');
      }));
      return;
    }

    if (!mounted || generation != _openGeneration) {
      AppLog.info(
        'MultiViewCell: open() stale — discarding'
        ' cell=${widget.cellIndex}'
        ' generation=$generation',
      );
      unawaited(engine.dispose().catchError((Object e) {
        AppLog.warn('MultiViewCell: dispose error after stale open() — $e');
      }));
      return;
    }

    AppLog.info(
      'MultiViewCell: open() succeeded'
      ' cell=${widget.cellIndex}'
      ' channel="${ch.name}"',
    );
    setState(() {
      _engine = engine;
      _loading = false;
      _retryMessage = null;
    });

    // fix341 layer 2: optional stability buffer. On a FRESH start (not a
    // retry — a drop-reconnect goes straight to live so the cell recovers
    // immediately), pause for N seconds so mpv's cache accumulates a cushion;
    // playback then runs ~N s behind live and plays THROUGH brief provider
    // connection drops (mpv keeps playing buffered data after network EOF,
    // only firing completed when the cache drains).
    if (!isRetry && bufferSecs > 0) {
      AppLog.info('MultiViewCell: stability buffer — pausing ${bufferSecs}s'
          ' cell=${widget.cellIndex}');
      await engine.pause();
      if (mounted) {
        setState(() => _retryMessage = 'Building ${bufferSecs}s buffer…');
      }
      unawaited(Future.delayed(Duration(seconds: bufferSecs), () async {
        if (!mounted || generation != _openGeneration || _engine != engine) {
          return;
        }
        AppLog.info('MultiViewCell: stability buffer ready — playing'
            ' cell=${widget.cellIndex}');
        await engine.play();
        // fix342: cancel the startup watchdog here. ExoPlayer auto-plays
        // during open(), so its ONE-SHOT liveness signal (fix335) fires
        // before the watchdog is armed and is consumed; after the buffer
        // pause -> play, Exo never toggles isBuffering on raw .ts, so no
        // signal ever reaches the watchdog and it fired at base+buffer on
        // every Exo cell (S24 21:38 log). open() succeeded and playback has
        // deliberately begun — the watchdog's job is done.
        if (_startupWatchdog != null) {
          _cancelStartupWatchdog();
          AppLog.info('MultiViewCell: startup watchdog cancelled'
              ' (buffer released) cell=${widget.cellIndex}');
        }
        if (mounted) setState(() => _retryMessage = null);
      }));
    }
  }

  Future<void> _pickChannel() async {
    final ch = await Navigator.of(context).push<Channel>(
      MaterialPageRoute(
        builder: (_) =>
            ChannelPickerScreen(sourceIds: widget.sourceIds),
      ),
    );
    if (ch != null) widget.onChannelPicked(ch);
  }

  Future<void> _promoteToFullScreen() async {
    final ch = widget.channel;
    if (ch == null) return;
    AppLog.info(
      'MultiViewCell: promoting to full-screen'
      ' cell=${widget.cellIndex}'
      ' channel="${ch.name}"',
    );
    // Clear any stale cooldown — the cell's active stream proves
    // it's live.
    Player.clearCooldown(ch.id);

    // channel_tile.dart:249 tap-to-play path that's the only other
    // place a user actively chooses a channel.
    if (ch.id != null) {
      unawaited(Sql.addToHistory(ch.id!));
    }

    // CRITICAL: dispose the cell's engine BEFORE pushing the full-
    // screen Player. Both engines would otherwise try to read the
    // same .ts URL from the same provider credentials, and the
    // provider rejects the duplicate read with "Failed to open"
    // 15:47:53–15:47:54). Without this, every long-press → Full
    // screen and every double-tap fails permanently.
    //
    // The cell falls through to _buildLoadingCell() during the
    // promotion (no _engine, _loading true). After the Player pops,
    // we restart the cell so the user gets video back when they
    // return to multi-view.
    _disposeEngine();
    setState(() => _loading = true);

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Player(
          channel: ch,
          settings: widget.settings,
          source: widget.source,
        ),
      ),
    );

    // Returned from full-screen. Re-open the cell with whatever
    // channel it currently holds. (If the user channel-zapped
    // inside the Player, that changed the Player's channel state,
    // not the cell's.)
    if (!mounted) return;
    final current = widget.channel;
    if (current != null) {
      _startEngine(current);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.channel == null) return _buildEmptyCell();
    if (_error) return _buildErrorCell();
    if (_loading || _engine == null) return _buildLoadingCell();
    return _buildVideoCell();
  }

  Widget _buildEmptyCell() {
    // fix250: make the "+" reachable and clearly highlighted via D-pad.
    // FloatingActionButton had no autofocus and a weak focused state, so on
    // TV it was hard to land on. FocusableActionDetector gives it a visible
    // focus ring and lets cell 0's "+" be the initial D-pad target when the
    // grid opens empty.
    return Container(
      color: const Color(0xFF111111),
      child: Center(
        child: FocusableActionDetector(
          autofocus: widget.cellIndex == 0,
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.select): _CellMenuIntent(),
            SingleActivator(LogicalKeyboardKey.enter): _CellMenuIntent(),
            SingleActivator(LogicalKeyboardKey.gameButtonA): _CellMenuIntent(),
          },
          actions: <Type, Action<Intent>>{
            _CellMenuIntent:
                CallbackAction<_CellMenuIntent>(onInvoke: (_) {
              _pickChannel();
              return null;
            }),
          },
          onShowFocusHighlight: (f) => setState(() => _addButtonFocused = f),
          child: GestureDetector(
            onTap: _pickChannel,
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: _addButtonFocused
                    ? Theme.of(context).colorScheme.primary
                    : const Color(0xFF2A2A2A),
                shape: BoxShape.circle,
                border: Border.all(
                  color: _addButtonFocused
                      ? Colors.white
                      : Colors.white24,
                  width: _addButtonFocused ? 3 : 1,
                ),
              ),
              child: const Icon(Icons.add, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorCell() {
    return GestureDetector(
      onLongPress: _showCellMenu,
      child: Container(
        color: const Color(0xFF111111),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image_outlined,
                  color: Colors.red, size: 32),
              const SizedBox(height: 8),
              const Text(
                'Stream unavailable',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      final ch = widget.channel;
                      if (ch != null) {
                        _disposeEngine();
                        _startEngine(ch);
                      }
                    },
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Retry'),
                  ),
                  TextButton.icon(
                    onPressed: _showCellMenu,
                    icon: const Icon(Icons.more_vert, size: 16),
                    label: const Text('More'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingCell() {
    // fix254: a reconnecting/loading cell is now focusable and its options
    // menu reachable (D-pad select or touch long-press), so the user can
    // swap the stream without waiting out the slow-recovery countdown.
    return _focusableWithMenu(
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: _retryMessage != null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white54,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _retryMessage!,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                  ],
                )
              : const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
        ),
      ),
    );
  }

  /// fix254: wraps a cell's content so it is D-pad focusable and its options
  /// menu is reachable via the select/center key (filled-cell behaviour from
  /// fix250). Used for the video AND loading/reconnecting states so a cell is
  /// never a dead, un-focusable rectangle. Touch long-press also opens the
  /// menu. A focused cell shows the same primary-color border as a playing
  /// focused cell.
  Widget _focusableWithMenu({required Widget child, bool showBorder = true}) {
    return FocusableActionDetector(
      autofocus: widget.cellIndex == 0,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.select): _CellMenuIntent(),
        SingleActivator(LogicalKeyboardKey.enter): _CellMenuIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonA): _CellMenuIntent(),
        SingleActivator(LogicalKeyboardKey.contextMenu): _CellMenuIntent(),
      },
      actions: <Type, Action<Intent>>{
        _CellMenuIntent: CallbackAction<_CellMenuIntent>(
          onInvoke: (_) {
            widget.onFocusTap();
            _showCellMenu();
            return null;
          },
        ),
      },
      onShowFocusHighlight: (focused) {
        if (focused) widget.onFocusTap();
      },
      child: GestureDetector(
        onTap: widget.onFocusTap,
        onLongPress: _showCellMenu,
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            if (showBorder && widget.isFocused)
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showCellMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('Replace channel'),
              onTap: () {
                Navigator.of(context).pop();
                _pickChannel();
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_full),
              title: const Text('Full screen'),
              onTap: () {
                Navigator.of(context).pop();
                _promoteToFullScreen();
              },
            ),
            ListTile(
              leading: const Icon(Icons.close, color: Colors.redAccent),
              title: const Text('Close cell',
                  style: TextStyle(color: Colors.redAccent)),
              onTap: () {
                Navigator.of(context).pop();
                widget.onCloseCell();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Translucent info bar pinned to the bottom of a playing cell.
  /// Shows channel name and, when EPG data is available, a now/next strip.
  Widget _buildInfoBar() {
    final ch = widget.channel;
    final epgId = ch?.epgChannelId;
    final hasEpg = ch != null &&
        ch.mediaType == MediaType.livestream &&
        epgId != null &&
        epgId.isNotEmpty;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(6, 3, 6, 4),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ch?.name ?? '',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (hasEpg)
            NowNextStrip(
              epgChannelId: epgId,
              sourceId: ch.sourceId,
            ),
        ],
      ),
    );
  }

  Widget _buildVideoCell() {
    return FocusableActionDetector(
      // fix170: D-pad focus → audio focus. Moving the remote to a cell
      // calls onFocusTap, so the focused cell plays audio and others mute.
      // fix172: cell 0 autofocuses so the D-pad has an initial target on TV.
      autofocus: widget.cellIndex == 0,
      // fix250: on a TV remote there is no touch long-press, so the cell
      // options menu (Replace / Full screen / Close) was unreachable once all
      // cells were filled. Map the D-pad select/center and the dedicated
      // context-menu / info keys to open the same menu. Touch long-press
      // (below) still works on phones/tablets.
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.select): _CellMenuIntent(),
        SingleActivator(LogicalKeyboardKey.enter): _CellMenuIntent(),
        SingleActivator(LogicalKeyboardKey.gameButtonA): _CellMenuIntent(),
        SingleActivator(LogicalKeyboardKey.contextMenu): _CellMenuIntent(),
      },
      actions: <Type, Action<Intent>>{
        _CellMenuIntent: CallbackAction<_CellMenuIntent>(
          onInvoke: (_) {
            widget.onFocusTap();
            _showCellMenu();
            return null;
          },
        ),
      },
      onShowFocusHighlight: (focused) {
        if (focused) widget.onFocusTap();
      },
      child: GestureDetector(
        onTap: widget.onFocusTap,
        onDoubleTap: _promoteToFullScreen,
        onLongPress: _showCellMenu,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _engine!.buildVideoView(context),

            // Focused-cell border
            if (widget.isFocused)
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                  ),
                ),
              ),

            // Info bar — bottom: channel name + EPG now/next strip
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildInfoBar(),
            ),

            // Volume icon — top right
            Positioned(
              right: 8,
              top: 8,
              child: IgnorePointer(
                child: Icon(
                  widget.isFocused ? Icons.volume_up : Icons.volume_off,
                  color: widget.isFocused ? Colors.white : Colors.white30,
                  size: 16,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
