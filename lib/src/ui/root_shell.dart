import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../core/app_navigator.dart';
import '../core/theme.dart';
import '../player/playback_controller.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'player_sheet.dart';
import 'player_sheet_controller.dart';
import 'shorts_page.dart';
import 'subscriptions_page.dart';

/// Bottom-nav shell matching YouTube's destinations: Home, Shorts,
/// Subscriptions, You. Search is not a tab — it lives in the Home top bar,
/// the way YouTube does it. Their middle create (+) button needs an account to
/// upload to, so it is left out.
///
/// Three layers, bottom to top, as in YouTube's Android app:
///
///  1. **The content navigator** ([contentNavigatorKey]). Its first route is
///     the four tabs, kept alive in an [IndexedStack]; every page opened from
///     them — channel, playlist, search, settings, the full-screen Shorts
///     player — is pushed onto it, so it opens under the player with the
///     navigation bar still there. It is laid out above the navigation bar
///     and, while something plays, above the docked mini player, so no page
///     ever has content hidden under either.
///  2. **The navigation bar**, which slides down out of the way as the player
///     expands and back as it collapses, following the sheet frame by frame.
///  3. **The player sheet** ([PlayerSheet]): the watch page and the mini
///     player as two ends of one draggable surface.
///
/// Dialogs and bottom sheets go to the ROOT navigator, above all three.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  /// See [_RootShellState.leaveShorts].
  static Future<void> leaveShorts() => _RootShellState.leaveShorts();

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> with TickerProviderStateMixin {
  final _homeKey = GlobalKey<HomePageState>();
  final _libraryKey = GlobalKey<LibraryPageState>();
  final _subsKey = GlobalKey<SubscriptionsPageState>();
  final _shortsKey = GlobalKey<ShortsPageState>();
  final _tab = ValueNotifier<int>(0);
  int get _index => _tab.value;

  /// NavigationBar's height in this app's theme (`navigationBarTheme.height`),
  /// before the system's bottom inset.
  static const _navBarHeight = 56.0;

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

  late final PlayerSheetController _sheet = PlayerSheetController(vsync: this);

  /// Built once: the content navigator and the tabs page inside it. Handing
  /// the same instances back on every shell rebuild is what keeps a sheet
  /// expanding or a page being pushed from rebuilding all four tabs.
  late final Widget _contentNavigator = Navigator(
    key: contentNavigatorKey,
    observers: [contentRouteStack],
    onGenerateRoute: (settings) => PageRouteBuilder<void>(
      settings: settings,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => _tabsPage,
    ),
  );

  late final Widget _tabsPage = ValueListenableBuilder<int>(
    valueListenable: _tab,
    builder: (context, index, _) => FadeTransition(
      opacity: _tabFade,
      child: SlideTransition(
        position: _tabSlide,
        child: IndexedStack(
          index: index,
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
  );

  @override
  void initState() {
    super.initState();
    _instance = this;
    _sheet.addListener(_onChromeChanged);
    contentRouteStack.addListener(_onChromeChanged);
    // pushContent leaves the player's fullscreen before pushing under it.
    playerForContent = () => context.read<PlaybackController>().player;
  }

  @override
  void dispose() {
    if (identical(_instance, this)) _instance = null;
    playerForContent = null;
    _sheet.removeListener(_onChromeChanged);
    contentRouteStack.removeListener(_onChromeChanged);
    _sheet.dispose();
    _tab.dispose();
    _tabIn.dispose();
    _subsScroll.dispose();
    _libraryScroll.dispose();
    super.dispose();
  }

  /// The sheet settled somewhere new, or a content page came or went. Both can
  /// be reported from inside a build (a route pushed by a widget's own build,
  /// a stop issued from a dispose), where setState is not allowed, so a
  /// rebuild asked for then waits for the frame to finish.
  void _onChromeChanged() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  /// Leaves the Shorts tab or the full-screen Shorts player, if either is
  /// showing, and completes once the Short they were playing has been
  /// stopped. For a video opened from outside the app (a shared link) while
  /// Shorts fill the screen: the sheet is hidden there, and the Short's own
  /// stop-on-leave would otherwise land after — and cancel — the new play.
  static Future<void> leaveShorts() async {
    final state = _instance;
    if (state == null || !state.mounted) return;
    var left = false;
    if (contentRouteStack.shortsOnTop) {
      contentNavigatorKey.currentState?.popUntil(
        (route) => route.settings.name != AppRoutes.shorts,
      );
      left = true;
    }
    if (state._index == 1 && contentRouteStack.atRoot) {
      state._onTabSelected(0);
      left = true;
    }
    if (!left) return;
    // The route's exit transition, then its dispose and the microtask that
    // stops its Short.
    await Future<void>.delayed(const Duration(milliseconds: 350));
  }

  static _RootShellState? _instance;

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

    // A page pushed over the tabs (a channel, settings) goes first: a tab is
    // a destination, and landing on it under someone else's page would hide
    // it. Tapping the tab you are already on then does just that, like
    // YouTube's re-tap from inside a channel.
    final content = contentNavigatorKey.currentState;
    if (contentRouteStack.canPop && content != null) {
      content.popUntil((route) => route.isFirst);
      if (previous == index) return;
    }

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

    setState(() => _tab.value = index);
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

  /// System back. See [sheetBackAction] for the order.
  void _onBack(bool sheetShown) {
    final player = context.read<PlaybackController>().player;
    final action = sheetBackAction(
      fullscreen: player?.isFullScreen ?? false,
      expanded: sheetShown && _sheet.isExpanded,
      contentCanPop: contentRouteStack.canPop,
    );
    switch (action) {
      case SheetBackAction.exitFullscreen:
        player?.exitFullScreen();
      case SheetBackAction.collapse:
        _sheet.collapse();
      case SheetBackAction.popContent:
        contentNavigatorKey.currentState?.maybePop();
      case SheetBackAction.system:
        // Not reached: the PopScope lets the pop through in this case.
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final outer = MediaQuery.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Shorts is full-bleed and is its own player: on the Shorts tab, and
    // under the full-screen Shorts player, there is no sheet at all.
    final shortsShowing =
        (_index == 1 && contentRouteStack.atRoot) ||
        contentRouteStack.shortsOnTop;
    final hasVideo = context.select<PlaybackController, bool>(
      (p) => p.current != null && !p.onShortsSurface,
    );
    final sheetShown =
        !shortsShowing && (hasVideo || _sheet.requested != null);
    final expanded = sheetShown && _sheet.isExpanded;

    // A hairline in light mode only; YouTube's dark bar has none.
    final showDivider = !shortsShowing && !isDark;
    final navHeight =
        _navBarHeight + outer.padding.bottom + (showDivider ? 1 : 0);
    // What the content area leaves free at the bottom: the bar, and the
    // docked mini player while there is one.
    final reserve = navHeight + (sheetShown ? PlayerSheet.miniHeight : 0);

    final canPop =
        sheetBackAction(
          fullscreen: false,
          expanded: expanded,
          contentCanPop: contentRouteStack.canPop,
        ) ==
        SheetBackAction.system;

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
    if (shortsShowing) {
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
    // The status-bar padding is removed: outside the Scaffold's bottom slot
    // (which strips it) the bar's own SafeArea padded itself by the status
    // bar's height as well, growing to 129dp and covering the bottom 49dp of
    // every screen with an empty band (measured on AIBitPhone).
    final navColumn = MediaQuery.removePadding(
      context: context,
      removeTop: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [if (showDivider) const Divider(height: 1), nav],
      ),
    );

    // The content area ends above the bar and the mini player, so its pages
    // see no bottom inset of their own, and a keyboard only as far as it
    // reaches past them.
    final contentMedia = outer.copyWith(
      padding: outer.padding.copyWith(bottom: 0),
      viewPadding: outer.viewPadding.copyWith(bottom: 0),
      viewInsets: outer.viewInsets.copyWith(
        bottom: (outer.viewInsets.bottom - reserve).clamp(0.0, double.infinity),
      ),
    );

    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack(sheetShown);
      },
      child: Scaffold(
        // The keyboard must not squeeze the whole shell; the content area
        // handles it through the insets above.
        resizeToAvoidBottomInset: false,
        extendBody: true,
        // Not a bar: an invisible spacer as tall as what is docked at the
        // bottom, so snackbars — which this Scaffold shows for every page,
        // being the root one — appear above the mini player and the
        // navigation bar instead of over them. Over the expanded watch page
        // they sit at the bottom of the screen.
        bottomNavigationBar: IgnorePointer(
          child: SizedBox(height: expanded ? 0 : reserve),
        ),
        body: MediaQuery(
          // extendBody would report the spacer as a bottom inset; the layers
          // below lay themselves out against the real screen.
          data: outer,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                right: 0,
                bottom: reserve,
                child: MediaQuery(data: contentMedia, child: _contentNavigator),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: AnimatedBuilder(
                  animation: _sheet.animation,
                  child: navColumn,
                  builder: (context, child) => Transform.translate(
                    offset: Offset(
                      0,
                      sheetShown ? navHeight * _sheet.animation.value : 0,
                    ),
                    child: child,
                  ),
                ),
              ),
              Positioned.fill(
                child: PlayerSheet(
                  controller: _sheet,
                  bottomInset: navHeight,
                  hidden: shortsShowing,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
