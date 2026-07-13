import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/player/player_engine.dart';
import 'package:open_tv/tv/theme/f4_tokens.dart';
import 'package:open_tv/widgets/player_channel_name_label.dart';
import 'package:open_tv/widgets/player_epg_now_label.dart';

/// fix714 (Phase 4 — TV player OSD, unit 1) — the Peer2 bottom **Info Bar**.
///
/// A token-glass strip anchored at the bottom of the player overlay: the
/// channel logo + name (with the resolution/codec the name label appends once
/// known) on top, the NOW programme (live only), and the caller's seek/progress
/// row. It REUSES the existing self-updating label widgets
/// ([PlayerChannelNameLabel], [PlayerEpgNowLabel]) and the caller's
/// `_buildOverlayProgress` row — this unit is a chrome-only presentation move
/// out of the old flat top bar. No engine / focus / key-handling changes; the
/// bar is display-only (no focusable children), so it never joins the D-pad
/// traversal that owns the action buttons.
class PlayerInfoBar extends StatelessWidget {
  final Channel channel;
  final PlayerEngine engine;
  final bool live;

  /// The caller's seek-progress row (position/duration), when the transport is
  /// seekable (DVR / VOD); null on a plain livestream.
  final Widget? progress;

  /// fix731: forwarded to [PlayerEpgNowLabel] so its 30s DB poll pauses while
  /// the (now always-mounted) OSD is hidden.
  final bool active;

  const PlayerInfoBar({
    super.key,
    required this.channel,
    required this.engine,
    required this.live,
    this.progress,
    this.active = true,
  });

  @override
  Widget build(BuildContext context) {
    final t = F4.of(context);
    final logo = channel.image;
    final hasLogo = logo != null && logo.isNotEmpty;
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: t.spacing.md, vertical: t.spacing.sm),
      decoration: BoxDecoration(
        color: t.colors.glassFill,
        borderRadius: BorderRadius.circular(t.radius.card),
        border: Border.all(color: t.colors.glassStroke, width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (hasLogo) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(t.radius.sm),
                  child: CachedNetworkImage(
                    imageUrl: logo,
                    width: 44,
                    height: 44,
                    fit: BoxFit.contain,
                    errorWidget: (_, _, _) =>
                        const SizedBox(width: 44, height: 44),
                  ),
                ),
                SizedBox(width: t.spacing.sm),
              ],
              Expanded(
                child: DefaultTextStyle(
                  style: TextStyle(
                    color: t.colors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  child: PlayerChannelNameLabel(
                      channelName: channel.name, engine: engine),
                ),
              ),
            ],
          ),
          // NOW programme (live only). The label self-hides (SizedBox.shrink)
          // when there's no EPG; no explicit spacer precedes it (one would leave
          // a phantom gap when the label shrinks) — the label's own line height
          // separates it from the name.
          if (live)
            PlayerEpgNowLabel(
              epgChannelId: channel.epgChannelId,
              sourceId: channel.sourceId,
              active: active,
            ),
          if (progress != null) ...[
            SizedBox(height: t.spacing.sm),
            progress!,
          ],
        ],
      ),
    );
  }
}
