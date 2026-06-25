import 'package:flutter/material.dart';
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
  static const int _cap = 1000;
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
    } catch (_) {
      groups = [];
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _typeRow(),
        Expanded(child: _body()),
      ],
    );
  }

  // fix547: centered row of the three media-type buttons. Equal-width, tightly
  // sized, horizontally centered (not stretched edge-to-edge).
  Widget _typeRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < _types.length; i++) ...[
            if (i > 0) const SizedBox(width: 14),
            _TypeButton(
              label: _typeLabel(_types[i]),
              icon: _typeIcon(_types[i]),
              selected: _types[i] == _selectedType,
              autofocus: i == 0,
              onTap: () => _selectType(_types[i]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _body() {
    if (!_ready) {
      return const Center(child: CircularProgressIndicator());
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              // fix538: halve the max extent (220->110) to roughly double the
              // column count (~8 across on a 4K TV), giving smaller tiles and
              // more categories visible per screen.
              maxCrossAxisExtent: 110,
              childAspectRatio: 0.82,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
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
                autofocus: i == 0,
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

// fix547: a focusable, DPad-navigable type button for the Categories type row.
// Mirrors TvBrowseView's _FocusTile (yellow focus border, primary-tinted when
// selected) so focus behaviour matches the rest of the TV UI.
class _TypeButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;
  const _TypeButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.autofocus,
    required this.onTap,
  });

  @override
  State<_TypeButton> createState() => _TypeButtonState();
}

class _TypeButtonState extends State<_TypeButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: widget.selected
          ? scheme.primary.withValues(alpha: 0.22)
          : Colors.white.withValues(alpha: 0.05),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        autofocus: widget.autofocus,
        onTap: widget.onTap,
        onFocusChange: (v) => setState(() => _focused = v),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 180,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _focused
                  ? Colors.yellow
                  : (widget.selected
                      ? scheme.primary
                      : Colors.white24),
              width: 3,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, size: 20),
              const SizedBox(width: 10),
              Text(
                widget.label,
                style: TextStyle(
                  fontWeight:
                      widget.selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
