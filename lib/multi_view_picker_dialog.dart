import 'package:flutter/material.dart';
import 'package:open_tv/models/multi_view_layout.dart';

/// Visual layout picker shown from Settings.
/// fix202: connection-limit gating removed. max_connections is a
/// provider-advertised value, not a client-side ceiling — a 1-connection
/// provider was observed running a full 2×2 (v1.23.19 log). Both layouts are
/// always offered; an informational hint notes some cells may fail on strict
/// providers. Source import no longer needed here.
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
          const SizedBox(height: 6),
          const Text(
            'Some providers limit simultaneous streams; if yours does, '
            'one or more cells may fail to load.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
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
              _LayoutCard(
                layout: MultiViewLayout.twoByTwo,
                isSelected: widget.current == MultiViewLayout.twoByTwo,
                onTap: () {
                  widget.onSelected(MultiViewLayout.twoByTwo);
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextButton(
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
