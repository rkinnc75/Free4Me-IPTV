import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:open_tv/source_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/http_client.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/backend/stream_scanner.dart';
import 'package:open_tv/backend/xtream.dart';
import 'package:open_tv/memory.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/playback_playlist.dart';
import 'package:open_tv/error.dart';
import 'package:open_tv/models/media_type.dart';
import 'package:open_tv/models/node.dart';
import 'package:open_tv/models/node_type.dart';
import 'package:open_tv/player.dart';
import 'package:open_tv/player/overlay_player_controller.dart';
import 'package:open_tv/views/channel_schedule.dart';
import 'package:open_tv/widgets/now_next_strip.dart';

class ChannelTile extends StatefulWidget {
  /// Returns the pre-warmed URL for a channel if fresh, else null.
  static String? prewarmedUrl(int channelId) {
    final e = _ChannelTileState._prewarmCache[channelId];
    if (e == null) return null;
    if (e.expiresAt.isBefore(DateTime.now())) {
      _ChannelTileState._prewarmCache.remove(channelId);
      return null;
    }
    return e.url;
  }

  final Channel channel;
  final BuildContext parentContext;
  final Function(Node node) setNode;
  final VoidCallback? onFocusNavbar;
  /// fix558/559/563: when set, arrow-up on this tile calls this UNCONDITIONALLY
  /// instead of asking Flutter's directional traversal to find a target.
  /// (fix558 originally tried "only escape if focusInDirection finds nothing"
  /// — but Flutter's policy always finds SOME node by falling back to "closest
  /// on screen", so that check could never fire.) fix563 wires this for EVERY
  /// search tile — interior rows move to the node one row up, top rows cross
  /// to the previous section — so vertical navigation never depends on
  /// Flutter's directional traversal, which is unreliable across these stacked
  /// grids, and especially right after a programmatic focus jump
  /// (flutter/flutter#70364). Null = no override (every other ChannelTile
  /// caller is unchanged).
  final VoidCallback? onFocusUpEscape;
  /// fix558: lets a caller pin a stable FocusNode to a specific tile (e.g.
  /// "the last tile in this section") so another widget can target it
  /// directly via requestFocus(), bypassing directional traversal entirely.
  /// Null (the default, every other caller) = the tile creates its own
  /// internal node as before.
  final FocusNode? focusNode;
  /// When [isHistory] is true, the long-press sheet includes a
  /// "Remove from history" option. [onRemoveHistory] is called after the
  /// entry is deleted so the parent can refresh its list.
  final bool isHistory;
  final VoidCallback? onRemoveHistory;
  /// fix182: when true, this tile grabs focus on first build.
  final bool autofocus;
  /// fix196: source tag color (ARGB int; null = no tint).
  final int? tintColor;
  /// fix501: TV-only — draw a solid full-saturation source-color edge bar on
  /// the leading edge + a yellow D-pad focus ring. Default false so the phone
  /// (touch) UI is byte-for-byte unchanged.
  final bool showSourceEdgeBar;
  /// fix278: for category tiles — toggle the category's enabled flag. Null for
  /// non-category tiles.
  final Future<void> Function(bool enabled)? onToggleEnabled;

  /// fix308: for category tiles — toggle the category's favorite flag (sorts it
  /// to the top of the Categories list). Null for non-category tiles.
  final Future<void> Function(bool favorite)? onFavoriteGroup;

  /// fix308: tapping the category name in a channel's long-press menu opens the
  /// Categories list filtered to that category name. Null disables the tap.
  final void Function(String categoryName)? onOpenCategory;

  /// fix584 (#6): long-press → "Open in Multi-view" for a LIVE channel. The
  /// caller supplies a closure that opens MultiViewScreen with this channel
  /// pre-assigned to the first free cell (each call site threads its own
  /// settings/sourceIds — there is no shared opener). Null = entry hidden.
  final Future<void> Function(Channel channel)? onOpenMultiView;

  /// fix589 (#5): fired when this tile GAINS focus (D-pad dwell preview in the
  /// TV browse grid). Emitted from the existing focus listener — no extra
  /// listener. Null everywhere except the browse grid.
  final void Function(Channel channel)? onFocusGained;

  /// fix397: the full ordered list this tile belongs to + this tile's index,
  /// so full-screen playback can surf channel +/- through the same list. Null
  /// list = no surf context (single-channel launch).
  final List<Channel>? playlist;
  final int playlistIndex;

  /// fix508: TV-only — render a portrait poster card (cover image + title)
  /// instead of the landscape row. Default false so the phone (touch) UI is
  /// byte-for-byte unchanged. All play / drill-in / focus / long-press
  /// behaviour is identical; only the InkWell child's layout differs.
  final bool poster;

  /// fix529: TV Categories management mode. The card's PRIMARY select toggles
  /// the category's enabled flag (via [onToggleEnabled]) and a checkbox overlay
  /// shows the state, instead of navigating into the category. Default false so
  /// phone + other TV uses are unchanged.
  final bool categoryToggleMode;

  /// fix643: TV left-at-edge back. When [leftEdge] is true (this tile sits in
  /// the grid's leftmost column) a D-pad LEFT fires [onLeftEdgeBack] instead of
  /// directional traversal, so LEFT steps back one screen exactly like the Back
  /// button. KeyDown only (not repeats) — a held LEFT must not pop multiple
  /// levels. Both default off so phone + non-edge tiles are unchanged.
  final bool leftEdge;
  final VoidCallback? onLeftEdgeBack;

  const ChannelTile({
    super.key,
    required this.channel,
    required this.setNode,
    required this.parentContext,
    this.onFocusNavbar,
    this.onFocusUpEscape,
    this.focusNode,
    this.isHistory = false,
    this.onRemoveHistory,
    this.autofocus = false,
    this.tintColor,
    this.showSourceEdgeBar = false, // fix501: TV-only edge bar + yellow focus
    this.onToggleEnabled, // fix278: category tiles only
    this.onFavoriteGroup, // fix308: category tiles only
    this.onOpenCategory, // fix308: channel long-press category link
    this.onOpenMultiView, // fix584 (#6): long-press → Multi-view (live only)
    this.onFocusGained, // fix589 (#5): browse-grid dwell preview
    this.playlist, // fix397
    this.playlistIndex = 0, // fix397
    this.poster = false, // fix508: TV portrait poster layout
    this.categoryToggleMode = false, // fix529: TV category-toggle grid
    this.leftEdge = false, // fix643: leftmost-column tile (TV back-on-LEFT)
    this.onLeftEdgeBack, // fix643: fired on LEFT from a leftEdge tile
  });

  @override
  State<ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<ChannelTile> {
  // fix558: use the caller-supplied FocusNode when given (so it can be
  // targeted directly from outside), else create our own exactly as before.
  late final FocusNode _focusNode = widget.focusNode ?? FocusNode();
  late final bool _ownsFocusNode = widget.focusNode == null;

  // fix586 (#6): TV remotes cannot fire InkWell.onLongPress (it is a touch
  // gesture), so the context menu — and its "Open in Multi-view" entry — was
  // unreachable by D-pad. We now detect a HELD select/OK: a quick press still
  // activates (play/toggle), a hold >= _selectHoldDelay opens the long-press
  // menu. Implemented with a timer rather than KeyRepeatEvent so it does not
  // depend on the box delivering key-repeat for DPAD_CENTER.
  Timer? _selectHoldTimer;
  bool _selectActed = false;
  static const Duration _selectHoldDelay = Duration(milliseconds: 450);

  static final Map<int, _PrewarmEntry> _prewarmCache = {};
  static const Duration _prewarmTtl = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    _focusNode.onKeyEvent = (node, event) {
      // fix643: leftmost-column tile — LEFT = back (mirrors the Back button).
      // KeyDown only: a KeyRepeat from a held LEFT must not pop several
      // screens. Non-edge tiles fall through to normal directional traversal.
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.arrowLeft &&
          widget.leftEdge &&
          widget.onLeftEdgeBack != null) {
        widget.onLeftEdgeBack!.call();
        return KeyEventResult.handled;
      }
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.arrowRight) {
        if (!FocusScope.of(
          context,
        ).focusInDirection(TraversalDirection.right)) {
          widget.onFocusNavbar?.call();
        }
        return KeyEventResult.handled;
      }
      // fix558/563: when the caller supplies an explicit up-target, move focus
      // there directly instead of asking Flutter's directional traversal.
      // fix562 tried focusInDirection(up) here, but that routes through the
      // SAME directional-traversal pass that is unreliable right after a
      // programmatic focus jump across the search screen's stacked grids
      // (flutter/flutter#70364), so it did not fix the first-press miss.
      // fix563 makes TvSearchView supply a deterministic node-reference target
      // for EVERY tile (see TvSearchView._upTargetFor), so no up press depends
      // on directional traversal at all.
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.arrowUp &&
          widget.onFocusUpEscape != null) {
        widget.onFocusUpEscape!.call();
        return KeyEventResult.handled;
      }
      // fix586 (#6): held-OK opens the long-press menu; quick-OK activates.
      // We consume the select keys here so InkWell's default ActivateIntent
      // (which would fire onTap on key-down) never runs — the play/toggle is
      // deferred to key-up so we can distinguish a tap from a hold.
      final k = event.logicalKey;
      final isSelect = k == LogicalKeyboardKey.select ||
          k == LogicalKeyboardKey.enter ||
          k == LogicalKeyboardKey.numpadEnter ||
          k == LogicalKeyboardKey.gameButtonA;
      if (isSelect) {
        if (event is KeyDownEvent) {
          _selectActed = false;
          _selectHoldTimer?.cancel();
          _selectHoldTimer = Timer(_selectHoldDelay, () {
            if (!mounted || !_focusNode.hasFocus) return;
            _selectActed = true;
            _onLongPress();
          });
          return KeyEventResult.handled;
        }
        if (event is KeyUpEvent) {
          _selectHoldTimer?.cancel();
          _selectHoldTimer = null;
          final acted = _selectActed;
          _selectActed = false;
          if (!acted) _activate();
          return KeyEventResult.handled;
        }
        // KeyRepeatEvent: swallow; the hold timer drives the menu.
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    _focusNode.addListener(() {
      if (mounted) setState(() {});
      if (_focusNode.hasFocus) {
        widget.onFocusGained?.call(widget.channel); // fix589 (#5)
        _maybePrewarm();
        // fix560: requestFocus() alone does not scroll the focused widget
        // into view when it sits inside a shrink-wrapped, non-scrolling grid
        // nested in an ancestor Scrollable (the TV search results layout,
        // fix557). Mirrors the proven channel_schedule.dart pattern of
        // calling ensureVisible in a post-frame callback once the newly-
        // focused tile is actually built/laid out.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_focusNode.hasFocus) return;
          final ctx = _focusNode.context;
          if (ctx == null) return;
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.5,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        });
      }
    });
  }

  void _maybePrewarm() {
    // Only pre-warm livestreams (VOD/series don't benefit; series is a group anyway)
    if (widget.channel.mediaType != MediaType.livestream) return;
    final url = widget.channel.url;
    final id = widget.channel.id;
    if (url == null || id == null) return;
    final settings = SettingsService.cached;
    if (settings == null) return;
    if (!settings.preWarmOnFocus) return;

    // Skip if already cached and fresh
    final existing = _prewarmCache[id];
    if (existing != null && existing.expiresAt.isAfter(DateTime.now())) return;

    AppLog.info('ChannelTile: prewarming channel="${widget.channel.name}"');
    // Fire-and-forget; failure is silent
    AppHttp.resolveRedirects(url).then((resolved) {
      if (resolved != null) {
        _prewarmCache[id] = _PrewarmEntry(
          resolved,
          DateTime.now().add(_prewarmTtl),
        );
      }
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _selectHoldTimer?.cancel();
    // fix558: only dispose a node we created — a caller-supplied node is the
    // caller's responsibility (e.g. it's reused across rebuilds to stay a
    // stable cross-section target).
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  // fix586 (#6): the InkWell's primary action, shared by touch onTap and the
  // quick-press D-pad path. categoryToggleMode toggles the category's enabled
  // flag; everything else plays the channel.
  Future<void> _activate() async {
    if (widget.categoryToggleMode && widget.onToggleEnabled != null) {
      await widget.onToggleEnabled!(!(widget.channel.groupEnabled ?? true));
    } else {
      await play();
    }
  }

  Future<void> _onLongPress() async {
    // fix308: category tiles — long-press toggles favorite (sorts the category
    // to the top of the list; does not favorite its channels).
    if (widget.channel.mediaType == MediaType.group) {
      if (widget.onFavoriteGroup == null) return;
      final fav = widget.channel.favorite;
      await showModalBottomSheet<void>(
        context: context,
        builder: (ctx) {
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    widget.channel.name,
                    style: Theme.of(ctx).textTheme.labelLarge,
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    fav ? Icons.star : Icons.star_border,
                    color: Colors.amber,
                  ),
                  title: Text(
                    fav
                        ? 'Remove category from favorites'
                        : 'Favorite category (sort to top)',
                  ),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    await widget.onFavoriteGroup!(!fav);
                  },
                ),
              ],
            ),
          );
        },
      );
      return;
    }

    // fix309: show the same long-press menu for livestream, movie, and serie
    // tiles (favorite + category link), so the All view behaves like Live TV.
    // Mini-player and Remove-from-history remain livestream/history-only inside.
    if (widget.channel.mediaType != MediaType.group) {
      await showModalBottomSheet<void>(
        context: context,
        builder: (ctx) {
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // fix305: header showing which category this channel came from.
                // fix308: now tappable — opens the Categories list filtered to
                // that category name.
                Builder(builder: (ctx2) {
                  final catName =
                      (widget.channel.group?.trim().isNotEmpty ?? false)
                          ? widget.channel.group!.trim()
                          : 'Uncategorized';
                  final canOpen = widget.onOpenCategory != null &&
                      catName != 'Uncategorized';
                  return InkWell(
                    onTap: !canOpen
                        ? null
                        : () {
                            Navigator.of(ctx).pop();
                            widget.onOpenCategory!(catName);
                          },
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.folder_outlined,
                            size: 18,
                            color: Theme.of(ctx).colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              catName,
                              style:
                                  Theme.of(ctx).textTheme.labelLarge?.copyWith(
                                        color:
                                            Theme.of(ctx).colorScheme.primary,
                                      ),
                            ),
                          ),
                          if (canOpen)
                            Icon(
                              Icons.chevron_right,
                              size: 18,
                              color: Theme.of(ctx).colorScheme.primary,
                            ),
                        ],
                      ),
                    ),
                  );
                }),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    widget.channel.favorite ? Icons.star : Icons.star_border,
                    color: Colors.amber,
                  ),
                  title: Text(
                    widget.channel.favorite
                        ? 'Remove from favorites'
                        : 'Add to favorites',
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    favorite();
                  },
                ),
                // fix309: mini-player only applies to live channels.
                if (widget.channel.mediaType == MediaType.livestream)
                  ListTile(
                    leading: const Icon(Icons.picture_in_picture),
                    title: const Text('Watch in mini-player'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _watchInMiniPlayer();
                    },
                  ),
                // fix584 (#6): open this live channel in Multi-view. Live-only
                // (matches mini-player) and only when the caller wired an opener.
                if (widget.channel.mediaType == MediaType.livestream &&
                    widget.onOpenMultiView != null)
                  ListTile(
                    leading: const Icon(Icons.grid_view),
                    title: const Text('Open in Multi-view'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await widget.onOpenMultiView!(widget.channel);
                    },
                  ),
                if (widget.isHistory && widget.channel.id != null)
                  ListTile(
                    leading: const Icon(Icons.history_toggle_off,
                        color: Colors.redAccent),
                    title: const Text('Remove from history'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await Sql.deleteHistoryEntry(widget.channel.id!);
                      widget.onRemoveHistory?.call();
                    },
                  ),
              ],
            ),
          );
        },
      );
      return;
    }
  }

  Future<void> _watchInMiniPlayer() async {
    final ch = widget.channel;
    if (ch.url == null || ch.id == null) return;
    final settings =
        SettingsService.cached ?? await SettingsService.getSettings();
    if (!mounted) return;
    final source = await Sql.getSourceById(ch.sourceId);
    if (!mounted) return;
    await OverlayPlayerController.instance.startOverlay(ch, settings, source);
  }

  Future<void> favorite() async {
    if (widget.channel.mediaType == MediaType.group) return;
    final wasFavorite = widget.channel.favorite;
    AppLog.info(
      'ChannelTile: favorite channel="${widget.channel.name}"'
      ' wasFavorite=$wasFavorite → ${!wasFavorite}',
    );
    await Error.tryAsyncNoLoading(() async {
      await Sql.favoriteChannel(widget.channel.id!, !wasFavorite);
      if (!mounted) return;
      setState(() {
        widget.channel.favorite = !wasFavorite;
      });
      AppLog.info(
        'ChannelTile: favorite done channel="${widget.channel.name}"'
        ' favorite=${!wasFavorite}',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wasFavorite ? "Removed from favorites" : "Added to favorites",
          ),
          duration: const Duration(milliseconds: 500),
        ),
      );
    }, context);
  }

  Future<void> play() async {
    AppLog.info(
      'ChannelTile: play channel="${widget.channel.name}"'
      ' prewarmed=${widget.channel.id != null && ChannelTile.prewarmedUrl(widget.channel.id!) != null}',
    );
    if (widget.channel.mediaType == MediaType.group ||
        widget.channel.mediaType == MediaType.serie) {
      if (widget.channel.mediaType == MediaType.serie &&
          !refreshedSeries.contains(widget.channel.id)) {
        await Error.tryAsync(
          () async {
            await getEpisodes(widget.channel);
            refreshedSeries.add(widget.channel.id!);
          },
          widget.parentContext,
          null,
          true,
          false,
        );
      }
      final seriesNodeId = widget.channel.mediaType == MediaType.serie
          ? (widget.channel.seriesId ??
              int.tryParse(widget.channel.url ?? '') ??
              widget.channel.id!)
          : widget.channel.id!;
      widget.setNode(
        Node(
          id: seriesNodeId,
          name: widget.channel.name,
          type: fromMediaType(widget.channel.mediaType),
        ),
      );
    } else {
      final channelId = widget.channel.id;
      if (channelId == null || widget.channel.url == null) return;
      final settings =
          SettingsService.cached ?? await SettingsService.getSettings();
      final source = await Sql.getSourceById(widget.channel.sourceId);
      unawaited(Sql.addToHistory(channelId));
      if (!mounted) return;
      // fix112: if a full-screen player is already active, halt it (dispose
      // its engine) BEFORE opening the new channel. On connection-limited
      // accounts the provider won't grant the new connection until the old
      // one is released; opening on top of a live engine races that release
      // and causes an instant "Failed to open".
      await OverlayPlayerController.instance.haltMain();
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => Player(
            channel: widget.channel,
            settings: settings,
            source: source,
            // fix397: carry the launching list so the player can surf CH +/-.
            playlist: widget.playlist == null
                ? null
                : PlaybackPlaylist(
                    channels: widget.playlist!,
                    index: widget.playlistIndex,
                  ),
          ),
        ),
      );
    }
  }

  /// fix508: portrait poster body (cover image + title) used when
  /// [ChannelTile.poster] is true. Swaps ONLY the visual layout of the InkWell
  /// child — play/drill-in/focus/long-press all stay on the shared code paths.
  Widget _buildPoster(BuildContext context) {
    const fallback = ColoredBox(
      color: Colors.black26,
      // fix538: smaller fallback glyph so it doesn't dominate the half-size
      // poster tiles (grid went from ~4 to ~8 across).
      child: Center(child: Icon(Icons.movie, size: 28, color: Colors.grey)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // fix558: channel logos (Live TV) are typically square/circular
              // brand marks — BoxFit.cover cropped them to their center,
              // turning a "FOX" wordmark-in-circle into an unreadable "O" (the
              // edges with the text were cut off). Movie/series posters are
              // genuine full-bleed portrait artwork and should still cover.
              // contain + a dark backdrop keeps the whole logo visible with
              // small letterboxing instead of cropping it.
              if (widget.channel.image != null)
                widget.channel.mediaType == MediaType.livestream
                    ? ColoredBox(
                        color: Colors.black26,
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: CachedNetworkImage(
                            imageUrl: widget.channel.image!,
                            memCacheHeight: 360,
                            fit: BoxFit.contain,
                            placeholder: (c, u) =>
                                const ColoredBox(color: Colors.black26),
                            errorWidget: (c, u, e) => fallback,
                          ),
                        ),
                      )
                    : CachedNetworkImage(
                        imageUrl: widget.channel.image!,
                        memCacheHeight: 360,
                        fit: BoxFit.cover,
                        placeholder: (c, u) =>
                            const ColoredBox(color: Colors.black26),
                        errorWidget: (c, u, e) => fallback,
                      )
              else
                fallback,
              // Source-color accent as a thin top strip in poster mode.
              if (widget.showSourceEdgeBar && widget.tintColor != null)
                Align(
                  alignment: Alignment.topCenter,
                  child: Container(height: 4, color: Color(widget.tintColor!)),
                ),
              if (widget.channel.favorite)
                const Positioned(
                  top: 4,
                  right: 4,
                  // fix538: smaller for the half-size poster tiles.
                  child: Icon(Icons.star, size: 16, color: Colors.amber),
                ),
              // fix529: category-toggle checkbox overlay (shows enabled state).
              if (widget.categoryToggleMode)
                Positioned(
                  top: 4,
                  left: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Icon(
                      (widget.channel.groupEnabled ?? true)
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      // fix538: smaller for the half-size category tiles.
                      size: 18,
                      color: (widget.channel.groupEnabled ?? true)
                          ? Colors.lightBlueAccent
                          : Colors.white70,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          // fix551: allow the title to wrap to 2 lines (was maxLines:1 +
          // ellipsis, too small/truncated to read at 10ft). Pairs with the
          // wider category tiles (tv_categories_view 8->6 across) and applies to
          // all TV poster tiles (categories + movies/series) for legibility.
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
          child: Text(
            widget.channel.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  void _openSchedule() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChannelScheduleView(channel: widget.channel),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // fix142: persisted stream_validated survives restart; session map
    // (StreamScanner.results) covers this-session scans. Both count.
    final scanOk = widget.channel.streamValidated == true ||
        (widget.channel.id != null &&
            StreamScanner.results[widget.channel.id] == true);
    return Card(
      elevation: _focusNode.hasFocus ? 8.0 : 2.0,
      // fix501: clip so the TV edge bar follows the card's rounded corners.
      // Gated on the TV flag so the phone card's clipping is unchanged.
      clipBehavior:
          widget.showSourceEdgeBar ? Clip.antiAlias : Clip.none,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        // fix501: on TV, a focused tile shows the app-standard yellow ring
        // (drawn over the source tint). Phone keeps elevation-only focus.
        side: (widget.showSourceEdgeBar && _focusNode.hasFocus)
            ? const BorderSide(color: Colors.yellow, width: 3)
            : scanOk
                ? const BorderSide(color: Colors.greenAccent, width: 2.5)
                : BorderSide.none,
      ),
      // fix196: tint the whole card with the source's tag color (~35%) so the
      // channel's source is identifiable at a glance. Null = surface unchanged.
      color: SourcePalette.tintOver(
        widget.tintColor,
        Theme.of(context).colorScheme.surfaceContainer,
      ),
      child: InkWell(
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onLongPress: _onLongPress,
        onTap: _activate,
        child: widget.poster
            ? _buildPoster(context)
            : Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // fix501: TV-only solid source-color edge bar (full saturation),
            // flush to the leading edge. Null source = no bar (explicit).
            if (widget.showSourceEdgeBar && widget.tintColor != null)
              Container(width: 6, color: Color(widget.tintColor!)),
            AspectRatio(
              aspectRatio: 1,
              child: Container(
                padding: const EdgeInsets.all(8.0),
                child: Center(
                  child: widget.channel.image != null
                      ? CachedNetworkImage(
                          imageUrl: widget.channel.image!,
                          memCacheHeight: 300,
                          memCacheWidth: 300,
                          fit: BoxFit.contain,
                          errorWidget: (ctx, url, err) => const Icon(
                            Icons.tv,
                            size: 45,
                            color: Colors.grey,
                          ),
                        )
                      : const Icon(Icons.tv, size: 45, color: Colors.grey),
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.channel.name,
                      textAlign: TextAlign.left,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.fontSize,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (widget.channel.epgChannelId != null &&
                        widget.channel.mediaType == MediaType.livestream)
                      NowNextStrip(
                        epgChannelId: widget.channel.epgChannelId!,
                        sourceId: widget.channel.sourceId,
                        onTap: _openSchedule,
                      ),
                  ],
                ),
              ),
            ),
            if (widget.channel.epgChannelId != null &&
                widget.channel.mediaType == MediaType.livestream)
              IconButton(
                icon: const Icon(Icons.calendar_today_outlined, size: 20),
                tooltip: 'Program guide',
                onPressed: _openSchedule,
              ),
            if (widget.channel.favorite)
              Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: Center(
                  child: const Icon(Icons.star, size: 25, color: Colors.amber),
                ),
              ),
            // fix278: per-category enable checkbox (Categories view only).
            // fix333: the tile is a single InkWell with one focus node, so on a
            // D-pad TV the checkbox (a plain Checkbox child) could never be
            // reached — there was only one focusable target per tile and select
            // opened the category. The tile's focus node already forwards
            // arrow-right via focusInDirection(right), so wrapping the checkbox
            // in its own focusable InkWell puts it in the traversal order:
            // right-arrow from the tile now lands on the checkbox (with a
            // visible focus highlight) and select toggles enabled. Falls
            // through to the navbar only if there is nothing to the right.
            if (widget.channel.mediaType == MediaType.group &&
                widget.onToggleEnabled != null)
              Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: Center(
                  child: Builder(builder: (context) {
                    final enabled = widget.channel.groupEnabled ?? true;
                    return InkWell(
                      canRequestFocus: true,
                      borderRadius: BorderRadius.circular(8),
                      onTap: () async =>
                          await widget.onToggleEnabled!(!enabled),
                      child: Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: IgnorePointer(
                          child: Checkbox(
                            value: enabled,
                            onChanged: (_) {},
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PrewarmEntry {
  final String url;
  final DateTime expiresAt;
  _PrewarmEntry(this.url, this.expiresAt);
}
