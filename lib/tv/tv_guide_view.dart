import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/epg_service.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/confirm_exit_scope.dart'; // finding 70
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
import 'package:open_tv/tv/theme/accent_scope.dart'; // fix704 (TV GUI redesign)
import 'package:open_tv/source_color_picker.dart';
import 'package:open_tv/tv/tv_hero_preview.dart';

// fix604 (#5): guide/EPG times go through the shared guideClockFmt()
// (settings_service), which honors the use24HourTime setting — 24-hour "21:38"
// vs 12-hour "9:38 PM". See _fmtEpoch.

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
  // fix644: raised 1000 -> 10000 — providers with huge category counts were
  // silently truncated in the rail.
  static const int _railCap = 10000;

  Map<int, int?> _sourceColors = {};
  List<int> _sourceIds = [];
  List<Channel> _groups = [];
  // fix645: Sql.groupsGen snapshot from the last rail build — reloadGuide
  // rebuilds when categories were enabled/disabled/favorited since.
  int _groupsGenSeen = 0;
  // finding 77: Sql.channelsGen snapshot — reloadGuide rebuilds when a channel's
  // favorite flag changed from another tab (the kept-alive Favorites rail would
  // otherwise stay stale until a manual re-select).
  int _channelsGenSeen = 0;
  int? _selectedGroupId; // null = All
  List<Channel> _channels = [];
  Map<String, List<Program>> _progByKey = {};
  late int _windowStart;
  late int _windowEnd;
  bool _ready = false;
  bool _loading = false;
  // finding 71: a load failure (DB throw in _init/_loadGuide) surfaces here so
  // the guide shows a focusable Retry instead of a permanently blank tab.
  String? _error;
  int _inv = 0;
  // fix510: hero live-preview state.
  Channel? _focused;
  late final TvHeroPreview _preview;
  bool _liveOk = false;
  int _dwellMs = 700;
  bool _favOnly = true; // fix539: Live defaults to Favorites (All pill removed)
  int _focusSeq = 0; // fix510: guards stale async focus callbacks
  bool _launching = false; // fix510: suppresses preview re-arm during _play
  // fix605: see _enterChannels — ignore a play within this window of entering a
  // category (catches the category-select OK bleeding into the first channel).
  int _enterChannelsAtMs = 0;
  static const int _enterPlayGuardMs = 700;

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
  // fix603 (#15): the channel rail and the EPG grid drifted out of vertical
  // alignment — the rail used variable-height tiles + top padding while the grid
  // used a fixed itemExtent with none, so channel N didn't line up with its EPG
  // row N. Now both use _rowHeight with no padding, and the grid MIRRORS the
  // rail's scroll (the rail is the focus master; the grid is passive) so row N
  // always lines up with channel N.
  final ScrollController _railScroll = ScrollController();
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
    // fix603 (#15): keep the passive EPG grid vertically locked to the channel
    // rail (the rail scrolls on D-pad focus; the grid follows).
    _railScroll.addListener(_syncGridToRail);
    _init();
  }

  // fix603 (#15): mirror the rail's scroll offset onto the grid so channel N and
  // EPG row N stay aligned. One-way (rail→grid) — the rail is the focus master,
  // the grid has no focus/controller-driven scroll of its own — so there is no
  // feedback loop. Both lists have identical item count + itemExtent + viewport
  // height, so a matching offset means matching rows.
  void _syncGridToRail() {
    if (!_gridScroll.hasClients || !_railScroll.hasClients) return;
    final target =
        _railScroll.offset.clamp(0.0, _gridScroll.position.maxScrollExtent);
    if ((_gridScroll.offset - target).abs() > 0.5) _gridScroll.jumpTo(target);
  }

  @override
  void dispose() {
    EpgService.epgVersion.removeListener(_onEpgVersionChanged); // fix600
    _epgReloadTimer?.cancel(); // fix601
    _preview.disposeController();
    for (final n in _railNodes.values) {
      n.dispose();
    }
    for (final n in _channelNodes.values) {
      n.dispose(); // fix597
    }
    _railScroll.removeListener(_syncGridToRail); // fix603
    _railScroll.dispose(); // fix603
    _gridScroll.dispose(); // fix597
    super.dispose();
  }

  // finding 71: reusable error surface with a focusable Retry so a load failure
  // never strands the default Live landing tab with an empty, unfocusable body.
  Widget _errorRetry(String msg, VoidCallback onRetry) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(msg, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          _FocusTile(
            selected: false,
            autofocus: true,
            onTap: onRetry,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text('Retry'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _init() async {
    // fix645: snapshot the category-change generation FIRST — a toggle landing
    // while this init runs will differ from the snapshot and trigger another
    // rebuild on the next reloadGuide instead of being lost.
    _groupsGenSeen = Sql.groupsGen;
    _channelsGenSeen = Sql.channelsGen; // finding 77
    // fix524 (safe-mode TV leak): the guide is built once at shell init and kept
    // alive in IndexedStack, so widget.settings can go stale if Safe Mode is
    // toggled afterward. Prefer the live SettingsService.cached value.
    final s = SettingsService.cached ?? widget.settings;
    // finding 71: guard the whole init so one thrown DB call surfaces a Retry
    // instead of leaving the default Live landing tab permanently blank.
    try {
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
    } catch (e, st) {
      // finding 72: don't swallow a browse-query failure and render an empty
      // rail silently — log it and surface the shared Retry error state
      // (finding 71). A legitimately empty provider throws nothing and falls
      // through to the normal 'no categories' render below.
      AppLog.error('Guide category rail query failed: $e\n$st');
      if (mounted) {
        setState(() {
          _error = 'Could not load channel categories.';
          _ready = true;
        });
      }
      return;
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
    } catch (e, st) {
      // finding 71: init-level DB failure (getSources / lowRam probe / initial
      // _loadGuide) — log and surface the shared Retry error state.
      AppLog.error('Guide _init failed: $e\n$st');
      if (mounted) {
        setState(() {
          _error = 'Could not load the guide.';
          _ready = true;
        });
      }
    }
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
    // finding 71: guard the awaited load so a DB throw surfaces Retry instead of
    // a silently-empty grid, and the finally always clears _loading for the
    // winning invocation (a superseded load leaves the newer one's flag alone).
    try {
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
    // finding 76: entering a category that resolves to zero VISIBLE channels
    // strands D-pad focus (no channel tiles for the post-frame grab, and the
    // categories rail unmounted on the swap). Compute against the SAME filter
    // _visibleChannels applies — for Favorites (groupId == null) that is the
    // favorite subset, so `scoped` can be non-empty while nothing renders.
    final visibleEmpty = enterChannels &&
        ((groupId == null)
            ? scoped.where((c) => c.favorite).isEmpty
            : scoped.isEmpty);
    setState(() {
      _channels = scoped;
      _progByKey = byKey;
      _loading = false;
      // finding 76: only swap to channels mode when there is something to focus;
      // an empty visible list would leave the swapped-in rail with no tile.
      if (enterChannels && !visibleEmpty) _railMode = RailMode.channels;
    });
    // finding 76: stayed in categories — surface a hint and return focus to the
    // just-selected category tile (UP/DOWN still moves, OK re-tries). Skip the
    // channels autofocus block below (it only applies when we actually swapped).
    if (visibleEmpty) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('No channels in this category yet')),
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            (_railNodes[groupId] ?? _railNodes[null])?.requestFocus();
          }
        });
      }
      return;
    }
    // fix599: the rail remount + first-channel autofocus is best-effort, but on
    // the swap the focused category tile unmounts and focus escapes UP to the
    // nav before autofocus claims the new tile (verified on-device v2.2.9). FORCE
    // focus to the first channel in a post-frame — it fires reliably (setState
    // scheduled the frame) and runs AFTER the unmount/escape settles, so it
    // overrides the nav grab.
    if (enterChannels && scoped.isNotEmpty) {
      final firstId = scoped.first.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _railMode == RailMode.channels) {
          // fix603 (#15): start both lists at the top so the focused first
          // channel and its EPG row are aligned (a persistent controller can
          // otherwise restore a stale offset on remount).
          if (_railScroll.hasClients) _railScroll.jumpTo(0);
          if (_gridScroll.hasClients) _gridScroll.jumpTo(0);
          if (firstId != null) _channelNodes[firstId]?.requestFocus();
        }
      });
    }
    } catch (e, st) {
      // finding 71: surface the shared Retry error state on a load failure.
      AppLog.error('Guide _loadGuide failed: $e\n$st');
      if (mounted && inv == _inv) {
        setState(() => _error = 'Could not load the guide.');
      }
    } finally {
      // finding 71: always clear _loading for the winning invocation — a
      // superseded load (inv != _inv) must not stomp the newer load's flag.
      if (mounted && inv == _inv && _loading) {
        setState(() => _loading = false);
      }
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
    // fix605: backstop for the auto-play-on-enter bug. The OK that selects the
    // category can bleed its key-UP into the first channel once focus lands
    // there (the orphan-KeyUp guard in _FocusTile catches the common case, but a
    // fast category load — e.g. Favorites — can still race it). Stamp the
    // enter time; _play ignores any play within _enterPlayGuardMs of it. A real
    // "open category then OK a channel" is always slower than this window.
    _enterChannelsAtMs = DateTime.now().millisecondsSinceEpoch;
    unawaited(_preview.stop()); // drop any dwell before the new selection
    unawaited(_loadGuide(groupId, enterChannels: true));
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
    _swapToCategories();
    return KeyEventResult.handled;
  }

  /// fix598/599: swap to categories. The SELECTED category's autofocus is
  /// best-effort; FORCE focus to it in a post-frame (same escape-to-nav race as
  /// entering channels). ALWAYS handled so LEFT never falls through to
  /// directional traversal.
  /// fix644: extracted so the Back button (guide PopScope) shares the exact
  /// behaviour of D-pad LEFT (fix584) — Back from the channels rail returns to
  /// the categories rail instead of bubbling to the app-exit confirm.
  void _swapToCategories() {
    setState(() => _railMode = RailMode.categories);
    final target = _railNodes[_selectedGroupId] ?? _railNodes[null];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _railMode == RailMode.categories) target?.requestFocus();
    });
  }

  Future<void> _play(Channel ch) async {
    if (ch.url == null) return;
    // fix605: ignore a play that fires within the enter-channels guard window —
    // it's the category-select OK bleeding through to the freshly-focused first
    // channel, not a deliberate channel activation.
    if (DateTime.now().millisecondsSinceEpoch - _enterChannelsAtMs <
        _enterPlayGuardMs) {
      AppLog.info('Guide: ignoring play "${ch.name}" — within enter-channels '
          'guard (bleed-through)');
      return;
    }
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
    // finding 71: a load failure shows a focusable Retry instead of a blank tab.
    if (_error != null) {
      return _errorRetry(_error!, () {
        setState(() => _error = null);
        _init();
      });
    }
    if (!_ready) return const SizedBox.shrink();
    // fix597 (#4 redesign): top band = 70% preview (left) + channel info
    // (right); below = swapping rail (left) + passive EPG grid (right). The
    // grid no longer carries a channel-name column — names live in the rail.
    // fix644: the channels rail is a MODE swap, not a pushed route, so a Back
    // press used to bubble straight to TvShell's exit confirm ("attempted to
    // exit the app from the channels", onn 2026-07-03). Intercept Back while
    // in channels mode and step back to the categories rail (same behaviour
    // as D-pad LEFT, fix584); in categories mode Back bubbles normally so the
    // shell's exit confirm still works.
    return PopScope(
      canPop: _railMode != RailMode.channels,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // finding 70: tell the shell's ConfirmExitScope this Back was consumed
        // here so it doesn't also arm the exit prompt on the same press.
        ConfirmExitScope.notePopConsumed();
        _swapToCategories();
      },
      child: Column(
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
        // fix603 (#15): the time header now spans a top row with a 210px spacer
        // ABOVE the rail, so the rail and grid bodies BOTH start at the same Y.
        // Previously the header lived only above the grid, pushing every EPG row
        // down by the header height relative to its channel in the rail.
        Row(
          children: [
            const SizedBox(width: 210),
            const SizedBox(width: 1),
            Expanded(child: _timeHeader()),
          ],
        ),
        Expanded(
          child: Row(
            children: [
              SizedBox(width: 210, child: _rail()),
              const VerticalDivider(width: 1),
              Expanded(child: _grid()),
            ],
          ),
        ),
      ],
      ),
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
      // fix603 (#15): clamp the rail's text scale so a large accessibility font
      // size can't push a 2-line channel name past the hard 56px itemExtent box
      // (which would paint RenderFlex overflow stripes). The grid rows are
      // already height-bounded (Positioned blocks), so clamping just the rail
      // keeps the two aligned.
      return MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.2,
        child: ListView.builder(
          key: const ValueKey('rail-channels'),
          controller: _railScroll, // fix603 (#15): mirror onto the grid
          // fix603 (#15): NO padding + fixed itemExtent == the grid's, so channel
          // row N lines up exactly with EPG row N (was variable-height + 8px top
          // padding, which drifted the two apart).
          itemExtent: _rowHeight,
          itemCount: chans.length,
          itemBuilder: (context, i) => _channelItem(chans[i], i == 0),
        ),
      );
    }
    // finding 74: lazy builder so a provider with thousands of categories does
    // not eagerly build every tile (and FocusNode) up front. Index 0 is the
    // synthetic "Favorites" item; the rest are the real categories.
    final cats = _groups.where((g) => g.id != null).toList();
    return ListView.builder(
      key: const ValueKey('rail-categories'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: cats.length + 1,
      itemBuilder: (context, i) {
        // fix545: top item is "Favorites" (replacing "All channels").
        if (i == 0) return _categoryItem(null, 'Favorites', Icons.star);
        final g = cats[i - 1];
        return _categoryItem(g.id, g.name, Icons.folder_outlined);
      },
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
      // fix603 (#10): NO grid-follow on category focus. Browsing the category
      // list must not reload the EPG grid (it showed "the focused category's
      // programmes but no channels", which is confusing — you're still picking
      // a category, not viewing it). The grid changes only on OK-enter.
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
          // fix603 (#14): favorites had NO visible marker anywhere. Show a star
          // on favorited channels (the toggle already persists; only the
          // indicator was missing).
          if (ch.favorite)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.star, size: 14, color: Colors.amber),
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
                    // finding 77: absorb this tab's own channelsGen bump so the
                    // self-initiated toggle (already reflected by the reload
                    // below) doesn't trigger a redundant full _init on the next
                    // reloadGuide re-entry.
                    _channelsGenSeen = Sql.channelsGen;
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
    // fix605: in categories mode NO channels are listed (the rail shows
    // categories), so the EPG grid must be EMPTY — not the preloaded Favorites
    // programmes, which read as "a guide for a category that isn't open". The
    // grid populates only once a category is opened (channels mode).
    if (_railMode == RailMode.categories) {
      return Center(
        child: Text('Open a category to see its guide',
            style: TextStyle(color: Colors.grey.shade500)),
      );
    }
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
            'NOW   ${onNow.title}   ·   ends ${_fmtEpoch(onNow.stopUtc)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
        if (next != null)
          Text(
            'NEXT   ${next.title}   ·   ${_fmtEpoch(next.startUtc)}',
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

  // fix510/597: a channel tile in the rail gained focus → highlight + scroll
  // its grid row, update the preview/info, and arm the dwell. Guarded to
  // channels mode so a stale focus event can't drive the preview while browsing
  // categories (the preview stays on the last-watched channel there).
  Future<void> _onChannelFocused(Channel ch) async {
    if (_railMode != RailMode.channels) return;
    final seq = ++_focusSeq;
    final prev = _focused;
    if (mounted) setState(() => _focused = ch);
    // fix603 (#15): no explicit grid scroll here — the rail auto-scrolls on
    // D-pad focus (traversal ensureVisible) and the grid mirrors it
    // (_syncGridToRail), so the rows stay aligned without a second animation
    // fighting the mirror.
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
  /// fix544: a full rebuild MUST re-run _init() (not just _loadGuide(null)):
  /// _loadGuide reuses the cached _sourceIds/_groups, so after the user disabled
  /// ALL sources reloadGuide re-queried with the STALE enabled-source list. So
  /// _init() re-reads getEnabledSourcesMinimal(), rebuilds the rail, and loads.
  ///
  /// fix610: REMEMBER the user's place. reloadGuide existed only to pick up a
  /// changed enabled-source set, but it unconditionally re-ran _init() — which
  /// reset the guide to the top (Favorites / category list) EVERY time the user
  /// returned to Live TV, losing the category/channels view they were on. Now it
  /// rebuilds+resets ONLY when the enabled sources actually changed; otherwise
  /// (the common tab-switch case) it keeps the kept-alive state and just restores
  /// focus to where the user was (mirrors the fix598/599 focus discipline).
  Future<void> reloadGuide() async {
    final enabled = await Sql.getEnabledSourcesMinimal();
    final ids = enabled.map((e) => e.id).whereType<int>().toList()..sort();
    final current = [..._sourceIds]..sort();
    if (!mounted) return;
    // fix645: also rebuild when categories changed (enable/disable/favorite in
    // the Categories tab or the phone Home) — the source-set check alone left
    // the rail stale after category toggles.
    if (!_ready ||
        ids.join(',') != current.join(',') ||
        _groupsGenSeen != Sql.groupsGen ||
        _channelsGenSeen != Sql.channelsGen) {
      // finding 77: rebuild when a channel's favorite changed from another tab.
      return _init(); // first load, sources changed, or categories changed
    }
    // Enabled sources unchanged → keep the user's place. fix610: but STILL
    // re-anchor the EPG window to NOW + refresh the grid programmes — the guide
    // is kept alive in the IndexedStack, so without this the window goes stale
    // across tab switches / next-day resumes (the fix541 bug). _reloadGridProgrammes
    // re-anchors _windowStart/_windowEnd and rebuilds _progByKey while leaving
    // channels / focus / rail mode untouched (no-ops if no channels are loaded).
    unawaited(_reloadGridProgrammes());
    // Restore focus to the focused channel (channels mode) or the selected
    // category (categories mode).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final fid = _focused?.id;
      if (_railMode == RailMode.channels && fid != null) {
        _channelNodes[fid]?.requestFocus();
      } else {
        (_railNodes[_selectedGroupId] ?? _railNodes[null])?.requestFocus();
      }
    });
  }

  // fix604 (#5): all guide/EPG times go through the shared guideClockFmt()
  // (settings_service) so the 12/24-hour choice is consistent across the Live
  // guide, now/next strip, schedule, and player label.
  String _fmtEpoch(int epochSecs) => guideClockFmt()
      .format(DateTime.fromMillisecondsSinceEpoch(epochSecs * 1000).toLocal());

  // fix604 (#4): the timeline now shows the CURRENT time at the left edge and
  // then labels snapped to clean :00/:30 boundaries, each POSITIONED at the time
  // it represents (same _x() mapping as the grid blocks) — instead of the old
  // now / now+1h / now+2h ticks that read "21:38, 22:38, 23:38". Horizontal pad
  // matches _gridRow's so a label sits above its programmes.
  Widget _timeHeader() {
    // fix605: no timeline in categories mode — the grid below is empty until a
    // category is opened, so a floating set of times reads as misleading.
    if (_railMode == RailMode.categories) return const SizedBox(height: 16);
    const tickStyle = TextStyle(fontSize: 11, color: Colors.grey);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
      child: SizedBox(
        height: 16,
        child: LayoutBuilder(builder: (context, c) {
          final width = c.maxWidth;
          final labels = <Widget>[
            // current time, pinned to the left edge.
            Positioned(
              left: 0,
              top: 0,
              child: Text(_fmtEpoch(_windowStart),
                  style: tickStyle.copyWith(
                      color: Colors.white70, fontWeight: FontWeight.w600)),
            ),
          ];
          const step = 1800; // 30-minute boundaries
          // first :00/:30 mark strictly after the window start.
          for (var b = ((_windowStart ~/ step) + 1) * step;
              b <= _windowEnd;
              b += step) {
            final x = _x(b, width);
            // skip a boundary that would overlap the left "now" label, or run
            // off the right edge (fix604: the label grows rightward from x, so a
            // near-edge tick would be clipped by the Stack's hard edge).
            if (x < 44 || x > width - 44) continue;
            labels.add(Positioned(
              left: x,
              top: 0,
              child: Text(_fmtEpoch(b), style: tickStyle),
            ));
          }
          return Stack(clipBehavior: Clip.hardEdge, children: labels);
        }),
      ),
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
          // finding 75: passive grid — exclude programme blocks from D-pad focus
          // traversal so RIGHT from a rail channel never lands inside the grid.
          // onTap still works for touch builds (a tap needs no focus).
          child: ExcludeFocus(
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

/// Small D-pad-friendly tile with an accent focus ring (matches the app's TV
/// focus standard — fix701-704 token language) used by the rail + the frozen
/// channel column. fix704: ring color is the app accent (AccentScope, default
/// white) instead of the old flat yellow, consistent with the tab bar (fix702)
/// and channel/poster tiles (fix703).
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
  // fix603 (#6): held-OK detection. Bound to the caller-supplied node's
  // onKeyEvent so it pre-empts InkWell's ActivateIntent (which would otherwise
  // fire onTap on key-DOWN). Rewritten from fix600/602 to fix two reported bugs:
  //  • _selectDown guards against a stray KeyUp with NO matching KeyDown on THIS
  //    tile — the OK that selects a CATEGORY releases AFTER focus has moved to
  //    the first channel, and without this guard that orphan KeyUp fired onTap
  //    and auto-PLAYED the channel on every category-enter.
  //  • The menu now opens on RELEASE (not mid-hold): opening it mid-hold moved
  //    focus to the modal while OK was still held, so the release/repeats leaked
  //    into the menu ("flashes menu then plays" + play/pause cycling). The timer
  //    only MARKS the hold as long enough; the KeyUp decides menu-vs-play.
  Timer? _selectHoldTimer;
  bool _selectDown = false;
  bool _heldLong = false;
  static const Duration _selectHoldDelay = Duration(milliseconds: 600);

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
        // A KeyDown always starts a fresh gesture ON this tile.
        _selectDown = true;
        _heldLong = false;
        _selectHoldTimer?.cancel();
        _selectHoldTimer = Timer(_selectHoldDelay, () {
          // Only mark the hold long enough — do NOT open the menu yet (that
          // would move focus to the modal mid-hold and leak the held key).
          if (mounted && n.hasFocus) _heldLong = true;
        });
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        _selectHoldTimer?.cancel();
        _selectHoldTimer = null;
        // Ignore an orphan KeyUp (no KeyDown on this tile) — e.g. the OK that
        // entered the category, releasing after focus moved here. This is what
        // caused the auto-play-on-enter bug. (Consequence, by design: a single
        // OK held THROUGH category-enter can't open the first channel's menu —
        // that hold belonged to the category-enter gesture; release and re-hold.)
        if (!_selectDown) return KeyEventResult.handled;
        _selectDown = false;
        final long = _heldLong;
        _heldLong = false;
        if (long) {
          widget.onLongPress?.call(); // open the menu on release
        } else {
          widget.onTap(); // quick press → play/activate
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled; // swallow repeats; the timer marks the hold
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
                // fix704: accent ring (default white) at draw time, not flat
                // yellow — matches tab bar (fix702) + tiles (fix703). Width 3
                // kept: the 56px itemExtent chrome budget (see below) is unchanged.
                color: _focused ? AccentScope.of(context) : Colors.transparent,
                width: 3,
              ),
            ),
            // fix603 (#15): vertical 8→4 so a 2-line channel name + chrome fits
            // inside the channel rail's hard 56px itemExtent box (added for grid
            // alignment) without a RenderFlex overflow. 18px chrome leaves a
            // ~38px content budget (2-line fontSize-12 ≈ 28px).
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
