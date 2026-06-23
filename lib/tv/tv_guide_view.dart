import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/program.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/player.dart';
import 'package:open_tv/player/overlay_player_controller.dart';
import 'package:open_tv/source_color_picker.dart';

final _timeFmt = DateFormat.Hm();

/// fix503: the Live tab's EPG guide — a category rail (left) scoping a
/// virtualized channel × time grid (right).
///
/// The grid shows a fixed forward window (the next [_windowHours] hours) so
/// every row shares one time axis without horizontal scrolling. Programmes are
/// laid out as proportional blocks; a "now" line marks the current time.
/// Channels are rail-scoped + capped so the grid never touches the full
/// ~1.15M-channel catalogue, and programmes are fetched in one bounded,
/// index-served [Sql.getGridPrograms] call. TV-only.
class TvGuideView extends StatefulWidget {
  final Settings settings;
  const TvGuideView({super.key, required this.settings});

  @override
  State<TvGuideView> createState() => _TvGuideViewState();
}

class _TvGuideViewState extends State<TvGuideView> {
  static const int _windowHours = 3;
  static const int _channelCap = 200; // rail-scoped guard against huge groups

  Map<int, int?> _sourceColors = {};
  List<int> _sourceIds = [];
  List<Channel> _groups = [];
  int? _selectedGroupId; // null = All
  List<Channel> _channels = [];
  Map<String, List<Program>> _progByKey = {};
  late int _windowStart;
  late int _windowEnd;
  bool _ready = false;
  bool _loading = false;
  int _inv = 0;

  @override
  void initState() {
    super.initState();
    _windowStart = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _windowEnd = _windowStart + _windowHours * 3600;
    _init();
  }

  Future<void> _init() async {
    final sources = await Sql.getSources();
    final enabled = await Sql.getEnabledSourcesMinimal();
    List<Channel> groups = [];
    try {
      groups = await Sql.search(Filters(
        viewType: ViewType.categories,
        mediaTypes: const [MediaType.livestream],
        sourceIds: enabled.map((e) => e.id).whereType<int>().toList(),
        searchMethod: widget.settings.searchMethod,
        safeMode: widget.settings.safeMode,
      ));
    } catch (_) {
      groups = [];
    }
    if (!mounted) return;
    setState(() {
      _sourceColors = {
        for (final s in sources)
          if (s.id != null) s.id!: s.color,
      };
      _sourceIds = enabled.map((e) => e.id).whereType<int>().toList();
      _groups = groups;
      _ready = true;
    });
    await _loadGuide(null);
  }

  Future<void> _loadGuide(int? groupId) async {
    final inv = ++_inv;
    setState(() {
      _loading = true;
      _selectedGroupId = groupId;
    });
    // Load the scoped channels, paged up to the cap (keeps the grid bounded).
    final channels = <Channel>[];
    for (var page = 1; channels.length < _channelCap; page++) {
      final batch = await Sql.search(Filters(
        viewType: ViewType.all,
        mediaTypes: const [MediaType.livestream],
        groupId: groupId,
        sourceIds: _sourceIds,
        page: page,
        searchMethod: widget.settings.searchMethod,
        safeMode: widget.settings.safeMode,
      ));
      if (batch.isEmpty) break;
      channels.addAll(batch);
      if (batch.length < pageSize) break;
    }
    if (!mounted || inv != _inv) return;
    final scoped = channels.take(_channelCap).toList();

    // One bounded, index-served programme fetch for the realized channel set.
    final epgIdsBySource = <int, List<String>>{};
    for (final ch in scoped) {
      final epg = ch.epgChannelId;
      if (epg != null) {
        (epgIdsBySource[ch.sourceId] ??= []).add(epg);
      }
    }
    final programmes = await Sql.getGridPrograms(
      epgIdsBySource: epgIdsBySource,
      windowStartEpoch: _windowStart,
      windowEndEpoch: _windowEnd,
    );
    if (!mounted || inv != _inv) return;
    final byKey = <String, List<Program>>{};
    for (final p in programmes) {
      (byKey['${p.sourceId}|${p.epgChannelId}'] ??= []).add(p);
    }
    for (final list in byKey.values) {
      list.sort((a, b) => a.startUtc.compareTo(b.startUtc));
    }
    setState(() {
      _channels = scoped;
      _progByKey = byKey;
      _loading = false;
    });
  }

  Future<void> _play(Channel ch) async {
    if (ch.url == null) return;
    final settings =
        SettingsService.cached ?? await SettingsService.getSettings();
    final source = await Sql.getSourceById(ch.sourceId);
    if (!mounted) return;
    await OverlayPlayerController.instance.haltMain();
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Player(channel: ch, settings: settings, source: source),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 210, child: _rail()),
        const VerticalDivider(width: 1),
        Expanded(child: _ready ? _guide() : const SizedBox.shrink()),
      ],
    );
  }

  Widget _rail() {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _railItem(null, 'All channels', Icons.live_tv),
        for (final g in _groups)
          if (g.id != null) _railItem(g.id, g.name, Icons.folder_outlined),
      ],
    );
  }

  Widget _railItem(int? groupId, String label, IconData icon) {
    final selected = groupId == _selectedGroupId;
    return _FocusTile(
      selected: selected,
      onTap: () => _loadGuide(groupId),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _guide() {
    return Column(
      children: [
        _timeHeader(),
        Expanded(
          child: _channels.isEmpty
              ? Center(
                  child: Text(_loading ? 'Loading guide…' : 'No channels'),
                )
              : ListView.builder(
                  itemCount: _channels.length,
                  itemBuilder: (context, i) => _row(_channels[i], i == 0),
                ),
        ),
      ],
    );
  }

  Widget _timeHeader() {
    final ticks = <Widget>[];
    for (var h = 0; h <= _windowHours; h++) {
      final t = DateTime.fromMillisecondsSinceEpoch(
          (_windowStart + h * 3600) * 1000);
      ticks.add(Expanded(
        child: Text(_timeFmt.format(t.toLocal()),
            style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(150, 6, 8, 4),
      child: Row(children: ticks),
    );
  }

  Widget _row(Channel ch, bool autofocus) {
    final progs = _progByKey['${ch.sourceId}|${ch.epgChannelId}'] ?? const [];
    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final tint = SourcePalette.tintOver(
      _sourceColors[ch.sourceId],
      Theme.of(context).colorScheme.surfaceContainer,
    );
    return SizedBox(
      height: 56,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Frozen channel column with the per-source edge bar (fix501 style).
          SizedBox(
            width: 144,
            child: _FocusTile(
              selected: false,
              onTap: () => _play(ch),
              autofocus: autofocus,
              child: Row(
                children: [
                  Container(width: 5, color: _edgeColor(ch.sourceId, tint)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(ch.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, c) {
              return Stack(children: [
                for (final p in progs) _block(p, c.maxWidth, nowEpoch, ch),
                _nowLine(c.maxWidth, nowEpoch),
              ]);
            }),
          ),
        ],
      ),
    );
  }

  Color _edgeColor(int sourceId, Color fallback) {
    final c = _sourceColors[sourceId];
    return c != null ? Color(c) : Colors.transparent;
  }

  double _x(int epoch, double width) {
    final frac = (epoch - _windowStart) / (_windowEnd - _windowStart);
    return (frac.clamp(0.0, 1.0)) * width;
  }

  Widget _block(Program p, double width, int nowEpoch, Channel ch) {
    final left = _x(p.startUtc, width);
    final right = _x(p.stopUtc, width);
    final w = (right - left);
    if (w <= 1) return const SizedBox.shrink();
    final isNow = p.isOnNow(nowEpoch);
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: left,
      top: 3,
      bottom: 3,
      width: w,
      child: Padding(
        padding: const EdgeInsets.only(right: 2),
        child: Material(
          color: isNow
              ? scheme.primary.withValues(alpha: 0.22)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
          child: InkWell(
            onTap: () => _play(ch),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(p.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: isNow ? FontWeight.w600 : FontWeight.normal,
                    )),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _nowLine(double width, int nowEpoch) {
    final x = _x(nowEpoch, width);
    return Positioned(
      left: x,
      top: 0,
      bottom: 0,
      width: 2,
      child: Container(color: Theme.of(context).colorScheme.primary),
    );
  }
}

/// Small D-pad-friendly tile with a yellow focus ring (matches the app's TV
/// focus standard) used by the rail + the frozen channel column.
class _FocusTile extends StatefulWidget {
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;
  final Widget child;
  const _FocusTile({
    required this.selected,
    required this.onTap,
    required this.child,
    this.autofocus = false,
  });

  @override
  State<_FocusTile> createState() => _FocusTileState();
}

class _FocusTileState extends State<_FocusTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Material(
        color: widget.selected
            ? scheme.primary.withValues(alpha: 0.18)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          autofocus: widget.autofocus,
          onTap: widget.onTap,
          onFocusChange: (v) => setState(() => _focused = v),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _focused ? Colors.yellow : Colors.transparent,
                width: 3,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
