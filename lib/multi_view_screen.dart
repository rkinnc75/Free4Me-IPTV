import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/multi_view_layout.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/multi_view_cell.dart';

/// Full-screen multi-view grid. Each cell is an independent stream.
/// One cell holds audio focus at a time; the others play muted.
///
/// Cell assignments persist across screen exits — the last channels
/// picked for each layout are restored on re-entry.
class MultiViewScreen extends StatefulWidget {
  const MultiViewScreen({
    super.key,
    required this.layout,
    required this.settings,
    required this.source,
    required this.sourceIds,
  });

  final MultiViewLayout layout;
  final Settings settings;
  final Source? source;
  final List<int> sourceIds;

  @override
  State<MultiViewScreen> createState() => _MultiViewScreenState();
}

class _MultiViewScreenState extends State<MultiViewScreen> {
  late final int _cellCount = widget.layout.cellCount;
  late final List<Channel?> _channels;
  int _focusedCell = 0;
  bool _restored = false;

  // Audio focus
  AudioSession? _audioSession;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  /// True while an audio interruption (call, Siri, etc.) has ducked us.
  bool _interrupted = false;

  @override
  void initState() {
    super.initState();
    _channels = List.filled(_cellCount, null);
    _restoreChannels();
    _initAudioSession();
  }

  /// Configure the audio session for video playback and subscribe to
  /// interruption events. On an interruption start we mute all cells; on
  /// interruption end we restore volume to the focused cell.
  Future<void> _initAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.mixWithOthers,
        avAudioSessionMode: AVAudioSessionMode.moviePlayback,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.movie,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ));
      _audioSession = session;
      await session.setActive(true);
      AppLog.info('MultiViewScreen: audio session active');

      _interruptionSub = session.interruptionEventStream.listen((event) {
        if (event.begin) {
          // Call, Siri, alarm — mute everything.
          _interrupted = true;
          AppLog.info(
            'MultiViewScreen: audio interrupted (${event.type.name})'
            ' — muting all cells',
          );
          if (mounted) setState(() {});
        } else {
          // Interruption over.
          if (event.type == AudioInterruptionType.pause ||
              event.type == AudioInterruptionType.unknown) {
            _interrupted = false;
            AppLog.info(
              'MultiViewScreen: audio interruption ended — restoring focus',
            );
            if (mounted) setState(() {});
          }
        }
      });
    } catch (e) {
      AppLog.warn('MultiViewScreen: audio session init failed — $e');
    }
  }

  @override
  void dispose() {
    AppLog.info('MultiViewScreen: disposing — layout=${widget.layout.name}');
    _interruptionSub?.cancel();
    _audioSession?.setActive(false).ignore();
    super.dispose();
  }

  /// Restore persisted channel IDs for the current layout. The stored
  /// string is comma-separated IDs (empty entry = empty cell).
  Future<void> _restoreChannels() async {
    final raw = widget.layout == MultiViewLayout.oneByTwo
        ? widget.settings.multiViewCells1x2
        : widget.settings.multiViewCells2x2;

    AppLog.info(
      'MultiViewScreen: restoring channels'
      ' layout=${widget.layout.name}'
      ' raw="$raw"',
    );

    final parts = raw.split(',');
    final toFetch = <int, int>{}; // cellIndex → channelId

    for (var i = 0; i < _cellCount && i < parts.length; i++) {
      final id = int.tryParse(parts[i]);
      if (id != null) toFetch[i] = id;
    }

    if (toFetch.isEmpty) {
      AppLog.info('MultiViewScreen: no persisted channels to restore');
      if (mounted) setState(() => _restored = true);
      return;
    }

    for (final entry in toFetch.entries) {
      final ch = await Sql.getChannelById(entry.value);
      if (!mounted) return;
      if (ch != null) _channels[entry.key] = ch;
    }

    AppLog.info(
      'MultiViewScreen: restored'
      ' ${_channels.where((c) => c != null).length}/$_cellCount cells',
    );
    setState(() => _restored = true);
  }

  void _persistChannels() {
    final ids = _channels
        .map((ch) => ch?.id?.toString() ?? '')
        .join(',');
    if (widget.layout == MultiViewLayout.oneByTwo) {
      widget.settings.multiViewCells1x2 = ids;
    } else {
      widget.settings.multiViewCells2x2 = ids;
    }
    // Persist asynchronously — fire and forget.
    SettingsService.updateSettings(widget.settings);
  }

  void _setChannel(int index, Channel channel) {
    AppLog.info(
      'MultiViewScreen: cell $index assigned'
      ' channel="${channel.name}"',
    );
    setState(() => _channels[index] = channel);
    _persistChannels();
    // Record in watch history. Only fires for explicit user picks;
    // auto-restore of saved layouts on app launch uses a different
    // path (constructor / _restoreSavedCells) that bypasses this
    // setter, so restored channels don't get spurious timestamp
    // bumps.
    if (channel.id != null) {
      unawaited(Sql.addToHistory(channel.id!));
    }
    // Give the new cell audio focus automatically.
    if (_focusedCell != index) setState(() => _focusedCell = index);
  }

  void _setFocus(int index) {
    if (_focusedCell == index) return;
    AppLog.info('MultiViewScreen: focus → cell $index (was $_focusedCell)');
    setState(() => _focusedCell = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.layout == MultiViewLayout.oneByTwo
              ? '1×2 Multi-view'
              : '2×2 Multi-view',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Exit multi-view',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: !_restored
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final h = constraints.maxHeight;
                final isLandscape = w >= h;

                if (widget.layout == MultiViewLayout.oneByTwo) {
                  // Portrait → stack vertically; landscape → side by side.
                  // Both use Expanded children so each cell fills its half.
                  return isLandscape
                      ? Row(children: _buildFlexCells())
                      : Column(children: _buildFlexCells());
                }

                // 2×2 — always 2 columns × 2 rows.
                // childAspectRatio = cellWidth / cellHeight
                //   cellWidth  = (w − 1 gap) / 2
                //   cellHeight = (h − 1 gap) / 2
                // This makes the grid fill the available body exactly in
                // both portrait and landscape without overflow or black bars.
                const gap = 2.0;
                final cellAspect =
                    ((w - gap) / 2) / ((h - gap) / 2);
                return GridView.count(
                  crossAxisCount: 2,
                  childAspectRatio: cellAspect.clamp(0.1, 10.0),
                  mainAxisSpacing: gap,
                  crossAxisSpacing: gap,
                  padding: EdgeInsets.zero,
                  physics: const NeverScrollableScrollPhysics(),
                  children: _buildGridCells(),
                );
              },
            ),
    );
  }

  Widget _buildCell(int i) => MultiViewCell(
        key: ValueKey('cell_$i'),
        cellIndex: i,
        channel: _channels[i],
        settings: widget.settings,
        source: widget.source,
        sourceIds: widget.sourceIds,
        isFocused: _focusedCell == i && !_interrupted,
        onFocusTap: () => _setFocus(i),
        onChannelPicked: (ch) => _setChannel(i, ch),
        onCloseCell: () => _closeCell(i),
      );

  /// 1×2 cells in a Row or Column — Expanded so each occupies exactly half
  /// the available space regardless of orientation.
  List<Widget> _buildFlexCells() =>
      List.generate(_cellCount, (i) => Expanded(child: _buildCell(i)));

  /// 2×2 cells in a GridView — grid provides constraints; no Expanded needed.
  List<Widget> _buildGridCells() =>
      List.generate(_cellCount, _buildCell);

  void _closeCell(int index) {
    AppLog.info(
      'MultiViewScreen: cell $index closed'
      ' was="${_channels[index]?.name ?? 'empty'}"',
    );
    setState(() => _channels[index] = null);
    _persistChannels();
  }
}
