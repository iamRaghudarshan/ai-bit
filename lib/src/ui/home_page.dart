import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../data/settings.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../data/yt_repository.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'watch_page.dart';
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
      final feed = await repo.homeFeed(
        channelIds: seeds.channelIds,
        searches: searches,
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

  /// Called by the shell when Home is selected again.
  Future<void> onTabOpened() async {
    if (_category != _CategoryChips.all) return;
    final db = context.read<AppDatabase>();
    final seeds = await db.feedSeeds();
    final searches = await db.recentSearches();
    if (!mounted) return;
    if (_signature(searches, seeds.channelIds) == _signals) return;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: _ModeSwitch(
          kids: context.watch<SettingsService>().kidsMode,
          onChanged: (kids) {
            context.read<SettingsService>().kidsMode = kids;
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
          // Category chips are meaningless in Kids mode, where the whole feed
          // is curated.
          if (!context.watch<SettingsService>().kidsMode) ...[
            _CategoryChips(
              selected: _category,
              onSelected: (value) {
                setState(() => _category = value);
                _load(reset: true);
              },
            ),
            const Divider(height: 1),
          ],
          Expanded(child: _buildFeed()),
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
            VideoCard card(VideoBrief video) => VideoCard(
                  video: video,
                  onTap: () => WatchPage.open(context, video),
                  onMenu: () => showVideoMenu(context, video),
                );

            // Phones keep the single-column list exactly as before; only wider
            // screens (tablets, foldables, landscape) fan the feed out into a
            // multi-column grid the way YouTube does on a big screen.
            return LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final columns = width >= 1400
                    ? 4
                    : width >= 1000
                        ? 3
                        : width >= 640
                            ? 2
                            : 1;

                if (columns == 1) {
                  return ListView.builder(
                    padding: const EdgeInsets.only(top: 8),
                    itemCount: _feed.length + (hasShelf ? 1 : 0),
                    addAutomaticKeepAlives: false,
                    itemBuilder: (context, index) {
                      if (hasShelf && index == 0) return shelf();
                      // No RepaintBoundary here: ListView.builder already gives
                      // every child one, and a second is pure overhead.
                      return card(_feed[index - (hasShelf ? 1 : 0)]);
                    },
                  );
                }

                // Fixed cell height = 16:9 thumbnail for the cell width plus the
                // card's meta block, so cells never clip regardless of columns.
                final cellWidth = width / columns;
                const metaHeight = 108.0;
                final cellHeight = cellWidth * 9 / 16 + metaHeight;

                return CustomScrollView(
                  slivers: [
                    if (hasShelf)
                      SliverToBoxAdapter(child: shelf()),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      sliver: SliverGrid(
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisExtent: cellHeight,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => card(_feed[index]),
                          childCount: _feed.length,
                        ),
                      ),
                    ),
                  ],
                );
              },
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
  static const _categories = [
    all,
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
