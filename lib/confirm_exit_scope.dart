import 'dart:async';

import 'package:flutter/material.dart';

/// fix587 (#23): wraps a top-level screen so that, when [enabled], a Back press
/// that would EXIT the app first shows a "Press Back again to exit" hint, and
/// only a second Back within [window] actually exits.
///
/// Two design points learned from the earlier (reverted) attempt:
///   1. This must wrap the SCREEN (Home / TvShell / SettingsView), NOT the root
///      MaterialApp — the phone bottom-nav rebuilds the root via
///      Navigator.pushAndRemoveUntil, which discards a root-level PopScope.
///   2. It must only intercept when Back would actually exit the app. When the
///      enclosing route can still pop (e.g. Settings opened as a sub-route on
///      TV), Back falls through normally so the user is never trapped — that is
///      the `!Navigator.canPop()` guard below.
class ConfirmExitScope extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final Duration window;

  const ConfirmExitScope({
    super.key,
    required this.child,
    required this.enabled,
    this.window = const Duration(seconds: 2),
  });

  // finding 70: a nested PopScope (e.g. the TV guide rail) that consumes a
  // blocked Back within the same frame calls [notePopConsumed] so this scope's
  // callback — which Flutter also fires for that one Back — skips arming the
  // exit prompt. The post-frame callback clears the flag so a genuine root Back
  // still arms normally on the next press.
  static bool _popConsumedThisFrame = false;

  static void notePopConsumed() {
    _popConsumedThisFrame = true;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _popConsumedThisFrame = false);
  }

  @override
  State<ConfirmExitScope> createState() => _ConfirmExitScopeState();
}

class _ConfirmExitScopeState extends State<ConfirmExitScope> {
  bool _armed = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _disarm() {
    _timer?.cancel();
    _timer = null;
    if (mounted && _armed) setState(() => _armed = false);
  }

  @override
  Widget build(BuildContext context) {
    // Only guard a Back that would leave the app: nothing left to pop to.
    final atRoot = !Navigator.of(context).canPop();
    final blocking = widget.enabled && atRoot && !_armed;
    return PopScope(
      canPop: !blocking,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // finding 70: a nested PopScope already handled this Back this frame —
        // don't arm the exit prompt or show the hint.
        if (ConfirmExitScope._popConsumedThisFrame) return;
        // We just blocked an exit-Back: arm the second press + show the hint,
        // then auto-disarm after the window so a later lone Back re-prompts.
        _timer?.cancel();
        _timer = Timer(widget.window, _disarm);
        setState(() => _armed = true);
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.hideCurrentSnackBar();
        messenger?.showSnackBar(
          SnackBar(
            content: const Text('Press Back again to exit'),
            duration: widget.window,
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
      child: widget.child,
    );
  }
}
