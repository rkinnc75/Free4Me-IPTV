import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/channel_tile.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/view_type.dart';

/// fix529: TV-native category management. A D-pad-navigable GRID of poster
/// cards (the same [ChannelTile] poster style as Search / Movies / Series)
/// where SELECT toggles the category's enabled flag (checkbox overlay), plus
/// Select All / Unselect All. Replaces the reused phone `Home` for the TV
/// Categories tab — that trapped D-pad focus on its search box and its checkbox
/// could only be reached by arrow-right off a focused row, so the remote could
/// not enable/disable categories. Scoped to live-TV categories. Toggles write
/// groups.enabled / channels.cat_enabled, shared with phone + the Live guide.
class TvCategoriesView extends StatefulWidget {
  final Settings settings;
  const TvCategoriesView({super.key, required this.settings});

  @override
  State<TvCategoriesView> createState() => _TvCategoriesViewState();
}

class _TvCategoriesViewState extends State<TvCategoriesView> {
  // fix644: raised 1000 -> 10000 (matches the guide rail's _railCap) —
  // providers with huge category counts were silently truncated.
  static const int _cap = 10000;
  // fix547: Categories now spans all three media types. A centered row of three
  // type buttons (Live TV / Movies / Series) selects which type's categories the
  // grid below shows; defaults to Live TV.
  static const List<MediaType> _types = [
    MediaType.livestream,
    MediaType.movie,
    MediaType.serie,
  ];
  MediaType _selectedType = MediaType.livestream;
  List<Channel> _groups = [];
  Map<int, int?> _sourceColors = {};
  List<int> _sourceIds = [];
  bool _ready = false;
  bool _loadFailed = false; // review finding 155
  int _inv = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final inv = ++_inv;
    final s = SettingsService.cached ?? widget.settings;
    final sources = await Sql.getSources();
    final enabled = await Sql.getEnabledSourcesMinimal();
    final ids = enabled.map((e) => e.id).whereType<int>().toList();
    // fix527-style paged category fetch so providers with >36 categories aren't
    // truncated.
    var groups = <Channel>[];
    var loadFailed = false; // review finding 155
    try {
      for (var page = 1; groups.length < _cap; page++) {
        final batch = await Sql.search(Filters(
          viewType: ViewType.categories,
          mediaTypes: [_selectedType],
          sourceIds: ids,
          page: page,
          searchMethod: s.searchMethod,
          safeMode: s.safeMode,
        ));
        if (batch.isEmpty) break;
        groups.addAll(batch);
        if (batch.length < pageSize) break;
      }
    } catch (e, st) {
      groups = [];
      loadFailed = true;
      // Review finding 155: a categories-query failure was swallowed and shown
      // as a genuinely-empty list. AppLog scrubs source credentials.
      AppLog.warn('TvCategoriesView: categories query failed for '
          '${_typeLabel(_selectedType)} — $e\n$st');
    }
    if (!mounted || inv != _inv) return;
    setState(() {
      _sourceColors = {
        for (final src in sources)
          if (src.id != null) src.id!: src.color,
      };
      _sourceIds = ids;
      _groups = groups.take(_cap).toList();
      _ready = true;
      _loadFailed = loadFailed;
    });
  }

  Future<void> _setAll(bool enabled) async {
    await Sql.setAllGroupsEnabled(_sourceIds, [_selectedType], enabled);
    await _load();
  }

  // fix547: switch which media type's categories are shown and reload.
  void _selectType(MediaType t) {
    if (t == _selectedType) return;
    setState(() {
      _selectedType = t;
      _ready = false;
      _loadFailed = false; // review finding 155
      _groups = [];
    });
    _load();
  }

  static String _typeLabel(MediaType t) {
    switch (t) {
      case MediaType.livestream:
        return 'Live TV';
      case MediaType.movie:
        return 'Movies';
      case MediaType.serie:
        return 'Series';
      case MediaType.group:
        return '';
    }
  }

  static IconData _typeIcon(MediaType t) {
    switch (t) {
      case MediaType.livestream:
        return Icons.live_tv;
      case MediaType.movie:
        return Icons.movie;
      case MediaType.serie:
        return Icons.video_library;
      case MediaType.group:
        return Icons.folder;
    }
  }

  @override
  Widget build(BuildContext context) {
    // fix553: Categories now uses a LEFT type-rail (Live TV / Movies / Series)
    // to match the Movies/Series browse layout, instead of the fix547 centered
    // pill row. Selecting a type switches the whole screen's category grid.
    return Row(
      children: [
        SizedBox(width: 210, child: _typeRail()),
        const VerticalDivider(width: 1),
        Expanded(child: _body()),
      ],
    );
  }

  // fix553: left vertical rail of the three media types, mirroring
  // TvBrowseView._rail / _railItem so the three TV screens share one layout.
  Widget _typeRail() {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (var i = 0; i < _types.length; i++)
          _typeRailItem(_types[i], autofocus: i == 0),
      ],
    );
  }

  Widget _typeRailItem(MediaType type, {bool autofocus = false}) {
    return _FocusTile(
      selected: type == _selectedType,
      autofocus: autofocus,
      onTap: () => _selectType(type),
      child: Row(
        children: [
          Icon(_typeIcon(type), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_typeLabel(type),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (!_ready) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadFailed) {
      // Review finding 155: distinct from genuinely-empty. autofocus so a
      // D-pad-only remote can reach the Retry button.
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Could not load categories',
                style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            TextButton.icon(
              autofocus: true,
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_groups.isEmpty) {
      return Center(
        child: Text('No ${_typeLabel(_selectedType)} categories',
            style: const TextStyle(color: Colors.white70)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Row(
            children: [
              Text('${_groups.length} categories · select toggles on/off',
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 14)),
              const Spacer(),
              TextButton.icon(
                onPressed: () => _setAll(true),
                icon: const Icon(Icons.done_all, size: 18),
                label: const Text('Select all'),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => _setAll(false),
                icon: const Icon(Icons.remove_done, size: 18),
                label: const Text('Unselect all'),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              // fix558: a few px wider (120->130), tighter spacing (10->6) so
              // less of the screen is padding and cards read larger. AR
              // 0.838 = 130/155.17 holds the SAME rendered height as before
              // (the fix553 baseline). Shared across Categories/Movies/Series/
              // Search so all four TV grids keep matching.
              maxCrossAxisExtent: 130,
              childAspectRatio: 0.838,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
            ),
            itemCount: _groups.length,
            itemBuilder: (context, i) {
              final g = _groups[i];
              return ChannelTile(
                key: ValueKey('tv-cat-${g.id ?? g.name}-$i'),
                channel: g,
                parentContext: context,
                setNode: (_) {}, // unused in categoryToggleMode
                tintColor: _sourceColors[g.sourceId],
                showSourceEdgeBar: true,
                poster: true,
                categoryToggleMode: true,
                // fix553: the left type-rail owns initial focus now, so the grid
                // no longer autofocuses its first tile (avoids a focus conflict).
                autofocus: false,
                onToggleEnabled: g.id != null
                    ? (enabled) async {
                        await Sql.setGroupEnabled(g.id!, enabled);
                        if (mounted) {
                          setState(() => g.groupEnabled = enabled);
                        }
                      }
                    : null,
              );
            },
          ),
        ),
      ],
    );
  }
}

// fix553: local focusable rail tile mirroring TvBrowseView._FocusTile (yellow
// focus border, primary-tinted when selected) so the Categories type-rail looks
// and behaves like the Movies/Series rail. Adds [autofocus] so the rail can own
// initial screen focus.
class _FocusTile extends StatefulWidget {
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;
  final Widget child;
  const _FocusTile({
    required this.selected,
    required this.onTap,
    required this.child,
    this.autofocus = false,
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
          autofocus: widget.autofocus,
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
