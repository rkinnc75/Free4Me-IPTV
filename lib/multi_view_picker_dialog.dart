import 'package:flutter/material.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/multi_view_layout.dart';
import 'package:open_tv/models/source.dart';

/// Visual layout picker shown from Settings.
/// fix184: loads enabled sources and gates layouts by their connection limit.
class MultiViewPickerDialog extends StatefulWidget {
  const MultiViewPickerDialog({
    super.key,
    required this.current,
    required this.onSelected,
  });

  final MultiViewLayout current;
  final ValueChanged<MultiViewLayout> onSelected;

  @override
  State<MultiViewPickerDialog> createState() => _MultiViewPickerDialogState();
}

class _MultiViewPickerDialogState extends State<MultiViewPickerDialog> {
  int? _ceiling;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadCeiling();
  }

  Future<void> _loadCeiling() async {
    try {
      final sources = await Sql.getSources();
      final ceiling = _connectionCeiling(sources.where((s) => s.enabled).toList());
      if (mounted) setState(() { _ceiling = ceiling; _loaded = true; });
    } catch (_) {
      if (mounted) setState(() { _loaded = true; });
    }
  }

  /// fix198: SUM of known maxConnections across enabled sources (null =
  /// none known). Multi-view cells can be filled from different sources, so
  /// the total simultaneous-stream ceiling is the sum of per-source limits,
  /// not the minimum. (e.g. a 4-connection source + a 1-connection source =
  /// 5 total, enough for 1×2 or 2×2.) Per-source over-allocation is prevented
  /// separately in the channel picker, not here.
  static int? _connectionCeiling(List<Source> enabled) {
    final known = enabled.map((s) => s.maxConnections).whereType<int>().toList();
    if (known.isEmpty) return null;
    return known.reduce((a, b) => a + b);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const AlertDialog(
        content: SizedBox(height: 80, child: Center(child: CircularProgressIndicator())),
      );
    }

    final ceiling = _ceiling;
    final allow1x2 = ceiling == null || ceiling >= 2;
    final allow2x2 = ceiling == null || ceiling >= 4;

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
          if (ceiling == null) ...[
            const SizedBox(height: 6),
            const Text(
              'Multi-view needs 2 connections (1×2) or 4 (2×2). '
              'If your provider allows fewer, cells may fail to load.',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
          if (!allow1x2) ...[
            const SizedBox(height: 10),
            Text(
              'Your enabled sources allow only $ceiling connection total. '
              'Multi-view needs at least 2 simultaneous streams.',
              style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 16),
          if (allow1x2)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _LayoutCard(
                  layout: MultiViewLayout.oneByTwo,
                  isSelected: widget.current == MultiViewLayout.oneByTwo,
                  onTap: () {
                    widget.onSelected(MultiViewLayout.oneByTwo);
                    Navigator.of(context).pop();
                  },
                ),
                if (allow2x2)
                  _LayoutCard(
                    layout: MultiViewLayout.twoByTwo,
                    isSelected: widget.current == MultiViewLayout.twoByTwo,
                    onTap: () {
                      widget.onSelected(MultiViewLayout.twoByTwo);
                      Navigator.of(context).pop();
                    },
                  )
                else
                  _LayoutCardDisabled(
                    layout: MultiViewLayout.twoByTwo,
                    note: '2×2 needs 4 connections; your sources allow $ceiling total.',
                  ),
              ],
            ),
          const SizedBox(height: 12),
          TextButton(
            autofocus: !allow1x2,
            onPressed: () {
              widget.onSelected(MultiViewLayout.none);
              Navigator.of(context).pop();
            },
            child: Text(
              'Disable multi-view',
              style: TextStyle(
                color: widget.current == MultiViewLayout.none
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
  const _LayoutCard({required this.layout, required this.isSelected, required this.onTap});
  final MultiViewLayout layout;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      autofocus: isSelected,
      borderRadius: BorderRadius.circular(12),
      focusColor: colorScheme.primary.withValues(alpha: 0.25),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? colorScheme.primary : colorScheme.outline.withValues(alpha: 0.3),
            width: isSelected ? 2.5 : 1.5,
          ),
          color: isSelected ? colorScheme.primaryContainer.withValues(alpha: 0.3) : Colors.transparent,
        ),
        child: Column(
          children: [
            _GridDiagram(layout: layout),
            const SizedBox(height: 6),
            Text(layout.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? colorScheme.primary : colorScheme.onSurface,
                )),
          ],
        ),
      ),
    );
  }
}

class _LayoutCardDisabled extends StatelessWidget {
  const _LayoutCardDisabled({required this.layout, required this.note});
  final MultiViewLayout layout;
  final String note;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: note,
      child: Opacity(
        opacity: 0.35,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
              width: 1.5,
            ),
          ),
          child: Column(
            children: [
              _GridDiagram(layout: layout),
              const SizedBox(height: 6),
              Text(layout.label,
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface)),
            ],
          ),
        ),
      ),
    );
  }
}

class _GridDiagram extends StatelessWidget {
  const _GridDiagram({required this.layout});
  final MultiViewLayout layout;

  @override
  Widget build(BuildContext context) {
    const cellColor = Color(0xFF1A1A1A);
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
        border: Border.all(color: Colors.white30, width: 1.5),
      ),
      padding: const EdgeInsets.all(pad),
      child: layout == MultiViewLayout.oneByTwo
          ? Row(children: [
              Expanded(child: Container(color: cellColor)),
              const SizedBox(width: gap),
              Expanded(child: Container(color: cellColor)),
            ])
          : Column(children: [
              Expanded(
                child: Row(children: [
                  Expanded(child: Container(color: cellColor)),
                  const SizedBox(width: gap),
                  Expanded(child: Container(color: cellColor)),
                ]),
              ),
              const SizedBox(height: gap),
              Expanded(
                child: Row(children: [
                  Expanded(child: Container(color: cellColor)),
                  const SizedBox(width: gap),
                  Expanded(child: Container(color: cellColor)),
                ]),
              ),
            ]),
    );
  }
}
