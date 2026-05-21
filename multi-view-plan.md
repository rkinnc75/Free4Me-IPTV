# multi-view-plan.md — Multi-View Implementation Plan

## Overview

Two layout formats — 1×2 (side-by-side) and 2×2 (quad grid) — selectable
from Settings via a visual popup picker. Each cell plays an independent live
stream. One cell has audio at a time; the others play muted. Tapping a cell
gives it audio focus. A `+` button in empty cells opens the channel picker.

---

## Part 1 — Data Model

### New file: `lib/models/multi_view_layout.dart`

Follows the exact pattern of `engine_type.dart`:

```dart
/// Layout format for the multi-view screen.
///
/// [none]    — multi-view disabled (default).
/// [oneByTwo] — two streams side-by-side (landscape).
/// [twoByTwo] — four streams in a 2×2 grid.
enum MultiViewLayout {
  none,
  oneByTwo,
  twoByTwo;

  String toJson() => name;

  static MultiViewLayout fromJson(String? v) => switch (v) {
        'oneByTwo'  => oneByTwo,
        'twoByTwo'  => twoByTwo,
        _           => none,
      };

  String get label => switch (this) {
        none      => 'Disabled',
        oneByTwo  => '1×2  Side by side',
        twoByTwo  => '2×2  Quad grid',
      };

  int get cellCount => switch (this) {
        none      => 0,
        oneByTwo  => 2,
        twoByTwo  => 4,
      };
}
```

### `lib/models/settings.dart` — add field

```dart
// After forcedEngine:
MultiViewLayout multiViewLayout;

// In constructor:
this.multiViewLayout = MultiViewLayout.none,
```

### `lib/backend/settings_service.dart` — persist it

```dart
const multiViewLayoutProp = "multiViewLayout";

// In _readFromDb():
var mvl = settingsMap[multiViewLayoutProp];
if (mvl != null) settings.multiViewLayout = MultiViewLayout.fromJson(mvl);

// In updateSettings():
settingsMap[multiViewLayoutProp] = settings.multiViewLayout.toJson();
```

---

## Part 2 — Visual Layout Picker Dialog

The existing `SelectDialog` is text-only. Multi-view needs a visual dialog
showing the two grid diagrams (matching the uploaded mockup images). This is
a new widget that does NOT modify `SelectDialog`.

### New file: `lib/multi_view_picker_dialog.dart`

```dart
import 'package:flutter/material.dart';
import 'package:open_tv/models/multi_view_layout.dart';

/// Visual layout picker shown from Settings.
/// Renders a miniature diagram of each layout so the user can see
/// what they're selecting before committing.
class MultiViewPickerDialog extends StatelessWidget {
  const MultiViewPickerDialog({
    super.key,
    required this.current,
    required this.onSelected,
  });

  final MultiViewLayout current;
  final ValueChanged<MultiViewLayout> onSelected;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Multi-view layout'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Choose how many streams to show simultaneously.\n'
            'Tap a layout to select it.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _LayoutCard(
                layout: MultiViewLayout.oneByTwo,
                isSelected: current == MultiViewLayout.oneByTwo,
                onTap: () {
                  onSelected(MultiViewLayout.oneByTwo);
                  Navigator.of(context).pop();
                },
              ),
              _LayoutCard(
                layout: MultiViewLayout.twoByTwo,
                isSelected: current == MultiViewLayout.twoByTwo,
                onTap: () {
                  onSelected(MultiViewLayout.twoByTwo);
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Disable option
          TextButton(
            onPressed: () {
              onSelected(MultiViewLayout.none);
              Navigator.of(context).pop();
            },
            child: Text(
              'Disable multi-view',
              style: TextStyle(
                color: current == MultiViewLayout.none
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LayoutCard extends StatelessWidget {
  const _LayoutCard({
    required this.layout,
    required this.isSelected,
    required this.onTap,
  });

  final MultiViewLayout layout;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? colorScheme.primary
                : colorScheme.outline.withValues(alpha: 0.3),
            width: isSelected ? 2.5 : 1.5,
          ),
          color: isSelected
              ? colorScheme.primaryContainer.withValues(alpha: 0.3)
              : Colors.transparent,
        ),
        child: Column(
          children: [
            _GridDiagram(layout: layout),
            const SizedBox(height: 6),
            Text(
              layout.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight:
                    isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected
                    ? colorScheme.primary
                    : colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders a miniature diagram of the grid layout using Containers.
/// Matches the mockup images: grey border, black cells, white dividers.
class _GridDiagram extends StatelessWidget {
  const _GridDiagram({required this.layout});
  final MultiViewLayout layout;

  @override
  Widget build(BuildContext context) {
    const cellColor = Color(0xFF1A1A1A);
    const dividerColor = Colors.white24;
    const borderColor = Colors.white30;
    const w = 110.0;
    const h = 70.0;
    const gap = 3.0;
    const pad = 6.0;

    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: borderColor, width: 1.5),
      ),
      padding: const EdgeInsets.all(pad),
      child: layout == MultiViewLayout.oneByTwo
          ? Row(
              children: [
                Expanded(child: Container(color: cellColor)),
                const SizedBox(width: gap),
                Expanded(child: Container(color: cellColor)),
              ],
            )
          : Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Expanded(child: Container(color: cellColor)),
                      const SizedBox(width: gap),
                      Expanded(child: Container(color: cellColor)),
                    ],
                  ),
                ),
                const SizedBox(height: gap),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(child: Container(color: cellColor)),
                      const SizedBox(width: gap),
                      Expanded(child: Container(color: cellColor)),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
```

---

## Part 3 — Settings Integration

### `lib/settings_view.dart`

Add a new tile in the **General** section (after the engine selection tile,
before the EPG section). Follows the same `ListTile` + trailing `TextButton`
pattern as `_engineSelectionTile`:

```dart
Widget _multiViewTile(Settings settings) {
  return ListTile(
    title: Row(
      children: [
        const Text('Multi-view layout'),
        const SizedBox(width: 4),
        _helpIcon(
          title: 'Multi-view',
          body:
              'Play multiple streams simultaneously in a split-screen grid.\n\n'
              '1×2 shows two streams side-by-side.\n'
              '2×2 shows four streams in a quad grid.\n\n'
              'Tap a cell to give it audio focus. Tap + to assign a channel '
              'to an empty cell. Double-tap to promote a cell to full-screen.\n\n'
              'Each stream uses its own decoder. On lower-end devices, '
              '2×2 may cause thermal throttling. Start with 1×2.',
        ),
      ],
    ),
    trailing: TextButton(
      onPressed: () => _showMultiViewPickerDialog(context, settings),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _multiViewShortLabel(settings.multiViewLayout),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(width: 4),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    ),
  );
}

String _multiViewShortLabel(MultiViewLayout layout) => switch (layout) {
      MultiViewLayout.none      => 'Off',
      MultiViewLayout.oneByTwo  => '1×2',
      MultiViewLayout.twoByTwo  => '2×2',
    };

void _showMultiViewPickerDialog(BuildContext context, Settings settings) {
  showDialog(
    context: context,
    barrierDismissible: true,
    builder: (_) => MultiViewPickerDialog(
      current: settings.multiViewLayout,
      onSelected: (layout) {
        setState(() => settings.multiViewLayout = layout);
        updateSettings();
      },
    ),
  );
}
```

---

## Part 4 — Multi-View Screen

### New file: `lib/multi_view_screen.dart`

```dart
import 'package:flutter/material.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/multi_view_layout.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/multi_view_cell.dart';

/// Full-screen multi-view grid. Each cell is an independent stream.
/// One cell has audio at a time; all others are muted.
class MultiViewScreen extends StatefulWidget {
  const MultiViewScreen({
    super.key,
    required this.layout,
    required this.settings,
    required this.source,
  });

  final MultiViewLayout layout;
  final Settings settings;
  final Source? source;

  @override
  State<MultiViewScreen> createState() => _MultiViewScreenState();
}

class _MultiViewScreenState extends State<MultiViewScreen> {
  late final int _cellCount = widget.layout.cellCount;
  late final List<Channel?> _channels = List.filled(_cellCount, null);
  int _focusedCell = 0; // which cell has audio

  void _setChannel(int index, Channel channel) {
    setState(() => _channels[index] = channel);
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
            icon: const Icon(Icons.grid_view),
            tooltip: 'Change layout',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: widget.layout == MultiViewLayout.oneByTwo
          ? Row(children: _buildCells())
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
        isFocused: _focusedCell == i,
        onFocusTap: () => _setFocus(i),
        onChannelPicked: (ch) => _setChannel(i, ch),
      );
    });
  }
}
```

### New file: `lib/multi_view_cell.dart`

```dart
import 'package:flutter/material.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/player.dart';
import 'package:open_tv/player/mpv_engine.dart';

/// A single cell in the multi-view grid.
///
/// - Empty cell: shows a centred + FAB to open the channel picker.
/// - Loaded cell: shows the live video, muted unless [isFocused].
/// - Tap: gives this cell audio focus.
/// - Double-tap: promotes to full-screen Player.
class MultiViewCell extends StatefulWidget {
  const MultiViewCell({
    super.key,
    required this.channel,
    required this.settings,
    required this.source,
    required this.isFocused,
    required this.onFocusTap,
    required this.onChannelPicked,
  });

  final Channel? channel;
  final Settings settings;
  final Source? source;
  final bool isFocused;
  final VoidCallback onFocusTap;
  final ValueChanged<Channel> onChannelPicked;

  @override
  State<MultiViewCell> createState() => _MultiViewCellState();
}

class _MultiViewCellState extends State<MultiViewCell> {
  MpvEngine? _engine;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    if (widget.channel != null) _startEngine(widget.channel!);
  }

  @override
  void didUpdateWidget(MultiViewCell old) {
    super.didUpdateWidget(old);
    // New channel assigned to this cell
    if (widget.channel != old.channel && widget.channel != null) {
      _engine?.dispose();
      _engine = null;
      _error = false;
      _startEngine(widget.channel!);
    }
    // Focus changed — update volume
    if (widget.isFocused != old.isFocused) {
      _engine?.setVolume(widget.isFocused ? 1.0 : 0.0);
    }
  }

  Future<void> _startEngine(Channel ch) async {
    // Use reduced buffers for preview — 32MB vs 256MB full-screen
    final previewSettings = Settings.copyWith(
      widget.settings,
      liveDemuxerMaxMB: 16,
    );
    final engine = MpvEngine(
      channel: ch,
      settings: previewSettings,
      fullscreenOnOpen: false,
    );
    await engine.setVolume(widget.isFocused ? 1.0 : 0.0);
    _engine = engine;

    try {
      await engine.open(url: ch.url ?? '');
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  void dispose() {
    _engine?.dispose();
    super.dispose();
  }

  Future<void> _pickChannel() async {
    // Navigate to Home in picker mode — returns a Channel
    final ch = await Navigator.of(context).push<Channel>(
      MaterialPageRoute(
        builder: (_) => const ChannelPickerScreen(),
      ),
    );
    if (ch != null) widget.onChannelPicked(ch);
  }

  Future<void> _promoteToFullScreen() async {
    final ch = widget.channel;
    if (ch == null) return;
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
    if (_engine == null) return _buildLoadingCell();
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
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, color: Colors.red, size: 32),
            SizedBox(height: 8),
            Text('Stream unavailable',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingCell() {
    return Container(
      color: Colors.black,
      child: const Center(
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
          _engine!.videoWidget(),
          // Focus indicator — thin coloured border on active cell
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
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
          // Audio icon badge — top right
          Positioned(
            right: 8,
            top: 8,
            child: Icon(
              widget.isFocused ? Icons.volume_up : Icons.volume_off,
              color: widget.isFocused ? Colors.white : Colors.white30,
              size: 16,
            ),
          ),
        ],
      ),
    );
  }
}
```

---

## Part 5 — Channel Picker Screen

A lightweight screen wrapping the existing Home search, returned via
`Navigator.push<Channel>`. Reuses all existing channel tile and search
infrastructure.

### New file: `lib/channel_picker_screen.dart`

```dart
import 'package:flutter/material.dart';
import 'package:open_tv/models/channel.dart';

/// Minimal channel picker for multi-view cell assignment.
/// Wraps the existing Home widget in "pick mode" — tapping a channel
/// pops with that channel instead of opening the Player.
class ChannelPickerScreen extends StatelessWidget {
  const ChannelPickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select channel')),
      // Home is instantiated in picker mode — channel tile onTap
      // calls Navigator.pop(channel) instead of pushing Player.
      body: Home(pickerMode: true),
    );
  }
}
```

Add `pickerMode` bool to `Home` widget constructor. When `pickerMode: true`,
`ChannelTile.onTap` calls `Navigator.of(context).pop(channel)` instead of
`Navigator.of(context).push(PlayerRoute)`.

---

## Part 6 — Entry Point from Home

When `settings.multiViewLayout != MultiViewLayout.none`, show a grid icon
in the Home toolbar that navigates to `MultiViewScreen`:

### `lib/home.dart`

```dart
// In the AppBar actions, after the radar icon:
if (settings.multiViewLayout != MultiViewLayout.none)
  IconButton(
    icon: const Icon(Icons.grid_view),
    tooltip: 'Multi-view',
    onPressed: () => Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MultiViewScreen(
          layout: settings.multiViewLayout,
          settings: settings,
          source: _selectedSource,
        ),
      ),
    ),
  ),
```

---

## Part 7 — Memory Configuration

### `lib/player/mpv_engine.dart`

Add `previewMode` flag to reduce buffer allocation for multi-view cells:

```dart
MpvEngine({
  required this.channel,
  required this.settings,
  this.fullscreenOnOpen = true,
  this.previewMode = false,   // ← ADD
});

// In PlayerConfiguration:
late final mk.Player _player = mk.Player(
  configuration: mk.PlayerConfiguration(
    bufferSize: previewMode
        ? 32 * 1024 * 1024   // 32MB per cell in multi-view
        : 256 * 1024 * 1024, // 256MB for full-screen
    logLevel: mk.MPVLogLevel.warn,
  ),
);

// In _applyMpvOptions(), live stream branch:
await np.setProperty('demuxer-max-bytes',
    previewMode ? '16MiB' : '${s.liveDemuxerMaxMB}MiB');
```

---

## Summary

| # | New file / change | Lines |
|---|---|---|
| 1 | `lib/models/multi_view_layout.dart` — enum | ~35 |
| 2 | `lib/models/settings.dart` — add field | 2 |
| 3 | `lib/backend/settings_service.dart` — persist | 4 |
| 4 | `lib/multi_view_picker_dialog.dart` — visual dialog | ~120 |
| 5 | `lib/settings_view.dart` — tile + dialog call | ~40 |
| 6 | `lib/multi_view_screen.dart` — grid screen | ~80 |
| 7 | `lib/multi_view_cell.dart` — cell widget | ~150 |
| 8 | `lib/channel_picker_screen.dart` — picker wrapper | ~20 |
| 9 | `lib/home.dart` — pickerMode + toolbar button | ~15 |
| 10 | `lib/player/mpv_engine.dart` — previewMode buffers | ~10 |
| **Total** | | **~476 lines** |

---

## Hardware limits

| Device | 1×2 | 2×2 |
|---|---|---|
| Phone (mid-range) | ✓ fine | ⚠ thermal risk |
| Onn 4K (Snapdragon 4s) | ✓ fine | ⚠ marginal |
| Shield (Tegra X1) | ✓ fine (needs fix13) | ✓ fine (needs fix13) |

**fix13 (`mediacodec-copy`) is a hard prerequisite for Android TV multi-view.**
Without it, multiple MediaCodec surface bindings will conflict on TV hardware.

---

## Model

Opus (architectural feature — new screen, new model, cross-cutting changes)
