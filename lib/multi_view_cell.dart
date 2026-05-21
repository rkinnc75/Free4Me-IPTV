import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/channel_picker_screen.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/player.dart';
import 'package:open_tv/player/mpv_engine.dart';

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
    required this.channel,
    required this.settings,
    required this.source,
    required this.sourceIds,
    required this.isFocused,
    required this.onFocusTap,
    required this.onChannelPicked,
  });

  final Channel? channel;
  final Settings settings;
  final Source? source;

  /// Enabled source IDs — forwarded to the channel picker.
  final List<int> sourceIds;

  final bool isFocused;
  final VoidCallback onFocusTap;
  final ValueChanged<Channel> onChannelPicked;

  @override
  State<MultiViewCell> createState() => _MultiViewCellState();
}

class _MultiViewCellState extends State<MultiViewCell> {
  MpvEngine? _engine;
  bool _error = false;
  bool _loading = false;

  /// Used to cancel an in-flight open() if the channel changes before it
  /// completes.
  int _openGeneration = 0;

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
      _engine?.setVolume(widget.isFocused ? 1.0 : 0.0);
    }
  }

  @override
  void dispose() {
    _disposeEngine();
    super.dispose();
  }

  void _disposeEngine() {
    _openGeneration++;
    final e = _engine;
    _engine = null;
    if (e != null) {
      // dispose() is async; we fire-and-forget since widget is gone.
      unawaited(e.dispose());
    }
  }

  Future<void> _startEngine(Channel ch) async {
    final generation = ++_openGeneration;
    if (mounted) setState(() { _loading = true; _error = false; });

    final engine = MpvEngine(
      channel: ch,
      settings: widget.settings,
      fullscreenOnOpen: false,
      previewMode: true,
    );

    // Set volume before open() so the first audio packet plays at the
    // correct level.
    await engine.setVolume(widget.isFocused ? 1.0 : 0.0);

    try {
      await engine.open(url: ch.url ?? '');
    } catch (err) {
      AppLog.warn('MultiViewCell: open failed — $err — "${ch.name}"');
      if (!mounted || generation != _openGeneration) {
        unawaited(engine.dispose());
        return;
      }
      setState(() { _error = true; _loading = false; });
      unawaited(engine.dispose());
      return;
    }

    if (!mounted || generation != _openGeneration) {
      unawaited(engine.dispose());
      return;
    }

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
    return Container(
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
          ],
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

  Widget _buildVideoCell() {
    return GestureDetector(
      onTap: widget.onFocusTap,
      onDoubleTap: _promoteToFullScreen,
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

          // Channel name badge — bottom left
          Positioned(
            left: 8,
            bottom: 8,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                widget.channel?.name ?? '',
                style:
                    const TextStyle(color: Colors.white, fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
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
