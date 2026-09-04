import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../data/kids_guard.dart';
import '../data/settings.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../data/yt_repository.dart';
import 'app_lock_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'watch_page.dart';
import 'widgets/responsive_feed.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// Landing screen — opens straight into a feed, the way the YouTube app does.
///
/// The feed is personalised from local watch history (recent channels first)
/// and topped up with popular topics, so a fresh install still shows something.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage>
    with AutomaticKeepAliveClientMixin {
  List<VideoBrief> _feed = const [];
  List<HistoryEntry> _continue = const [];
  bool _loading = true;
  String? _error;
  int _refreshToken = 0;
  String _category = _CategoryChips.all;

  /// True when the Subscribed chip found nothing followed on this device.
  ///
  /// Kept apart from [_error] because it is not a failure: an empty feed here
  /// needs an invitation to subscribe, not a Retry button that would fetch
  /// nothing again.
  bool _noSubscriptions = false;

  /// The interest signals the visible feed was built from.
  ///
  /// The tab is built once at startup and kept alive, so a feed loaded before
  /// the user had searched for anything stayed on screen for the rest of the
  /// session — which read as "recommendations don't work". Coming back to Home
  /// now compares the signals and refetches only when they have moved, so a
  /// plain tab switch stays instant.
  String _signals = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool reset = false}) async {
    setState(() {
      // A mode or category change is a different feed, so show the skeleton
      // rather than leaving the old rows up while the new ones fetch. A plain
      // refresh keeps them (the pull-to-refresh spinner covers that).
      _loading = reset || _feed.isEmpty;
      if (reset) _feed = const [];
      _error = null;
      _noSubscriptions = false;
    });
    try {
      final repo = context.read<YtRepository>();

      // The Continue-watching shelf belongs only to the personalised feed.
      if (context.read<SettingsService>().kidsMode ||
          _category != _CategoryChips.all) {
        _continue = const [];
      }

      // Kids mode takes over the whole feed, regardless of the chosen category
      // chip, so nothing but curated kid content shows.
      if (context.read<SettingsService>().kidsMode) {
        final feed = await repo.homeFeed(
          refreshToken: _refreshToken,
          kids: true,
        );
        if (!mounted) return;
        setState(() {
          _feed = feed;
          _loading = false;
          _error = feed.isEmpty ? 'Nothing came back.' : null;
        });
        return;
      }

      // Subscribed builds the feed only from channels followed on this
      // device — the local subscriptions table, since there is no account to
      // read real subscriptions from.
      if (_category == _CategoryChips.subscribed) {
        final channels = await context.read<AppDatabase>().subscriptions();
        if (!mounted) return;
        if (channels.isEmpty) {
          setState(() {
            _feed = const [];
            _loading = false;
            _noSubscriptions = true;
          });
          return;
        }
        final feed = await repo.subscribedFeed(channels: channels);
        if (!mounted) return;
        setState(() {
          _feed = feed;
          _loading = false;
          _error = feed.isEmpty
              ? 'No recent uploads from the channels you follow.'
              : null;
        });
        return;
      }

      // Trending is the closest thing available without the official Data API:
      // several popular topics, each sorted by view count, interleaved.
      if (_category == _CategoryChips.trending) {
        final feed = await repo.trending(refreshToken: _refreshToken);
        if (!mounted) return;
        setState(() {
          _feed = feed;
          _loading = false;
          _error = feed.isEmpty ? 'Nothing trending came back.' : null;
        });
        return;
      }

      // Any other chosen category is a topic search; "All" is the
      // personalised feed.
      if (_category != _CategoryChips.all) {
        final feed = await repo.search(_category, sortByViews: true);
        if (!mounted) return;
        setState(() {
          _feed = feed;
          _loading = false;
          _error = feed.isEmpty ? 'Nothing came back for $_category.' : null;
        });
        return;
      }

      final db = context.read<AppDatabase>();
      final seeds = await db.feedSeeds();
      final searches = await db.recentSearches();
      if (!mounted) return;
      _signals = _signature(searches, seeds.channelIds);
      final resumeable = await db.continueWatching();
      if (!mounted) return;
      _continue = resumeable;
      final subscribed = await db.subscriptions();
      if (!mounted) return;
      final feed = await repo.homeFeed(
        channelIds: seeds.channelIds,
        searches: searches,
        subscribedIds: [for (final c in subscribed) c.id],
        refreshToken: _refreshToken,
        kids: context.read<SettingsService>().kidsMode,
      );
      if (!mounted) return;
      setState(() {
        _feed = feed;
        _loading = false;
        _error = feed.isEmpty ? 'Nothing came back from YouTube.' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the feed. Check your connection.';
      });
    }
  }

  Future<void> _refresh() async {
    _refreshToken++;
    await _load();
  }

  static String _signature(List<String> searches, List<String> channelIds) =>
      '${searches.join('|')}##${channelIds.join('|')}';

  /// Tapping Home while already on Home: reload, the way the real app does.
  ///
  /// Distinct from [onTabOpened], which is a cheap "did anything change?"
  /// check for arriving from another tab. This one is a deliberate ask for
  /// fresh rows, so it rotates the window as a pull-to-refresh would rather
  /// than returning the identical feed and looking broken.
  Future<void> reloadFeed() async {
    _refreshToken++;
    await _load(reset: true);
  }

  /// Called by the shell when Home is selected again.
  Future<void> onTabOpened() async {
    // Coming back to an empty Subscribed feed is almost always the return trip
    // from a channel page where something was just subscribed to, so refetch
    // that one case. A populated Subscribed feed is left alone: refetching it
    // is fifteen browse requests, too expensive for a plain tab switch.
    if (_category == _CategoryChips.subscribed) {
      if (_feed.isEmpty) await _load(reset: true);
      return;
    }
    if (_category != _CategoryChips.all) return;
    final db = context.read<AppDatabase>();
    final seeds = await db.feedSeeds();
    final searches = await db.recentSearches();
    if (!mounted) return;
    if (_signature(searches, seeds.channelIds) == _signals) return;
    await _load();
  }

  /// The Kids allowance tracker, or null when the app was built without one
  /// in the widget tree.
  ///
  /// KidsGuard is injected by main.dart the same way PlaybackController takes
  /// it — optionally. Looked up with a catch rather than assumed present so
  /// Home still renders in a harness that provides only the essentials, and
  /// logged rather than swallowed, because a countdown that silently never
  /// appears is exactly the dead feature a bare catch has hidden here before.
  KidsGuard? _kidsGuard(BuildContext context) {
    try {
      return Provider.of<KidsGuard>(context);
    } on ProviderNotFoundException {
      // Once per session, not once per rebuild: this runs on every build of
      // Home, and a line repeated that often would drown the log it exists to
      // help.
      if (!_loggedMissingGuard) {
        _loggedMissingGuard = true;
        debugPrint('AI BIT: no KidsGuard provided - daily limit UI is off.');
      }
      return null;
    }
  }

  static bool _loggedMissingGuard = false;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final settings = context.watch<SettingsService>();
    final kids = settings.kidsMode;
    final guard = _kidsGuard(context);
    // A spent allowance replaces the feed rather than the whole screen, so the
    // mode switch stays reachable for a grown-up with the PIN.
    final timeUp = kids && (guard?.limitReached ?? false);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: _ModeSwitch(
          kids: kids,
          onChanged: (wantsKids) async {
            // The one and only write site for kidsMode, so the guard below is
            // the whole rule and cannot be walked around from elsewhere.
            //
            // Turning Kids mode ON is free. Turning it OFF is the move a child
            // makes to get out of it, so that is the direction the PIN guards.
            // AppLockPage.confirmKidsPin is the same PIN pad the app lock uses
            // — a second, free-text prompt for this used to live here, and two
            // different-looking asks for one action read as a bug. It returns
            // true when no Kids PIN is set, which is exactly the unguarded
            // case, so there is no separate branch for it.
            if (!wantsKids && !await AppLockPage.confirmKidsPin(context)) {
              // Cancelled or wrong: stay in Kids mode, and say nothing more —
              // the pad already reported the wrong PIN without dismissing.
              return;
            }
            if (!mounted) return;
            settings.kidsMode = wantsKids;
            // Reset to All and reload with the skeleton, so the switch reads as
            // an instant change rather than a frozen old feed.
            _category = _CategoryChips.all;
            _load(reset: true);
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SearchPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (YtRepository.isPreview) const _PreviewBanner(),
          // The countdown is a thin strip, not a dialog: it should be
          // glanceable without interrupting anything. Hidden once the time is
          // up, since the panel below then says so in full.
          if (kids && guard != null && guard.hasLimit && !timeUp)
            _KidsTimeBar(remainingSeconds: guard.remainingSeconds),
          // Category chips are meaningless in Kids mode, where the whole feed
          // is curated.
          if (!kids) ...[
            _CategoryChips(
              selected: _category,
              onSelected: (value) {
                setState(() => _category = value);
                _load(reset: true);
              },
            ),
            const Divider(height: 1),
          ],
          Expanded(child: timeUp ? const _KidsTimeUp() : _buildFeed()),
        ],
      ),
    );
  }

  Widget _buildFeed() {
    return RefreshIndicator(
        onRefresh: _refresh,
        child: Builder(
          builder: (context) {
            if (_loading) return const FeedSkeleton(count: 4);
            if (_feed.isEmpty) {
              // Nothing followed yet is not a broken feed, so it gets an
              // invitation and a way back to All rather than a Retry that
              // would fetch nothing again.
              if (_noSubscriptions) {
                return ListView(
                  children: [
                    const SizedBox(height: 80),
                    EmptyState(
                      icon: Icons.subscriptions_outlined,
                      title: 'No subscriptions yet',
                      message:
                          'Open any channel and tap Subscribe. Their newest '
                          'videos will fill this feed.\n\nSubscriptions live '
                          'on this device only, not in a Google account — this '
                          'app has no sign-in.',
                      action: FilledButton(
                        onPressed: () {
                          setState(() => _category = _CategoryChips.all);
                          _load(reset: true);
                        },
                        child: const Text('Back to All'),
                      ),
                    ),
                  ],
                );
              }
              return ListView(
                children: [
                  const SizedBox(height: 80),
                  EmptyState(
                    icon: Icons.wifi_off_outlined,
                    title: 'Feed unavailable',
                    message: _error,
                    action: FilledButton(
                      onPressed: _refresh,
                      child: const Text('Retry'),
                    ),
                  ),
                ],
              );
            }
            final hasShelf = _continue.isNotEmpty;

            Widget shelf() => _ContinueWatchingShelf(
                  entries: _continue,
                  onOpened: () async {
                    // Refresh the shelf when returning from a video.
                    final resumeable =
                        await context.read<AppDatabase>().continueWatching();
                    if (mounted) setState(() => _continue = resumeable);
                  },
                );
            VideoCard card(VideoBrief video, {bool inGrid = false}) =>
                VideoCard(
                  video: video,
                  inGrid: inGrid,
                  onTap: () => WatchPage.open(context, video),
                  onMenu: () => showVideoMenu(context, video),
                );

            // Phones keep the single-column list exactly as before; only wider
            // screens (tablets, foldables, landscape) fan the feed out into a
            // multi-column grid the way YouTube does on a big screen.
            return ResponsiveVideoFeed(
              videos: _feed,
              header: hasShelf ? shelf() : null,
              listPadding: const EdgeInsets.only(top: 8),
              // No RepaintBoundary on items: ListView.builder already gives
              // every child one, and a second is pure overhead.
              listItemBuilder: (context, index) => card(_feed[index]),
              gridItemBuilder: (context, index) =>
                  card(_feed[index], inGrid: true),
            );
          },
      ),
    );
  }
}

/// Horizontal topic filter across the top of the feed, mirroring the real
/// app's chip row.
/// Horizontal "Continue watching" row of partly-watched videos with a resume
/// bar, shown at the top of the personalised feed.
class _ContinueWatchingShelf extends StatelessWidget {
  const _ContinueWatchingShelf({required this.entries, required this.onOpened});

  final List<HistoryEntry> entries;
  final Future<void> Function() onOpened;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Text(
            'Continue watching',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
        SizedBox(
          height: 168,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final entry = entries[i];
              return SizedBox(
                width: 200,
                child: GestureDetector(
                  onTap: () async {
                    await WatchPage.open(context, entry.video);
                    await onOpened();
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      VideoThumb(video: entry.video, progress: entry.progress),
                      const SizedBox(height: 6),
                      Text(
                        entry.video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const Divider(height: 24),
      ],
    );
  }
}

/// The pill toggle in the top bar: normal AI BIT on the left, Kids on the
/// right. Default is normal; tapping a side switches the whole app's feed.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.kids, required this.onChanged});

  final bool kids;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segment(context, label: 'AI BIT', icon: Icons.play_arrow_rounded, selected: !kids, onTap: () => onChanged(false)),
          _segment(context, label: 'Kids', icon: Icons.child_care, selected: kids, onTap: () => onChanged(true)),
        ],
      ),
    );
  }

  Widget _segment(
    BuildContext context, {
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    // Kids side gets a friendly green; normal side the brand red.
    final activeColor = label == 'Kids' ? const Color(0xFF34A853) : AppColors.brand;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? activeColor : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: selected ? Colors.white : scheme.onSurface),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                color: selected ? Colors.white : scheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryChips extends StatelessWidget {
  const _CategoryChips({required this.selected, required this.onSelected});

  static const all = 'All';
  static const trending = 'Trending';
  static const subscribed = 'Subscribed';
  static const _categories = [
    all,
    subscribed,
    trending,
    'Music',
    'Gaming',
    'News',
    'Movies',
    'Live',
    'Sports',
    'Learning',
    'Podcasts',
    'Comedy',
  ];

  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: _categories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final category = _categories[index];
          final isSelected = category == selected;
          return ChoiceChip(
            label: Text(category),
            selected: isSelected,
            showCheckmark: false,
            onSelected: (_) => onSelected(category),
            backgroundColor: scheme.onSurface.withValues(alpha: 0.08),
            selectedColor: scheme.onSurface,
            labelStyle: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: isSelected ? scheme.surface : scheme.onSurface,
            ),
            side: BorderSide.none,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          );
        },
      ),
    );
  }
}

/// Only ever shown in a browser build.
class _PreviewBanner extends StatelessWidget {
  const _PreviewBanner();

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.brand,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 16, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Preview — sample data, no playback.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.white,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}


/// Thin strip under the app bar counting down the Kids allowance.
///
/// Deliberately quiet — a child should be able to ignore it and a parent
/// should be able to check it at a glance. It refreshes when KidsGuard
/// notifies, which happens as playback records time, so there is no ticker
/// burning a frame a second on a screen that is mostly idle.
class _KidsTimeBar extends StatelessWidget {
  const _KidsTimeBar({required this.remainingSeconds});

  final int remainingSeconds;

  /// "8 min left today". Minutes round **up** so the last 30 seconds still
  /// read as "1 min left" rather than a "0 min left" that sits there while
  /// the video keeps playing.
  static String label(int seconds) {
    if (seconds <= 0) return 'No time left today';
    if (seconds >= 3600) {
      final hours = seconds ~/ 3600;
      final minutes = (seconds % 3600) ~/ 60;
      final tail = minutes == 0 ? '' : ' $minutes min';
      return '$hours hr$tail left today';
    }
    return '${(seconds / 60).ceil()} min left today';
  }

  @override
  Widget build(BuildContext context) {
    // The same green the Kids side of the mode switch uses, so the strip reads
    // as part of Kids mode rather than as a warning.
    const kidsGreen = Color(0xFF34A853);
    return Container(
      width: double.infinity,
      color: kidsGreen.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.timer_outlined, size: 15, color: kidsGreen),
          const SizedBox(width: 6),
          Text(
            label(remainingSeconds),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: kidsGreen,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown in place of the Kids feed once the daily allowance is spent.
///
/// Replaces only the feed, not the whole screen: the mode switch stays in the
/// app bar so a grown-up with the PIN can still leave Kids mode, and Settings
/// stays reachable to raise the limit.
class _KidsTimeUp extends StatelessWidget {
  const _KidsTimeUp();

  @override
  Widget build(BuildContext context) => const EmptyState(
    icon: Icons.bedtime_outlined,
    title: "That's all for today",
    message:
        'Kids time is up. More videos tomorrow.\n\nA grown-up can change the '
        'daily limit in Settings.',
  );
}
