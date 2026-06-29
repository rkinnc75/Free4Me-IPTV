import 'package:flutter/material.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/home.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/backend/issue_reporter.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/confirm_exit_scope.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/settings_view.dart';
import 'package:open_tv/tv/tv_browse_view.dart';
import 'package:open_tv/tv/tv_categories_view.dart';
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
    // fix525: Categories management — mounts the SAME ViewType.categories Home
    // the phone uses (Select All / Unselect All + per-category enable/disable),
    // scoped to live-TV categories so foreign-language groups (|AR|, |DE|, ...)
    // can be hidden. Built by _ensureBuilt's generic `else` Home branch; the
    // toggles write groups.enabled / channels.cat_enabled shared with phone.
    TvTab(
      label: 'Categories',
      color: Color(0xFF26C6DA),
      mediaTypes: [MediaType.livestream],
      viewType: ViewType.categories,
    ),
    // fix539: the standalone Favorites tab is removed — Favorites now lives
    // inside Live/Movies/Series (the rail's top item / the guide's pill), so a
    // separate cross-media Favorites tab is redundant.
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
  // fix524: bumped to force the History tab body to rebuild after a clear.
  int _historyGen = 0;
  // fix534: bumped on tab re-select / return-from-Settings to force the cached
  // TV tabs (Search/Movies/Series/Categories) to rebuild with a fresh key, so
  // they re-run initState/_load and pick up a changed enabled-source set. The
  // IndexedStack keeps every tab alive, so without this they stay stale.
  int _reloadGen = 0;
  late final List<Widget?> _built = List<Widget?>.filled(_tabs.length, null);
  // fix510: lets _select() release the Live guide's hero preview on tab-away.
  final GlobalKey<TvGuideViewState> _guideKey = GlobalKey<TvGuideViewState>();

  @override
  void initState() {
    super.initState();
    _index = _landingIndex(widget.settings.defaultView);
    _ensureBuilt(_index);
  }

  /// fix500: map the saved Default view onto a landing tab. [ViewType] has no
  /// livestream/movie/serie member, so `all` lands on Live TV; history and
  /// categories map to their own tabs.
  /// fix525: indices shifted by the inserted Categories tab (now index 3).
  /// fix539: the standalone Favorites tab is removed; a saved "favorites"
  /// default now lands on Live TV (which itself defaults to Favorites). History
  /// shifts up to index 4.
  int _landingIndex(ViewType v) {
    switch (v) {
      case ViewType.categories:
        return 3;
      case ViewType.history:
        return 4;
      case ViewType.favorites:
      case ViewType.all:
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
      _built[i] = TvSearchView(
        key: ValueKey<String>('tv-search-$_reloadGen'),
        settings: widget.settings,
      );
    } else if (i == 0) {
      _built[i] = TvGuideView(key: _guideKey, settings: widget.settings);
    } else if (i == 1 || i == 2) {
      // fix507: Movies (1) / Series (2) get the native rail+grid browse instead
      // of the reused phone Home body. One parameterized widget serves both.
      _built[i] = TvBrowseView(
        key: ValueKey<String>('tv-browse-${t.label}-$_reloadGen'),
        settings: widget.settings,
        mediaType: t.mediaTypes.first,
      );
    } else if (t.viewType == ViewType.categories) {
      // fix529: TV-native category management (D-pad checkable poster grid),
      // not the phone Home (which trapped focus on its search box).
      _built[i] = TvCategoriesView(
        key: ValueKey<String>('tv-categories-$_reloadGen'),
        settings: widget.settings,
      );
    } else {
      _built[i] = Home(
        key: ValueKey<String>('tv-tab-${t.label}-$_reloadGen-$_historyGen'),
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

  Future<void> _select(int i) async {
    if (i == _index) return;
    // fix510: leaving Live TV → release the hero's muted preview (and its
    // provider connection) BEFORE switching, so a stream opened from the next
    // tab can't race the still-releasing preview on a 1-connection provider.
    // IndexedStack keeps the guide mounted, so there is no implicit hook.
    if (_index == 0 && i != 0) {
      await _guideKey.currentState?.stopHeroPreview();
    }
    if (!mounted) return;
    setState(() {
      _index = i;
      // fix534: force the target tab to re-query the (possibly changed)
      // enabled-source set. The guide reloads via its GlobalKey method; the
      // other keyed tabs rebuild under a fresh _reloadGen key. Home-based tabs
      // (Favorites/History) and the guide's own cached widget are untouched
      // except where they re-query themselves.
      if (i == 0) {
        _guideKey.currentState?.reloadGuide();
      } else {
        _reloadGen++;
        _built[i] = null;
      }
      _ensureBuilt(i);
    });
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => SettingsView(showNavBar: false, tvRailPane: true)),
    );
    // fix534: sources (and other settings) may have changed in Settings. The
    // IndexedStack keeps the current tab alive, so force it to re-query on
    // return — same mechanism as _select's tab-change reload.
    if (!mounted) return;
    setState(() {
      if (_index == 0) {
        _guideKey.currentState?.reloadGuide();
      } else {
        _reloadGen++;
        _built[_index] = null;
        _ensureBuilt(_index);
      }
    });
  }

  /// fix524: long-press the History tab to clear ALL watch history (after a
  /// confirm). Other tabs ignore the long-press. On confirm, wipes history via
  /// [Sql.clearHistory] and rebuilds the History body with a fresh key so it
  /// re-queries (now empty) instead of reusing the cached, stale State.
  Future<void> _onTabLongPress(int i) async {
    // fix607: held-OK on the LIVE TV tab (index 0) is a hidden diagnostic
    // shortcut — when diagnostic mode (debugLogging) is on, it auto-submits a
    // diagnostic report (subject = timestamp, blank body) using the SAME
    // scrubbed payload as Settings › Report an issue. Gated on !logUserPass too,
    // so a log that captured raw credentials is never sent.
    if (i == 0) {
      final s = SettingsService.cached;
      if (s == null || !s.debugLogging || s.logUserPass) return;
      final subject = DateTime.now().toIso8601String();
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        const SnackBar(content: Text('Sending diagnostic report…')),
      );
      final r =
          await IssueReporter.submit(subject: subject, details: '');
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text(r.success
            ? 'Diagnostic report sent.'
            : 'Report failed: ${r.errorMsg ?? 'error'}'),
      ));
      return;
    }
    if (_tabs[i].viewType != ViewType.history) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text(
            'Remove all channels from your watch history? '
            'This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await Sql.clearHistory();
    if (!mounted) return;
    setState(() {
      _historyGen++;
      final TvTab t = _tabs[i];
      _built[i] = Home(
        key: ValueKey<String>('tv-tab-${t.label}-$_reloadGen-$_historyGen'),
        hasTouchScreen: false,
        home: HomeManager(
          filters: Filters(
            viewType: t.viewType,
            mediaTypes: List<MediaType>.of(t.mediaTypes),
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    // fix540: full-screen neon background, cropped to fill (BoxFit.cover), with
    // a dark scrim so foreground text/tiles stay readable. The Scaffold and its
    // content are transparent so the image shows through; only the guide's
    // small now-line element paints its own color (intended).
    // fix587 (#23): confirm-to-exit guard around the whole TV shell (no-op
    // unless the setting is on and Back would exit the app).
    return ConfirmExitScope(
      enabled: widget.settings.confirmToExit,
      child: Stack(
      fit: StackFit.expand,
      children: [
        const Image(
          image: AssetImage('assets/tv_background.webp'),
          fit: BoxFit.cover,
        ),
        // Dark scrim: fix553 softened further to ~75% black (0xCC->0xBF) per
        // on-device review — lets more of the neon art through while keeping
        // foreground text/tiles legible. (Was 90% fix540 -> 80% fix551.)
        const ColoredBox(color: Color(0xBF000000)),
        Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(
              children: [
                TvTopTabBar(
                  tabs: _tabs,
                  selectedIndex: _index,
                  onSelected: _select,
                  onSettings: _openSettings,
                  onLongPress: _onTabLongPress,
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
        ),
      ],
      ),
    );
  }
}
