import 'package:flutter/material.dart';
import 'package:open_tv/player.dart';
import 'package:open_tv/player/overlay_player_controller.dart';

/// Floating, draggable mini-player rendered above all routes.
///
/// Injected into [MyApp]'s builder `Stack` so it persists across navigation.
/// When no overlay is active ([OverlayPlayerController.channel] is null),
/// renders a zero-size widget.
///
/// Layout: 224 × 156 px total (30 px top bar + 126 px video at 16:9).
class OverlayPlayerWidget extends StatefulWidget {
  const OverlayPlayerWidget({super.key});

  @override
  State<OverlayPlayerWidget> createState() => _OverlayPlayerWidgetState();
}

class _OverlayPlayerWidgetState extends State<OverlayPlayerWidget> {
  static const double _kWidth = 224;
  static const double _kVideoHeight = 126; // 224 × 9 / 16
  static const double _kBarHeight = 30;
  static const double _kTotalHeight = _kVideoHeight + _kBarHeight;
  static const double _kMarginH = 12;
  static const double _kMarginV = 72; // clear bottom nav / system bars

  final _ctrl = OverlayPlayerController.instance;

  /// Drag position; null means "use snapped corner position".
  Offset? _dragOffset;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ctrl.channel == null) return const SizedBox.shrink();

    final mq = MediaQuery.of(context);
    final size = mq.size;
    final padding = mq.padding;

    final snapped = _cornerOffset(_ctrl.corner, size, padding);
    final pos = _dragOffset ?? snapped;

    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (d) {
            setState(() {
              final cur = _dragOffset ?? snapped;
              _dragOffset = Offset(
                (cur.dx + d.delta.dx).clamp(0.0, size.width - _kWidth),
                (cur.dy + d.delta.dy)
                    .clamp(padding.top, size.height - _kTotalHeight),
              );
            });
          },
          onPanEnd: (_) {
            final cur = _dragOffset ?? snapped;
            _ctrl.setCorner(_nearestCorner(cur, size));
            setState(() => _dragOffset = null);
          },
          child: _buildCard(context),
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context) {
    final engine = _ctrl.engine;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: _kWidth,
        height: _kTotalHeight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(
                color: Color(0xAA000000),
                blurRadius: 10,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Column(
            children: [
              // ── Control bar ────────────────────────────────────────────────
              SizedBox(
                height: _kBarHeight,
                child: ColoredBox(
                  color: const Color(0xDD000000),
                  child: Row(
                    children: [
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _ctrl.channel?.name ?? '',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // Swap
                      SizedBox(
                        width: 30,
                        height: _kBarHeight,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 16,
                          tooltip: 'Swap channels',
                          icon: const Icon(
                            Icons.swap_horiz,
                            color: Colors.white,
                          ),
                          onPressed: () => _swap(context),
                        ),
                      ),
                      // Close
                      SizedBox(
                        width: 30,
                        height: _kBarHeight,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 16,
                          tooltip: 'Close mini-player',
                          icon: const Icon(
                            Icons.close,
                            color: Colors.white,
                          ),
                          onPressed: () => _ctrl.stopOverlay(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // ── Video surface ──────────────────────────────────────────────
              SizedBox(
                width: _kWidth,
                height: _kVideoHeight,
                child: engine != null
                    ? engine.buildVideoView(context)
                    : const ColoredBox(color: Colors.black),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Swap ───────────────────────────────────────────────────────────────────

  Future<void> _swap(BuildContext context) async {
    // Capture state before mutating
    final snapshot = await _ctrl.consumeOverlay();
    if (snapshot == null) return;

    final mainCh = _ctrl.mainChannel;
    final mainSettings = _ctrl.mainSettings;
    final mainSource = _ctrl.mainSource;

    // Pop the current full-screen player (if any)
    if (mainCh != null && context.mounted) {
      Navigator.of(context).pop();
    }

    // Push the ex-overlay channel as the new full-screen player
    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Player(
          channel: snapshot.ch,
          settings: snapshot.s,
          source: snapshot.src,
        ),
      ),
    );

    // Start the ex-main channel as the new muted overlay
    if (mainCh != null && mainSettings != null) {
      await _ctrl.startOverlay(mainCh, mainSettings, mainSource);
    }
  }

  // ── Corner helpers ─────────────────────────────────────────────────────────

  Offset _cornerOffset(Alignment corner, Size size, EdgeInsets padding) {
    final l = _kMarginH;
    final r = size.width - _kWidth - _kMarginH;
    final t = padding.top + _kMarginV;
    final b = size.height - _kTotalHeight - _kMarginV;

    if (corner == Alignment.topLeft) return Offset(l, t);
    if (corner == Alignment.topRight) return Offset(r, t);
    if (corner == Alignment.bottomLeft) return Offset(l, b);
    return Offset(r, b); // bottomRight (default)
  }

  Alignment _nearestCorner(Offset pos, Size size) {
    final cx = pos.dx + _kWidth / 2;
    final cy = pos.dy + _kTotalHeight / 2;
    final isLeft = cx < size.width / 2;
    final isTop = cy < size.height / 2;
    if (isTop && isLeft) return Alignment.topLeft;
    if (isTop) return Alignment.topRight;
    if (isLeft) return Alignment.bottomLeft;
    return Alignment.bottomRight;
  }
}
