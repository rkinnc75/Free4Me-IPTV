import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:open_tv/models/playback_playlist.dart';
import 'package:open_tv/tv/theme/accent_scope.dart';
import 'package:open_tv/tv/theme/f4_tokens.dart';

/// fix716 (Phase 4 — TV player OSD, unit 3) — the Peer2 **Channel Bar**.
///
/// A horizontal strip of the current surf group ([PlaybackPlaylist.channels]),
/// centered on the tuned channel ([PlaybackPlaylist.index]) which carries the
/// accent highlight; neighbours are dimmed. It gives channel-surf context ("you
/// are here, these are around you") in the revealed OSD, above the Info Bar.
///
/// **Display-only** by design: wrapped in `IgnorePointer`, no `FocusNode` /
/// `InkWell`, so it never joins the overlay's `FocusTraversalGroup` D-pad
/// traversal. Under Option B (short-OK reveals everything; Center stays
/// play/pause) this keeps the proven trigger/focus model untouched — the user
/// still surfs with ▲▼ and the strip re-centers when a fresh Player launches at
/// the new index. (A focusable channel picker is a possible later refinement.)
class PlayerChannelBar extends StatefulWidget {
  final PlaybackPlaylist playlist;
  const PlayerChannelBar({super.key, required this.playlist});

  @override
  State<PlayerChannelBar> createState() => _PlayerChannelBarState();
}

class _PlayerChannelBarState extends State<PlayerChannelBar> {
  static const double _chipW = 150;
  static const double _gap = 4; // == t.spacing.xs — keep in sync
  static const double _stride = _chipW + _gap * 2; // real per-item layout width
  static const double _height = 64;
  final ScrollController _sc = ScrollController();

  @override
  void initState() {
    super.initState();
    // Center the tuned channel once the strip is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerCurrent());
  }

  void _centerCurrent() {
    if (!_sc.hasClients) return;
    final vp = _sc.position.viewportDimension;
    // Each item occupies _stride px (chip + both margins); center that slot.
    final target = (widget.playlist.index * _stride) - (vp - _stride) / 2;
    final max = _sc.position.maxScrollExtent;
    _sc.jumpTo(target.clamp(0.0, max));
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = F4.of(context);
    final accent = AccentScope.of(context);
    final channels = widget.playlist.channels;
    final current = widget.playlist.index;
    return IgnorePointer(
      child: SizedBox(
        height: _height,
        child: ListView.builder(
          controller: _sc,
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(), // display-only
          itemExtent: _stride, // exact stride → centering math is precise
          itemCount: channels.length,
          itemBuilder: (context, i) {
            final ch = channels[i];
            final isCurrent = i == current;
            final logo = ch.image;
            return Container(
              width: _chipW,
              margin: const EdgeInsets.symmetric(horizontal: _gap),
              padding: EdgeInsets.symmetric(
                  horizontal: t.spacing.sm, vertical: t.spacing.xs),
              decoration: BoxDecoration(
                color: isCurrent ? t.colors.glassFill : Colors.transparent,
                borderRadius: BorderRadius.circular(t.radius.card),
                border: isCurrent
                    ? Border.all(color: accent, width: 2)
                    : null,
              ),
              child: Opacity(
                opacity: isCurrent ? 1.0 : 0.55,
                child: Row(
                  children: [
                    if (logo != null && logo.isNotEmpty) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(t.radius.sm),
                        child: CachedNetworkImage(
                          imageUrl: logo,
                          width: 32,
                          height: 32,
                          fit: BoxFit.contain,
                          errorWidget: (_, _, _) =>
                              const SizedBox(width: 32, height: 32),
                        ),
                      ),
                      SizedBox(width: t.spacing.xs),
                    ],
                    Expanded(
                      child: Text(
                        ch.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.colors.textPrimary,
                          fontSize: 12,
                          fontWeight:
                              isCurrent ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
