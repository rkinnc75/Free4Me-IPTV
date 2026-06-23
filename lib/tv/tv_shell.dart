import 'package:flutter/material.dart';
import 'package:open_tv/home.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/settings_view.dart';
import 'package:open_tv/tv/tv_guide_view.dart';
import 'package:open_tv/tv/tv_search_view.dart';
import 'package:open_tv/tv/tv_top_tab_bar.dart';

/// fix500: the persistent TV top-tab shell that replaces the old two-level
/// giant-button TvHome menu.
///
/// Each tab hosts the existing [Home] body (with `hasTouchScreen: false`, so
/// `BottomNav` stays suppressed) built from a per-tab [Filters]. Bodies are
/// built lazily on first selection and kept alive via [IndexedStack], so launch
/// runs a single cold catalogue query (the landing tab) rather than six.
///
/// Phone mode is untouched: this widget is only ever mounted on the TV entry
/// path (`main.dart` -> `TvHome` -> `TvShell`); phone uses `Home` +
/// `BottomNav` directly.
class TvShell extends StatefulWidget {
  final Settings settings;
  const TvShell({super.key, required this.settings});

  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> {
  // Section colors copied from bottom_nav.dart's palette.
  static const List<TvTab> _tabs = [
    TvTab(
      label: 'Live TV',
      color: Color(0xFF4E9FE5),
      mediaTypes: [MediaType.livestream],
      viewType: ViewType.all,
    ),
    TvTab(
      label: 'Movies',
      color: Color(0xFF8BC34A),
      mediaTypes: [MediaType.movie],
      viewType: ViewType.all,
    ),
    TvTab(
      label: 'Series',
      color: Color(0xFFE040FB),
      mediaTypes: [MediaType.serie],
      viewType: ViewType.all,
    ),
    TvTab(
      label: 'Favorites',
      color: Color(0xFFF0B429),
      mediaTypes: [MediaType.livestream, MediaType.movie, MediaType.serie],
      viewType: ViewType.favorites,
    ),
    TvTab(
      label: 'History',
      color: Color(0xFF4CAF78),
      mediaTypes: [MediaType.livestream, MediaType.movie, MediaType.serie],
      viewType: ViewType.history,
    ),
    // Search tab: the dedicated grouped EPG + channel "what's on" search
    // (fix502). mediaTypes/viewType are unused for this tab.
    TvTab(
      label: 'Search',
      color: Color(0xFFB0BEC5),
      mediaTypes: [MediaType.livestream, MediaType.movie, MediaType.serie],
      viewType: ViewType.all,
      isSearch: true,
    ),
  ];

  late int _index;
  late final List<Widget?> _built = List<Widget?>.filled(_tabs.length, null);

  @override
  void initState() {
    super.initState();
    _index = _landingIndex(widget.settings.defaultView);
    _ensureBuilt(_index);
  }

  /// fix500: map the saved Default view onto a landing tab. [ViewType] has no
  /// livestream/movie/serie member, so `all` / `categories` land on Live TV
  /// (the category rail focus arrives in fix501); favorites/history map to
  /// their own tabs.
  int _landingIndex(ViewType v) {
    switch (v) {
      case ViewType.favorites:
        return 3;
      case ViewType.history:
        return 4;
      case ViewType.all:
      case ViewType.categories:
      case ViewType.settings:
        return 0;
    }
  }

  void _ensureBuilt(int i) {
    if (_built[i] != null) return;
    final TvTab t = _tabs[i];
    // fix503: Live TV (tab 0) hosts the EPG guide (category rail + channel×time
    // grid). fix502: the Search tab hosts the grouped "what's on" search. The
    // other content tabs host the existing Home browse body.
    if (t.isSearch) {
      _built[i] = TvSearchView(settings: widget.settings);
    } else if (i == 0) {
      _built[i] = TvGuideView(settings: widget.settings);
    } else {
      _built[i] = Home(
        key: ValueKey<String>('tv-tab-${t.label}'),
        hasTouchScreen: false,
        home: HomeManager(
          filters: Filters(
            viewType: t.viewType,
            mediaTypes: List<MediaType>.of(t.mediaTypes),
          ),
        ),
      );
    }
  }

  void _select(int i) {
    if (i == _index) return;
    setState(() {
      _index = i;
      _ensureBuilt(i);
    });
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SettingsView(showNavBar: false)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            TvTopTabBar(
              tabs: _tabs,
              selectedIndex: _index,
              onSelected: _select,
              onSettings: _openSettings,
            ),
            Expanded(
              child: IndexedStack(
                index: _index,
                children: [
                  for (final Widget? w in _built)
                    w ?? const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
