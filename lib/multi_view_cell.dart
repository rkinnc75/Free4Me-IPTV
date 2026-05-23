import 'dart:async';

import 'package:flutter/material.dart';
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

  /// Used to cancel an in-flight open() if the channel changes before it
  /// completes.
  int _openGeneration = 0;

  /// Stream subscriptions held against the current engine. Tracked so we
  /// can cancel them explicitly in [_disposeEngine] — relying solely on
  /// engine.dispose() to close the underlying StreamControllers leaks
  /// listeners if dispose() ever throws or is skipped.
  final List<StreamSubscription<dynamic>> _engineSubs = [];

  /// Per-cell transient retry counter. Resets to 0 on a fresh
  /// [_startEngine] call and on 15 s of stable playback after an error.
  int _transientRetries = 0;

  /// Per-cell transient retry budget. Five attempts at a 3-second cadence
  /// gives a healthy stream up to 15 s of recovery time during provider
  /// edge cycling. The 15-second stable-playback counter (see
  /// bufferingStream listener) still resets the count to zero, so a
  /// truly-dead channel still hits the error UI promptly.
  static const int _maxTransientRetries = 5;
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
    _disposeEngine();
    super.dispose();
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
  /// transient retry budget is exhausted (see [_maxTransientRetries]).
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
        err.contains('Server returned 5');
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

  Future<void> _startEngine(Channel ch) async {
    final generation = ++_openGeneration;
    _transientRetries = 0;
    _lastErrorAt = null;
    _lastBufferingState = null;
    _lastTransientIncrementAt = null;

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
    // disconnect). See fix20.md for evidence.
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
        ' retries=$_transientRetries/$_maxTransientRetries'
        ' error="$err"',
      );

      if (!mounted || generation != _openGeneration) return;

      // 2. Transient — retry up to N times with a short delay.
      if (transient && _transientRetries < _maxTransientRetries) {
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
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && generation == _openGeneration) {
            AppLog.info(
              'MultiViewCell: retry $attempt/$_maxTransientRetries'
              ' cell=${widget.cellIndex}'
              ' channel="${ch.name}"',
            );
            _disposeEngine();
            _startEngine(ch);
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
      setState(() { _error = true; _loading = false; });
      _disposeEngine();
    }));

    _engineSubs.add(engine.completedStream.listen((done) {
      if (!done) return;
      final delayMs = widget.settings.streamCompletedDelayMs;
      AppLog.info(
        'MultiViewCell: stream completed'
        ' cell=${widget.cellIndex}'
        ' channel="${ch.name}"'
        ' — retrying in ${delayMs}ms',
      );
      // Single silent retry — honours the user's streamCompletedDelayMs
      // setting (same as full-screen Player).
      Future.delayed(Duration(milliseconds: delayMs), () {
        if (mounted && generation == _openGeneration && !_error) {
          _disposeEngine();
          _startEngine(ch);
        }
      });
    }));

    _engineSubs.add(engine.bufferingStream.listen((buffering) {
      // Reset the transient retry counter after 15 s of stable playback.
      if (!buffering &&
          _lastErrorAt != null &&
          DateTime.now().difference(_lastErrorAt!).inSeconds > 15) {
        _transientRetries = 0;
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

    try {
      await engine.open(url: ch.url ?? '', headers: httpHeaders);
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
    });
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
    // Clear any stale cooldown — the cell's active stream proves it's live.
    Player.clearCooldown(ch.id);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Player(
          channel: ch,
          settings: widget.settings,
          source: widget.source,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.channel == null) return _buildEmptyCell();
    if (_error) return _buildErrorCell();
    if (_loading || _engine == null) return _buildLoadingCell();
    return _buildVideoCell();
  }

  Widget _buildEmptyCell() {
    return Container(
      color: const Color(0xFF111111),
      child: Center(
        child: FloatingActionButton(
          heroTag: null,
          mini: true,
          onPressed: _pickChannel,
          child: const Icon(Icons.add),
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
    return const ColoredBox(
      color: Colors.black,
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
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
    return GestureDetector(
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
                color: widget.isFocused
                    ? Colors.white
                    : Colors.white30,
                size: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
