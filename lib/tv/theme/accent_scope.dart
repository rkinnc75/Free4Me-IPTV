import 'package:flutter/widgets.dart';

/// fix701 (TV GUI redesign, Phase 0) — the single live accent color for TV mode.
///
/// One user-selectable accent (ROYGBIV, default **White**) recolors every focus
/// ring / selected chip at draw time. It lives in an [InheritedNotifier] high in
/// the tree (above the `MaterialApp` content) so changing it notifies ONLY the
/// widgets that read it — no `MaterialApp` rebuild, no theme churn, and (since
/// Flutter never recreates the Activity) the player `Texture` never stutters.
///
/// This mirrors Peer4's `LocalAccentColorOverride`. Static tokens live in
/// `F4Tokens` (a `ThemeExtension`); only the accent is live, hence separate.
///
/// Read at draw time:
/// ```dart
/// final accent = AccentScope.of(context); // rebuilds this widget on change
/// ```
class AccentScope extends InheritedNotifier<ValueNotifier<Color>> {
  const AccentScope({
    super.key,
    required ValueNotifier<Color> notifier,
    required super.child,
  }) : super(notifier: notifier);

  /// The current accent. Depends on the scope, so the caller rebuilds when the
  /// accent changes. Falls back to white if no scope is present (defensive; the
  /// TV tree always installs one).
  static Color of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AccentScope>();
    return scope?.notifier?.value ?? const Color(0xFFFFFFFF);
  }

  /// The backing notifier, WITHOUT subscribing to changes — for the settings
  /// accent picker to write a new value.
  static ValueNotifier<Color>? notifierOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<AccentScope>()?.notifier;
  }
}

/// The ROYGBIV accent palette, user-selectable. Default (unknown / null) =
/// White, the neutral focus ring. `blue` doubles as our Live-TV identity blue.
Color accentFromName(String? name) => switch (name) {
  'red' => const Color(0xFFFF4444),
  'orange' => const Color(0xFFFF8800),
  'yellow' => const Color(0xFFFFDD44),
  'green' => const Color(0xFF44CC44),
  'blue' => const Color(0xFF4488FF),
  'indigo' => const Color(0xFF6644CC),
  'violet' => const Color(0xFFBB44CC),
  _ => const Color(0xFFFFFFFF), // White = default
};

/// fix701: the app-wide TV accent notifier. Installed by [AccentScope] high in
/// the widget tree (main.dart). Default White; the Settings accent picker (a
/// later redesign phase) sets its value to recolor every focus ring live with
/// no `MaterialApp` rebuild.
final ValueNotifier<Color> appAccentNotifier = ValueNotifier<Color>(
  accentFromName(null),
);

/// The selectable accent names, in ROYGBIV order with White first (default).
const List<String> kAccentNames = <String>[
  'white',
  'red',
  'orange',
  'yellow',
  'green',
  'blue',
  'indigo',
  'violet',
];
