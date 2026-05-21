import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    _channels = List.filled(_cellCount, null);
    _restoreChannels();
  }

  /// Restore persisted channel IDs for the current layout. The stored
  /// string is comma-separated IDs (empty entry = empty cell).
  Future<void> _restoreChannels() async {
    final raw = widget.layout == MultiViewLayout.oneByTwo
        ? widget.settings.multiViewCells1x2
        : widget.settings.multiViewCells2x2;

    final parts = raw.split(',');
    final toFetch = <int, int>{}; // cellIndex → channelId

    for (var i = 0; i < _cellCount && i < parts.length; i++) {
      final id = int.tryParse(parts[i]);
      if (id != null) toFetch[i] = id;
    }

    if (toFetch.isEmpty) {
      if (mounted) setState(() => _restored = true);
      return;
    }

    for (final entry in toFetch.entries) {
      final ch = await Sql.getChannelById(entry.value);
      if (!mounted) return;
      if (ch != null) _channels[entry.key] = ch;
    }

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
    setState(() => _channels[index] = channel);
    _persistChannels();
    // Give the new cell audio focus automatically.
    if (_focusedCell != index) setState(() => _focusedCell = index);
  }

  void _setFocus(int index) {
    if (_focusedCell == index) return;
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
          : widget.layout == MultiViewLayout.oneByTwo
              ? Row(
                  children: _buildCells(),
                )
              : GridView.count(
                  crossAxisCount: 2,
                  childAspectRatio: 16 / 9,
                  mainAxisSpacing: 2,
                  crossAxisSpacing: 2,
                  padding: EdgeInsets.zero,
                  physics: const NeverScrollableScrollPhysics(),
                  children: _buildCells(),
                ),
    );
  }

  List<Widget> _buildCells() {
    return List.generate(_cellCount, (i) {
      return MultiViewCell(
        key: ValueKey('cell_$i'),
        channel: _channels[i],
        settings: widget.settings,
        source: widget.source,
        sourceIds: widget.sourceIds,
        isFocused: _focusedCell == i,
        onFocusTap: () => _setFocus(i),
        onChannelPicked: (ch) => _setChannel(i, ch),
      );
    });
  }
}
