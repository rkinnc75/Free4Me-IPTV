import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/widgets/dpad_text_field.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/source_color_picker.dart';
import 'package:open_tv/backend/stream_scanner.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/settings.dart' show SearchMethod;
import 'package:open_tv/models/view_type.dart';

/// fix138: persisted OR session validation — shared by sort + section grouping.
bool _isValidated(Channel ch) =>
    ch.streamValidated == true ||
    (ch.id != null && StreamScanner.results[ch.id] == true);

/// fix138: 6-tier sort — Favorite → History → All; Validated-first within each;
/// then alphabetical. Favorite wins over history.
int _channelTier(Channel ch) {
  final validated = _isValidated(ch);
  final watched = ch.lastWatched != null;
  if (ch.favorite) return validated ? 0 : 1;
  if (watched) return validated ? 2 : 3;
  return validated ? 4 : 5;
}

/// fix258: provider-aware multi-source sort for the channel picker.
/// For sources in 'provider' mode: favorites first, then provider_order
/// (NULLs last) — matching the SQL browse sort. For 'alpha' mode sources,
/// the 6-tier sort. Between sources, group by provider mode (provider first),
/// then apply within-source sort.
int _pickSortWithProvider(Channel a, Channel b, Set<int> providerSourceIds,
    Set<int> categorySourceIds) {
  // Within the same source, apply source-specific sort.
  if (a.sourceId == b.sourceId) {
    final isProvider = providerSourceIds.contains(a.sourceId);
    final isCategory = categorySourceIds.contains(a.sourceId);
    if (isCategory) {
      // fix272 Category mode: favorites first, then category (group), then
      // provider order within category, then name.
      final favA = a.favorite ? 0 : 1;
      final favB = b.favorite ? 0 : 1;
      if (favA != favB) return favA.compareTo(favB);
      final gA = (a.group ?? '').toLowerCase();
      final gB = (b.group ?? '').toLowerCase();
      if (gA != gB) return gA.compareTo(gB);
      final orderA = a.providerOrder ?? double.infinity.toInt();
      final orderB = b.providerOrder ?? double.infinity.toInt();
      if (orderA != orderB) return orderA.compareTo(orderB);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    } else if (isProvider) {
      // Provider mode: favorites first, then provider_order (nulls last), then name.
      final favA = a.favorite ? 0 : 1;
      final favB = b.favorite ? 0 : 1;
      if (favA != favB) return favA.compareTo(favB);
      final orderA = a.providerOrder ?? double.infinity.toInt();
      final orderB = b.providerOrder ?? double.infinity.toInt();
      if (orderA != orderB) return orderA.compareTo(orderB);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    } else {
      // Alpha mode: use the 6-tier sort.
      final ta = _channelTier(a);
      final tb = _channelTier(b);
      if (ta != tb) return ta.compareTo(tb);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }
  }

  // Between different sources: provider/category sources first, then alpha.
  final aOrdered = providerSourceIds.contains(a.sourceId) ||
      categorySourceIds.contains(a.sourceId);
  final bOrdered = providerSourceIds.contains(b.sourceId) ||
      categorySourceIds.contains(b.sourceId);
  if (aOrdered != bOrdered) {
    return aOrdered ? -1 : 1; // Ordered sources come first.
  }

  // Same mode: fall back to 6-tier (cross-source sorting is still tier-based).
  final ta = _channelTier(a);
  final tb = _channelTier(b);
  if (ta != tb) return ta.compareTo(tb);
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// Lightweight channel picker for multi-view cell assignment.
///
/// Returns the selected [Channel] via [Navigator.pop]. Does not modify
/// any existing screen — completely standalone.
class ChannelPickerScreen extends StatefulWidget {
  const ChannelPickerScreen({super.key, required this.sourceIds});

  /// Source IDs to search in — same set the caller is currently browsing.
  final List<int> sourceIds;

  @override
  State<ChannelPickerScreen> createState() => _ChannelPickerScreenState();
}

class _ChannelPickerScreenState extends State<ChannelPickerScreen> {
  static const _searchDebounce = Duration(milliseconds: 200);

  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<Channel> _channels = [];
  bool _loading = true;

  int _loadInvocation = 0;

  String _activeQuery = '';
  bool _initialBrowseLoaded = false;

  List<Channel>? _cachedEmptyQuery;

  // fix228: per-source pastel tag colors, so the multi-view channel picker
  // tints rows by source like the live picker (fix196). Map<sourceId, ARGB?>.
  Map<int, int?> _sourceColors = {};

  // fix258: track which sources are in provider sort mode so the picker can
  // sort each source correctly. Set<sourceId> containing source IDs with
  // sort_mode='provider'.
  Set<int> _providerSources = {};
  // fix272: sources in 'category' sort mode. (Divider hiding is applied by the
  // SQL query in Sql.search, so the picker needs no separate divider set.)
  Set<int> _categorySources = {};

  @override
  void initState() {
    super.initState();
    _loadSourceColors();
    _loadInitialBrowse();
  }

  // fix228: load source tag colors once (mirrors home.dart fix200).
  // fix258/fix272: also track per-source sort mode.
  Future<void> _loadSourceColors() async {
    final sources = await Sql.getSources();
    if (!mounted) return;
    setState(() {
      _sourceColors = {
        for (final src in sources)
          if (src.id != null) src.id!: src.color,
      };
      _providerSources = {
        for (final src in sources)
          if (src.id != null && src.sortMode == 'provider') src.id!,
      };
      _categorySources = {
        for (final src in sources)
          if (src.id != null && src.sortMode == 'category') src.id!,
      };
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Filters _liveTvPickerFilters({required String? query, required int page}) {
    final s = SettingsService.cached;
    return Filters(
      query: query,
      sourceIds: widget.sourceIds,
      mediaTypes: const [MediaType.livestream],
      viewType: ViewType.all,
      page: page,
      searchMethod: s?.searchMethod ?? SearchMethod.inMemory,
      safeMode: s?.safeMode ?? false,
    );
  }

  /// The SQL ORDER BY already surfaces favorites and validated
  /// channels first, so paginating the entire catalogue is unnecessary.
  /// A single page loads in <60ms instead of minutes. The cached result
  /// is reused whenever the search box is cleared.
  Future<void> _loadInitialBrowse() async {
    if (!mounted || _initialBrowseLoaded) return;
    final inv = ++_loadInvocation;
    setState(() => _loading = true);

    final pageResults = await Sql.search(
      _liveTvPickerFilters(query: null, page: 1),
      invocation: inv,
    );
    if (_loadInvocation != inv || !mounted) return;

    final sorted = List<Channel>.from(pageResults)
        ..sort((a, b) => _pickSortWithProvider(a, b, _providerSources, _categorySources));
    _cachedEmptyQuery = List.unmodifiable(sorted);
    _initialBrowseLoaded = true;

    setState(() {
      _channels = _cachedEmptyQuery!;
      _loading = false;
    });
  }

  Future<void> _loadSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty || !mounted) return;
    final inv = ++_loadInvocation;
    setState(() => _loading = true);

    final all = <Channel>[];
    var page = 1;
    while (true) {
      if (_loadInvocation != inv) return;
      final pageResults = await Sql.search(
        _liveTvPickerFilters(query: trimmed, page: page),
        invocation: inv,
      );
      all.addAll(pageResults);
      if (pageResults.length < pageSize) break;
      page++;
    }
    all.sort((a, b) => _pickSortWithProvider(a, b, _providerSources, _categorySources));

    if (_loadInvocation != inv || !mounted) return;
    setState(() {
      _channels = all;
      _loading = false;
    });
  }

  void _onQueryChanged(String value) {
    final query = value.trim();
    _debounce?.cancel();

    if (query.isEmpty) {
      // Already showing the browse list and nothing changed — no-op.
      if (_activeQuery.isEmpty && _initialBrowseLoaded) return;
      _activeQuery = '';
      final cached = _cachedEmptyQuery;
      if (cached != null) {
        setState(() {
          _channels = cached;
          _loading = false;
        });
      }
      return;
    }

    if (query == _activeQuery) return;

    _debounce = Timer(_searchDebounce, () {
      if (!mounted) return;
      _activeQuery = query;
      _loadSearch(query);
    });
  }

  /// Returns a section-header widget when index [i] is the first item in a
  /// new tier (favourites → validated → all), otherwise null.
  Widget? _sectionHeader(int i) {
    String label(Channel ch) {
      // fix138: THREE primary groups only. Validation is badge-only;
      // validated rows sort to the top of their group via _channelTier.
      if (ch.favorite) return 'Favourites';
      if (ch.lastWatched != null) return 'History';
      return 'All channels';
    }

    final cur = label(_channels[i]);
    if (i == 0) {
      return _headerRow(cur);
    }
    final prev = label(_channels[i - 1]);
    if (cur != prev) return _headerRow(cur);
    return null;
  }

  Widget _headerRow(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: title == 'Favourites'
                ? Colors.amberAccent
                : title == 'History'
                    ? Colors.lightBlueAccent // fix138: History header
                    : Colors.white38,
            letterSpacing: 0.8,
          ),
        ),
      );

  Widget _buildTile(BuildContext context, Channel ch, bool scanOk,
      {bool autofocus = false}) {
    Widget logo = ch.image != null
        ? SizedBox(
            width: 40,
            height: 40,
            child: CachedNetworkImage(
              imageUrl: ch.image!,
              fit: BoxFit.contain,
              errorWidget: (_, _, _) => const Icon(Icons.tv),
            ),
          )
        : const Icon(Icons.tv);

    if (scanOk) {
      logo = Stack(
        clipBehavior: Clip.none,
        children: [
          logo,
          const Positioned(
            right: -4,
            bottom: -4,
            child: Icon(
              Icons.check_circle,
              color: Colors.greenAccent,
              size: 14,
            ),
          ),
        ],
      );
    }

    // fix228: tint the row by source tag color (~35%), matching the live
    // picker's ChannelTile (fix196). Null color = surface unchanged.
    return Container(
      color: SourcePalette.tintOver(
        _sourceColors[ch.sourceId],
        Theme.of(context).colorScheme.surfaceContainer,
      ),
      child: ListTile(
        autofocus: autofocus, // fix252: first tile gets initial D-pad focus
        leading: logo,
        title: Text(
          ch.name,
          style: scanOk ? const TextStyle(color: Colors.greenAccent) : null,
        ),
        trailing: ch.favorite
            ? const Icon(Icons.star, color: Colors.amberAccent, size: 16)
            : null,
        subtitle: ch.group != null
            ? Text(
                ch.group!,
                style: Theme.of(context).textTheme.bodySmall,
              )
            : null,
        onTap: () => Navigator.of(context).pop(ch),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select channel'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: DpadTextField(
              controller: _searchCtrl,
              // fix252: do NOT autofocus the search field. On TV the focus
              // should land on the first channel tile so the user can scroll
              // immediately; pressing UP from the top row moves to the search
              // bar (DpadTextField yields up/down to traversal). autofocus
              // here previously trapped initial focus in the text field.
              autofocus: false,
              decoration: InputDecoration(
                hintText: 'Search channels…',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                isDense: true,
              ),
              onChanged: _onQueryChanged,
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _channels.isEmpty
              ? const Center(child: Text('No channels found'))
              : ListView.builder(
                  itemCount: _channels.length,
                  itemBuilder: (context, i) {
                    final ch = _channels[i];
                    final scanOk = _isValidated(ch); // fix142: persisted OR session

                    // Section header dividers between tiers.
                    final Widget? header = _sectionHeader(i);
                    if (header != null) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [header, _buildTile(context, ch, scanOk, autofocus: i == 0)],
                      );
                    }
                    return _buildTile(context, ch, scanOk, autofocus: i == 0);
                  },
                ),
    );
  }
}
