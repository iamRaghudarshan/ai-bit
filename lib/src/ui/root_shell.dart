import 'package:flutter/material.dart';

import 'home_page.dart';
import 'library_page.dart';
import 'search_page.dart';
import 'subscriptions_page.dart';
import 'widgets/mini_player.dart';

/// Bottom-nav shell.
///
/// Four destinations rather than YouTube's five: theirs includes a Shorts tab
/// and a create (+) button. Shorts is not built yet, and there is nothing to
/// upload to without an account, so a button for it would be decoration.
///
/// Tabs are kept alive in an [IndexedStack] so switching away from the feed and
/// back does not refetch it.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  final _libraryKey = GlobalKey<LibraryPageState>();
  final _searchKey = GlobalKey<SearchPageState>();
  final _subsKey = GlobalKey<SubscriptionsPageState>();
  int _index = 0;

  void _onTabSelected(int index) {
    setState(() => _index = index);
    // Tabs are kept alive, so their initState only ever runs once — anything
    // that should happen "on arrival" has to be driven from here.
    switch (index) {
      case 1:
        _searchKey.currentState?.focusInput();
      case 2:
        // A subscription may have been added from a channel page since the
        // last visit.
        _subsKey.currentState?.reload();
      case 3:
        _libraryKey.currentState?.reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          const HomePage(),
          SearchPage(key: _searchKey),
          SubscriptionsPage(key: _subsKey),
          LibraryPage(key: _libraryKey),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniPlayer(),
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
                icon: Icon(Icons.search_outlined),
                selectedIcon: Icon(Icons.search),
                label: 'Search',
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
