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

class _RootShellState extends State<RootShell>
    with SingleTickerProviderStateMixin {
  final _homeKey = GlobalKey<HomePageState>();
  final _libraryKey = GlobalKey<LibraryPageState>();
  final _subsKey = GlobalKey<SubscriptionsPageState>();
  final _shortsKey = GlobalKey<ShortsPageState>();
  int _index = 0;

  /// Primary scroll controllers for Subscriptions and You, so a re-tap can
  /// take them to the top without either page exposing a hook for it.
  ///
  /// Their feeds are vertical scroll views with no controller of their own,
  /// which on a phone inherit the nearest [PrimaryScrollController] — this
  /// one. (It also makes the iOS status-bar tap scroll the visible tab.) A
  /// page that later gives its list its own controller simply opts out:
  /// the re-tap then falls through to the reload it did before.
  final _subsScroll = ScrollController();
  final _libraryScroll = ScrollController();

  /// One controller for the tab-switch transition, restarted on every switch:
  /// the incoming tab fades in and rises a few pixels, YouTube's ~200ms.
  /// Driving the IndexedStack as a whole is what keeps it one controller —
  /// only the selected child paints, so the animation is the incoming tab's.
  late final AnimationController _tabIn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 1,
  );
  late final Animation<double> _tabFade =
      CurvedAnimation(parent: _tabIn, curve: Curves.easeOut);
  late final Animation<Offset> _tabSlide = Tween(
    begin: const Offset(0, 0.015),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _tabIn, curve: Curves.easeOutCubic));

  @override
  void dispose() {
    _tabIn.dispose();
    _subsScroll.dispose();
    _libraryScroll.dispose();
    super.dispose();
  }

  /// Animates [controller] to the top if it is scrolled at all, and says
  /// whether it did — false means the tab was already at the top.
  static bool _scrollToTop(ScrollController controller) {
    if (!controller.hasClients) return false;
    final positions = controller.positions.toList();
    if (!positions.any((p) => p.pixels > 0)) return false;
    for (final position in positions) {
      position.animateTo(
        0,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    }
    return true;
  }

  void _onTabSelected(int index) {
    final previous = _index;

    // Tapping the tab you are already on: back to the top if scrolled, and a
    // refresh if already there — what the real app does. Without this the
    // tap did nothing at all, which reads as the button being broken.
    if (previous == index) {
      switch (index) {
        case 0:
          _homeKey.currentState?.onReselected();
        case 1:
          // Back to the first Short and a fresh feed, as YouTube does.
          _shortsKey.currentState?.refresh();
        case 2:
          if (!_scrollToTop(_subsScroll)) _subsKey.currentState?.reload();
        case 3:
          if (!_scrollToTop(_libraryScroll)) {
            _libraryKey.currentState?.reload();
          }
      }
      return;
    }

    setState(() => _index = index);
    _tabIn.forward(from: 0);

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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    Widget nav = NavigationBar(
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
          icon: Icon(Icons.account_circle_outlined),
          selectedIcon: Icon(Icons.account_circle),
          label: 'You',
        ),
      ],
    );
    if (isShorts) {
      // Black with white icons in either theme, as YouTube's bar is over a
      // Short: a white bar under a full-bleed video is a seam.
      nav = Theme(
        data: theme.copyWith(
          navigationBarTheme: theme.navigationBarTheme.copyWith(
            backgroundColor: AppColors.shortsBar,
            iconTheme: const WidgetStatePropertyAll(
              IconThemeData(size: 24, color: Colors.white),
            ),
            labelTextStyle: const WidgetStatePropertyAll(
              TextStyle(
                fontSize: 10,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
        child: nav,
      );
    }

    return Scaffold(
      body: FadeTransition(
        opacity: _tabFade,
        child: SlideTransition(
          position: _tabSlide,
          child: IndexedStack(
            index: _index,
            children: [
              HomePage(key: _homeKey),
              ShortsPage(key: _shortsKey),
              PrimaryScrollController(
                controller: _subsScroll,
                child: SubscriptionsPage(key: _subsKey),
              ),
              PrimaryScrollController(
                controller: _libraryScroll,
                child: LibraryPage(key: _libraryKey),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isShorts) const _NowPlayingBar(),
          // A hairline in light mode only; YouTube's dark bar has none.
          if (!isShorts && !isDark) const Divider(height: 1),
          nav,
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
