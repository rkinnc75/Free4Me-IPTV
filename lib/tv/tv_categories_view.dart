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
  static const int _cap = 500;
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
          mediaTypes: const [MediaType.livestream],
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
    await Sql.setAllGroupsEnabled(
        _sourceIds, const [MediaType.livestream], enabled);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_groups.isEmpty) {
      return const Center(
        child: Text('No live-TV categories',
            style: TextStyle(color: Colors.white70)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
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
              maxCrossAxisExtent: 220,
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
