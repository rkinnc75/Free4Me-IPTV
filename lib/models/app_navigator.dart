import 'package:flutter/material.dart';

/// App-wide navigator key, shared between [MyApp] (which registers it on the
/// [MaterialApp]) and any widget that lives outside the Navigator's subtree
/// (e.g. the floating mini-player overlay in [MaterialApp.builder]).
///
/// Using a top-level key instead of [Navigator.of(context)] is necessary for
/// widgets that are siblings of the Navigator in the widget tree rather than
/// descendants of it.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
