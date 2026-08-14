import 'package:flutter/material.dart';

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
          if (!isShorts) const MiniPlayer(),
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
