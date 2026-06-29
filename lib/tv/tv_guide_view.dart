import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:open_tv/backend/epg_service.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/playback_playlist.dart';
import 'package:open_tv/models/device_detector.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/program.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/multi_view_screen.dart';
import 'package:open_tv/player.dart';
import 'package:open_tv/player/overlay_player_controller.dart';
import 'package:open_tv/source_color_picker.dart';
import 'package:open_tv/tv/tv_hero_preview.dart';

final _timeFmt = DateFormat.Hm();

/// fix597 (#4 redesign): the left rail SWAPS content. [categories] shows the
/// provider's live categories; selecting one switches to [channels] — that
/// category's channel list. D-pad LEFT on a channel returns to [categories].
enum RailMode { categories, channels }

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

  // fix597 (#4 redesign): the left rail swaps categories <-> channels.
  // _railNodes hold the CATEGORY tiles (stable so LEFT-from-channel can restore
  // focus to the selected category via EXPLICIT requestFocus — directional
  // focus is unreliable here, fix558/562/563). _channelNodes hold the CHANNEL
  // tiles in channels mode. _gridScroll aligns the passive EPG grid to the
  // focused channel (align-on-focus, not a synced 2nd controller).
  RailMode _railMode = RailMode.categories;
  final Map<int?, FocusNode> _railNodes = {};
  final Map<int, FocusNode> _channelNodes = {};
  final ScrollController _gridScroll = ScrollController();
  Timer? _catFollowTimer; // debounce the category-follow grid reload
  Timer? _epgReloadTimer; // fix601: coalesce epgVersion bumps into one reload
  static const double _rowHeight = 56;

  @override
  void initState() {
    super.initState();
    _preview = TvHeroPreview();
    _windowStart = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _windowEnd = _windowStart + _windowHours * 3600;
    // fix600: a foreground EPG refresh (launch stale-check or source refresh)
    // bumps EpgService.epgVersion. Re-fetch the current grid's programmes so the
    // new forecast appears without the user switching tabs. Channels/focus are
    // left untouched (programmes-only reload).
    EpgService.epgVersion.addListener(_onEpgVersionChanged);
    _init();
  }

  @override
  void dispose() {
    EpgService.epgVersion.removeListener(_onEpgVersionChanged); // fix600
    _epgReloadTimer?.cancel(); // fix601
    _catFollowTimer?.cancel();
    _preview.disposeController();
    for (final n in _railNodes.values) {
      n.dispose();
    }
    for (final n in _channelNodes.values) {
      n.dispose(); // fix597
    }
    _gridScroll.dispose(); // fix597
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

  Future<void> _loadGuide(int? groupId, {bool enterChannels = false}) async {
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
      // fix545: the rail's top item (groupId == null) is "Favorites" → enable
      // the favorites filter; selecting a real category disables it so the whole
      // category shows. This replaces the old standalone Favorites pill.
      _favOnly = groupId == null;
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
      if (enterChannels) _railMode = RailMode.channels;
    });
    // fix599: the rail remount + first-channel autofocus is best-effort, but on
    // the swap the focused category tile unmounts and focus escapes UP to the
    // nav before autofocus claims the new tile (verified on-device v2.2.9). FORCE
    // focus to the first channel in a post-frame — it fires reliably (setState
    // scheduled the frame) and runs AFTER the unmount/escape settles, so it
    // overrides the nav grab.
    if (enterChannels && scoped.isNotEmpty) {
      final firstId = scoped.first.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _railMode == RailMode.channels && firstId != null) {
          _channelNodes[firstId]?.requestFocus();
        }
      });
    }
  }

  // fix600: an EPG refresh completed elsewhere (launch stale-check or a Settings
  // source refresh). Re-fetch ONLY the programmes for the channels already on
  // screen and rebuild the grid — channels, focus, and the rail mode are left
  // exactly as the user left them.
  void _onEpgVersionChanged() {
    if (!mounted || !_ready) return;
    // fix601: refreshAllSources bumps epgVersion once PER source — coalesce so
    // an N-source refresh triggers one grid reload, not N concurrent
    // getGridPrograms reads racing each other.
    _epgReloadTimer?.cancel();
    _epgReloadTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) unawaited(_reloadGridProgrammes());
    });
  }

  Future<void> _reloadGridProgrammes() async {
    final inv = _inv; // don't bump — a concurrent _loadGuide must win
    if (_channels.isEmpty) return;
    // re-anchor the window to NOW (same rationale as _loadGuide/fix541).
    _windowStart = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _windowEnd = _windowStart + _windowHours * 3600;
    final epgIdsBySource = <int, List<String>>{};
    for (final ch in _channels) {
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
    if (!mounted || inv != _inv) return; // a real reload superseded us
    final byKey = <String, List<Program>>{};
    for (final p in programmes) {
      (byKey['${p.sourceId}|${p.epgChannelId}'] ??= []).add(p);
    }
    for (final list in byKey.values) {
      list.sort((a, b) => a.startUtc.compareTo(b.startUtc));
    }
    setState(() => _progByKey = byKey);
  }

  // fix597: OK on a category → (re)load it and switch the rail to channels.
  void _enterChannels(int? groupId) {
    unawaited(_preview.stop()); // drop any dwell before the new selection
    unawaited(_loadGuide(groupId, enterChannels: true));
  }

  // fix597: focusing a category in the rail follows the grid to that category's
  // channels (debounced so fast D-pad scrolling doesn't hammer the DB). The
  // preview is NOT re-armed here — it stays on the last-watched channel.
  void _onCategoryFocused(int? groupId) {
    if (_railMode != RailMode.categories) return;
    if (groupId == _selectedGroupId) return;
    _catFollowTimer?.cancel();
    _catFollowTimer = Timer(const Duration(milliseconds: 280), () {
      if (mounted && _railMode == RailMode.categories) {
        unawaited(_loadGuide(groupId));
      }
    });
  }

  /// fix584 (#4): D-pad LEFT from a channel re-expands the rail (if collapsed)
  /// and restores focus to the selected category. ALWAYS handled and ALWAYS an
  /// explicit requestFocus to the stored node — never a fall-through to
  /// directional traversal, which is unreliable across these grids
  /// (fix558/562/563) and would strand focus.
  KeyEventResult _onChannelLeftKey(KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (e.logicalKey != LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.ignored;
    }
    if (_railMode != RailMode.channels) return KeyEventResult.ignored;
    // fix598/599: swap to categories. The SELECTED category's autofocus is
    // best-effort; FORCE focus to it in a post-frame (same escape-to-nav race as
    // entering channels). ALWAYS handled so LEFT never falls through to
    // directional traversal.
    setState(() => _railMode = RailMode.categories);
    final target = _railNodes[_selectedGroupId] ?? _railNodes[null];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _railMode == RailMode.categories) target?.requestFocus();
    });
    return KeyEventResult.handled;
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
      // fix577: pass the guide's visible channel list so the player can surf
      // channel +/- (D-pad up/down + CH keys). The guide previously passed no
      // playlist, so _canSurf was always false and channel-switching did
      // nothing when a stream was launched from the guide.
      final list = _visibleChannels;
      final idx = list.indexOf(ch);
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => Player(
            channel: ch,
            settings: settings,
            source: source,
            playlist: idx >= 0
                ? PlaybackPlaylist(channels: list, index: idx)
                : null,
          ),
        ),
      );
    } finally {
      _launching = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox.shrink();
    // fix597 (#4 redesign): top band = 70% preview (left) + channel info
    // (right); below = swapping rail (left) + passive EPG grid (right). The
    // grid no longer carries a channel-name column — names live in the rail.
    return Column(
      children: [
        SizedBox(
          height: 124,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 210, child: _previewBox(_focused)),
                const SizedBox(width: 14),
                Expanded(child: _heroInfo(_focused)),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              SizedBox(width: 210, child: _rail()),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    _timeHeader(),
                    Expanded(child: _grid()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // fix597: the rail swaps content by mode. categories → the live category
  // list; channels → the selected category's channel names (which drive the
  // passive EPG grid via focus). LEFT on a channel returns to categories.
  Widget _rail() {
    if (_railMode == RailMode.channels) {
      final chans = _visibleChannels;
      if (chans.isEmpty) {
        return Center(child: Text(_loading ? 'Loading…' : 'No channels'));
      }
      // fix598: distinct key per mode so a categories↔channels SWAP remounts
      // the list — that makes `autofocus` on the target tile fire reliably
      // (autofocus only fires on first mount; my earlier cross-rebuild
      // requestFocus was the fragile part that stranded focus on-device).
      return ListView.builder(
        key: const ValueKey('rail-channels'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: chans.length,
        itemBuilder: (context, i) => _channelItem(chans[i], i == 0),
      );
    }
    return ListView(
      key: const ValueKey('rail-categories'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        // fix545: top item is "Favorites" (replacing "All channels").
        _categoryItem(null, 'Favorites', Icons.star),
        for (final g in _groups)
          if (g.id != null) _categoryItem(g.id, g.name, Icons.folder_outlined),
      ],
    );
  }

  Widget _categoryItem(int? groupId, String label, IconData icon) {
    final isSelected = groupId == _selectedGroupId;
    return _FocusTile(
      selected: isSelected,
      // fix598: the selected category autofocuses when the rail (re)mounts into
      // categories mode (app start + LEFT-from-channel), restoring focus to the
      // category the user was in. Stable node kept for identity.
      autofocus: isSelected,
      focusNode: _railNodes[groupId] ??= FocusNode(debugLabel: 'rail-$groupId'),
      onTap: () => _enterChannels(groupId), // OK → load + switch to channels
      onFocusGained: (_) => _onCategoryFocused(groupId), // follow the grid
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _channelItem(Channel ch, bool first) {
    final id = ch.id;
    final tint = SourcePalette.tintOver(
      _sourceColors[ch.sourceId],
      Theme.of(context).colorScheme.surfaceContainer,
    );
    return _FocusTile(
      // fix601: key by channel id so a list shrink/reorder (e.g. a favorite
      // toggle that drops a channel) re-pairs State↔node BY CHANNEL instead of
      // by index. Without this, ListView.builder reuses the State at each index
      // and only swaps its widget — so the held-OK handler (installed once in
      // initState, bound to the node) desyncs: it stays on the old node while
      // the tile now renders a different channel, and the channel that slid up
      // gets no handler. Keys make the removed channel's State dispose (clearing
      // its node handler) and survivors keep their correct pairing.
      key: ValueKey('gch-${ch.id ?? ch.name}'),
      selected: identical(ch, _focused),
      // fix598: first channel autofocuses when the rail remounts into channels
      // mode (OK on a category) — lands focus at the top + fires _onChannelFocused
      // (which arms the preview on multi-connection sources).
      autofocus: first,
      focusNode:
          id != null ? (_channelNodes[id] ??= FocusNode(debugLabel: 'chan-$id')) : null,
      onKeyEvent: _onChannelLeftKey, // LEFT → back to categories
      onTap: () => _play(ch),
      // fix600 (#6): held-OK opens the channel context menu — same "Open in
      // Multi-view" entry the Search/Movies tiles have (channel_tile), which was
      // previously unreachable from the Live guide.
      onLongPress: () => _showChannelMenu(ch),
      onFocusGained: (_) => _onChannelFocused(ch),
      child: Row(
        children: [
          Container(width: 5, height: 28, color: _edgeColor(ch.sourceId, tint)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(ch.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // fix600 (#6): the Live-guide channel context menu (held-OK). Mirrors
  // channel_tile's long-press sheet — Open-in-Multi-view (live + has URL) and
  // favorite toggle. TV remotes can't fire InkWell.onLongPress, so _FocusTile
  // detects a held select and calls this.
  Future<void> _showChannelMenu(Channel ch) async {
    final id = ch.id;
    final isLive = ch.mediaType == MediaType.livestream &&
        (ch.url?.isNotEmpty ?? false);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(ch.name,
                    style: Theme.of(ctx).textTheme.labelLarge,
                    textAlign: TextAlign.center),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.play_arrow),
                title: const Text('Play'),
                autofocus: true,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _play(ch);
                },
              ),
              if (isLive)
                ListTile(
                  leading: const Icon(Icons.grid_view),
                  title: const Text('Open in Multi-view'),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    final s = SettingsService.cached ?? widget.settings;
                    await MultiViewScreen.openWithChannel(
                        context, s, _sourceIds, ch);
                  },
                ),
              if (id != null)
                ListTile(
                  leading: Icon(
                    ch.favorite ? Icons.star : Icons.star_border,
                    color: Colors.amber,
                  ),
                  title: Text(ch.favorite
                      ? 'Remove from favorites'
                      : 'Add to favorites'),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    final next = !ch.favorite;
                    // fix601: reflect the toggle in the in-memory model + UI
                    // immediately (mirrors channel_tile.favorite); the async
                    // reload below replaces the objects but this keeps the star
                    // correct if the menu is reopened before it lands.
                    setState(() => ch.favorite = next);
                    await Sql.favoriteChannel(id, next);
                    if (!mounted) return;
                    await _loadGuide(_selectedGroupId);
                    // fix601: in the Favorites view, un-favoriting drops the
                    // focused channel from _visibleChannels, so focus would be
                    // stranded (the enterChannels post-frame re-grab doesn't run
                    // here). Re-anchor: keep focus on the toggled channel if it
                    // survived the reload (a real category keeps it), else fall
                    // to the new first channel. Mirrors the fix599 discipline.
                    if (!mounted || _railMode != RailMode.channels) return;
                    final stillThere = _visibleChannels.any((c) => c.id == id);
                    final targetId = stillThere
                        ? id
                        : (_visibleChannels.isNotEmpty
                            ? _visibleChannels.first.id
                            : null);
                    if (targetId != null) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted && _railMode == RailMode.channels) {
                          _channelNodes[targetId]?.requestFocus();
                        }
                      });
                    }
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  // fix597: the passive EPG grid — one timeline row per channel (NO name
  // column; names live in the rail). Attached to _gridScroll so a focused rail
  // channel scrolls its row into view (align-on-focus). The focused channel's
  // row is highlighted.
  Widget _grid() {
    final channels = _visibleChannels;
    if (channels.isEmpty) {
      return Center(child: Text(_loading ? 'Loading guide…' : 'No channels'));
    }
    return ListView.builder(
      controller: _gridScroll,
      itemCount: channels.length,
      itemExtent: _rowHeight,
      itemBuilder: (context, i) => _gridRow(channels[i]),
    );
  }

  // fix543: the favorites filter applies ONLY to the top-level "All channels"
  // view. When the user explicitly drills into a category (e.g. "USA CBS
  // Locals", _selectedGroupId != null) they want that category's channels — not
  // an empty favorites-filtered list. Before this, fix539's _favOnly=true
  // default stripped every non-favorite even inside a selected category, so
  // every category showed "No channels" for anyone without live favorites.
  List<Channel> get _visibleChannels =>
      (_favOnly && _selectedGroupId == null)
          ? _channels.where((c) => c.favorite).toList()
          : _channels;

  // fix597: the 70%-size preview box (top-left). Shows the focused channel's
  // art with the always-live MUTED preview cross-faded in once the dwell-gated
  // engine produces a frame. In categories mode [ch] is the last-watched
  // channel (the preview is not re-armed while browsing categories).
  Widget _previewBox(Channel? ch) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Container(
          color: Colors.black,
          child: ch == null
              ? const Center(
                  child: Icon(Icons.live_tv, color: Colors.white24, size: 40))
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

  // fix597: align the passive EPG grid so the focused channel's row is in view.
  void _scrollGridTo(Channel ch) {
    if (!_gridScroll.hasClients) return;
    final idx = _visibleChannels.indexOf(ch);
    if (idx < 0) return;
    final target = (idx * _rowHeight - _rowHeight * 2)
        .clamp(0.0, _gridScroll.position.maxScrollExtent);
    _gridScroll.animateTo(target,
        duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
  }

  // fix510/597: a channel tile in the rail gained focus → highlight + scroll
  // its grid row, update the preview/info, and arm the dwell. Guarded to
  // channels mode so a stale focus event can't drive the preview while browsing
  // categories (the preview stays on the last-watched channel there).
  Future<void> _onChannelFocused(Channel ch) async {
    if (_railMode != RailMode.channels) return;
    final seq = ++_focusSeq;
    final prev = _focused;
    if (mounted) setState(() => _focused = ch);
    _scrollGridTo(ch);
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
  ///
  /// fix544: this MUST re-run _init(), not just _loadGuide(null). _loadGuide
  /// re-queries channels but reuses the cached _sourceIds and _groups (the
  /// category rail) captured at the last _init(). So after the user disabled
  /// ALL sources, reloadGuide() re-queried with the STALE enabled-source list
  /// and the Live grid kept showing channels (while Movies/Series/Categories,
  /// which rebuild fully, correctly went empty). _init() re-reads
  /// getEnabledSourcesMinimal(), rebuilds the rail, and then loads the guide.
  Future<void> reloadGuide() => _init();

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
      // fix597: align with the grid rows' left edge (no 144px name column now).
      padding: const EdgeInsets.fromLTRB(4, 6, 8, 4),
      child: Row(children: ticks),
    );
  }

  // fix597: a passive timeline row (no name column, no focus). The focused
  // channel (driven by the rail) is highlighted; tapping a programme plays.
  Widget _gridRow(Channel ch) {
    final progs = _progByKey['${ch.sourceId}|${ch.epgChannelId}'] ?? const [];
    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final focused = identical(ch, _focused);
    return Container(
      key: ValueKey('guide-row-${ch.sourceId}-${ch.id ?? ch.name}'),
      height: _rowHeight,
      decoration: focused
          ? BoxDecoration(
              color:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.14))
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: LayoutBuilder(builder: (context, c) {
          return Stack(children: [
            for (final p in progs) _block(p, c.maxWidth, nowEpoch, ch),
            _nowLine(c.maxWidth, nowEpoch),
          ]);
        }),
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
  /// fix584 (#4): caller-supplied node so another widget can requestFocus this
  /// tile directly (rail categories + the first channel row).
  final FocusNode? focusNode;
  /// fix584 (#4): observe keys bubbling from the tile (e.g. LEFT on a channel
  /// to re-expand the rail). Returns handled to stop directional traversal.
  final KeyEventResult Function(KeyEvent)? onKeyEvent;
  /// fix600 (#6): held-OK context menu. When set, a quick OK still fires
  /// [onTap] (on key-UP) and a hold >= 450ms fires this — same gesture model as
  /// channel_tile's held-OK menu (TV remotes can't fire InkWell.onLongPress).
  /// Requires [focusNode] (the hold detector binds to its onKeyEvent).
  final Future<void> Function()? onLongPress;
  const _FocusTile({
    super.key,
    required this.selected,
    required this.onTap,
    required this.child,
    this.autofocus = false,
    this.onFocusGained,
    this.focusNode,
    this.onKeyEvent,
    this.onLongPress,
  });

  @override
  State<_FocusTile> createState() => _FocusTileState();
}

class _FocusTileState extends State<_FocusTile> {
  bool _focused = false;
  // fix600 (#6): held-OK detection (mirrors channel_tile/fix586). Bound to the
  // caller-supplied node's onKeyEvent so it pre-empts InkWell's ActivateIntent
  // (which would otherwise fire onTap on key-DOWN, before a hold can register).
  Timer? _selectHoldTimer;
  bool _selectActed = false;
  static const Duration _selectHoldDelay = Duration(milliseconds: 450);

  @override
  void initState() {
    super.initState();
    _installHoldHandler();
  }

  void _installHoldHandler() {
    final node = widget.focusNode;
    if (node == null || widget.onLongPress == null) return;
    node.onKeyEvent = (n, event) {
      final k = event.logicalKey;
      final isSelect = k == LogicalKeyboardKey.select ||
          k == LogicalKeyboardKey.enter ||
          k == LogicalKeyboardKey.numpadEnter ||
          k == LogicalKeyboardKey.gameButtonA;
      if (!isSelect) return KeyEventResult.ignored; // LEFT etc. bubble up
      if (event is KeyDownEvent) {
        _selectActed = false;
        _selectHoldTimer?.cancel();
        _selectHoldTimer = Timer(_selectHoldDelay, () {
          if (!mounted || !n.hasFocus) return;
          _selectActed = true;
          widget.onLongPress?.call();
        });
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        _selectHoldTimer?.cancel();
        _selectHoldTimer = null;
        final acted = _selectActed;
        _selectActed = false;
        if (!acted) widget.onTap();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled; // swallow repeats; the timer drives the menu
    };
  }

  @override
  void dispose() {
    _selectHoldTimer?.cancel();
    // Clear the handler we installed so a recycled node (channel nodes persist
    // in _channelNodes across rail swaps) doesn't keep this disposed State's
    // closure. The next _FocusTile re-installs in initState.
    if (widget.onLongPress != null) widget.focusNode?.onKeyEvent = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget tile = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Material(
        color: widget.selected
            ? scheme.primary.withValues(alpha: 0.18)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          onTap: widget.onTap,
          // fix602: also wire the TOUCH long-press to the same menu (parity with
          // channel_tile). The remote path is the held-OK key detector above;
          // this adds the touch gesture for touchscreens AND makes the menu
          // reachable by a synthetic touch long-press for on-device testing (a
          // sustained D-pad hold can't be injected via adb on a non-rooted box).
          onLongPress:
              widget.onLongPress == null ? null : () => widget.onLongPress!(),
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
    final onKey = widget.onKeyEvent;
    if (onKey == null) return tile;
    // fix584 (#4): non-focusable observer — catches keys bubbling from the
    // focused InkWell (e.g. LEFT) without taking focus or joining traversal.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, e) => onKey(e),
      child: tile,
    );
  }
}
