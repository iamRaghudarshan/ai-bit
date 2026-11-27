import 'package:flutter/widgets.dart';

import '../ui/widgets/now_playing_overlay.dart';

/// The app's one Navigator, reachable from anywhere.
///
/// Needed by everything that lives in `MaterialApp.builder` — the app-lock
/// shield and the now-playing bar painted over pushed routes. Those are built
/// *outside* the Navigator they wrap, so `Navigator.of(context)` from them
/// throws, and the throw is swallowed by the tap handler: tapping the bar over
/// a channel page or a playlist did nothing at all, which was reported as
/// "the minimised video will not open".
final appNavigatorKey = GlobalKey<NavigatorState>();

/// Tracks the navigation stack so the now-playing bar can be painted over
/// pushed routes. See [NowPlayingOverlay].
final appRouteStack = RouteStackObserver();

/// The navigator for [context] if it has one, else the app's.
NavigatorState? navigatorFor(BuildContext context) =>
    Navigator.maybeOf(context) ?? appNavigatorKey.currentState;

/// [text] where a tooltip can be shown, null where it cannot.
///
/// A tooltip floats in an [Overlay], and the now-playing bar over pushed
/// screens is built above the Navigator, which is where the app's Overlay
/// lives. A long-press there threw "No Overlay widget found" and the error
/// replaced the button it was pressed on.
String? tooltipIfPossible(BuildContext context, String text) =>
    Overlay.maybeOf(context) == null ? null : text;
