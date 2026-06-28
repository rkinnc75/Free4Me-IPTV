import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/media_type.dart'; // fix144
import 'package:open_tv/models/multi_view_layout.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/multi_view_cell.dart';
import 'package:open_tv/player/overlay_player_controller.dart';

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
    this.initialChannel, // fix584 (#6): pre-assign this channel after restore
  });

  final MultiViewLayout layout;
  final Settings settings;
  final Source? source;
  final List<int> sourceIds;

  /// fix584 (#6): when opened from a channel's long-press "Open in Multi-view",
  /// this channel is dropped into the first empty cell (cell 0 if all full)
  /// after the saved layout is restored.
  final Channel? initialChannel;

  /// fix584 (#6): open Multi-view from a long-pressed LIVE channel, dropping it
  /// into the first free cell. Each caller passes its OWN [sourceIds] (there is
  /// no shared opener state). Uses the last-used layout, defaulting to 2×2 when
  /// none has been chosen yet. Closes any mini-player overlay first.
  static Future<void> openWithChannel(
    BuildContext context,
    Settings settings,
    List<int> sourceIds,
    Channel channel,
  ) async {
    if (sourceIds.isEmpty) return;
    final layout = settings.multiViewLayout == MultiViewLayout.none
        ? MultiViewLayout.twoByTwo
        : settings.multiViewLayout;
    await OverlayPlayerController.instance.stopOverlay();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MultiViewScreen(
          layout: layout,
          settings: settings,
          source: null,
          sourceIds: sourceIds,
          initialChannel: channel,
        ),
      ),
    );
  }

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
    // fix584 (#6): seed the long-pressed channel AFTER restore completes (covers
    // every _restoreChannels exit path: auto-restore-off, no-saved, restored).
    unawaited(_restoreChannels().then((_) {
      if (mounted) _seedInitialChannel();
    }));
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
    // cells empty. The persisted channel IDs in multiViewCells1x2 /
    // multiViewCells2x2 are NOT cleared — flipping the setting back
    // on restores them on the next entry.
    if (!widget.settings.multiViewAutoRestoreChannels) {
      AppLog.info(
        'MultiViewScreen: auto-restore disabled — opening with empty cells'
        ' layout=${widget.layout.name}',
      );
      if (mounted) setState(() => _restored = true);
      return;
    }

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
      // fix140: multi-view is live TV only. A persisted ID can become a
      // movie/series after a source refresh; skip anything not livestream.
      if (ch != null && ch.mediaType == MediaType.livestream) {
        _channels[entry.key] = ch;
      } else if (ch != null) {
        AppLog.info(
          'MultiViewScreen: restore skipped non-livestream cell ${entry.key}'
          ' channel="${ch.name}" mediaType=${ch.mediaType}',
        );
      }
    }

    AppLog.info(
      'MultiViewScreen: restored'
      ' ${_channels.where((c) => c != null).length}/$_cellCount cells',
    );
    setState(() => _restored = true);
    unawaited(_checkConnectionLimits()); // fix352
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

  /// fix352: last connection-limit warning shown, to avoid repeating the
  /// same SnackBar when the violating cell composition hasn't changed.
  String? _lastConnWarning;

  /// fix352: warn when more cells are assigned to one source than the
  /// provider allows (sources.max_connections, captured on Xtream refresh
  /// since fix184). Oversubscribing causes the provider to round-robin
  /// connections — each new cell connect kills another cell's stream
  /// (confirmed via Dino API dump + S24 logs, 2026-06-11/12). Null/unknown
  /// limits warn nothing.
  Future<void> _checkConnectionLimits() async {
    final counts = <int, int>{};
    for (final ch in _channels) {
      if (ch != null) counts[ch.sourceId] = (counts[ch.sourceId] ?? 0) + 1;
    }
    final warnings = <String>[];
    for (final e in counts.entries) {
      if (e.value < 2) continue; // one cell can never exceed a positive limit
      final src = await Sql.getSourceById(e.key);
      final limit = src?.maxConnections;
      if (src != null && limit != null && e.value > limit) {
        warnings.add(
          '${src.name} allows $limit connection${limit == 1 ? '' : 's'} — '
          '${e.value} cells will fight over it',
        );
      }
    }
    if (warnings.isEmpty) {
      _lastConnWarning = null;
      return;
    }
    final msg = warnings.join('\n');
    if (msg == _lastConnWarning) return; // already warned for this layout
    _lastConnWarning = msg;
    AppLog.warn(
      'MultiViewScreen: connection-limit warning — ${warnings.join(' | ')}',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 8)),
    );
  }

  /// fix584 (#6): drop [widget.initialChannel] into the first empty cell
  /// (preserving the restored layout); fall back to cell 0 if all are full.
  /// Reuses _setChannel so it persists + records history like a manual pick.
  void _seedInitialChannel() {
    final ch = widget.initialChannel;
    if (ch == null) return;
    var idx = _channels.indexWhere((c) => c == null);
    if (idx < 0) idx = 0;
    _setChannel(idx, ch);
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
    unawaited(_checkConnectionLimits()); // fix352
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
      // fix172: contain D-pad traversal to the cells.
      body: !_restored
          ? const Center(child: CircularProgressIndicator())
          : FocusTraversalGroup(
              child: LayoutBuilder(
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
