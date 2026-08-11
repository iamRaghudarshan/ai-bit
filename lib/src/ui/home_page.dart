import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';

import '../core/theme.dart';
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
        title: Row(
          children: [
            const Icon(Icons.play_circle_fill, color: Color(0xFFFF0033), size: 26),
            const SizedBox(width: 6),
            Text('AI BIT', style: Theme.of(context).appBarTheme.titleTextStyle),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SearchPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (YtRepository.isPreview) const _PreviewBanner(),
          _CategoryChips(
            selected: _category,
            onSelected: (value) {
              setState(() => _category = value);
              _load();
            },
          ),
          const Divider(height: 1),
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
              scrollCacheExtent: const ScrollCacheExtent.pixels(600.0),
              addAutomaticKeepAlives: false,
              itemBuilder: (context, index) {
                final video = _feed[index];
                // Each card paints into its own layer, so scrolling does not
                // repaint the whole list on every frame.
                return RepaintBoundary(
                  child: VideoCard(
                    video: video,
                    onTap: () => WatchPage.open(context, video),
                    onMenu: () => showVideoMenu(context, video),
                  ),
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
