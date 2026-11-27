import 'package:better_player_plus/better_player_plus.dart'
    show BetterPlayerController;
import 'package:flutter/widgets.dart';

import '../ui/player_sheet_controller.dart';

/// The app's ROOT Navigator — the one `MaterialApp` owns.
///
/// Only things that must cover everything, the player layer and the bottom
/// navigation bar included, go here: dialogs (the `showDialog` default),
/// bottom sheets (`useRootNavigator: true` at every call site), the player's
/// fullscreen route (the vendored plugin pushes with `rootNavigator: true`),
/// the app-lock PIN pad, the forced-update screen. Its only page is
/// `RootShell`.
///
/// Also used from code that runs with no context of its own — incoming links,
/// the launch-time update check, the app-lock gate in `MaterialApp.builder`.
final appNavigatorKey = GlobalKey<NavigatorState>();

/// The CONTENT Navigator inside `RootShell`, whose first route is the four
/// tabs. Every ordinary page — channel, playlist, search, settings, history,
/// downloads, the full-screen Shorts player — is pushed here, so it opens
/// UNDER the player layer with the navigation bar still visible, as on
/// YouTube. `Navigator.of(context)` from inside a tab already lands here;
/// [pushContent] is for code that may run from the player layer or a root
/// sheet, where the nearest Navigator is the root one.
final contentNavigatorKey = GlobalKey<NavigatorState>();

/// Watches [contentNavigatorKey], so the shell knows how deep the content
/// stack is (system back) and whether the full-screen Shorts player is on top
/// (which hides the player layer).
final contentRouteStack = ContentRouteObserver();

/// Route names the app recognises.
abstract final class AppRoutes {
  /// The full-screen Shorts player (`ShortsRoute`). The player sheet is
  /// hidden while it is on top of the content stack.
  static const shorts = 'shorts';

  /// The app-lock PIN pad.
  static const appLock = 'app-lock';
}

/// Pushes [route] onto the content navigator, collapsing the player sheet
/// first if it is expanded — tapping the channel name on the watch page opens
/// the channel under the minimised player, exactly as YouTube does.
///
/// Falls back to the nearest navigator before the shell exists (tests, the
/// first frame).
Future<T?> pushContent<T extends Object?>(
  BuildContext context,
  Route<T> route,
) {
  // The player's fullscreen route sits on the ROOT navigator, above the shell,
  // so a page pushed under it (a shared playlist link arriving mid-video)
  // would open unseen. Leaving fullscreen first shows it.
  // Not in PiP, which the plugin also presents through its fullscreen route.
  final player = playerForContent?.call();
  if (player != null &&
      player.isFullScreen &&
      !(player.videoPlayerController?.value.isPip ?? false)) {
    player.exitFullScreen();
  }
  final content = contentNavigatorKey.currentState;
  if (content == null || !content.mounted) {
    return Navigator.of(context).push(route);
  }
  PlayerSheetController.instance?.collapse();
  return content.push(route);
}

/// The live player, for [pushContent]. Set by `RootShell`, which can read
/// the `PlaybackController`; a hook rather than a provider lookup so this
/// file needs neither the controller nor a context that has one.
BetterPlayerController? Function()? playerForContent;

/// The navigator for [context] if it has one, else the app's root one.
NavigatorState? navigatorFor(BuildContext context) =>
    Navigator.maybeOf(context) ?? appNavigatorKey.currentState;

/// [text] where a tooltip can be shown, null where it cannot.
///
/// A tooltip floats in an [Overlay]; asked for from a widget with no Overlay
/// above it, a long-press threw "No Overlay widget found".
String? tooltipIfPossible(BuildContext context, String text) =>
    Overlay.maybeOf(context) == null ? null : text;

/// The content navigator's stack, as far as the shell needs it.
///
/// A [NavigatorObserver] rather than something read from the tree, so a push
/// or a pop anywhere in the content stack is heard without each page having to
/// report it. It notifies only when an answer actually changes.
class ContentRouteObserver extends NavigatorObserver with ChangeNotifier {
  /// Pages on the content stack, innermost last. The first entry is the tab
  /// shell's own route. Bottom sheets, menus and dialogs are not pages and are
  /// not counted.
  final _stack = <Route<dynamic>>[];

  /// Whether system back has a content page to pop — anything above the tabs.
  bool get canPop => _stack.length > 1;

  /// Whether the full-screen Shorts player is the page on top. The player
  /// sheet hides while it is: a Short is its own player, and a mini player
  /// over its caption and action rail would be absurd.
  bool get shortsOnTop =>
      _stack.isNotEmpty && _stack.last.settings.name == AppRoutes.shorts;

  /// Whether the tabs themselves are showing, with nothing pushed over them.
  bool get atRoot => _stack.length <= 1;

  /// Whether [route] is the page on top of the content stack — what a pushed
  /// Shorts player asks to know it is the one on screen. True when nothing
  /// is being observed (no shell: tests, a route pushed on a fallback
  /// navigator), so a page outside the shell is not left believing it is
  /// covered for ever.
  bool isTop(Route<dynamic>? route) =>
      _stack.isEmpty || (route != null && identical(_stack.last, route));

  /// The page on top of the content stack, notified whenever it changes —
  /// including one Shorts player pushed over another, which leaves [canPop]
  /// and [shortsOnTop] as they were. A separate notifier so the shell, which
  /// listens to this observer itself, still rebuilds only when its answers
  /// change.
  final ValueNotifier<Route<dynamic>?> top = ValueNotifier(null);

  void _update(void Function() change) {
    final before = (canPop, shortsOnTop);
    change();
    top.value = _stack.lastOrNull;
    if ((canPop, shortsOnTop) != before) notifyListeners();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) return;
    _update(() => _stack.add(route));
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) return;
    _update(() => _stack.remove(route));
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) return;
    _update(() => _stack.remove(route));
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _update(() {
      final index = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
      if (index >= 0) {
        if (newRoute != null) {
          _stack[index] = newRoute;
        } else {
          _stack.removeAt(index);
        }
      } else if (newRoute != null && newRoute is! PopupRoute) {
        _stack.add(newRoute);
      }
    });
  }
}
