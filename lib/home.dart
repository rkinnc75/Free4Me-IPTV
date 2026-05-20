import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/utils.dart';
import 'package:open_tv/bottom_nav.dart';
import 'package:open_tv/channel_tile.dart';
import 'package:open_tv/loading.dart';
import 'package:open_tv/widgets/dpad_text_field.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/filters.dart';
import 'package:open_tv/models/home_manager.dart';
import 'package:open_tv/models/no_push_animation_material_page_route.dart';
import 'package:open_tv/models/node.dart';
import 'package:open_tv/models/node_type.dart';
import 'package:open_tv/models/view_type.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/whats_new_modal.dart';

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
  Timer? _debounce;
  bool reachedMax = false;
  final int pageSize = 36;
  List<Channel> channels = [];
  late final TextEditingController searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool isLoading = false;
  bool blockSettings = false;
  bool scrolledDeepEnough = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollListener);
    initializeAsync();
  }

  Future<void> initializeAsync() async {
    if (widget.home.filters.sourceIds == null) {
      final sources = await Sql.getEnabledSourcesMinimal();
      if (!mounted) return;
      widget.home.filters.sourceIds = sources.map((x) => x.id).toList();
    }
    if (widget.home.filters.mediaTypes == null) {
      final s =
          SettingsService.cached ?? await SettingsService.getSettings();
      if (!mounted) return;
      widget.home.filters.mediaTypes = s.getMediaTypes();
    }

    final versionFuture = widget.firstLaunch
        ? SettingsService.shouldShowWhatsNew()
        : Future<String?>.value(null);

    await load();

    final version = await versionFuture;
    if (!mounted) return;
    if (version != null) {
      await showWhatsNew(version);
    }

    if (!mounted || !widget.refresh) return;
    await Error.tryAsyncNoLoading(
      () async {
        if (mounted) {
          setState(() => blockSettings = true);
        }
        await Utils.refreshAllSources();
        if (mounted) await load(false);
      },
      context,
      true,
      "Refreshed all sources",
    );
    if (mounted) setState(() => blockSettings = false);
  }

  Future<void> showWhatsNew(String version) async {
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
    if (more) {
      widget.home.filters.page++;
    } else {
      widget.home.filters.page = 1;
    }
    if (AppLog.enabled) {
      final f = widget.home.filters;
      AppLog.info(
        'Home.load: view=${viewTypeToString(f.viewType)} '
        'page=${f.page} more=$more '
        'sources=${f.sourceIds?.length ?? "null"} '
        'mediaTypes=${f.mediaTypes?.map((m) => m.name).join(",") ?? "null"} '
        'groupId=${f.groupId} seriesId=${f.seriesId} '
        'query=${f.query ?? "none"}',
      );
    }
    await Error.tryAsyncNoLoading(() async {
      final results = await Sql.search(widget.home.filters);
      if (AppLog.enabled) {
        AppLog.info('Home.load: got ${results.length} results '
            'for ${viewTypeToString(widget.home.filters.viewType)}');
      }
      if (!mounted) return;
      setState(() {
        if (!more) {
          channels = results;
        } else {
          channels.addAll(results);
        }
        reachedMax = results.length < pageSize;
      });
    }, context);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    searchController.dispose();
    _debounce?.cancel();
    super.dispose();
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

  void clearSearch() {
    widget.home.filters.query = null;
    searchController.clear();
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
            ),
          ),
        ),
      ),
      (route) => false,
    );
  }

  void setNode(Node node) {
    final home = HomeManager(
      node: node,
      filters: Filters(
        viewType: ViewType.all,
        mediaTypes: widget.home.filters.mediaTypes,
        sourceIds: widget.home.filters.sourceIds,
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
              return CustomScrollView(
                controller: _scrollController,
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: DpadTextField(
                          style: TextStyle(
                            fontSize: Theme.of(
                              context,
                            ).textTheme.titleMedium?.fontSize!,
                          ),
                          controller: searchController,
                          onChanged: (query) {
                            _debounce?.cancel();
                            _debounce = Timer(
                              const Duration(milliseconds: 500),
                              () {
                                if (!mounted) return;
                                widget.home.filters.query = query;
                                load(false);
                              },
                            );
                          },
                          decoration: InputDecoration(
                            hintText: "Search...",
                            hintStyle: TextStyle(
                              fontSize: Theme.of(
                                context,
                              ).textTheme.titleMedium?.fontSize!,
                            ),
                            prefixIcon: const Icon(Icons.search),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide.none,
                            ),
                            suffixIcon: IconButton(
                              onPressed: () {
                                widget.home.filters.useKeywords =
                                    !widget.home.filters.useKeywords;
                                load(false);
                              },
                              icon: Icon(
                                widget.home.filters.useKeywords
                                    ? Icons.label
                                    : Icons.label_outline,
                              ),
                            ),
                            filled: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(10, 5, 10, 10),
                    sliver: SliverGrid(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final channel = channels[index];
                          return ChannelTile(
                            key: ValueKey(
                              'ch-${channel.id ?? channel.name}-$index',
                            ),
                            channel: channel,
                            parentContext: context,
                            setNode: setNode,
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
