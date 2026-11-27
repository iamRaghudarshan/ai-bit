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
      // The app's whole UI, passed as the builder's `child` so that a push or
      // a pop rebuilds this wrapper and nothing underneath it.
      child: child,
      builder: (context, child) {
        // select rather than watch: this only cares whether *something* is
        // playing. The mini player inside rebuilds itself on everything else.
        final hasVideo = context.select<PlaybackController, bool>(
          (playback) => playback.current != null,
        );
        // Always the same Stack, with the bar in or out of it. Returning the
        // bare child in one case and a Stack around it in the other changed
        // the shape of the tree above the Navigator every time the bar came
        // or went, which tears down and rebuilds everything between them.
        return Stack(
          // Tight, as the bare child used to be given.
          fit: StackFit.expand,
          children: [
            child!,
            if (hasVideo && routes.wantsNowPlayingBar)
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _Bar(),
              ),
          ],
        );
      },
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar();

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
  /// The routes currently on the stack above the shell, innermost last.
  /// Routes rather than names, so a pop removes exactly the route that went.
  final _stack = <Route<dynamic>>[];

  /// Whether the now-playing bar should be painted over the current route.
  ///
  ///   * **Something is pushed.** On a root tab the shell draws its own bar in
  ///     a better position, so painting a second one would double it up.
  ///   * **The top route is not the player's own screen** — the watch page or
  ///     the fullscreen route the player pushes above it.
  ///
  /// This used to say "the watch page is nowhere in the stack", and that hid
  /// the bar on every screen opened *from* the watch page: tap the channel
  /// name, a playlist or a hashtag and the page went over the watch page, the
  /// video kept playing, and there was no bar anywhere to reopen or close it
  /// from — reported as "the minimised video will not show and will not
  /// close". The fullscreen route is named now (PATCHES.md #29), so asking
  /// about the top route is enough.
  bool get wantsNowPlayingBar {
    if (_popups != 0 || _stack.isEmpty) return false;
    final top = _stack.last.settings.name;
    return top != watchRouteName &&
        top != fullscreenRouteName &&
        // Nor over the full-screen Shorts player: it is its own player
        // screen, and a bar there would cover the Short's caption and rail.
        top != shortsRouteName &&
        // Nor over the app-lock PIN pad: a bar with the playing video's title
        // and artwork on the lock screen gives away exactly what the lock
        // hides.
        top != appLockRouteName;
  }

  /// Watch pages still on the stack — buried under something opened from
  /// them, since the bar is only shown when none is on top.
  List<Route<dynamic>> get watchRoutes => [
        for (final r in _stack)
          if (r.settings.name == watchRouteName) r,
      ];

  /// Route name given to the watch page, so it can be recognised here.
  static const watchRouteName = 'watch';

  /// Route name the vendored player gives its fullscreen route.
  static const fullscreenRouteName = 'better-player-fullscreen';

  /// Route name given to the full-screen Shorts player (`ShortsRoute`).
  static const shortsRouteName = 'shorts';

  /// Route name given to the app-lock PIN pad.
  static const appLockRouteName = 'app-lock';

  void _update(void Function() change) {
    final before = wantsNowPlayingBar;
    change();
    if (wantsNowPlayingBar != before) notifyListeners();
  }

  /// Bottom sheets, menus and dialogs open right now.
  ///
  /// They are routes too, and counting them as pushed pages painted the bar
  /// over every sheet opened from a tab — on an emulator it covered the last
  /// two rows of a video's menu, "Not interested" and "Don't recommend
  /// channel", so they could not be reached. A popup is drawn over the bar
  /// rather than under it, as on YouTube.
  int _popups = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      _update(() => _popups++);
      return;
    }
    // The first route is the shell itself and is not "pushed" for this
    // purpose; everything above it is.
    if (previousRoute == null) return;
    _update(() => _stack.add(route));
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      _update(() => _popups = _popups > 0 ? _popups - 1 : 0);
      return;
    }
    _update(() => _remove(route));
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      _update(() => _popups = _popups > 0 ? _popups - 1 : 0);
      return;
    }
    _update(() => _remove(route));
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
      } else if (newRoute != null) {
        _stack.add(newRoute);
      }
    });
  }

  /// Removes exactly [route]. Routes do not always leave in the order they
  /// came — a `popUntil`, a `removeRoute`, a dialog dismissed behind a page
  /// transition — and dropping the wrong entry would leave the stack out of
  /// step with reality, which shows up as a bar that never comes back. The
  /// shell's own route is not in the list, so a miss is simply ignored.
  void _remove(Route<dynamic> route) => _stack.remove(route);
}
