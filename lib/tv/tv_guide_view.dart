import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/device_detector.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/program.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/player.dart';
import 'package:open_tv/player/overlay_player_controller.dart';
import 'package:open_tv/source_color_picker.dart';
import 'package:open_tv/tv/tv_hero_preview.dart';

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
  State<TvGuideView> createState() => TvGuideViewState();
}

// fix510: public so TvShell can call stopHeroPreview() via a GlobalKey on
// tab-away (IndexedStack keeps this view mounted, so there is no implicit
// visibility hook to release the preview's provider connection).
class TvGuideViewState extends State<TvGuideView> {
  static const int _windowHours = 3;
  static const int _channelCap = 200; // rail-scoped guard against huge groups
  // fix527: cap the (now paged) Live category rail, mirroring TvBrowseView.
  static const int _railCap = 1000;

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
  // fix510: hero live-preview state.
  Channel? _focused;
  late final TvHeroPreview _preview;
  bool _liveOk = false;
  int _dwellMs = 700;
  bool _favOnly = true; // fix539: Live defaults to Favorites (All pill removed)
  int _focusSeq = 0; // fix510: guards stale async focus callbacks
  bool _launching = false; // fix510: suppresses preview re-arm during _play

  @override
  void initState() {
    super.initState();
    _preview = TvHeroPreview();
    _windowStart = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _windowEnd = _windowStart + _windowHours * 3600;
    _init();
  }

  @override
  void dispose() {
    _preview.disposeController();
    super.dispose();
  }

  Future<void> _init() async {
    // fix524 (safe-mode TV leak): the guide is built once at shell init and kept
    // alive in IndexedStack, so widget.settings can go stale if Safe Mode is
    // toggled afterward. Prefer the live SettingsService.cached value.
    final s = SettingsService.cached ?? widget.settings;
    final sources = await Sql.getSources();
    final enabled = await Sql.getEnabledSourcesMinimal();
    final enabledIds = enabled.map((e) => e.id).whereType<int>().toList();
    // fix527: page the Live category rail so providers with >36 categories
    // aren't truncated. Previously a single page-1 Sql.search capped the Live
    // TV rail at pageSize (36). Mirrors TvBrowseView's rail paging; bounded by
    // _railCap.
    var groups = <Channel>[];
    try {
      for (var page = 1; groups.length < _railCap; page++) {
        final batch = await Sql.search(Filters(
          viewType: ViewType.categories,
          mediaTypes: const [MediaType.livestream],
          sourceIds: enabledIds,
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
    // fix510: gate the always-live hero preview. Capable boxes default ON;
    // low-RAM (Onn/Amlogic) defaults to art-first unless the owner opts in.
    final lowRam = await DeviceDetector.isLowRamDevice();
    if (!mounted) return;
    setState(() {
      _sourceColors = {
        for (final s in sources)
          if (s.id != null) s.id!: s.color,
      };
      _sourceIds = enabledIds;
      _groups = groups.take(_railCap).toList();
      _liveOk = !lowRam || widget.settings.tvHeroLivePreview;
      _dwellMs = lowRam ? 1100 : 700;
      _ready = true;
    });
    await _loadGuide(null);
  }

  Future<void> _loadGuide(int? groupId) async {
    final inv = ++_inv;
    // fix541: re-anchor the EPG window to NOW on every load. _windowStart/_End
    // were set ONCE in initState; because the guide is kept alive by the shell's
    // IndexedStack, that window went stale as time passed (and across an app
    // resume the next day), so getGridPrograms fetched a fully-elapsed window
    // and now/next details silently disappeared. Recomputing here keeps the
    // grid + the hero now/next anchored to the real current time on each reload.
    _windowStart = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _windowEnd = _windowStart + _windowHours * 3600;
    setState(() {
      _loading = true;
      _selectedGroupId = groupId;
    });
    // fix524 (safe-mode TV leak): use the live settings value, not the possibly
    // stale widget.settings (the guide is kept alive across Settings changes).
    final s = SettingsService.cached ?? widget.settings;
    // Load the scoped channels, paged up to the cap (keeps the grid bounded).
    final channels = <Channel>[];
    for (var page = 1; channels.length < _channelCap; page++) {
      final batch = await Sql.search(Filters(
        viewType: ViewType.all,
        mediaTypes: const [MediaType.livestream],
        groupId: groupId,
        sourceIds: _sourceIds,
        page: page,
        searchMethod: s.searchMethod,
        safeMode: s.safeMode,
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
    // fix510: suppress preview re-arm for the whole launch, and release the
    // hero preview (and its provider connection) BEFORE opening full-screen,
    // so the full-open never races the preview on a connection-limited
    // provider (fix112 instant "Failed to open").
    _launching = true;
    try {
      await _preview.stop();
      final settings =
          SettingsService.cached ?? await SettingsService.getSettings();
      final source = await Sql.getSourceById(ch.sourceId);
      // Single-connection providers need a beat to release the preview socket.
      if (source?.maxConnections == 1) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
      Player.clearCooldown(ch.id);
      if (!mounted) return;
      await OverlayPlayerController.instance.haltMain();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              Player(channel: ch, settings: settings, source: source),
        ),
      );
    } finally {
      _launching = false;
    }
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
    final channels = _visibleChannels;
    return Column(
      children: [
        _hero(),
        _filterPills(),
        _timeHeader(),
        Expanded(
          child: channels.isEmpty
              ? Center(
                  child: Text(_loading ? 'Loading guide…' : 'No channels'),
                )
              : ListView.builder(
                  itemCount: channels.length,
                  itemBuilder: (context, i) => _row(channels[i], i == 0),
                ),
        ),
      ],
    );
  }

  List<Channel> get _visibleChannels =>
      _favOnly ? _channels.where((c) => c.favorite).toList() : _channels;

  // fix510: hero with the focused channel's art + an always-live MUTED preview
  // cross-faded in once the dwell-gated engine produces a frame.
  Widget _hero() {
    final ch = _focused;
    return SizedBox(
      height: 168,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  color: Colors.black,
                  child: ch == null
                      ? const Center(
                          child: Icon(Icons.live_tv,
                              color: Colors.white24, size: 40))
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            if (ch.image != null)
                              CachedNetworkImage(
                                imageUrl: ch.image!,
                                fit: BoxFit.contain,
                                memCacheHeight: 240,
                                errorWidget: (c, u, e) => const Center(
                                    child: Icon(Icons.live_tv,
                                        color: Colors.white24, size: 40)),
                              )
                            else
                              const Center(
                                  child: Icon(Icons.live_tv,
                                      color: Colors.white24, size: 40)),
                            ListenableBuilder(
                              listenable: _preview,
                              builder: (context, _) {
                                final v = _preview.buildVideoView(context);
                                return AnimatedOpacity(
                                  opacity: _preview.isLive ? 1 : 0,
                                  duration: const Duration(milliseconds: 250),
                                  child: v ?? const SizedBox.shrink(),
                                );
                              },
                            ),
                          ],
                        ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(child: _heroInfo(ch)),
          ],
        ),
      ),
    );
  }

  Widget _heroInfo(Channel? ch) {
    if (ch == null) return const SizedBox.shrink();
    final progs = _progByKey['${ch.sourceId}|${ch.epgChannelId}'] ?? const [];
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    Program? onNow;
    Program? next;
    for (final p in progs) {
      if (p.startUtc <= now && now < p.stopUtc) {
        onNow = p;
        continue;
      }
      if (p.startUtc >= now) {
        next = p;
        break;
      }
    }
    final theme = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(ch.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        if (onNow != null)
          Text(
            'NOW   ${onNow.title}   ·   ends '
            '${_timeFmt.format(DateTime.fromMillisecondsSinceEpoch(onNow.stopUtc * 1000).toLocal())}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
        if (next != null)
          Text(
            'NEXT   ${next.title}   ·   '
            '${_timeFmt.format(DateTime.fromMillisecondsSinceEpoch(next.startUtc * 1000).toLocal())}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            SizedBox(
              width: 150,
              child: _FocusTile(
                selected: false,
                onTap: () => _play(ch),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.play_arrow, size: 20),
                    SizedBox(width: 6),
                    Text('Watch'),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            ListenableBuilder(
              listenable: _preview,
              builder: (context, _) => _preview.isLive
                  ? const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.volume_off, size: 16, color: Colors.grey),
                        SizedBox(width: 4),
                        Text('Muted preview',
                            style:
                                TextStyle(color: Colors.grey, fontSize: 12)),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ],
    );
  }

  Widget _filterPills() {
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          // fix539: the 'All' pill is removed; Favorites is a sticky toggle.
          // Tapping toggles between favorites-only (default) and all channels.
          _pill('Favorites', _favOnly, () => setState(() => _favOnly = !_favOnly)),
        ],
      ),
    );
  }

  Widget _pill(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: _FocusTile(
        selected: selected,
        onTap: onTap,
        child: Text(label),
      ),
    );
  }

  // fix510: a channel tile gained focus → update the hero + arm the dwell.
  Future<void> _onChannelFocused(Channel ch) async {
    final seq = ++_focusSeq;
    final prev = _focused;
    if (mounted) setState(() => _focused = ch);
    // Same channel re-focus, or a full-screen launch is in progress → don't
    // (re-)arm a preview.
    if (prev != null && identical(prev, ch)) return;
    if (_launching) return;
    final overlayUp = OverlayPlayerController.instance.channel != null;
    final source = await Sql.getSourceById(ch.sourceId);
    // Bail if superseded by a newer focus, unmounted, or a launch began while
    // awaiting — prevents a stale tile (or the tile we just left to play
    // full-screen) from re-opening a preview connection.
    if (!mounted || seq != _focusSeq || _launching) return;
    final liveEnabled =
        _liveOk && !overlayUp && source?.maxConnections != 1;
    _preview.onChannelFocused(
      ch,
      settings: widget.settings,
      dwellMs: _dwellMs,
      liveEnabled: liveEnabled,
    );
  }

  /// fix510: called by TvShell when leaving the Live tab so the muted preview
  /// (and its provider connection) is released immediately.
  Future<void> stopHeroPreview() => _preview.stop();

  /// fix534: called by TvShell when the Live tab is re-selected (or after
  /// returning from Settings), so the guide re-reads the enabled-source set and
  /// re-queries. The IndexedStack keeps this widget alive, so initState does NOT
  /// re-run on re-entry; without this the rail/grid stay stale after the user
  /// changes which sources are enabled. Reloads from the top (no group filter).
  Future<void> reloadGuide() => _loadGuide(null);

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
      key: ValueKey('guide-row-${ch.sourceId}-${ch.id ?? ch.name}'),
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
              onFocusGained: (_) => _onChannelFocused(ch),
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
  final ValueChanged<bool>? onFocusGained;
  const _FocusTile({
    required this.selected,
    required this.onTap,
    required this.child,
    this.autofocus = false,
    this.onFocusGained,
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
          onFocusChange: (v) {
            setState(() => _focused = v);
            if (v) widget.onFocusGained?.call(true);
          },
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
