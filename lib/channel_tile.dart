import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_tv/backend/http_client.dart';
import 'package:open_tv/backend/settings_service.dart';
import 'package:open_tv/backend/sql.dart';
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

  const ChannelTile({
    super.key,
    required this.channel,
    required this.setNode,
    required this.parentContext,
    this.onFocusNavbar,
    this.isHistory = false,
    this.onRemoveHistory,
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
    // For groups, long-press does nothing
    if (widget.channel.mediaType == MediaType.group) return;

    // For livestreams offer "Favorite" + "Watch in mini-player"
    // + "Remove from history" when in the history view.
    if (widget.channel.mediaType == MediaType.livestream) {
      await showModalBottomSheet<void>(
        context: context,
        builder: (ctx) {
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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

    // For movies / series, keep original behavior (favorite toggle)
    await favorite();
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
    await Error.tryAsyncNoLoading(() async {
      await Sql.favoriteChannel(widget.channel.id!, !wasFavorite);
      if (!mounted) return;
      setState(() {
        widget.channel.favorite = !wasFavorite;
      });
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

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: _focusNode.hasFocus ? 8.0 : 2.0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: InkWell(
        focusNode: _focusNode,
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
                          errorWidget: (_, __, ___) => const Icon(
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
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChannelScheduleView(
                              channel: widget.channel,
                            ),
                          ),
                        ),
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
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        ChannelScheduleView(channel: widget.channel),
                  ),
                ),
              ),
            if (widget.channel.favorite)
              Padding(
                padding: const EdgeInsets.only(right: 8.0),
                child: Center(
                  child: const Icon(Icons.star, size: 25, color: Colors.amber),
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
