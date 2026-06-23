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

/// fix502 / fix509: TV "what's on" search.
///
/// Combines channel-name matches ([Sql.search]) with EPG programme-title
/// matches ([Sql.searchPrograms], forward-only window clamped to the EPG
/// forecast) resolved to the live channels airing them, then groups the result
/// into FIVE logical shelves (fix509): **On now · Coming up · Channels · Movies
/// · Series**. Each shelf is a horizontal card row (live groups use the
/// landscape now/next card; Movies/Series use portrait posters). Reuses
/// [ChannelTile] (play, now/next strip, source edge bar, series drill-in) so
/// there is no bespoke player wiring. TV-only — the phone Search is untouched
/// (this view is only mounted by the TV shell's Search tab).
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
  // fix509: five logical groups.
  List<Channel> _onNow = [];
  List<Channel> _comingUp = [];
  List<Channel> _channels = [];
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
          _onNow = [];
          _comingUp = [];
          _channels = [];
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

    // Merge into 5 groups. EPG title matches answer "what's on" — split the
    // live channels they resolve to into On now (a matched programme airing
    // now) vs Coming up (a matched programme starting later in the window),
    // first-match-wins per channel, in programme start order. Then
    // channel-NAME matches fill Channels (livestreams not already shown) /
    // Movies / Series.
    final onNow = <Channel>[];
    final comingUp = <Channel>[];
    final channels = <Channel>[];
    final movies = <Channel>[];
    final series = <Channel>[];
    final seenLive = <int>{};
    for (final p in programmes) {
      final ch = epgChannels['${p.sourceId}|${p.epgChannelId}'];
      if (ch == null || ch.id == null || !seenLive.add(ch.id!)) continue;
      (p.isOnNow(now) ? onNow : comingUp).add(ch);
    }
    for (final ch in nameResults) {
      switch (ch.mediaType) {
        case MediaType.livestream:
          if (ch.id == null || seenLive.add(ch.id!)) channels.add(ch);
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
      _onNow = onNow;
      _comingUp = comingUp;
      _channels = channels;
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
    final empty = _onNow.isEmpty &&
        _comingUp.isEmpty &&
        _channels.isEmpty &&
        _movies.isEmpty &&
        _series.isEmpty;
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
              : ListView(children: _buildShelves()),
        ),
      ],
    );
  }

  /// fix509: build the non-empty shelves in priority order; the first non-empty
  /// shelf's first card receives initial focus.
  List<Widget> _buildShelves() {
    final groups = <(String, List<Channel>, bool)>[
      ('On now', _onNow, false),
      ('Coming up', _comingUp, false),
      ('Channels', _channels, false),
      ('Movies', _movies, true),
      ('Series', _series, true),
    ];
    final shelves = <Widget>[];
    var autofocusNext = true;
    for (final (title, items, poster) in groups) {
      if (items.isEmpty) continue;
      shelves.add(
        _shelf(title, items, poster: poster, autofocusFirst: autofocusNext),
      );
      autofocusNext = false;
    }
    return shelves;
  }

  /// A horizontal card shelf. [poster] true = portrait poster cards
  /// (Movies/Series); false = the landscape now/next card (live groups — its
  /// NowNextStrip shows what's on).
  Widget _shelf(
    String title,
    List<Channel> items, {
    required bool poster,
    bool autofocusFirst = false,
  }) {
    final double rowHeight = poster ? 236 : 104;
    final double cardWidth = poster ? 150 : 320;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Text(
            '$title (${items.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        SizedBox(
          height: rowHeight,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final ch = items[i];
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: cardWidth,
                  child: ChannelTile(
                    key: ValueKey('search-$title-${ch.id ?? ch.name}-$i'),
                    channel: ch,
                    parentContext: context,
                    setNode: _setNode,
                    tintColor: _sourceColors[ch.sourceId],
                    showSourceEdgeBar: true,
                    poster: poster,
                    autofocus: autofocusFirst && i == 0,
                    playlist: items,
                    playlistIndex: i,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
