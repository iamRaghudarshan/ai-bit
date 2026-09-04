import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../player/floating_player.dart';
import '../player/playback_controller.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'shorts_page.dart';
import 'subscriptions_page.dart';
import 'widgets/mini_player.dart';

/// Bottom-nav shell matching YouTube's destinations: Home, Shorts,
/// Subscriptions, You. Search is not a tab — it lives in the Home top bar,
/// the way YouTube does it. Their middle create (+) button needs an account to
/// upload to, so it is left out.
///
/// Tabs are kept alive in an [IndexedStack] so switching away from the feed and
/// back does not refetch it.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  final _homeKey = GlobalKey<HomePageState>();
  final _libraryKey = GlobalKey<LibraryPageState>();
  final _subsKey = GlobalKey<SubscriptionsPageState>();
  final _shortsKey = GlobalKey<ShortsPageState>();
  int _index = 0;

  void _onTabSelected(int index) {
    final previous = _index;

    // Tapping the tab you are already on means "refresh", as it does in the
    // real app. Without this the tap did nothing at all, which reads as the
    // button being broken.
    if (previous == index) {
      if (index == 0) _homeKey.currentState?.reloadFeed();
      if (index == 2) _subsKey.currentState?.reload();
      if (index == 3) _libraryKey.currentState?.reload();
      return;
    }

    setState(() => _index = index);

    // Shorts autoplays, so leaving the tab has to stop it — otherwise a Short
    // keeps playing underneath the Home feed.
    if (previous == 1 && index != 1) _shortsKey.currentState?.onTabClosed();

    // Tabs are kept alive, so their initState only ever runs once — anything
    // that should happen "on arrival" has to be driven from here.
    switch (index) {
      case 0:
        // Searching elsewhere changes what Home should recommend.
        _homeKey.currentState?.onTabOpened();
      case 1:
        // Shorts loads nothing until first visited: fetching a feed nobody has
        // opened wastes a request on every cold start.
        _shortsKey.currentState?.onTabOpened();
      case 2:
        _subsKey.currentState?.reload();
      case 3:
        _libraryKey.currentState?.reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Shorts is full-bleed and has its own controls; the mini player would sit
    // on top of its action rail.
    final isShorts = _index == 1;

    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          HomePage(key: _homeKey),
          ShortsPage(key: _shortsKey),
          SubscriptionsPage(key: _subsKey),
          LibraryPage(key: _libraryKey),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isShorts) const _NowPlayingBar(),
          const Divider(height: 1),
          NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: _onTabSelected,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.smart_display_outlined),
                selectedIcon: Icon(Icons.smart_display),
                label: 'Shorts',
              ),
              NavigationDestination(
                icon: Icon(Icons.subscriptions_outlined),
                selectedIcon: Icon(Icons.subscriptions),
                label: 'Subscriptions',
              ),
              NavigationDestination(
                icon: Icon(Icons.video_library_outlined),
                selectedIcon: Icon(Icons.video_library),
                label: 'You',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The mini player plus the pop-out button.
///
/// The button is here rather than inside `MiniPlayer` because the shell is the
/// one surface that is on screen for every tab, and because [FloatingPlayer]
/// is a whole-app concern (an Android overlay window, or iOS PiP) rather than
/// a control belonging to one row of UI.
class _NowPlayingBar extends StatefulWidget {
  const _NowPlayingBar();

  @override
  State<_NowPlayingBar> createState() => _NowPlayingBarState();
}

class _NowPlayingBarState extends State<_NowPlayingBar> {
  /// Whether the previous build had something playing, so the transition to
  /// "nothing playing" can be spotted.
  bool _wasPlaying = false;

  @override
  void dispose() {
    // The bubble is a handle back to something that is playing. Once this
    // shell is gone there is nothing for it to be a handle to.
    FloatingPlayer.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // select rather than watch: this bar only cares whether *something* is
    // playing, and the mini player below rebuilds itself on the rest.
    final hasVideo = context.select<PlaybackController, bool>(
      (playback) => playback.current != null,
    );

    if (_wasPlaying && !hasVideo) {
      _wasPlaying = false;
      // Playback stopped, so the floating bubble is now a dead button sitting
      // above every other app on the phone. Deferred off the frame because it
      // is a platform call, not something build should be doing.
      WidgetsBinding.instance.addPostFrameCallback((_) => FloatingPlayer.stop());
    } else if (hasVideo) {
      _wasPlaying = true;
    }

    // MiniPlayer collapses itself to nothing when there is no current video;
    // returning it unwrapped keeps that behaviour exactly as it was.
    if (!hasVideo) return const MiniPlayer();

    final theme = Theme.of(context);
    return Material(
      // The same surface MiniPlayer paints, repeated here so the strip the
      // button sits on does not read as a seam beside it.
      color: theme.brightness == Brightness.dark
          ? AppColors.darkElevated
          : AppColors.lightSurface,
      child: Row(
        children: [
          const Expanded(child: MiniPlayer()),
          const FloatingPlayerButton(),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}
