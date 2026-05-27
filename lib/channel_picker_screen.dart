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

/// Sort key for the picker — mirrors the ORDER BY from fix72/74:
/// favorites+validated → favorites → validated → alphabetical.
///
/// fix74: reads [Channel.streamValidated] (persisted DB value) with
/// [StreamScanner.results] as a fallback for in-session scans.
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
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<Channel> _channels = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load(String query) async {
    if (!mounted) return;
    setState(() => _loading = true);

    // Fetch all pages so that favorites/validated channels beyond the first
    // page are included, then sort client-side.
    final all = <Channel>[];
    var page = 1;
    while (true) {
      // fix76: use the user's chosen search method and safe mode setting,
      // same as the main channel grid. Defaults to LIKE Scan if settings
      // aren't loaded yet (safe and reasonably fast for any query length).
      final s = SettingsService.cached;
      final pageResults = await Sql.search(Filters(
        query: query.isEmpty ? null : query,
        sourceIds: widget.sourceIds,
        mediaTypes: [MediaType.livestream],
        viewType: ViewType.all,
        page: page,
        searchMethod: s?.searchMethod ?? SearchMethod.likeSubstring,
        safeMode: s?.safeMode ?? false,
      ));
      all.addAll(pageResults);
      if (pageResults.length < pageSize) break;
      page++;
    }
    all.sort(_pickSort);

    if (!mounted) return;
    setState(() {
      _channels = all;
      _loading = false;
    });
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _load(q));
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
