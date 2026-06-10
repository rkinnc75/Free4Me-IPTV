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
  /// When [isHistory] is true, the long-press sheet includes a
  /// "Remove from history" option. [onRemoveHistory] is called after the
  /// entry is deleted so the parent can refresh its list.
  final bool isHistory;
  final VoidCallback? onRemoveHistory;
  /// fix182: when true, this tile grabs focus on first build.
  final bool autofocus;
  /// fix196: source tag color (ARGB int; null = no tint).
  final int? tintColor;
  /// fix278: for category tiles — toggle the category's enabled flag. Null for
  /// non-category tiles.
  final Future<void> Function(bool enabled)? onToggleEnabled;

  /// fix308: for category tiles — toggle the category's favorite flag (sorts it
  /// to the top of the Categories list). Null for non-category tiles.
  final Future<void> Function(bool favorite)? onFavoriteGroup;

  /// fix308: tapping the category name in a channel's long-press menu opens the
  /// Categories list filtered to that category name. Null disables the tap.
  final void Function(String categoryName)? onOpenCategory;

  const ChannelTile({
    super.key,
    required this.channel,
    required this.setNode,
    required this.parentContext,
    this.onFocusNavbar,
    this.isHistory = false,
    this.onRemoveHistory,
    this.autofocus = false,
    this.tintColor,
    this.onToggleEnabled, // fix278: category tiles only
    this.onFavoriteGroup, // fix308: category tiles only
    this.onOpenCategory, // fix308: channel long-press category link
  });

  @override
  State<ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<ChannelTile> {
  final FocusNode _focusNode = FocusNode();

  static final Map<int, _PrewarmEntry> _prewarmCache = {};
  static const Duration _prewarmTtl = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    _focusNode.onKeyEvent = (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.arrowRight) {
        if (!FocusScope.of(
          context,
        ).focusInDirection(TraversalDirection.right)) {
          widget.onFocusNavbar?.call();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    _focusNode.addListener(() {
      if (mounted) setState(() {});
      if (_focusNode.hasFocus) {
        _maybePrewarm();
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
    _focusNode.dispose();
    super.dispose();
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
          ),
        ),
      );
    }
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: scanOk
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
        onTap: () async => await play(),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
