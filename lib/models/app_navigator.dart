import 'package:flutter/material.dart';

/// App-wide navigator key, shared between [MyApp] (which registers it on the
/// [MaterialApp]) and any widget that lives outside the Navigator's subtree
/// (e.g. the floating mini-player overlay in [MaterialApp.builder]).
///
/// Using a top-level key instead of [Navigator.of(context)] is necessary for
/// widgets that are siblings of the Navigator in the widget tree rather than
/// descendants of it.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// App-wide route observer for the [Player] widget. fix98: lets Player
/// subscribe to didPushNext/didPopNext so it mutes when covered by another
/// route and unmutes when uncovered — preventing audio bleed.
final RouteObserver<PageRoute> playerRouteObserver =
    RouteObserver<PageRoute>();
