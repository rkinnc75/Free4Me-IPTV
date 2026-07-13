import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
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

/// fix733 (mock §4.5): TV-native History tab.
///
/// Replaces the reused phone-`Home` body the History tab fell through to
/// (`tv_shell.dart`). A tokenized poster wall of the recently-watched channels,
/// using [ChannelTile] verbatim (source-tint edge bar + poster + the proven
/// play / series drill-in) on the SAME grid spec as Movies/Series
/// (maxExtent 130, AR 0.838). History is a flat recently-watched list, so there
/// is no category rail (unlike [TvBrowseView]). Bounded query (`_itemCap`).
///
/// TV-only: reachable solely via TvShell (`!hasTouchScreen`); phone never mounts
/// it.
class TvHistoryView extends StatefulWidget {
  final Settings settings;
  const TvHistoryView({super.key, required this.settings});

  @override
  State<TvHistoryView> createState() => _TvHistoryViewState();
}

class _TvHistoryViewState extends State<TvHistoryView> {
  static const int _itemCap = 200;

  Map<int, int?> _sourceColors = {};
  List<int> _sourceIds = [];
  List<Channel> _items = [];
  bool _ready = false;
  bool _error = false;
  final ScrollController _gridController = ScrollController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _gridController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _error = false;
    try {
      final s = SettingsService.cached ?? widget.settings;
      final sources = await Sql.getSources();
      final enabled = await Sql.getEnabledSourcesMinimal();
      _sourceIds = enabled.map((e) => e.id).whereType<int>().toList();
      _sourceColors = {
        for (final src in sources)
          if (src.id != null) src.id!: src.color,
      };
      // History spans every media type; the query is time-ordered by lastWatched
      // (Sql.search short-circuits to the history path for ViewType.history).
      final items = <Channel>[];
      for (var page = 1; items.length < _itemCap; page++) {
        final batch = await Sql.search(Filters(
          viewType: ViewType.history,
          mediaTypes: const [
            MediaType.livestream,
            MediaType.movie,
            MediaType.serie,
          ],
          sourceIds: _sourceIds,
          page: page,
          searchMethod: s.searchMethod,
          safeMode: s.safeMode,
        ));
        if (batch.isEmpty) break;
        items.addAll(batch);
        if (batch.length < pageSize) break;
      }
      if (!mounted) return;
      setState(() {
        _items = items.take(_itemCap).toList();
        _ready = true;
      });
    } catch (e) {
      AppLog.warn('TvHistoryView: load failed — $e');
      if (mounted) {
        setState(() {
          _error = true;
          _ready = true;
        });
      }
    }
  }

  /// Series drill-in — mirrors TvBrowseView._setNode (route the seriesId into a
  /// navigation Home so episode browsing keeps its proven behavior).
  void _setNode(Node node) {
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
    if (!_ready) return const Center(child: Text('Loading…'));
    if (_error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Could not load history',
                style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => setState(() {
                _ready = false;
                _init();
              }),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Text(
          'Nothing watched yet.\nChannels you play show up here.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Text(
            'History — ${_items.length}${_items.length >= _itemCap ? '+' : ''} recently watched',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Expanded(
          child: GridView.builder(
            controller: _gridController,
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            // Shared grid spec with Movies/Series (fix558).
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 130,
              childAspectRatio: 0.838,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
            ),
            itemCount: _items.length,
            itemBuilder: (context, i) {
              final ch = _items[i];
              return ChannelTile(
                key: ValueKey('history-${ch.id ?? ch.name}-$i'),
                channel: ch,
                parentContext: context,
                setNode: _setNode,
                tintColor: _sourceColors[ch.sourceId],
                showSourceEdgeBar: true,
                poster: true,
                autofocus: i == 0,
                isHistory: true,
                onRemoveHistory: () => _init(), // reload after removal
                playlist: _items,
                playlistIndex: i,
              );
            },
          ),
        ),
      ],
    );
  }
}
