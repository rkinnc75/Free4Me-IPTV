import 'package:flutter/material.dart';

/// fix196: the approved pastel palette for per-source color tagging.
/// Values are full ARGB ints (stored in sources.color; null = None/no tint).
class SourcePalette {
  static const List<({String name, int? value})> swatches = [
    (name: 'None', value: null),
    (name: 'Rose', value: 0xFFF8BBD0),
    (name: 'Peach', value: 0xFFFFCCBC),
    (name: 'Butter', value: 0xFFFFF9C4),
    (name: 'Mint', value: 0xFFC8E6C9),
    (name: 'Sky', value: 0xFFB3E5FC),
    (name: 'Periwinkle', value: 0xFFC5CAE9),
    (name: 'Lavender', value: 0xFFE1BEE7),
    (name: 'Aqua', value: 0xFFB2DFDB),
  ];

  /// Blend a stored source color (~35%) over a base surface color so channel
  /// text stays legible. Returns base unchanged when color is null.
  static Color tintOver(int? color, Color base) {
    if (color == null) return base;
    // Color.lerp(base, color, 0.35): 35% toward the tag color, opaque result.
    return Color.lerp(base, Color(color), 0.35) ?? base;
  }
}

/// Shows a pastel picker. Returns a record indicating whether the user made a
/// choice and the chosen color (null = None). Returns null if dismissed.
Future<({bool chose, int? color})?> showSourceColorPicker(
  BuildContext context, {
  int? current,
}) {
  return showDialog<({bool chose, int? color})>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: const Text('Source color'),
        content: SizedBox(
          width: double.maxFinite,
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 3,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            children: [
              for (final s in SourcePalette.swatches)
                _Swatch(
                  name: s.name,
                  value: s.value,
                  selected: s.value == current,
                  onTap: () =>
                      Navigator.of(ctx).pop((chose: true, color: s.value)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
        ],
      );
    },
  );
}

class _Swatch extends StatelessWidget {
  final String name;
  final int? value;
  final bool selected;
  final VoidCallback onTap;
  const _Swatch({
    required this.name,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isNone = value == null;
    return InkWell(
      autofocus: selected,
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: isNone ? Colors.transparent : Color(value!),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? Colors.greenAccent : Colors.grey,
            width: selected ? 3 : 1,
          ),
        ),
        child: Center(
          child: Text(
            name,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isNone ? Colors.grey : Colors.black87,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}
