import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
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
    // fix561: dispose the State-level last-row FocusNode cache (these are no
    // longer created fresh per build, so they must be cleaned up explicitly).
    for (final nodes in _lastRowNodeCache.values) {
      for (final n in nodes) {
        n.dispose();
      }
    }
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
    // fix554: instrument the full TV-search wall-clock. Only Sql.search was
    // logged before; the EPG "what's on" phase (searchPrograms +
    // getLiveChannelsByEpg) ran serially per query and was invisible. Times
    // each phase so the field log shows where the Go->results lag actually is.
    final swTotal = Stopwatch()..start();

    // Channel-name matches across all media types.
    final swName = Stopwatch()..start();
    final nameResults = await Sql.search(Filters(
      query: query,
      viewType: ViewType.all,
      mediaTypes: const [MediaType.livestream, MediaType.movie, MediaType.serie],
      sourceIds: _sourceIds,
      searchMethod: s.searchMethod,
      safeMode: s.safeMode,
      // fix557: TV search previously inherited the global 36-per-page cap
      // silently — "fox" showed 34 results while the Live category alone has
      // 100+. Search isn't a paged browse; raise the ceiling so a real query
      // returns effectively everything, while still bounding a pathological
      // 1-2 char query from returning the whole catalog.
      limit: 1000,
    ));
    swName.stop();

    // EPG "what's on" matches → resolve to the live channels airing them,
    // within the forward-only window (clamped to the EPG forecast).
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final hours = widget.settings.epgSearchHours
        .clamp(
          SettingBounds.epgSearchHoursMin,
          SettingBounds.epgSearchHoursMax(widget.settings.epgForecastDays),
        )
        .toInt();
    final swProg = Stopwatch()..start();
    final programmes = await Sql.searchPrograms(
      query: query,
      sourceIds: _sourceIds,
      nowEpoch: now,
      windowEndEpoch: now + hours * 3600,
    );
    swProg.stop();
    final epgIds = programmes.map((p) => p.epgChannelId).toSet().toList();
    final swEpgCh = Stopwatch()..start();
    final epgChannels =
        await Sql.getLiveChannelsByEpg(_sourceIds, epgIds, safeMode: s.safeMode);
    swEpgCh.stop();
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
    AppLog.info('TvSearch._run: query="$query" total=${swTotal.elapsedMilliseconds}ms '
        '(name=${swName.elapsedMilliseconds}ms/${nameResults.length} '
        'epgProg=${swProg.elapsedMilliseconds}ms/${programmes.length} '
        'epgCh=${swEpgCh.elapsedMilliseconds}ms/${epgChannels.length})');
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
            // fix555: pressing Go/Enter (or D-pad select) runs the search
            // immediately instead of waiting out the 250ms onChanged debounce.
            onSubmitted: (q) {
              _debounce?.cancel();
              _run(q.trim());
            },
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

  /// fix557: each section is its own WRAPPING grid (not a horizontal-scroll
  /// shelf) using the same tile size as Categories/Movies/Series
  /// (maxCrossAxisExtent 120, AR 0.773, spacing 10 — fix553), so the search
  /// screen matches the rest of the TV UI instead of looking like a separate,
  /// smaller phone-style layout. All 5 sections (including On now/Coming up,
  /// previously landscape now/next cards) use the same poster tile.
  ///
  /// fix558/559/560/561: Flutter's default directional focus traversal does
  /// not reliably cross between multiple stacked GridViews
  /// (flutter/flutter#70364) — arrow-up from a section's top row could skip
  /// straight past the section above it to the search field, or land on a
  /// far-away widget. fix561 redesigned the escape to be COLUMN-AWARE: each
  /// section exposes one stable FocusNode per column of its LAST row (a
  /// `List<FocusNode>`, built once per section and reused across rebuilds via
  /// a State-level cache keyed by section title — see [_lastRowNodesFor]).
  /// Every top-row tile's escape callback captures ITS OWN column index and
  /// requests focus on that same column in the previous section's last row,
  /// clamped to that section's column count if it's narrower. This keeps the
  /// landing position visually aligned with where the user came from instead
  /// of always snapping to column 0.
  List<Widget> _buildShelves() {
    final groups = <(String, List<Channel>)>[
      ('On now', _onNow),
      ('Coming up', _comingUp),
      ('Channels', _channels),
      ('Movies', _movies),
      ('Series', _series),
    ];
    final sections = <Widget>[];
    var autofocusNext = true;
    String? previousTitle;
    for (final (title, items) in groups) {
      if (items.isEmpty) continue;
      sections.add(
        _section(
          title,
          items,
          autofocusFirst: autofocusNext,
          previousSectionTitle: previousTitle,
        ),
      );
      autofocusNext = false;
      previousTitle = title;
    }
    return sections;
  }

  /// fix561: stable per-section `List<FocusNode>` for "the last row's tiles,
  /// one per column", cached in State (NOT recreated every _buildShelves()
  /// call, unlike the fix558/559 single-node approach which WAS recreated
  /// each build). Grown to match [columns] if the section's column count is
  /// read before the node at that index exists.
  final Map<String, List<FocusNode>> _lastRowNodeCache = {};
  List<FocusNode> _lastRowNodesFor(String title, int columns) {
    final list = _lastRowNodeCache.putIfAbsent(title, () => []);
    while (list.length < columns) {
      list.add(FocusNode(debugLabel: 'search-$title-lastrow-col-${list.length}'));
    }
    return list;
  }

  /// A titled, wrapping poster grid — same tile size/spacing as
  /// TvCategoriesView / TvBrowseView (fix553) for a consistent TV UI.
  Widget _section(
    String title,
    List<Channel> items, {
    bool autofocusFirst = false,
    String? previousSectionTitle,
  }) {
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          // fix557: shrink-wrapped + non-scrolling — the OUTER ListView (in
          // build()) owns the page scroll, this grid just lays out its own
          // rows inline at their natural height.
          //
          // fix559: LayoutBuilder gives the actual available width so we can
          // compute the SAME column count SliverGridDelegateWithMaxCrossAxis-
          // Extent will use internally (ceil(width / (maxExtent+spacing))).
          child: LayoutBuilder(
            builder: (context, constraints) {
              const maxExtent = 130.0;
              const spacing = 6.0;
              final columns =
                  (constraints.maxWidth / (maxExtent + spacing)).ceil().clamp(
                        1,
                        items.isEmpty ? 1 : items.length,
                      );
              final lastRowStart =
                  items.isEmpty ? 0 : ((items.length - 1) ~/ columns) * columns;
              // fix561: this section's own last-row node list (for the NEXT
              // section to target) and, if there IS a previous section, ITS
              // last-row node list (for THIS section's top row to escape to).
              final myLastRowNodes = _lastRowNodesFor(title, columns);
              final prevLastRowNodes = previousSectionTitle == null
                  ? null
                  : _lastRowNodeCache[previousSectionTitle];
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 10),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  // fix558: matches the Categories/Movies/Series tile update.
                  maxCrossAxisExtent: maxExtent,
                  childAspectRatio: 0.838,
                  mainAxisSpacing: spacing,
                  crossAxisSpacing: spacing,
                ),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final ch = items[i];
                  final col = i % columns;
                  final isTopRow = i < columns;
                  final isLastRow = i >= lastRowStart;
                  return ChannelTile(
                    key: ValueKey('search-$title-${ch.id ?? ch.name}-$i'),
                    channel: ch,
                    parentContext: context,
                    setNode: _setNode,
                    tintColor: _sourceColors[ch.sourceId],
                    showSourceEdgeBar: true,
                    poster: true,
                    autofocus: autofocusFirst && i == 0,
                    playlist: items,
                    playlistIndex: i,
                    // fix561: every LAST-ROW tile gets ITS OWN stable node
                    // (column-indexed), so the NEXT section can target the
                    // exact column the user was in. Every TOP-ROW tile's
                    // escape captures its own column and asks the PREVIOUS
                    // section's last row for that same column, clamped to
                    // however many columns that section actually has.
                    focusNode: isLastRow ? myLastRowNodes[col] : null,
                    onFocusUpEscape: (isTopRow && prevLastRowNodes != null)
                        ? () {
                            final target = prevLastRowNodes[
                                col.clamp(0, prevLastRowNodes.length - 1)];
                            target.requestFocus();
                          }
                        : null,
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
