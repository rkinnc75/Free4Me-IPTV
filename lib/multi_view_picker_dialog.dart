import 'package:flutter/material.dart';
import 'package:open_tv/models/multi_view_layout.dart';

/// Visual layout picker shown from Settings.
/// Renders a miniature diagram of each layout alongside a label so the
/// user can see what they're selecting before committing.
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
          const SizedBox(height: 12),
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
                    : Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.5),
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
    return InkWell(
      onTap: onTap,
      autofocus: isSelected, // fix156: focus selected card on open
      borderRadius: BorderRadius.circular(12),
      focusColor: colorScheme.primary.withValues(alpha: 0.25),
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

/// Miniature diagram of the grid layout.
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
