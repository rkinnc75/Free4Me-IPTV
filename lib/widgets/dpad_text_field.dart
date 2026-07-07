import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A [TextField] that does not trap Android TV D-pad up/down navigation.
///
/// Flutter's stock [TextField] absorbs every arrow key for caret movement
/// once it has keyboard focus. On a TV remote this means a user who types
/// a search query has no way to leave the field with the D-pad — up/down
/// just move the caret within the (often single-line) text.
///
/// This wrapper:
///   * Lets ArrowLeft / ArrowRight reach the inner [TextField] so caret
///     movement and standard text editing still work.
///   * Returns [KeyEventResult.ignored] for ArrowUp / ArrowDown so the
///     parent [FocusTraversalGroup] / [FocusScope] can move focus to the
///     next focusable widget.
///   * Treats Enter / Select as "submit and move on" — calls [onSubmitted]
///     (if provided) and yields focus by calling `node.nextFocus()`.
///
/// Behaviour on a touch screen is unchanged: drag and tap still work and
/// the soft keyboard's own Enter key still dismisses the field.
class DpadTextField extends StatelessWidget {
  final TextEditingController? controller;
  final InputDecoration? decoration;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputType? keyboardType;
  final TextStyle? style;
  final bool autofocus;
  final bool obscureText;
  final int? maxLines;
  final FocusNode? focusNode;
  final bool enabled;
  // fix600: optional deterministic D-pad DOWN target. When provided and it
  // returns true, it OVERRIDES the default node.nextFocus() — which relies on
  // Flutter's directional traversal and does not reliably reach a specific
  // widget across stacked grids (flutter/flutter#70364). Return false to fall
  // back to nextFocus() (e.g. when there is no target yet).
  final bool Function()? onArrowDown;
  // fix603: when true, pressing Enter/Select does NOT yield focus via
  // node.nextFocus() after onSubmitted — the caller keeps/redirects focus
  // itself (e.g. the search view focuses the first result card once the async
  // search returns). Default false preserves the move-to-next-field behaviour
  // used by forms (settings, setup, channel-picker).
  final bool submitKeepsFocus;

  const DpadTextField({
    super.key,
    this.controller,
    this.decoration,
    this.onChanged,
    this.onSubmitted,
    this.keyboardType,
    this.style,
    this.autofocus = false,
    this.obscureText = false,
    this.maxLines = 1,
    this.focusNode,
    this.enabled = true,
    this.onArrowDown,
    this.submitKeepsFocus = false,
  });

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      node.previousFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      // fix600: prefer the explicit DOWN target (e.g. the first search result
      // card) over directional traversal, which is unreliable here.
      if (onArrowDown != null && onArrowDown!()) {
        return KeyEventResult.handled;
      }
      node.nextFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      // Submit the current text and (by default) yield focus so the user can
      // return to navigating the rest of the screen with the D-pad. fix603: the
      // search view keeps focus (submitKeepsFocus) and redirects to the first
      // result card itself once the async search returns — node.nextFocus()
      // here would escape to the tab bar (and strand focus when there are no
      // results).
      final text = controller?.text ?? '';
      onSubmitted?.call(text);
      if (!submitKeepsFocus) node.nextFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      // skipTraversal:false (default) so this widget IS reachable by D-pad,
      // but onKeyEvent intercepts up/down before the TextField sees them.
      onKeyEvent: _handleKey,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        enabled: enabled,
        decoration: decoration,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        keyboardType: keyboardType,
        style: style,
        obscureText: obscureText,
        maxLines: maxLines,
      ),
    );
  }
}

/// Wraps any text-input widget (e.g. [FormBuilderTextField]) in a [Focus]
/// that intercepts D-pad up/down before the inner field receives them.
///
/// Use this when you need the dpad-escape behaviour for a widget that
/// isn't a plain [TextField] and so can't be swapped out for
/// [DpadTextField].
class DpadFocusEscape extends StatelessWidget {
  final Widget child;
  const DpadFocusEscape({super.key, required this.child});

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      node.previousFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      node.nextFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(onKeyEvent: _handleKey, child: child);
  }
}
