import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/stream_scanner.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/view_type.dart';

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
    final results = await Sql.search(Filters(
      query: query.isEmpty ? null : query,
      sourceIds: widget.sourceIds,
      mediaTypes: [MediaType.livestream],
      viewType: ViewType.all,
      page: 1,
    ));
    if (!mounted) return;
    setState(() {
      _channels = results;
      _loading = false;
    });
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _load(q));
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
                    Widget logo = ch.image != null
                        ? SizedBox(
                            width: 40,
                            height: 40,
                            child: CachedNetworkImage(
                              imageUrl: ch.image!,
                              fit: BoxFit.contain,
                              errorWidget: (_, _, _) =>
                                  const Icon(Icons.tv),
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
                        style: scanOk
                            ? const TextStyle(color: Colors.greenAccent)
                            : null,
                      ),
                      subtitle: ch.group != null
                          ? Text(
                              ch.group!,
                              style: Theme.of(context).textTheme.bodySmall,
                            )
                          : null,
                      onTap: () => Navigator.of(context).pop(ch),
                    );
                  },
                ),
    );
  }
}
