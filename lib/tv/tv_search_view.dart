import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/setting_bounds.dart';
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
import 'package:open_tv/widgets/dpad_text_field.dart';

/// fix502: TV "what's on" search.
///
/// Combines channel-name matches ([Sql.search]) with EPG programme-title
/// matches ([Sql.searchPrograms], forward-only window clamped to the EPG
/// forecast) resolved to the live channels airing them, then groups the result
/// by media type. Reuses [ChannelTile] (play, now/next strip, source edge bar)
/// so there is no bespoke player wiring. TV-only — the phone Search is
/// untouched (this view is only mounted by the TV shell's Search tab).
class TvSearchView extends StatefulWidget {
  final Settings settings;
  const TvSearchView({super.key, required this.settings});

  @override
  State<TvSearchView> createState() => _TvSearchViewState();
}

class _TvSearchViewState extends State<TvSearchView> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  int _inv = 0;
  Map<int, int?> _sourceColors = {};
  List<int> _sourceIds = [];
  bool _ready = false;
  bool _loading = false;
  List<Channel> _live = [];
  List<Channel> _movies = [];
  List<Channel> _series = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final sources = await Sql.getSources();
    final enabled = await Sql.getEnabledSourcesMinimal();
    if (!mounted) return;
    setState(() {
      _sourceColors = {
        for (final s in sources)
          if (s.id != null) s.id!: s.color,
      };
      _sourceIds = enabled.map((e) => e.id).whereType<int>().toList();
      _ready = true;
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _run(q.trim()));
  }

  Future<void> _run(String query) async {
    if (query.length < 2) {
      if (mounted) {
        setState(() {
          _live = [];
          _movies = [];
          _series = [];
          _loading = false;
        });
      }
      return;
    }
    final inv = ++_inv;
    setState(() => _loading = true);
    final s = SettingsService.cached ?? widget.settings;

    // Channel-name matches across all media types.
    final nameResults = await Sql.search(Filters(
      query: query,
      viewType: ViewType.all,
      mediaTypes: const [MediaType.livestream, MediaType.movie, MediaType.serie],
      sourceIds: _sourceIds,
      searchMethod: s.searchMethod,
      safeMode: s.safeMode,
    ));

    // EPG "what's on" matches → resolve to the live channels airing them,
    // within the forward-only window (clamped to the EPG forecast).
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final hours = widget.settings.epgSearchHours
        .clamp(
          SettingBounds.epgSearchHoursMin,
          SettingBounds.epgSearchHoursMax(widget.settings.epgForecastDays),
        )
        .toInt();
    final programmes = await Sql.searchPrograms(
      query: query,
      sourceIds: _sourceIds,
      nowEpoch: now,
      windowEndEpoch: now + hours * 3600,
    );
    final epgIds = programmes.map((p) => p.epgChannelId).toSet().toList();
    final epgChannels = await Sql.getLiveChannelsByEpg(_sourceIds, epgIds);
    if (!mounted || inv != _inv) return;

    // Merge: EPG-derived channels first (they answer "what's on", in programme
    // start order), then channel-name matches; dedup live by id; group by type.
    final live = <Channel>[];
    final movies = <Channel>[];
    final series = <Channel>[];
    final seenLive = <int>{};
    for (final p in programmes) {
      final ch = epgChannels['${p.sourceId}|${p.epgChannelId}'];
      if (ch != null && ch.id != null && seenLive.add(ch.id!)) live.add(ch);
    }
    for (final ch in nameResults) {
      switch (ch.mediaType) {
        case MediaType.livestream:
          if (ch.id == null || seenLive.add(ch.id!)) live.add(ch);
          break;
        case MediaType.movie:
          movies.add(ch);
          break;
        case MediaType.serie:
          series.add(ch);
          break;
        default:
          break;
      }
    }
    setState(() {
      _live = live;
      _movies = movies;
      _series = series;
      _loading = false;
    });
  }

  void _setNode(Node node) {
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
          ),
        ),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final empty = _live.isEmpty && _movies.isEmpty && _series.isEmpty;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: DpadTextField(
            controller: _controller,
            enabled: _ready,
            autofocus: true,
            onChanged: _onChanged,
            decoration: InputDecoration(
              hintText: "Search channels and what's on…",
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              filled: true,
            ),
          ),
        ),
        Expanded(
          child: empty
              ? Center(
                  child: Text(
                    _controller.text.trim().length < 2
                        ? "Type to search channels and what's on"
                        : (_loading ? 'Searching…' : 'No results'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                )
              : ListView(
                  children: [
                    _section('Channels', _live, true),
                    _section('Movies', _movies, false),
                    _section('Series', _series, false),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _section(String title, List<Channel> items, bool autofocusFirst) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        LayoutBuilder(builder: (context, c) {
          final cols = (c.maxWidth / 350).floor().clamp(1, 3);
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisExtent: 100,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final ch = items[i];
              return ChannelTile(
                key: ValueKey('search-${ch.id ?? ch.name}-$i'),
                channel: ch,
                parentContext: context,
                setNode: _setNode,
                tintColor: _sourceColors[ch.sourceId],
                showSourceEdgeBar: true,
                autofocus: autofocusFirst && i == 0,
                playlist: items,
                playlistIndex: i,
              );
            },
          );
        }),
      ],
    );
  }
}
