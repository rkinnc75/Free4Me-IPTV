import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/channel_tile.dart';
import 'package:open_tv/home.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/node.dart';
import 'package:open_tv/models/node_type.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/view_type.dart';

/// fix507: the TV Movies / Series browse screen.
///
/// One widget parameterized by [mediaType] (movie or serie) serves both the
/// Movies (tab 1) and Series (tab 2) tabs of [TvShell]. Layout mirrors the
/// proven [TvGuideView] skeleton: a LEFT vertical rail of the provider's REAL
/// categories (`ViewType.categories` -> `searchGroup`) scoping a RIGHT 2D grid
/// of [ChannelTile] content cards for the selected category.
///
/// This replaces the old phone-`Home` body those tabs reused (the "phone/TV
/// mix"). The rail shows the provider's actual categories — NOT curated genres
/// (a locked product decision). ChannelTile is reused verbatim so play (movies)
/// and series drill-in (getEpisodes + setNode) keep their proven behavior.
///
/// Perf: every catalogue read is a bounded OFFSET/LIMIT page; the rail is capped
/// at [_railCap] and the content list at [_itemCap], with an `_inv` invalidation
/// token so rapid rail navigation cancels stale loads. No unbounded query is
/// reachable, so cold open stays well under the 1000ms budget even on the
/// low-RAM Onn 4K box against the ~1.15M-row catalogue.
///
/// TV-only: reachable solely via TvHome -> TvShell (the `!hasTouchScreen` path);
/// phone mode never mounts it.
class TvBrowseView extends StatefulWidget {
  final Settings settings;
  final MediaType mediaType;
  const TvBrowseView({
    super.key,
    required this.settings,
    required this.mediaType,
  });

  @override
  State<TvBrowseView> createState() => _TvBrowseViewState();
}

class _TvBrowseViewState extends State<TvBrowseView> {
  // Bounded-query guards (mirror TvGuideView). One page (pageSize) is the
  // common case; the caps protect against pathological providers.
  static const int _itemCap = 200;
  static const int _railCap = 1000;

  Map<int, int?> _sourceColors = {};
  List<int> _sourceIds = [];
  List<Channel> _groups = [];
  int? _selectedGroupId; // null = All
  String _selectedLabel = 'All';
  List<Channel> _items = [];
  bool _ready = false;
  bool _loading = false;
  int _inv = 0;
  final ScrollController _gridController = ScrollController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _gridController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final s = SettingsService.cached ?? widget.settings;
    final sources = await Sql.getSources();
    final enabled = await Sql.getEnabledSourcesMinimal();
    final sourceIds = enabled.map((e) => e.id).whereType<int>().toList();
    // Category rail: paged (so providers with >pageSize categories aren't
    // truncated) and capped. query + groupId stay null so Sql.search
    // short-circuits to searchGroup, returning this media type's real groups.
    var groups = <Channel>[];
    try {
      for (var page = 1; groups.length < _railCap; page++) {
        final batch = await Sql.search(Filters(
          viewType: ViewType.categories,
          mediaTypes: [widget.mediaType],
          sourceIds: sourceIds,
          page: page,
          searchMethod: s.searchMethod,
          safeMode: s.safeMode,
        ));
        if (batch.isEmpty) break;
        groups.addAll(batch);
        if (batch.length < pageSize) break;
      }
    } catch (_) {
      groups = [];
    }
    if (!mounted) return;
    setState(() {
      _sourceColors = {
        for (final src in sources)
          if (src.id != null) src.id!: src.color,
      };
      _sourceIds = sourceIds;
      _groups = groups.take(_railCap).toList();
      _ready = true;
    });
    await _loadItems(null, 'All');
  }

  Future<void> _loadItems(int? groupId, String label) async {
    final inv = ++_inv;
    setState(() {
      _loading = true;
      _selectedGroupId = groupId;
      _selectedLabel = label;
    });
    final s = SettingsService.cached ?? widget.settings;
    // Bounded item paging: viewType=all + groupId scopes into the category.
    final items = <Channel>[];
    for (var page = 1; items.length < _itemCap; page++) {
      final batch = await Sql.search(Filters(
        viewType: ViewType.all,
        mediaTypes: [widget.mediaType],
        groupId: groupId,
        sourceIds: _sourceIds,
        page: page,
        searchMethod: s.searchMethod,
        safeMode: s.safeMode,
      ));
      if (batch.isEmpty) break;
      items.addAll(batch);
      if (batch.length < pageSize) break;
    }
    if (!mounted || inv != _inv) return;
    setState(() {
      _items = items.take(_itemCap).toList();
      _loading = false;
    });
    // Re-show the top so the freshly-autofocused item-0 card is on screen.
    if (_gridController.hasClients) _gridController.jumpTo(0);
  }

  /// Series drill-in. ChannelTile builds the series [Node] and calls this for
  /// serie tiles (it also fetches episodes internally); we only route the
  /// seriesId into a navigation [Home]. Copied from TvSearchView._setNode.
  void _setNode(Node node) {
    // fix524 (safe-mode TV leak): the pushed Home runs its own Sql.search /
    // searchGroup; without safeMode the drilled-in subtree defaulted to OFF.
    final s = SettingsService.cached ?? widget.settings;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Home(
        hasTouchScreen: false,
        home: HomeManager(
          node: node,
          filters: Filters(
            viewType: ViewType.all,
            mediaTypes: const [
              MediaType.livestream,
              MediaType.movie,
              MediaType.serie,
            ],
            sourceIds: _sourceIds,
            seriesId: node.type == NodeType.series ? node.id : null,
            safeMode: s.safeMode,
          ),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 210, child: _rail()),
        const VerticalDivider(width: 1),
        Expanded(child: _ready ? _content() : const SizedBox.shrink()),
      ],
    );
  }

  Widget _rail() {
    final allIcon =
        widget.mediaType == MediaType.serie ? Icons.video_library : Icons.movie;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _railItem(null, 'All', allIcon),
        for (final g in _groups)
          if (g.id != null) _railItem(g.id, g.name, Icons.folder_outlined),
      ],
    );
  }

  Widget _railItem(int? groupId, String label, IconData icon) {
    final selected = groupId == _selectedGroupId;
    return _FocusTile(
      selected: selected,
      onTap: () => _loadItems(groupId, label),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _content() {
    if (_items.isEmpty) {
      return Center(child: Text(_loading ? 'Loading…' : 'No titles'));
    }
    final noun = widget.mediaType == MediaType.serie ? 'series' : 'titles';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Text(
            '$_selectedLabel — ${_items.length}$_capSuffix $noun',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Expanded(
          child: GridView.builder(
            controller: _gridController,
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            // fix508: portrait poster wall (cover image + title) — the mockup
            // "movies boxes". maxCrossAxisExtent adapts the column count to the
            // content width; childAspectRatio < 1 keeps the cards portrait.
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 180,
              childAspectRatio: 0.58,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
            ),
            itemCount: _items.length,
            itemBuilder: (context, i) {
              final ch = _items[i];
              return ChannelTile(
                key: ValueKey(
                    'browse-${widget.mediaType.index}-${ch.id ?? ch.name}-$i'),
                channel: ch,
                parentContext: context,
                setNode: _setNode,
                tintColor: _sourceColors[ch.sourceId],
                showSourceEdgeBar: true,
                poster: true, // fix508: portrait poster layout
                autofocus: i == 0,
                playlist: _items,
                playlistIndex: i,
              );
            },
          ),
        ),
      ],
    );
  }

  // "200+" when the cap clipped the list, so the header doesn't imply an exact
  // count when there may be more.
  String get _capSuffix => _items.length >= _itemCap ? '+' : '';
}

/// Small D-pad-friendly tile with a yellow focus ring (matches the app's TV
/// focus standard), used by the category rail. Duplicated from TvGuideView
/// (it is private there and self-contained); duplicating avoids exporting from
/// or editing the Live-tab file.
class _FocusTile extends StatefulWidget {
  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  const _FocusTile({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  @override
  State<_FocusTile> createState() => _FocusTileState();
}

class _FocusTileState extends State<_FocusTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Material(
        color: widget.selected
            ? scheme.primary.withValues(alpha: 0.18)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: widget.onTap,
          onFocusChange: (v) => setState(() => _focused = v),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _focused ? Colors.yellow : Colors.transparent,
                width: 3,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
