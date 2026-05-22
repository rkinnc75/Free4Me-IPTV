import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/channel_picker_screen.dart';
import 'package:open_tv/models/channel.dart';
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
  static const int _maxTransientRetries = 3;
  DateTime? _lastErrorAt;

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

  /// Returns true if [err] looks like a transient network condition that
  /// is worth retrying.
  static bool _isTransientError(String err) {
    return err.contains('0xffffff92') ||
        err.contains('ffurl_read') ||
        err.contains('Failed to recognize file format') ||
        err.contains('Connection timed out') ||
        err.contains('Connection reset') ||
        err.contains('ETIMEDOUT');
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

    // Volume first so the first audio packet plays at the correct level.
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

      // 3. Permanent or retries exhausted — surface the error UI.
      setState(() { _error = true; _loading = false; });
    }));

    _engineSubs.add(engine.completedStream.listen((done) {
      if (!done) return;
      AppLog.info(
        'MultiViewCell: stream completed'
        ' cell=${widget.cellIndex}'
        ' channel="${ch.name}"'
        ' — retrying in 2s',
      );
      // Single silent retry after 2 s (matches streamCompletedDelayMs default).
      Future.delayed(const Duration(seconds: 2), () {
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

    try {
      await engine.open(url: ch.url ?? '');
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
