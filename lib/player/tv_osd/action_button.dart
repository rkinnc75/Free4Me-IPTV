import 'package:flutter/material.dart';
import 'package:open_tv/tv/theme/f4_motion.dart';

/// fix715 (Phase 4 — TV player OSD, unit 2) — an OSD action button with the
/// Peer2 focus **lift**.
///
/// Wraps the overlay's `IconButton` so it scales up on focus (the "2→8dp lift"
/// feel), on top of the accent focus **ring** the global TV `iconButtonTheme`
/// already draws (fix707). This is Option B: the reveal trigger and all
/// D-pad / `_navMode` behavior are UNCHANGED — only the focused button's look.
///
/// The `IconButton` still owns focus via [focusNode] (the caller's node when
/// given — e.g. play/pause's autofocus node — otherwise an internal one), so
/// traversal, activation, and the fix707 ring are untouched; this widget only
/// observes that node to drive the scale. [onInteract] fires before [onTap]
/// (it resets the overlay auto-hide timer, preserving `_ovlButton`'s old
/// onPressed behavior).
class OsdActionButton extends StatefulWidget {
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  final VoidCallback onInteract;
  final FocusNode? focusNode;

  const OsdActionButton({
    super.key,
    required this.icon,
    required this.tip,
    required this.onTap,
    required this.onInteract,
    this.focusNode,
  });

  @override
  State<OsdActionButton> createState() => _OsdActionButtonState();
}

class _OsdActionButtonState extends State<OsdActionButton> {
  FocusNode? _own;
  FocusNode get _node => widget.focusNode ?? (_own ??= FocusNode());
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocusChange);
  }

  // Robustness (review): if a rebuild ever hands this State a different
  // focusNode (today the StreamBuilder around play/pause prevents positional
  // reuse across the one caller-node button, so this is latent — but cheap
  // insurance against a future second focusNode: caller), move the listener
  // from the previously-observed node to the new one.
  @override
  void didUpdateWidget(OsdActionButton old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _own)?.removeListener(_onFocusChange);
      _node.addListener(_onFocusChange);
      _onFocusChange();
    }
  }

  void _onFocusChange() {
    if (mounted && _node.hasFocus != _focused) {
      setState(() => _focused = _node.hasFocus);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChange);
    // Only dispose a node we created; a caller-supplied node is theirs.
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      // OSD icons are small (34px) — a slightly stronger lift than the content
      // tiles' 1.05 so the raise reads clearly against the video behind glass.
      scale: _focused ? 1.15 : 1.0,
      duration: F4Motion.fast,
      curve: F4Motion.easeOut,
      child: IconButton(
        focusNode: _node,
        icon: Icon(widget.icon, color: Colors.white, size: 34),
        tooltip: widget.tip,
        onPressed: () {
          widget.onInteract();
          widget.onTap();
        },
      ),
    );
  }
}
