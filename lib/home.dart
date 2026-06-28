import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/background_task_service.dart';
import 'package:open_tv/backend/channel_search_cache.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/search_query_gate.dart';
import 'package:open_tv/backend/stream_scanner.dart';
import 'package:open_tv/models/multi_view_layout.dart';
import 'package:open_tv/multi_view_screen.dart';
import 'package:open_tv/player/overlay_player_controller.dart';
import 'package:open_tv/bottom_nav.dart';
import 'package:open_tv/channel_tile.dart';
import 'package:open_tv/loading.dart';
import 'package:open_tv/widgets/dpad_text_field.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/no_push_animation_material_page_route.dart';
import 'package:open_tv/models/node.dart';
import 'package:open_tv/models/node_type.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/whats_new_modal.dart';
import 'package:open_tv/widgets/sources_refresh_dialog.dart';

class Home extends StatefulWidget {
  final HomeManager home;
  final bool refresh;
  final bool firstLaunch;
  final bool hasTouchScreen;
  const Home({
    super.key,
    required this.home,
    this.refresh = false,
    this.firstLaunch = false,
    this.hasTouchScreen = true,
  });
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  /// fix196: sourceId -> tag color (ARGB int or null).
  Map<int, int?> _sourceColors = {};
  Timer? _debounce;
  // keystroke rate with perceived search latency. Reset whenever the
  // debounce actually fires (i.e. user has stopped typing).
  DateTime? _firstKeystrokeAt;
  DateTime? _lastKeystrokeAt;
  int _keystrokeCountInBurst = 0;
  int _searchInvocation = 0; // monotonic; correlates debounce → SQL → setState lines
  bool reachedMax = false;
  List<Channel> channels = [];
  late final TextEditingController searchController =
      TextEditingController(text: widget.home.filters.query ?? '');
  final ScrollController _scrollController = ScrollController();
  bool isLoading = false;
  bool blockSettings = false;
  bool scrolledDeepEnough = false;

  // Disables the search TextField so the user doesn't get empty results
  // before the cache is ready.
  bool _searchReady = true;

  // Stream scanner state
  bool _isScanning = false;
  bool _scanCancelled = false;
  final ValueNotifier<({int done, int total})> _scanProgress =
      ValueNotifier(const (done: 0, total: 0));

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollListener);
    initializeAsync();
  }

  // fix124: fix120.1's RouteAware/didPopNext can NEVER fire — Home is
  // MaterialApp.home (the root route) and a RouteObserver does not deliver
  // didPopNext to the root route (confirmed: zero occurrences in the
  // 1.22.8+122 log). Instead, repaint Home when the overlay controller
  // signals the full-screen player was torn down (unregisterMain), which
  // fires exactly when the Player exits and Home is revealed.
  bool _overlayListenerAttached = false;

  void _onOverlayChanged() {
    // When no full-screen player and no mini is active, Home is the visible
    // surface again — force a repaint so the compositor re-rasterises Home
    // rather than retaining the popped Player's black layer.
    if (!mounted) return;
    AppLog.info('Home: overlay changed — forcing repaint of revealed Home');
    setState(() {});
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_overlayListenerAttached) {
      OverlayPlayerController.instance.addListener(_onOverlayChanged);
      _overlayListenerAttached = true;
    }
  }

  Future<void> initializeAsync() async {
    // First-launch only: rotate the debug log so each new version starts with
    // a clean slate. Idempotent — only fires the very first time the app
    // boots on a given build number.
    if (widget.firstLaunch) {
      await SettingsService.maybeRotateLogOnVersionChange();
      if (!mounted) return;
    }

    // fix200: load the source tag-color map on EVERY Home init, not only when
    // filters are fresh. Tab switches (Live/Favorites/History) rebuild Home but
    // carry sourceIds forward (see updateViewMode), so the old placement inside
    // the `sourceIds == null` guard ran only when arriving from Settings — which
    // is why colors appeared from Settings but vanished on Live→Favorites.
    final fullSources = await Sql.getSources();
    _sourceColors = {
      for (final s in fullSources)
        if (s.id != null) s.id!: s.color,
    };
    if (!mounted) return;

    if (widget.home.filters.sourceIds == null) {
      final sources = await Sql.getEnabledSourcesMinimal();
      if (!mounted) return;
      widget.home.filters.sourceIds = sources.map((x) => x.id).toList();
    }
    // fix524 (safe-mode TV leak): sync safeMode/searchMethod from settings even
    // when mediaTypes is pre-populated. The TV tabs and the _setNode drill-in
    // pushes set mediaTypes, which previously skipped this whole block → safeMode
    // stayed at the Filters default (false). Only the mediaTypes fallback stays
    // gated on null.
    {
      final s =
          SettingsService.cached ?? await SettingsService.getSettings();
      if (!mounted) return;
      widget.home.filters.safeMode = s.safeMode;
      widget.home.filters.searchMethod = s.searchMethod;
      if (widget.home.filters.mediaTypes == null) {
        widget.home.filters.mediaTypes = s.getMediaTypes();
      }
    }

    final versionFuture = widget.firstLaunch
        ? SettingsService.shouldShowWhatsNew()
        : Future<String?>.value(null);

    await load();

    // fix128: start the cache build WITHOUT awaiting it so the What's New
    // dialog can show immediately. The user reads release notes while the
    // cache builds in the background. We await the cache future AFTER the
    // dialog closes (or if there's no dialog, inline as before).
    Future<void>? cacheFuture;
    final cachedSettings = SettingsService.cached;
    if (cachedSettings != null &&
        cachedSettings.searchMethod == SearchMethod.inMemory &&
        ChannelSearchCache.needsRebuild()) {
      if (mounted) setState(() => _searchReady = false);
      cacheFuture = ChannelSearchCache.ensureBuilt();
    }

    // Show What's New while the cache builds (if needed).
    final version = await versionFuture;
    if (!mounted) return;
    if (version != null) {
      await showWhatsNew(version);
    }

    // Now wait for the cache to finish (no-op if not needed or already done).
    if (cacheFuture != null && mounted && !_searchReady) {
      // fix382 (cold-eyes MED-1): a cache-build failure must NOT strand the
      // search field disabled. _searchReady was re-enabled only on the success
      // path, so a throw from ensureBuilt()/rebuild() left the TextField greyed
      // out for the life of this Home with no recovery. Re-enable in finally;
      // Sql.search already tolerates an unbuilt cache (falls back to SQL).
      try {
        await cacheFuture;
        AppLog.info('Home: ChannelSearchCache warmup completed');
      } catch (e) {
        AppLog.warn('Home: ChannelSearchCache warmup failed — $e');
      } finally {
        if (mounted) setState(() => _searchReady = true);
      }
    }

    if (!mounted || !widget.refresh) return;
    // Show the same progress dialog used by the backup import flow.
    // Previously this ran behind tryAsyncNoLoading with no visible
    // feedback — the user saw an empty grid for up to 60 seconds with
    if (mounted) setState(() => blockSettings = true);
    await showSourcesRefreshDialog(context);
    if (mounted) {
      setState(() => blockSettings = false);
      await load(false);
    }
  }

  Future<void> showWhatsNew(String version) async {
    if (!mounted) return;
    // fix338: guarantee the once-per-version log/metrics rotation has run
    // before the What's New dialog appears. The rotation and the What's New
    // trigger track different settings keys (lastLogClearedVersion vs
    // lastSeenVersion) and previously fired independently under firstLaunch,
    // so a path that showed What's New without rotating would leave the prior
    // version's log in place. This makes "new-version screen shown" and
    // "log cleared for this version" inseparable. Idempotent — a no-op if it
    // already ran this version.
    await SettingsService.maybeRotateLogOnVersionChange();
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) => WhatsNewModal(version: version),
    );
  }

  void scrollToTop() {
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 500),
      curve: Curves.easeInOut,
    );
  }

  Future<void> load([bool more = false]) async {
    // changes made in the Settings screen take effect without a restart.
    // fix524 (safe-mode TV leak): always resolve a non-null Settings so safeMode
    // is set before every query. The old cached-only guard left safeMode at the
    // Filters default (false) on a cold cache — leaking adult content in the TV
    // Favorites/History tabs (which pre-populate mediaTypes and so skipped the
    // initState-time sync below).
    final liveSettings =
        SettingsService.cached ?? await SettingsService.getSettings();
    if (!mounted) return;
    widget.home.filters.searchMethod = liveSettings.searchMethod;
    widget.home.filters.safeMode = liveSettings.safeMode;

    if (more) {
      widget.home.filters.page++;
    } else {
      widget.home.filters.page = 1;
    }

    // concurrent load() that modifies widget.home.filters.page (or any
    // other field) mid-flight doesn't corrupt the query we're about to run.
    final snapshot = widget.home.filters.copy();

    // keystroke / debounce / SQL / setState lines can be correlated.
    final inv = ++_searchInvocation;
    final loadStart = DateTime.now();

    if (AppLog.enabled) {
      final f = snapshot;
      AppLog.info(
        'Home.load[$inv]: view=${viewTypeToString(f.viewType)} '
        'page=${f.page} more=$more '
        'sources=${f.sourceIds?.length ?? "null"} '
        'mediaTypes=${f.mediaTypes?.map((m) => m.name).join(",") ?? "null"} '
        'groupId=${f.groupId} seriesId=${f.seriesId} '
        'query=${f.query ?? "none"}',
      );
    }
    await Error.tryAsyncNoLoading(() async {
      final searchStart = DateTime.now();
      final results =
          await Sql.search(snapshot, invocation: inv);
      final searchElapsed =
          DateTime.now().difference(searchStart).inMilliseconds;
      if (AppLog.enabled) {
        AppLog.info(
          'Home.load[$inv]: got ${results.length} results in ${searchElapsed}ms'
          ' for ${viewTypeToString(snapshot.viewType)}',
        );
      }
      if (!mounted) return;

      // Drop late results from a superseded query. If a newer load()
      // has started, don't clobber its results with ours — including
      // append out-of-order to a newer search's result list).
      if (inv != _searchInvocation) {
        if (AppLog.enabled) {
          AppLog.info(
            'Home.load[$inv]: SUPERSEDED — current=$_searchInvocation,'
            ' dropping ${results.length} stale results (more=$more)',
          );
        }
        return;
      }

      final setStateStart = DateTime.now();
      // Replacing `channels` with a new list causes SliverGrid to
      // rebuild and ScrollController to reset to offset 0. Save and
      // restore the offset so a favorite toggle or filter change
      // doesn't jump the user back to the top.
      final savedOffset = (!more && _scrollController.hasClients)
          ? _scrollController.offset
          : null;
      setState(() {
        if (!more) {
          channels = results;
        } else {
          channels.addAll(results);
        }
        reachedMax = results.length < pageSize;
      });
      if (savedOffset != null && _scrollController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            final maxExtent = _scrollController.position.maxScrollExtent;
            _scrollController.jumpTo(savedOffset.clamp(0.0, maxExtent));
          }
        });
      }

      if (AppLog.enabled) {
        // Use a post-frame callback to measure the time from setState
        // to the first frame after the new tiles are actually painted.
        // This catches any heavy work in build/layout/paint that the
        // user perceives as "search is slow."
        final setStateSync =
            DateTime.now().difference(setStateStart).inMilliseconds;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final totalElapsed =
              DateTime.now().difference(loadStart).inMilliseconds;
          AppLog.info(
            'Home.load[$inv]: rendered'
            ' setState=${setStateSync}ms'
            ' total=${totalElapsed}ms'
            ' (search=${searchElapsed}ms,'
            ' rest=${totalElapsed - searchElapsed}ms)',
          );
        });
      }
    }, context);
  }

  @override
  void dispose() {
    // fix124: detach the overlay-controller repaint listener (replaces
    // fix120's dead RouteAware unsubscribe).
    if (_overlayListenerAttached) {
      OverlayPlayerController.instance.removeListener(_onOverlayChanged);
      _overlayListenerAttached = false;
    }
    _scrollController.dispose();
    searchController.dispose();
    _debounce?.cancel();
    _scanProgress.dispose();
    super.dispose();
  }

  Future<void> _openMultiView(MultiViewLayout layout) async {
    final settings =
        SettingsService.cached ?? await SettingsService.getSettings();
    final sourceIds = widget.home.filters.sourceIds;
    if (!mounted || sourceIds == null || sourceIds.isEmpty) return;
    // Close any active mini-player before entering multi-view — the overlay
    // widget renders above all routes and would float on top of the grid.
    await OverlayPlayerController.instance.stopOverlay();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MultiViewScreen(
          layout: layout,
          settings: settings,
          source: null,
          sourceIds: sourceIds,
        ),
      ),
    );
  }

  Future<void> _startScan() async {
    if (_isScanning || channels.isEmpty) return;

    final settings =
        SettingsService.cached ?? await SettingsService.getSettings();
    if (!mounted) return;

    final maxCount = settings.streamScanMaxCount.clamp(1, 100);
    final timeout = Duration(
      seconds: settings.streamScanTimeoutSecs.clamp(3, 60),
    );
    // fix305: begin scanning at the first on-screen tile. The grid row pitch is
    // mainAxisExtent(100) + mainAxisSpacing(12) = 112, after a 5px top padding
    // (SliverPadding fromLTRB(10,5,10,10)). fix304 used 100 and no padding, so
    // the computed row ran ahead of the real first-visible tile.
    final width = MediaQuery.of(context).size.width;
    final cols = (width / 350).floor().clamp(1, 3);
    var startIndex = 0;
    if (_scrollController.hasClients) {
      const topPad = 5.0;
      const rowPitch = 112.0; // 100 extent + 12 spacing
      final row = ((_scrollController.offset - topPad) / rowPitch)
          .floor()
          .clamp(0, 1 << 30);
      startIndex = (row * cols).clamp(0, channels.length - 1);
    }
    final scanList = channels.sublist(startIndex);
    final initialTotal = scanList.length.clamp(1, maxCount);

    // Clear prior results so the new scan is authoritative.
    StreamScanner.clearResults();
    _scanCancelled = false;
    _scanProgress.value = (done: 0, total: initialTotal);
    setState(() => _isScanning = true);

    // Show progress dialog with a cancel button. Uses a ValueListenableBuilder
    // so progress updates regardless of whether the parent state rebuilds.
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dCtx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.radar),
            SizedBox(width: 8),
            Text('Scanning streams…'),
          ],
        ),
        content: ValueListenableBuilder<({int done, int total})>(
          valueListenable: _scanProgress,
          builder: (_, progress, _) {
            final pct = progress.total > 0
                ? progress.done / progress.total
                : null;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(value: pct),
                const SizedBox(height: 12),
                Text('${progress.done} / ${progress.total} streams tested'),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () {
              _scanCancelled = true;
              Navigator.of(dCtx).pop();
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    // fix349: when background processing is enabled, keep the scan alive via
    // a foreground service if the user switches away (same pattern as the
    // fix318 source refresh). Work stays on the main isolate.
    await BackgroundTaskService.run<void>(
      enabled: settings.backgroundProcessing,
      title: 'Scanning streams',
      work: (update) => StreamScanner.scan(
        channels: scanList,
        maxChannels: maxCount,
        timeout: timeout,
        isCancelled: () => _scanCancelled,
        onProgress: (done, total) {
          _scanProgress.value = (done: done, total: total);
          // Trigger a parent rebuild so green outlines on tiles refresh as
          // each result lands.
          if (mounted) setState(() {});
          update('$done / $total streams tested');
        },
      ),
    );

    if (mounted) {
      if (!_scanCancelled) Navigator.of(context, rootNavigator: true).pop();
      // fix306: copy the freshly-persisted validation results onto the
      // in-memory channel objects so the validated flag is reflected on every
      // scanned tile even after StreamScanner.results is later cleared. Done in
      // place — no reload, so the scroll position is preserved.
      for (final ch in channels) {
        final id = ch.id;
        if (id != null && StreamScanner.results.containsKey(id)) {
          ch.streamValidated = StreamScanner.results[id];
        }
      }
      setState(() => _isScanning = false);
    }
  }

  void _scrollListener() async {
    if (!_scrollController.hasClients) return;
    final bool shouldShow = _scrollController.offset > 200;

    if (mounted && scrolledDeepEnough != shouldShow) {
      setState(() => scrolledDeepEnough = shouldShow);
    }

    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent * 0.75 &&
        !isLoading &&
        !reachedMax) {
      if (mounted) setState(() => isLoading = true);
      await load(true);
      if (mounted) setState(() => isLoading = false);
    }
  }

  ViewType getStartingView() {
    if (widget.home.filters.groupId != null) {
      return ViewType.categories;
    }
    return widget.home.filters.viewType;
  }

  void updateViewMode(ViewType type) {
    if (AppLog.enabled) {
      final f = widget.home.filters;
      AppLog.info(
        'Home: switching view → ${viewTypeToString(type)} '
        '| sources=${f.sourceIds?.length ?? "null"} '
        '| mediaTypes=${f.mediaTypes?.map((m) => m.name).join(",") ?? "null"} '
        '| groupId=${f.groupId} '
        '| query=${f.query ?? "none"}',
      );
    }
    Navigator.of(context).pushAndRemoveUntil(
      NoPushAnimationMaterialPageRoute(
        builder: (context) => Home(
          home: HomeManager(
            filters: Filters(
              viewType: type,
              mediaTypes: widget.home.filters.mediaTypes,
              sourceIds: widget.home.filters.sourceIds,
              safeMode: widget.home.filters.safeMode,
              searchMethod: widget.home.filters.searchMethod,
            ),
          ),
        ),
      ),
      (route) => false,
    );
  }

  // fix278: Select All / Unselect All for categories. Updates every category
  // for the current sources + media types, then reloads the grid.
  Future<void> _setAllCategories(bool enabled) async {
    // fix389: route through setAllGroupsEnabledForSearch. When a search query is
    // active it toggles exactly the matching categories across every page (the
    // same set the grid shows); with no query it delegates internally to the
    // unfiltered setAllGroupsEnabled. No dispatch branch lives here.
    await Sql.setAllGroupsEnabledForSearch(widget.home.filters, enabled);
    await load(false);
  }

  // fix308: open the Categories list filtered to [categoryName]. Pushes a fresh
  // Categories-view Home with the search box pre-filled, so the tapped
  // category surfaces at the top of the list (reusing existing search + the
  // favorite-first sort). No fragile scroll-to-index needed.
  void _openCategoryByName(String categoryName) {
    final home = HomeManager(
      filters: Filters(
        viewType: ViewType.categories,
        query: categoryName,
        mediaTypes: widget.home.filters.mediaTypes,
        sourceIds: widget.home.filters.sourceIds,
        safeMode: widget.home.filters.safeMode,
        searchMethod: widget.home.filters.searchMethod,
      ),
    );
    Navigator.of(context).push(
      NoPushAnimationMaterialPageRoute(builder: (context) => Home(home: home)),
    );
  }

  void setNode(Node node) {
    final home = HomeManager(
      node: node,
      filters: Filters(
        viewType: ViewType.all,
        mediaTypes: widget.home.filters.mediaTypes,
        sourceIds: widget.home.filters.sourceIds,
        safeMode: widget.home.filters.safeMode,
        searchMethod: widget.home.filters.searchMethod,
      ),
    );
    if (widget.home.filters.groupId != null) {
      home.filters.groupId = widget.home.filters.groupId;
    } else if (node.type == NodeType.category) {
      home.filters.groupId = node.id;
    }
    if (node.type == NodeType.series) home.filters.seriesId = node.id;
    Navigator.of(context).push(
      NoPushAnimationMaterialPageRoute(builder: (context) => Home(home: home)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.home.node != null
          ? AppBar(
              title: Text(widget.home.node.toString()),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              ),
            )
          : null,
      body: Loading(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final double width = constraints.maxWidth;
              final int crossAxisCount = (width / 350).floor().clamp(1, 3);
              return Column(
                children: [
                  // fix304: search bar + radar/multi-view icons pinned
                  // above the scrolling grid instead of scrolling away.
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(
                          child: DpadTextField(
                            style: TextStyle(
                              fontSize: Theme.of(
                                context,
                              ).textTheme.titleMedium?.fontSize ?? 16,
                            ),
                            controller: searchController,
                            enabled: _searchReady,
                            onChanged: (query) {
                              // relative to the burst so we can see how long the
                              // user has been typing before the debounce fires,
                              // and how stale the on-screen results are.
                              final now = DateTime.now();
                              if (AppLog.enabled) {
                                final firstAt = _firstKeystrokeAt ??= now;
                                final sinceFirst =
                                    now.difference(firstAt).inMilliseconds;
                                final sincePrev = _lastKeystrokeAt == null
                                    ? 0
                                    : now
                                        .difference(_lastKeystrokeAt!)
                                        .inMilliseconds;
                                _keystrokeCountInBurst++;
                                AppLog.info(
                                  'Search.keystroke: chars=${query.length}'
                                  ' burst=$_keystrokeCountInBurst'
                                  ' sinceFirst=${sinceFirst}ms'
                                  ' sincePrev=${sincePrev}ms'
                                  ' query="$query"',
                                );
                              }
                              _lastKeystrokeAt = now;

                              _debounce?.cancel();
                              // that a fast typist sees results update mid-word;
                              // long enough that a single typing burst doesn't
                              // fire ~4 queries per character.
                              final scheduledFor = now.add(
                                const Duration(milliseconds: 200),
                              );
                              _debounce = Timer(
                                const Duration(milliseconds: 200),
                                () {
                                  if (!mounted) return;
                                  if (AppLog.enabled) {
                                    final firedAt = DateTime.now();
                                    final scheduledLatency = firedAt
                                        .difference(scheduledFor)
                                        .inMilliseconds;
                                    final burstDuration =
                                        _firstKeystrokeAt == null
                                            ? 0
                                            : firedAt
                                                .difference(_firstKeystrokeAt!)
                                                .inMilliseconds;
                                    AppLog.info(
                                      'Search.debounce-fired:'
                                      ' keystrokes=$_keystrokeCountInBurst'
                                      ' burstDuration=${burstDuration}ms'
                                      ' scheduledLatency=${scheduledLatency}ms'
                                      ' query="$query"',
                                    );
                                  }
                                  // Reset burst tracking now that we're firing.
                                  _firstKeystrokeAt = null;
                                  _keystrokeCountInBurst = 0;
                                  // fix400: a single typed character triggers a
                                  // full-catalogue substring scan that's always
                                  // superseded by the next keystroke — skip it.
                                  // ≥2 chars search; 1 char leaves the current
                                  // list; empty restores the full browse.
                                  if (!searchQueryShouldLoad(query)) return;
                                  widget.home.filters.query = query;
                                  load(false);
                                },
                              );
                            },
                            decoration: InputDecoration(
                              hintText: _searchReady
                                  ? 'Search…'
                                  : 'Preparing search…',
                              hintStyle: TextStyle(
                                fontSize: Theme.of(
                                  context,
                                ).textTheme.titleMedium?.fontSize ?? 16,
                              ),
                              prefixIcon: const Icon(Icons.search),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide.none,
                              ),
                              // suffixIcon removed — keyword vs phrase mode
                              // is now controlled by the search method
                              filled: true,
                            ),
                          ),
                        ),
                        // Radar scan button — only shown when there are
                        // channels visible (active search or normal listing).
                        if (channels.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Tooltip(
                              message: 'Scan stream validity',
                              child: IconButton.filled(
                                icon: const Icon(Icons.radar),
                                onPressed:
                                    _isScanning ? null : _startScan,
                              ),
                            ),
                          ),
                        // Multi-view button — only shown when a layout is
                        // selected in Settings.
                        Builder(builder: (context) {
                          final mvLayout = (SettingsService.cached
                                      ?.multiViewLayout ??
                                  MultiViewLayout.none);
                          if (mvLayout == MultiViewLayout.none) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Tooltip(
                              message: 'Multi-view',
                              child: IconButton.filled(
                                icon: const Icon(Icons.grid_view),
                                onPressed: () =>
                                    _openMultiView(mvLayout),
                              ),
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                  Expanded(
                    child: CustomScrollView(
                      controller: _scrollController,
                      slivers: [
                        // fix278: Select All / Unselect All for the Categories view.
                        if (widget.home.filters.viewType == ViewType.categories &&
                            channels.isNotEmpty)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 0, 16, 4),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  TextButton.icon(
                                    icon: const Icon(Icons.check_box_outlined,
                                        size: 18),
                                    label: const Text('Select all'),
                                    onPressed: () => _setAllCategories(true),
                                  ),
                                  const SizedBox(width: 8),
                                  TextButton.icon(
                                    icon: const Icon(
                                        Icons.check_box_outline_blank, size: 18),
                                    label: const Text('Unselect all'),
                                    onPressed: () => _setAllCategories(false),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (channels.isEmpty)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(32),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      (widget.home.filters.query?.isNotEmpty == true)
                                          ? Icons.search_off
                                          : Icons.tv_off,
                                      size: 48,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withAlpha(80),
                                    ),
                                    const SizedBox(height: 16),
                                    Text(
                                      (widget.home.filters.query?.isNotEmpty == true)
                                          ? 'No results found'
                                          : 'No channels available',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withAlpha(128),
                                          ),
                                    ),
                                    if (widget.home.filters.query?.isNotEmpty == true)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: Text(
                                          'Try a shorter or different search term',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurface
                                                    .withAlpha(100),
                                              ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          )
                        else
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(10, 5, 10, 10),
                            sliver: SliverGrid(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  final channel = channels[index];
                                  final isHistory = widget.home.filters.viewType ==
                                      ViewType.history;
                                  return ChannelTile(
                                    key: ValueKey(
                                      'ch-${channel.id ?? channel.name}-$index',
                                    ),
                                    channel: channel,
                                    tintColor: _sourceColors[channel.sourceId],
                                    // fix501: TV-only source edge bar + yellow
                                    // focus ring; phone passes false (unchanged).
                                    showSourceEdgeBar: !widget.hasTouchScreen,
                                    parentContext: context,
                                    setNode: setNode,
                                    isHistory: isHistory,
                                    // fix584 (#6): long-press → Multi-view for
                                    // live channels (uses this view's sourceIds).
                                    onOpenMultiView: (ch) async {
                                      final s = SettingsService.cached ??
                                          await SettingsService.getSettings();
                                      if (!context.mounted) return;
                                      await MultiViewScreen.openWithChannel(
                                        context,
                                        s,
                                        widget.home.filters.sourceIds ??
                                            const [],
                                        ch,
                                      );
                                    },
                                    autofocus: index == 0,
                                    // fix397: hand the tile the full result list
                                    // + its position so full-screen playback can
                                    // surf channel +/- through this same list.
                                    playlist: channels,
                                    playlistIndex: index,
                                    onRemoveHistory:
                                        isHistory ? () => load(false) : null,
                                    // fix278: category tiles get an enable checkbox.
                                    onToggleEnabled: channel.mediaType ==
                                                MediaType.group &&
                                            channel.id != null
                                        ? (enabled) async {
                                            await Sql.setGroupEnabled(
                                                channel.id!, enabled);
                                            setState(() =>
                                                channel.groupEnabled = enabled);
                                          }
                                        : null,
                                    // fix308: long-press a category tile to
                                    // favorite it (sorts to top of Categories).
                                    onFavoriteGroup: channel.mediaType ==
                                                MediaType.group &&
                                            channel.id != null
                                        ? (favorite) async {
                                            await Sql.favoriteGroup(
                                                channel.id!, favorite);
                                            channel.favorite = favorite;
                                            await load(false);
                                          }
                                        : null,
                                    // fix308: tap the category name in a
                                    // channel's long-press menu to open the
                                    // Categories list filtered to it.
                                    onOpenCategory: _openCategoryByName,
                                  );
                                },
                                childCount: channels.length,
                                addRepaintBoundaries: true,
                              ),
                              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: crossAxisCount,
                                mainAxisExtent: 100,
                                mainAxisSpacing: 12,
                                crossAxisSpacing: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
      bottomNavigationBar: widget.hasTouchScreen
          ? BottomNav(
              startingView: getStartingView(),
              blockSettings: blockSettings,
              updateViewMode: updateViewMode,
              settings: SettingsService.cached ?? Settings(),
              contentTypeFilter:
                  SettingsService.cached?.contentTypeFilter ??
                  ContentTypeFilter.all,
              onContentTypeChanged: (filter) async {
                final s = SettingsService.cached;
                if (s == null) return;
                // Update in-memory state immediately so getMediaTypes()
                // returns the correct filter before the DB write completes.
                s.contentTypeFilter = filter;
                if (!mounted) return;
                setState(() {
                  widget.home.filters.mediaTypes = s.getMediaTypes();
                });
                // Reload the channel list with the new filter immediately.
                await load(false);
                // Persist to DB after the UI has already updated.
                // User sees the new content without waiting for the write.
                if (mounted) await SettingsService.updateSettings(s);
              },
            )
          : null,
      floatingActionButton: IgnorePointer(
        ignoring: !scrolledDeepEnough,
        child: AnimatedOpacity(
          opacity: scrolledDeepEnough ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child: FloatingActionButton(
            onPressed: scrollToTop,
            shape: const CircleBorder(),
            tooltip: 'Scroll to Top',
            child: const Icon(Icons.arrow_upward),
          ),
        ),
      ),
    );
  }
}
