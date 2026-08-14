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

  Future<void> _load() async {
    setState(() {
      _loading = _feed.isEmpty;
      _error = null;
    });
    try {
      final repo = context.read<YtRepository>();

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
            // Reset to All and reload so the feed flips immediately.
            setState(() => _category = _CategoryChips.all);
            _load();
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
                _load();
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
            return ListView.builder(
              padding: const EdgeInsets.only(top: 8),
              itemCount: _feed.length,
              // Cards are tall, so the default cache extent keeps several
              // screens of decoded thumbnails alive above and below the
              // viewport. One screen either side is enough to scroll smoothly
              // and holds a fraction of the images.
              addAutomaticKeepAlives: false,
              itemBuilder: (context, index) {
                final video = _feed[index];
                // No RepaintBoundary here: ListView.builder already gives
                // every child one, and a second is pure overhead.
                return VideoCard(
                  video: video,
                  onTap: () => WatchPage.open(context, video),
                  onMenu: () => showVideoMenu(context, video),
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
