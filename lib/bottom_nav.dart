import 'package:flutter/material.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/settings_view.dart';
import 'package:open_tv/recordings_view.dart';


const _fixedColors = [
  Color(0xFF9B59D9), // Categories — purple
  Color(0xFFF0B429), // Favorites  — amber
  Color(0xFF4CAF78), // History    — green
  Color(0xFFE8624A), // Settings   — red-orange
  Color(0xFFEC407A), // Recordings — pink (fix669)
];

const _fixedIcons = [
  Icons.dashboard,
  Icons.star,
  Icons.history,
  Icons.settings,
  Icons.fiber_smart_record, // fix669
];

const _fixedLabels = ['Categories', 'Favorites', 'History', 'Settings', 'Recordings'];


const _filterColors = {
  ContentTypeFilter.all:     Color(0xFFFFFFFF), // fix152: white (distinct from Live)
  ContentTypeFilter.live:    Color(0xFF4E9FE5), // blue
  ContentTypeFilter.movies:  Color(0xFF8BC34A), // lime
  ContentTypeFilter.series:  Color(0xFFE040FB), // magenta
};

const _filterIcons = {
  ContentTypeFilter.all:     Icons.list,
  ContentTypeFilter.live:    Icons.live_tv,
  ContentTypeFilter.movies:  Icons.movie,
  ContentTypeFilter.series:  Icons.video_library,
};

const _filterLabels = {
  ContentTypeFilter.all:     'All',
  ContentTypeFilter.live:    'Live',
  ContentTypeFilter.movies:  'Movies',
  ContentTypeFilter.series:  'Series',
};

class BottomNav extends StatefulWidget {
  final Function(ViewType) updateViewMode;
  final Function(ContentTypeFilter) onContentTypeChanged;
  final ViewType startingView;
  final ContentTypeFilter contentTypeFilter;
  final Settings settings;
  final bool blockSettings;

  const BottomNav({
    super.key,
    required this.updateViewMode,
    required this.onContentTypeChanged,
    required this.settings,
    this.startingView = ViewType.all,
    this.contentTypeFilter = ContentTypeFilter.all,
    this.blockSettings = false,
  });

  @override
  State<BottomNav> createState() => _BottomNavState();
}

class _BottomNavState extends State<BottomNav> {
  // 0 = All/filter tab; 1–4 = Categories, Favorites, History, Settings
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.startingView.index;
  }

  void _onFilterTap() {
    final available = widget.settings.availableContentFilters();
    if (available.length <= 1) return; // static — nothing to cycle
    final next = widget.settings.nextContentFilter();
    widget.onContentTypeChanged(next);
  }

  void _onFixedTap(int fixedIndex) {
    // fixedIndex 0–3 maps to Categories, Favorites, History, Settings
    final viewIndex = fixedIndex + 1;
    if (widget.blockSettings && viewIndex == ViewType.settings.index) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Settings disabled while refreshing on start'),
        ),
      );
      return;
    }
    setState(() => _selectedIndex = viewIndex);
    if (viewIndex == ViewType.settings.index) {
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
    // fix669: Recordings is its own screen (like Settings), not a Home filter.
    if (viewIndex == ViewType.recordings.index) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const RecordingsView()),
      ).then((_) {
        // Return focus to the previous tab after closing Recordings.
        if (mounted) setState(() => _selectedIndex = ViewType.all.index);
      });
      return;
    }
    widget.updateViewMode(ViewType.values[viewIndex]);
  }

  Widget _navItem({
    required Color color,
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              decoration: BoxDecoration(
                color: selected ? color.withAlpha(46) : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filter = widget.contentTypeFilter;
    final filterColor = _filterColors[filter]!;
    final filterIcon = _filterIcons[filter]!;
    final filterLabel = _filterLabels[filter]!;

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
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 80,
          child: Row(
            children: [
              _navItem(
                color: filterColor,
                icon: filterIcon,
                label: filterLabel,
                selected: _selectedIndex == ViewType.all.index,
                onTap: () {
                  // widget.startingView (construction-time) to decide
                  // whether to navigate or cycle the filter.
                  // startingView never updates after BottomNav is built,
                  // so it was always the view at construction — wrong after
                  // any navigation.
                  final alreadyOnAll = _selectedIndex == ViewType.all.index;
                  setState(() => _selectedIndex = ViewType.all.index);
                  if (alreadyOnAll) {
                    // Already on All — cycle content type filter in place.
                    // onContentTypeChanged handles the reload; no navigation.
                    _onFilterTap();
                  } else {
                    // Coming from another tab — navigate to All without cycling.
                    widget.updateViewMode(ViewType.all);
                  }
                },
              ),
              for (var i = 0; i < _fixedLabels.length; i++)
                _navItem(
                  color: _fixedColors[i],
                  icon: _fixedIcons[i],
                  label: _fixedLabels[i],
                  selected: _selectedIndex == i + 1,
                  onTap: () => _onFixedTap(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
