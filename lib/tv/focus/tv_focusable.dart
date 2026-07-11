import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/accent_scope.dart';
import '../theme/f4_motion.dart';
import '../theme/f4_tokens.dart';

/// fix701 (TV GUI redesign, Phase 0) — the single TV focus primitive.
///
/// Replaces the 3 copy-pasted `_FocusTile`s, the tab bar's separate hold widget,
/// and the flat yellow `Border.all`. One widget provides, all token/accent
/// driven:
///  - an **accent focus ring** whose color is read from [AccentScope] at draw
///    time (so an accent swap recolors it for free, no rebuild wiring);
///  - **asymmetric ring alpha** — focus-IN snaps to full instantly, focus-OUT
///    fades over [F4Motion.focusOut] (120ms). This kills the one-frame no-focus
///    flash on fast D-pad travel;
///  - **1.05× focus scale / 0.97× press** ([F4Motion]) as a transform (never
///    layout — rows don't reflow);
///  - the **held-OK detector** (our #1 win), unified on the SAFE fire-on-release
///    model: a KeyDown starts a timer that only *marks* the hold; KeyUp decides
///    held (→ [onHeldOk]) vs quick (→ [onTap]). Touch long-press also fires
///    [onHeldOk]. Never opens the menu mid-hold (which would leak the key).
///
/// TV-scoped: phone widgets never use this.
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.builder,
    this.onTap,
    this.onHeldOk,
    this.autofocus = false,
    this.focusNode,
    this.scaleFocused = F4Motion.scaleFocused,
    this.outlineWidth,
    this.borderRadius,
    this.transformOrigin = Alignment.center,
    this.holdThreshold = const Duration(milliseconds: 500),
    this.onFocusChange,
    this.enabled = true,
  });

  /// Builds the content; [isFocused] lets the child restyle (e.g. brighten).
  final Widget Function(BuildContext context, bool isFocused) builder;
  final VoidCallback? onTap;

  /// Held-OK (D-pad) / long-press (touch). Null → no hold behaviour.
  final VoidCallback? onHeldOk;
  final bool autofocus;
  final FocusNode? focusNode;
  final double scaleFocused;

  /// Ring stroke width; defaults to `F4Focus.ringCard` (2.5).
  final double? outlineWidth;

  /// Ring corner radius; defaults to `F4Radius.card` (12).
  final double? borderRadius;
  final Alignment transformOrigin;
  final Duration holdThreshold;
  final ValueChanged<bool>? onFocusChange;
  final bool enabled;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable>
    with SingleTickerProviderStateMixin {
  FocusNode? _internalNode;
  FocusNode get _node => widget.focusNode ?? (_internalNode ??= FocusNode());

  bool _focused = false;
  bool _pressed = false;

  // Ring alpha 0→1. focus-IN snaps to 1.0 (no tween); focus-OUT animates.
  late final AnimationController _ring = AnimationController(
    vsync: this,
    duration: F4Motion.focusOut,
    value: 0,
  );

  Timer? _holdTimer;
  bool _selectDown = false;
  bool _heldLong = false;

  @override
  void dispose() {
    _holdTimer?.cancel();
    _ring.dispose();
    _internalNode?.dispose();
    super.dispose();
  }

  void _handleFocusChange(bool focused) {
    if (focused == _focused) return;
    setState(() => _focused = focused);
    if (focused) {
      _ring.value = 1.0; // instant in — no flash
    } else {
      _ring.animateTo(0, curve: F4Motion.easeOut); // fade out over focusOut
    }
    widget.onFocusChange?.call(focused);
  }

  KeyEventResult _onKey(FocusNode n, KeyEvent event) {
    final k = event.logicalKey;
    final isSelect = k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.gameButtonA;
    if (!isSelect) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      _selectDown = true;
      _heldLong = false;
      if (!_pressed) setState(() => _pressed = true);
      _holdTimer?.cancel();
      if (widget.onHeldOk != null) {
        _holdTimer = Timer(widget.holdThreshold, () {
          if (mounted && n.hasFocus) _heldLong = true;
        });
      }
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      _holdTimer?.cancel();
      _holdTimer = null;
      if (_pressed && mounted) setState(() => _pressed = false);
      if (!_selectDown) return KeyEventResult.handled;
      _selectDown = false;
      final long = _heldLong;
      _heldLong = false;
      // Fire on RELEASE: held → onHeldOk, quick → onTap. Never mid-hold.
      if (long && widget.onHeldOk != null) {
        widget.onHeldOk!();
      } else {
        widget.onTap?.call();
      }
      return KeyEventResult.handled;
    }
    // KeyRepeatEvent: swallow — the timer marks the hold, not the repeats.
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = F4.of(context);
    final accent = AccentScope.of(context);
    final radius = widget.borderRadius ?? tokens.radius.card;
    final width = widget.outlineWidth ?? tokens.focus.ringCard;
    final scale = _pressed
        ? F4Motion.scalePressed
        : (_focused ? widget.scaleFocused : 1.0);

    Widget content = widget.builder(context, _focused);

    // Accent ring, alpha driven by the asymmetric controller.
    content = AnimatedBuilder(
      animation: _ring,
      builder: (context, child) => CustomPaint(
        foregroundPainter: _RingPainter(
          color: accent.withValues(alpha: _ring.value.clamp(0.0, 1.0)),
          width: width,
          radius: radius,
        ),
        child: child,
      ),
      child: content,
    );

    content = AnimatedScale(
      scale: scale,
      duration: F4Motion.normal,
      curve: F4Motion.easeOut,
      alignment: widget.transformOrigin,
      child: content,
    );

    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      canRequestFocus: widget.enabled,
      onKeyEvent: widget.enabled ? _onKey : null,
      onFocusChange: _handleFocusChange,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled
            ? () {
                _node.requestFocus();
                widget.onTap?.call();
              }
            : null,
        onLongPress: widget.enabled ? widget.onHeldOk : null, // touch path
        child: RepaintBoundary(child: content),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.color,
    required this.width,
    required this.radius,
  });

  final Color color;
  final double width;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0) return; // fully faded out — nothing to draw
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = color;
    // Inset by half the stroke so the ring sits inside the box (no clipping).
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(width / 2),
      Radius.circular(radius),
    );
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.color != color || old.width != width || old.radius != radius;
}
