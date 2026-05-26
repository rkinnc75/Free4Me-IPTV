import 'package:flutter/material.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/settings_view.dart';

// Per-item colors matching the design screenshot.
const _navColors = [
  Color(0xFF4E9FE5), // All — blue
  Color(0xFF9B59D9), // Categories — purple
  Color(0xFFF0B429), // Favorites — amber
  Color(0xFF4CAF78), // History — green
  Color(0xFFE8624A), // Settings — red-orange
];

const _navIcons = [
  Icons.list,
  Icons.dashboard,
  Icons.star,
  Icons.history,
  Icons.settings,
];

const _navLabels = ['All', 'Categories', 'Favorites', 'History', 'Settings'];

class BottomNav extends StatefulWidget {
  final Function(ViewType) updateViewMode;
  final ViewType startingView;
  final bool blockSettings;
  const BottomNav({
    super.key,
    required this.updateViewMode,
    this.startingView = ViewType.all,
    this.blockSettings = false,
  });

  @override
  State<BottomNav> createState() => _BottomNavState();
}

class _BottomNavState extends State<BottomNav> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.startingView.index;
  }

  void onBarTapped(int index) {
    if (widget.blockSettings && index == ViewType.settings.index) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Settings disabled while refreshing on start"),
        ),
      );
      return;
    }
    setState(() => _selectedIndex = index);
    if (_selectedIndex == ViewType.settings.index) {
      Navigator.pushAndRemoveUntil(
        context,
        PageRouteBuilder(
          pageBuilder: (_, _, _) => const SettingsView(),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          transitionsBuilder:
              (context, animation, secondaryAnimation, child) => child,
        ),
        (route) => false,
      );
      return;
    }
    widget.updateViewMode(ViewType.values[_selectedIndex]);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceBright,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.surfaceBright,
            width: 1,
          ),
        ),
      ),
      // Match the height NavigationBar uses at its default size.
      height: 80,
      child: Row(
        children: List.generate(_navLabels.length, (i) {
          final color = _navColors[i];
          final selected = _selectedIndex == i;
          return Expanded(
            child: InkWell(
              onTap: () => onBarTapped(i),
              borderRadius: BorderRadius.circular(16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Selected pill — same shape as Material 3 NavigationBar.
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeInOut,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: selected
                          ? color.withValues(alpha: 0.18)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      _navIcons[i],
                      color: color,
                      size: 24,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _navLabels[i],
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}
