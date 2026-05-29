import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/stream_scanner.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/settings.dart' show SearchMethod;
import 'package:open_tv/models/view_type.dart';

/// Sort key for the picker: favorites plus validated streams first, then
/// favorites, validated streams, and alphabetical fallback.
int _pickSort(Channel a, Channel b) {
  int tier(Channel ch) {
    final validated = ch.streamValidated == true ||
        (ch.id != null && StreamScanner.results[ch.id] == true);
    if (ch.favorite && validated) return 0;
    if (ch.favorite) return 1;
    if (validated) return 2;
    return 3;
  }

  final td = tier(a) - tier(b);
  if (td != 0) return td;
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

  @override
  void initState() {
    super.initState();
    _loadInitialBrowse();
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
      searchMethod: s?.searchMethod ?? SearchMethod.ftsAnd,
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

    final sorted = List<Channel>.from(pageResults)..sort(_pickSort);
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
    all.sort(_pickSort);

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
      if (ch.favorite) return 'Favourites';
      if (ch.id != null && StreamScanner.results[ch.id] == true) {
        return 'Validated';
      }
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
                : title == 'Validated'
                    ? Colors.greenAccent
                    : Colors.white38,
            letterSpacing: 0.8,
          ),
        ),
      );

  Widget _buildTile(BuildContext context, Channel ch, bool scanOk) {
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

    return ListTile(
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
            child: TextField(
              controller: _searchCtrl,
              autofocus: true,
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
                    final scanOk = ch.id != null &&
                        StreamScanner.results[ch.id] == true;

                    // Section header dividers between tiers.
                    final Widget? header = _sectionHeader(i);
                    if (header != null) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [header, _buildTile(context, ch, scanOk)],
                      );
                    }
                    return _buildTile(context, ch, scanOk);
                  },
                ),
    );
  }
}
