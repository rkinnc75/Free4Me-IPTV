import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // finding 108: LogicalKeyboardKey for Back/Esc escape hatch
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/models/app_navigator.dart';
import 'package:open_tv/player.dart';
import 'package:open_tv/player/overlay_player_controller.dart';

/// Floating, draggable mini-player rendered above all routes.
///
/// Injected into [MyApp]'s builder `Stack` so it persists across navigation.
/// When no overlay is active ([OverlayPlayerController.channel] is null),
/// renders a zero-size widget.
///
/// Layout: 256 wide × 188 px total (44 px control bar + 144 px video at 16:9).
///
/// Interaction design:
/// - Drag: grab the **video area** to drag the window to a new corner.
/// - Tap video: swap (promotes overlay to full-screen, demotes current full-screen to mini).
/// - ⇄ button: same as tapping the video — swap channels.
/// - ✕ button: close the mini-player.
///
/// The control bar buttons are NOT inside the drag GestureDetector, which
/// prevents accidental dismissal when tapping near the edge of a button.
class OverlayPlayerWidget extends StatefulWidget {
  const OverlayPlayerWidget({super.key});

  @override
  State<OverlayPlayerWidget> createState() => _OverlayPlayerWidgetState();
}

class _OverlayPlayerWidgetState extends State<OverlayPlayerWidget> {
  // Dimensions chosen so every touch target is ≥ 44 px (Material / HIG spec).
  static const double _kWidth = 256;
  static const double _kVideoHeight = 144; // 256 × 9 / 16
  static const double _kBarHeight = 44;
  static const double _kTotalHeight = _kVideoHeight + _kBarHeight;
  static const double _kBtnWidth = 44;
  static const double _kMarginH = 12;
  static const double _kMarginV = 72; // clear bottom nav / system bars

  final _ctrl = OverlayPlayerController.instance;

  /// Non-null while the user is dragging; null = use snapped corner position.
  Offset? _dragOffset;

  /// fix104: prevents a rapid double-tap from firing _swap twice and
  /// re-introducing route stacking.
  bool _swapInFlight = false;

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
      // finding 108: defensive D-pad dismiss — Back/Esc closes an overlay that
      // is somehow active on a D-pad device. canRequestFocus:false /
      // skipTraversal:true so it never steals focus or alters traversal; it
      // only intercepts Back if a key event happens to route through here.
      child: Focus(
        autofocus: false,
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.goBack ||
                  event.logicalKey == LogicalKeyboardKey.escape)) {
            _ctrl.stopOverlay();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Material(
          color: Colors.transparent,
          child: _buildCard(context, size, padding, snapped),
        ),
      ),
    );
  }

  Widget _buildCard(
    BuildContext context,
    Size size,
    EdgeInsets padding,
    Offset snapped,
  ) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: _kWidth,
        height: _kTotalHeight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [
              BoxShadow(
                color: Color(0xBB000000),
                blurRadius: 12,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Column(
            children: [
              _buildControlBar(context),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _swap, // fix104: maximize removed; body tap = swap
                onPanUpdate: (d) {
                  setState(() {
                    final cur = _dragOffset ?? snapped;
                    _dragOffset = Offset(
                      (cur.dx + d.delta.dx)
                          .clamp(0.0, size.width - _kWidth),
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
                child: SizedBox(
                  width: _kWidth,
                  height: _kVideoHeight,
                  child: _ctrl.engine != null
                      ? _ctrl.engine!.buildVideoView(context)
                      : const ColoredBox(color: Colors.black),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  //
  // Layout (left → right):
  //   [channel name expanded] [⇄ swap 44px] [✕ close 44px]
  //
  // Each action button is exactly _kBtnWidth × _kBarHeight — meeting the
  // 44 px minimum touch target on both axes.  The close button has a red
  // icon tint so it is visually distinct from swap even at a glance.
  // fix104: maximize button removed; body tap and swap button both promote.

  Widget _buildControlBar(BuildContext context) {
    return SizedBox(
      height: _kBarHeight,
      child: ColoredBox(
        color: const Color(0xEE111111),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _ctrl.channel?.name ?? '',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ),
            ),

            _barButton(
              icon: Icons.swap_horiz,
              tooltip: 'Swap with full-screen',
              color: Colors.white,
              onTap: _swap,
            ),

            // Thin visual separator so close is clearly distinct
            const VerticalDivider(
              width: 1,
              thickness: 1,
              color: Color(0x55FFFFFF),
              indent: 8,
              endIndent: 8,
            ),

            _barButton(
              icon: Icons.close,
              tooltip: 'Close mini-player',
              color: Colors.redAccent,
              onTap: () => _ctrl.stopOverlay(),
            ),
          ],
        ),
      ),
    );
  }

  /// A button cell inside the control bar.  Uses [GestureDetector] directly
  /// so the full [_kBtnWidth] × [_kBarHeight] area is the touch target —
  /// `IconButton` clips its splash to a smaller circle by default.
  Widget _barButton({
    required IconData icon,
    required String tooltip,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: _kBtnWidth,
          height: _kBarHeight,
          child: Icon(icon, color: color, size: 20),
        ),
      ),
    );
  }


  NavigatorState get _nav => appNavigatorKey.currentState!;

  /// Swap the overlay channel with the current full-screen player.
  ///
  /// Promotes the overlay channel to full-screen and demotes the current
  /// full-screen channel into the overlay. If no full-screen player is
  /// registered, the overlay simply becomes the full-screen player.
  ///
  /// fix104: ensures exactly one full-screen route exists at any time —
  /// before fix104, swap stacked routes (user had to close ~6 instances).
  /// Also guards against rapid double-tap via _swapInFlight.
  /// fix120: switched the route op from pushReplacement to pop+push —
  /// pushReplacement caused the revealed Home route to render black on
  /// the next pop. Stack shape is unchanged.
  Future<void> _swap() async {
    if (_swapInFlight) {
      AppLog.warn('OverlayWidget: _swap ignored — already in flight');
      return;
    }
    _swapInFlight = true;
    try {
      AppLog.info(
        'OverlayWidget: _swap START'
        ' overlay="${_ctrl.channel?.name ?? 'none'}"'
        ' main="${_ctrl.mainChannel?.name ?? 'none'}"',
      );

      // Capture main BEFORE detaching the overlay.
      final mainCh = _ctrl.mainChannel;
      final mainSettings = _ctrl.mainSettings;
      final mainSource = _ctrl.mainSource;
      final hadMain = mainCh != null && mainSettings != null;
      AppLog.info(
        'OverlayWidget: _swap captured'
        ' main="${mainCh?.name ?? 'none'}" hadMain=$hadMain',
      );

      // finding 110: refuse the swap when the top route is NOT the
      // full-screen Player (e.g. a dialog is open above it). Blindly popping
      // would dismiss the dialog and strand a zombie detached Player. Single
      // file constraint: identity tracking of the Player route lives in the
      // controller, so we use a non-mutating top-route probe here instead.
      // This guard runs BEFORE any destructive detach (finding 109 reorder),
      // so on abort nothing has been touched. On the normal path (Player on
      // top) behavior is identical to before.
      if (hadMain && !_topRouteIsPlayer()) {
        AppLog.warn(
          'OverlayWidget: _swap ABORT — top route is not the Player'
          ' (dialog open?)',
        );
        return;
      }

      // finding 109: detach (do NOT dispose) the overlay engine FIRST — this
      // is the side-effect-free read. Abort here BEFORE touching the main
      // player so a missing overlay can never strand the live full-screen
      // Player in the detachForSwap (exiting/_exitInvoked/_engineDisposed)
      // state (which would leave a zombie full-screen player + dead Back).
      final overlay = _ctrl.detachOverlayEngine();
      if (overlay == null) {
        AppLog.warn('OverlayWidget: _swap ABORT — no overlay to detach');
        return;
      }

      // fix116: detach (do NOT dispose) the outgoing full-screen engine so
      // it can become the overlay. Returns null if not an MpvEngine.
      final detachedMain = hadMain ? _ctrl.detachMain() : null;
      AppLog.info(
        'OverlayWidget: _swap detached'
        ' overlay="${overlay.ch.name}" overlayEid=${identityHashCode(overlay.engine)}'
        ' mainEid=${detachedMain == null ? 'null' : identityHashCode(detachedMain)}',
      );

      // Promoted channel was live — clear any stale give-up cooldown so its
      // new Player starts immediately.
      Player.clearCooldown(overlay.ch.id);

      // fix104: replace the current full-screen route instead of pop+push.
      // fix116: pass the live overlay engine (adoptEngine) — no reopen, no stall.
      final promoted = MaterialPageRoute(
        builder: (_) => Player(
          channel: overlay.ch,
          settings: overlay.s,
          source: overlay.src,
          adoptEngine: overlay.engine, // fix116
        ),
      );
      if (hadMain) {
        // fix120: pop the outgoing full-screen route, THEN push the new
        // one, instead of pushReplacement. pushReplacement left the
        // revealed route (Home, after a later pop) rendering black —
        // the compositor retained the disposed Player's layer.
        // Explicit pop+push reaches the same stack shape
        // ([Home, Player(new)]) via the same operations the rest of the
        // app uses. The outgoing engine is already detached by
        // detachMain (fix116) and _engineDisposed guards prevent the
        // pop from disposing the handed-off engine.
        AppLog.info(
          'OverlayWidget: _swap pop+push → "${overlay.ch.name}" (adopt)',
        );
        AppLog.info('OverlayWidget: _swap nav.canPop(before)=${_nav.canPop()}');
        _nav.pop();
        _nav.push(promoted);
        AppLog.info('OverlayWidget: _swap nav.canPop(after)=${_nav.canPop()}');
      } else {
        AppLog.info(
          'OverlayWidget: _swap push → "${overlay.ch.name}" (adopt)',
        );
        _nav.push(promoted);
      }

      // Demote the ex-full-screen channel into the overlay.
      if (hadMain) {
        if (detachedMain != null) {
          // fix116: adopt the live ex-main engine as the overlay — no reopen.
          AppLog.info(
            'OverlayWidget: _swap demoting "${mainCh.name}"'
            ' → mini-player (adopt, muted)',
          );
          _ctrl.adoptOverlayEngine(
            mainCh, mainSettings, mainSource, detachedMain,
            muted: true,
          );
        } else {
          // Fallback: ex-main wasn't an MpvEngine — reopen as overlay.
          AppLog.info(
            'OverlayWidget: _swap demoting "${mainCh.name}"'
            ' → mini-player (reopen fallback, muted)',
          );
          await _ctrl.startOverlay(
            mainCh, mainSettings, mainSource,
            forceMuted: true,
          );
        }
        AppLog.info(
          'OverlayWidget: _swap DONE'
          ' full-screen="${overlay.ch.name}" fullEid=${identityHashCode(overlay.engine)}'
          '${detachedMain != null
              ? ' mini="${mainCh.name}" miniEid=${identityHashCode(detachedMain)}'
              : ' mini="${mainCh.name}" (reopened)'}',
        );
      } else {
        AppLog.info(
          'OverlayWidget: _swap DONE'
          ' full-screen="${overlay.ch.name}" fullEid=${identityHashCode(overlay.engine)}'
          ' mini=none',
        );
      }
    } finally {
      _swapInFlight = false;
    }
  }

  /// finding 110: non-mutating probe for whether the topmost route is the
  /// full-screen [Player]. The Player is pushed as a nameless
  /// [MaterialPageRoute] that is never the first (Home) route, so a top route
  /// matching (name == null && MaterialPageRoute && !isFirst) is treated as
  /// the Player. Returning true from the [NavigatorState.popUntil] predicate
  /// on the FIRST route stops immediately and pops nothing — it is used here
  /// purely to read the current top route without mutating the stack.
  /// Heuristic (single-file fallback): a robust version would track the
  /// Player's Route identity in OverlayPlayerController, but that would touch
  /// a second file. When unsure this returns false, which only makes _swap
  /// MORE conservative (refuse the swap) — never less safe.
  bool _topRouteIsPlayer() {
    var isPlayer = false;
    _nav.popUntil((route) {
      isPlayer = route.settings.name == null &&
          route is MaterialPageRoute &&
          route.isFirst == false;
      return true;
    });
    return isPlayer;
  }


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
