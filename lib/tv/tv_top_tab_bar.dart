import 'package:flutter/material.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/view_type.dart';

/// fix500: a single tab in the TV shell's top bar.
///
/// Colors are COPIED from `bottom_nav.dart`'s per-section palette — we copy the
/// consts rather than reuse the phone-only `BottomNav` widget, so phone mode is
/// untouched.
class TvTab {
  final String label;
  final Color color;
  final List<MediaType> mediaTypes;
  final ViewType viewType;
  final bool isSearch;

  const TvTab({
    required this.label,
    required this.color,
    required this.mediaTypes,
    required this.viewType,
    this.isSearch = false,
  });
}

/// fix500: the persistent top tab bar — brand · tabs · Settings gear.
/// D-pad: tabs are a horizontal [FocusTraversalGroup]; the active tab is
/// highlighted with its section color and the focused tab draws a yellow ring
/// (matching the app-wide TV focus border). Down from a tab enters the body.
class TvTopTabBar extends StatelessWidget {
  final List<TvTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback onSettings;

  /// fix524: optional long-press per tab index (TV History tab → clear all).
  final ValueChanged<int>? onLongPress;

  const TvTopTabBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    required this.onSettings,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // fix529: the real app icon, not the placeholder green TV icon.
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.asset('assets/icon.png',
                      width: 28, height: 28, fit: BoxFit.cover),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Free4Me',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
                ),
              ],
            ),
          ),
          Expanded(
            child: FocusTraversalGroup(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (int i = 0; i < tabs.length; i++)
                    _TabButton(
                      tab: tabs[i],
                      selected: i == selectedIndex,
                      autofocus: i == selectedIndex,
                      onTap: () => onSelected(i),
                      onLongPress:
                          onLongPress == null ? null : () => onLongPress!(i),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: onSettings,
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatefulWidget {
  final TvTab tab;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _TabButton({
    required this.tab,
    required this.selected,
    required this.autofocus,
    required this.onTap,
    this.onLongPress,
  });

  @override
  State<_TabButton> createState() => _TabButtonState();
}

class _TabButtonState extends State<_TabButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final bool selected = widget.selected;
    final Color bg = selected ? widget.tab.color : Colors.transparent;
    final Color fg = selected ? Colors.black : Colors.white70;
    final Color border = _focused ? Colors.yellow : Colors.transparent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          autofocus: widget.autofocus,
          borderRadius: BorderRadius.circular(999),
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          onFocusChange: (value) => setState(() => _focused = value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: border, width: 3),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.tab.isSearch) ...[
                  Icon(Icons.search, size: 18, color: fg),
                  const SizedBox(width: 6),
                ],
                Text(
                  widget.tab.label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
