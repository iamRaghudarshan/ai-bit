import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../player/floating_player.dart';
import '../../player/playback_controller.dart';
import 'mini_player.dart';

/// Keeps the now-playing bar on screen on every route, not only the four tabs.
///
/// The mini player used to live in `RootShell.bottomNavigationBar`, which is
/// exactly as far as it reached: open a channel, a playlist, search, history or
/// settings and the route covered the shell, so the bar — and with it the only
/// handle back to what was playing — vanished. The audio kept going, which
/// made it worse rather than better: something was clearly playing and there
/// was no way to pause it or get back to it without walking back through the
/// navigation stack.
///
/// YouTube does not have this problem because its channel and playlist screens
/// render *inside* the tab shell, so the bar below them never goes away.
/// Matching that here would mean a nested `Navigator` per tab and re-testing
/// every push in the app, including the watch page's non-opaque slide-up
/// route. This takes the shorter path to the same visible behaviour: the bar
/// is painted over whatever route is on top, from [MaterialApp.builder], the
/// same place `_AppLockGate` sits and for the same reason — a builder wraps the
/// Navigator, so it covers every pushed route instead of sitting under them.
///
/// It appears only on pushed routes. On the four root tabs the shell's own bar
/// is already there and is laid out *above* the navigation bar rather than over
/// it, which is the better arrangement where it is available.
class NowPlayingOverlay extends StatelessWidget {
  const NowPlayingOverlay({required this.routes, required this.child, super.key});

  /// The live view of the navigation stack. See [RouteStackObserver].
  final RouteStackObserver routes;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: routes,
      builder: (context, _) {
        // select rather than watch: this only cares whether *something* is
        // playing. The mini player inside rebuilds itself on everything else.
        final hasVideo = context.select<PlaybackController, bool>(
          (playback) => playback.current != null,
        );
        if (!hasVideo || !routes.wantsNowPlayingBar) return child;

        return Stack(
          children: [
            child,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _Bar(),
            ),
          ],
        );
      },
      child: child,
    );
  }
}

class _Bar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.brightness == Brightness.dark
          ? AppColors.darkElevated
          : AppColors.lightSurface,
      // Elevated, because here it really is floating over someone else's
      // content rather than sitting in a column above the navigation bar.
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Divider(height: 1),
            Row(
              children: const [
                Expanded(child: MiniPlayer()),
                FloatingPlayerButton(),
                SizedBox(width: 4),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Watches the navigator so the overlay knows where it is.
///
/// A [NavigatorObserver] rather than something read out of the widget tree,
/// because [MaterialApp.builder] runs *outside* the Navigator it wraps: there
/// is no route to ask about from in there. Installed through
/// `MaterialApp.navigatorObservers`.
///
/// It is a [ChangeNotifier] so the overlay can rebuild on a push or a pop, and
/// it notifies only when the answer actually changes — a push and pop happen
/// on every navigation and most of them do not alter whether the bar belongs
/// on screen.
class RouteStackObserver extends NavigatorObserver with ChangeNotifier {
  /// Names of the routes currently on the stack, innermost last.
  final _stack = <String?>[];

  /// Whether the now-playing bar should be painted over the current route.
  ///
  /// Two conditions, and both matter:
  ///
  ///   * **Something is pushed.** On a root tab the shell draws its own bar in
  ///     a better position, so painting a second one would double it up.
  ///   * **The watch page is nowhere in the stack.** Not merely "is not on
  ///     top": the player's own fullscreen route is pushed *above* the watch
  ///     page, and a mini player floating over a fullscreen video is absurd.
  ///     Asking about the whole stack covers fullscreen, picture-in-picture
  ///     and anything else the watch page opens, without having to name them.
  bool get wantsNowPlayingBar =>
      _stack.isNotEmpty && !_stack.contains(watchRouteName);

  /// Route name given to the watch page, so it can be recognised here.
  static const watchRouteName = 'watch';

  void _update(void Function() change) {
    final before = wantsNowPlayingBar;
    change();
    if (wantsNowPlayingBar != before) notifyListeners();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // The first route is the shell itself and is not "pushed" for this
    // purpose; everything above it is.
    if (previousRoute == null) return;
    _update(() => _stack.add(route.settings.name));
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _update(() => _removeLast(route.settings.name));
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _update(() => _removeLast(route.settings.name));
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _update(() {
      _removeLast(oldRoute?.settings.name);
      if (newRoute != null) _stack.add(newRoute.settings.name);
    });
  }

  /// Removes the topmost entry matching [name].
  ///
  /// By name rather than blindly dropping the last element: routes do not
  /// always pop in the order they were pushed — a `popUntil`, or a dialog
  /// dismissed behind a page transition, can interleave them — and dropping
  /// the wrong entry would leave the stack permanently out of step with
  /// reality, which shows up as a bar that never comes back.
  void _removeLast(String? name) {
    final index = _stack.lastIndexOf(name);
    if (index >= 0) {
      _stack.removeAt(index);
    } else if (_stack.isNotEmpty) {
      _stack.removeLast();
    }
  }
}
