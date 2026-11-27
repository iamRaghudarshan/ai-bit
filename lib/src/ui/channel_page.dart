import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_navigator.dart';
import '../core/theme.dart';
import '../data/browse_client.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../data/subscription_activity.dart';
import '../data/yt_repository.dart';
import 'playlist_page.dart';
import 'watch_page.dart';
import 'widgets/library_widgets.dart';
import 'widgets/responsive_feed.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// A channel's own page, laid out as YouTube's: banner, avatar, name, the
/// "@handle · subscribers · videos" line, a description preview opening the
/// About sheet, the links line, a full-width Subscribe pill, then the tabs
/// the channel actually has.
///
/// Each tab loads on its own, so a channel with no playlists — or a tab
/// YouTube declines to serve — still shows its videos. Videos, Shorts and
/// Live page as they are scrolled, and Videos sorts Latest / Popular /
/// Oldest on YouTube's side (see [YoutubeBrowseClient.channelTab]).
class ChannelPage extends StatefulWidget {
  const ChannelPage({super.key, required this.channelId, this.initialTitle});

  final String channelId;

  /// Shown until the real header arrives, so the page never opens blank.
  final String? initialTitle;

  static Future<void> open(
    BuildContext context,
    String channelId, {
    String? title,
  }) {
    // Onto the content navigator, under the player: opened from the watch
    // page it minimises the video, as YouTube does.
    return pushContent(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ChannelPage(channelId: channelId, initialTitle: title),
      ),
    );
  }

  @override
  State<ChannelPage> createState() => _ChannelPageState();
}

/// One paged video tab's state.
class _TabFeed {
  _TabFeed(this.tab);

  final ChannelTab tab;
  List<VideoBrief> videos = const [];
  String? continuation;
  List<({String label, String token, bool selected})> sorts = const [];
  int sort = 0;
  bool loading = true;
  bool loadingMore = false;
  bool started = false;
  String? error;
}

enum _Kind { videos, shorts, live, playlists }

class _ChannelPageState extends State<ChannelPage>
    with TickerProviderStateMixin {
  TabController? _tabs;
  List<_Kind> _kinds = const [_Kind.videos];

  final _outer = ScrollController();
  bool _collapsed = false;

  ChannelInfo? _info;
  bool _headerFailed = false;
  final _videos = _TabFeed(ChannelTab.videos);
  final _shorts = _TabFeed(ChannelTab.shorts);
  final _live = _TabFeed(ChannelTab.live);
  List<PlaylistBrief> _playlists = const [];
  bool _loadingPlaylists = true;
  bool _playlistsStarted = false;

  String get _title => _info?.title.isNotEmpty == true
      ? _info!.title
      : (widget.initialTitle ?? '');

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _kinds.length, vsync: this);
    _outer.addListener(() {
      // The name moves into the app bar once the header has scrolled under
      // it, as YouTube's does.
      final collapsed = _outer.hasClients && _outer.offset > 160;
      if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
    });
    _load();
    _markSeen();
  }

  @override
  void dispose() {
    _tabs?.dispose();
    _outer.dispose();
    super.dispose();
  }

  /// Opening a channel is looking at it: clears its unseen-upload dot on
  /// the Subscriptions strip.
  Future<void> _markSeen() async {
    final activity = await SubscriptionActivity.load();
    activity.markViewed(widget.channelId);
    await activity.save();
  }

  void _load() {
    final repo = context.read<YtRepository>();
    _startTab(_videos);

    repo.channelInfo(widget.channelId).then(
      (info) {
        if (!mounted) return;
        setState(() => _info = info);
        _applyTabs(info.tabs);
      },
      onError: (Object e) {
        // A missing header is survivable; the video list is the point. Every
        // tab is then offered and each hides itself if it comes back empty.
        debugPrint('AI BIT: channel header failed for ${widget.channelId} — $e');
        if (!mounted) return;
        setState(() => _headerFailed = true);
        _applyTabs(null);
      },
    );
  }

  /// Rebuilds the tab bar from what the channel has. Unknown (no tab list in
  /// the header) offers the usual four and fetches each, so the empty ones
  /// can drop out.
  void _applyTabs(Set<String>? tabs) {
    final kinds = <_Kind>[
      _Kind.videos,
      if (tabs == null || tabs.contains('shorts')) _Kind.shorts,
      if (tabs == null || tabs.contains('streams')) _Kind.live,
      if (tabs == null || tabs.contains('playlists')) _Kind.playlists,
    ];
    if (kinds.contains(_Kind.shorts)) _startTab(_shorts);
    if (kinds.contains(_Kind.live)) _startTab(_live);
    if (kinds.contains(_Kind.playlists)) _startPlaylists();
    _setKinds(kinds);
  }

  void _setKinds(List<_Kind> kinds) {
    if (_listEquals(kinds, _kinds)) return;
    final current = _kinds[_tabs?.index ?? 0];
    final old = _tabs;
    setState(() {
      _kinds = kinds;
      _tabs = TabController(
        length: kinds.length,
        vsync: this,
        initialIndex: kinds.contains(current) ? kinds.indexOf(current) : 0,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
  }

  static bool _listEquals(List<_Kind> a, List<_Kind> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// With no tab list to go by, a tab that turned out empty is dropped
  /// rather than left showing "nothing here".
  void _dropEmptyTabs() {
    if (!_headerFailed && _info?.tabs != null) return;
    final kinds = _kinds.where((k) {
      return switch (k) {
        _Kind.videos => true,
        _Kind.shorts => _shorts.loading || _shorts.videos.isNotEmpty,
        _Kind.live => _live.loading || _live.videos.isNotEmpty,
        _Kind.playlists => _loadingPlaylists || _playlists.isNotEmpty,
      };
    }).toList();
    _setKinds(kinds);
  }

  void _startTab(_TabFeed feed) {
    if (feed.started) return;
    feed.started = true;
    final repo = context.read<YtRepository>();
    repo
        .channelTabPage(widget.channelId, tab: feed.tab, channelTitle: _title)
        .then(
          (page) {
            if (!mounted) return;
            setState(() {
              feed.videos = page.videos;
              feed.continuation = page.continuation;
              feed.sorts = page.sorts;
              final selected = page.sorts.indexWhere((s) => s.selected);
              feed.sort = selected < 0 ? 0 : selected;
              feed.loading = false;
            });
            _dropEmptyTabs();
          },
          onError: (Object e) async {
            if (!mounted) return;
            // The Videos tab has a second route through the package, which
            // is what the page used before paging existed.
            if (feed.tab == ChannelTab.videos) {
              try {
                final videos = await repo.channelUploads(
                  widget.channelId,
                  limit: 30,
                  channelTitle: _title,
                );
                if (!mounted) return;
                setState(() {
                  feed.videos = videos;
                  feed.loading = false;
                });
                return;
              } catch (_) {
                // Fall through to the error below, which names the first
                // failure rather than this one.
              }
            }
            if (!mounted) return;
            setState(() {
              feed.loading = false;
              feed.error = '$e';
            });
            _dropEmptyTabs();
          },
        );
  }

  void _startPlaylists() {
    if (_playlistsStarted) return;
    _playlistsStarted = true;
    context.read<YtRepository>().channelPlaylists(widget.channelId).then(
      (playlists) {
        if (!mounted) return;
        setState(() {
          _playlists = playlists;
          _loadingPlaylists = false;
        });
        _dropEmptyTabs();
      },
      onError: (Object e) {
        debugPrint('AI BIT: channel playlists failed — $e');
        if (!mounted) return;
        setState(() => _loadingPlaylists = false);
        _dropEmptyTabs();
      },
    );
  }

  /// Asked for from item builders, which run during a build — so the fetch
  /// (and its setState) is deferred to after the frame.
  void _more(_TabFeed feed) {
    if (feed.continuation == null || feed.loadingMore || feed.loading) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchMore(feed);
    });
  }

  Future<void> _fetchMore(_TabFeed feed) async {
    final token = feed.continuation;
    if (token == null || feed.loadingMore || feed.loading) return;
    setState(() => feed.loadingMore = true);
    try {
      final page = await context.read<YtRepository>().channelTabMore(
        token,
        tab: feed.tab,
        channelId: widget.channelId,
        channelTitle: _title,
        avatarUrl: _info?.avatarUrl ?? feed.videos.firstOrNull?.avatarUrl,
      );
      if (!mounted) return;
      final seen = feed.videos.map((v) => v.id).toSet();
      setState(() {
        feed.videos = [
          ...feed.videos,
          ...page.videos.where((v) => seen.add(v.id)),
        ];
        feed.continuation = page.videos.isEmpty ? null : page.continuation;
        feed.loadingMore = false;
      });
    } catch (e) {
      debugPrint('AI BIT: channel tab paging failed — $e');
      if (!mounted) return;
      // Stop rather than retry on every scroll tick.
      setState(() {
        feed.continuation = null;
        feed.loadingMore = false;
      });
    }
  }

  /// Re-fetches the tab in another order. The chip tokens come from the
  /// first page and stay valid for the visit.
  Future<void> _sortBy(_TabFeed feed, int index) async {
    if (index == feed.sort || index >= feed.sorts.length) return;
    final previous = feed.sort;
    setState(() {
      feed.sort = index;
      feed.loading = true;
    });
    try {
      final page = await context.read<YtRepository>().channelTabMore(
        feed.sorts[index].token,
        tab: feed.tab,
        channelId: widget.channelId,
        channelTitle: _title,
        avatarUrl: _info?.avatarUrl ?? feed.videos.firstOrNull?.avatarUrl,
      );
      if (!mounted) return;
      setState(() {
        feed.videos = page.videos;
        feed.continuation = page.continuation;
        feed.loading = false;
      });
    } catch (e) {
      debugPrint('AI BIT: channel sort failed — $e');
      if (!mounted) return;
      setState(() {
        feed.sort = previous;
        feed.loading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not re-sort just now.')),
      );
    }
  }

  void _openAbout() {
    final info = _info;
    if (info == null) return;
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _AboutSheet(info: info),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs!;
    return Scaffold(
      body: NestedScrollView(
        controller: _outer,
        headerSliverBuilder: (context, _) => [
          SliverAppBar(
            pinned: true,
            title: AnimatedOpacity(
              opacity: _collapsed ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.share_outlined),
                tooltip: 'Share channel',
                onPressed: () => SharePlus.instance.share(
                  ShareParams(
                    uri: Uri.parse(
                      'https://www.youtube.com/channel/${widget.channelId}',
                    ),
                  ),
                ),
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: _Header(
              // With no header, enough of one from the rows to subscribe by.
              info: _info ??
                  (_headerFailed && _videos.videos.isNotEmpty
                      ? ChannelInfo(
                          id: widget.channelId,
                          title: widget.initialTitle ??
                              _videos.videos.first.author,
                          avatarUrl: _videos.videos.first.avatarUrl,
                        )
                      : null),
              fallbackTitle: widget.initialTitle,
              channelId: widget.channelId,
              onAbout: _openAbout,
            ),
          ),
          SliverPersistentHeader(
            pinned: true,
            delegate: _TabBarHeader(
              TabBar(
                key: ValueKey(_kinds.join()),
                controller: tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  for (final k in _kinds)
                    Tab(
                      text: switch (k) {
                        _Kind.videos => 'Videos',
                        _Kind.shorts => 'Shorts',
                        _Kind.live => 'Live',
                        _Kind.playlists => 'Playlists',
                      },
                    ),
                ],
              ),
              Theme.of(context).scaffoldBackgroundColor,
            ),
          ),
        ],
        body: TabBarView(
          key: ValueKey(_kinds.join()),
          controller: tabs,
          children: [
            for (final k in _kinds)
              switch (k) {
                _Kind.videos => _buildFeed(_videos, 'No videos',
                    'This channel has nothing to show.'),
                _Kind.shorts => _buildShorts(),
                _Kind.live => _buildFeed(_live, 'No streams',
                    'This channel has not gone live.'),
                _Kind.playlists => _buildPlaylists(),
              },
          ],
        ),
      ),
    );
  }

  Widget _sortChips(_TabFeed feed) => feed.sorts.length < 2
      ? const SizedBox(height: 4)
      : FeedChipRow(
          labels: [for (final s in feed.sorts) s.label],
          selected: feed.sort,
          onSelected: (i) => _sortBy(feed, i),
        );

  Widget _loadingFooter(_TabFeed feed) => feed.continuation == null
      ? const SizedBox(height: 24)
      : const Padding(
          padding: EdgeInsets.all(20),
          child: Center(child: CircularProgressIndicator()),
        );

  /// The Videos and Live tabs: sort chips, then cards, paging near the end.
  Widget _buildFeed(_TabFeed feed, String emptyTitle, String emptyMessage) {
    if (feed.loading && feed.videos.isEmpty) {
      return Column(
        children: [
          _sortChips(feed),
          const Expanded(child: FeedSkeleton(count: 3)),
        ],
      );
    }
    if (feed.videos.isEmpty) {
      return EmptyState(
        icon: Icons.videocam_off_outlined,
        title: emptyTitle,
        message: feed.error ?? emptyMessage,
      );
    }
    final videos = feed.videos;
    return ResponsiveVideoFeed(
      key: ValueKey('${feed.tab}-${feed.sort}'),
      videos: videos,
      header: Stack(
        children: [
          _sortChips(feed),
          if (feed.loading)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: LinearProgressIndicator(minHeight: 2),
            ),
        ],
      ),
      onNearEnd: () => _more(feed),
      footer: _loadingFooter(feed),
      listItemBuilder: (context, i) {
        final video = videos[i];
        return VideoCard(
          video: video,
          // Already on this channel: the avatar must not push it again.
          avatarOpensChannel: false,
          onTap: () => WatchPage.openQueue(context, videos, startAt: i),
          onMenu: () => showVideoMenu(context, video),
        );
      },
      gridItemBuilder: (context, i) {
        final video = videos[i];
        return VideoCard(
          video: video,
          inGrid: true,
          avatarOpensChannel: false,
          onTap: () => WatchPage.openQueue(context, videos, startAt: i),
          onMenu: () => showVideoMenu(context, video),
        );
      },
    );
  }

  /// The Shorts tab: a 3-column 9:16 grid with each view count over its
  /// tile, opening the Shorts player on this channel's list.
  Widget _buildShorts() {
    final feed = _shorts;
    if (feed.loading && feed.videos.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (feed.videos.isEmpty) {
      return EmptyState(
        icon: Icons.bolt,
        title: 'No Shorts',
        message: feed.error ?? 'This channel has not posted any.',
      );
    }
    final shorts = feed.videos;
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.maxWidth / 130).floor().clamp(3, 8);
        return CustomScrollView(
          key: ValueKey('shorts-${feed.sort}'),
          slivers: [
            SliverToBoxAdapter(child: _sortChips(feed)),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                  childAspectRatio: 9 / 16,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    if (i >= shorts.length - columns * 2) _more(feed);
                    return ShortTile(
                      video: shorts[i],
                      onTap: () => openShortsList(context, shorts, index: i),
                    );
                  },
                  childCount: shorts.length,
                ),
              ),
            ),
            SliverToBoxAdapter(child: _loadingFooter(feed)),
          ],
        );
      },
    );
  }

  Widget _buildPlaylists() {
    if (_loadingPlaylists) return const FeedSkeleton(count: 3);
    if (_playlists.isEmpty) {
      return const EmptyState(
        icon: Icons.playlist_play,
        title: 'No playlists',
        message: 'This channel has not published any playlists.',
      );
    }
    // A grid of cards, which is what YouTube's Playlists tab is — two columns
    // on a phone, wider on a tablet, one more than the video feed because a
    // playlist card is narrower than a video card.
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = (feedColumnsFor(constraints.maxWidth) + 1).clamp(2, 5);
        final tileWidth =
            (constraints.maxWidth - 24 - 12 * (columns - 1)) / columns;
        final textScale = MediaQuery.textScalerOf(context).scale(1);
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 16,
            crossAxisSpacing: 12,
            mainAxisExtent: tileWidth * 9 / 16 + 8 + 5 + 58 * textScale,
          ),
          itemCount: _playlists.length,
          itemBuilder: (context, i) {
            final playlist = _playlists[i];
            return PlaylistCard(
              title: playlist.title,
              subtitle: 'View full playlist',
              imageUrl: playlist.thumbnailUrl,
              count: playlist.videoCount,
              onTap: () => PlaylistPage.open(context, playlist),
            );
          },
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.info,
    required this.fallbackTitle,
    required this.channelId,
    required this.onAbout,
  });

  final ChannelInfo? info;
  final String? fallbackTitle;
  final String channelId;
  final VoidCallback onAbout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.62);
    final info = this.info;
    final title = info?.title.isNotEmpty == true ? info!.title : (fallbackTitle ?? '');
    final meta = [
      ?info?.handle,
      ?info?.subscriberLabel,
      ?info?.videoCountLabel,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (info?.bannerUrl != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 6.2,
                child: CachedNetworkImage(
                  imageUrl: info!.bannerUrl!,
                  fit: BoxFit.cover,
                  memCacheWidth: 1280,
                  placeholder: (_, _) =>
                      const ColoredBox(color: AppColors.darkElevated),
                  errorWidget: (_, _, _) =>
                      const ColoredBox(color: AppColors.darkElevated),
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 38,
                backgroundColor: AppColors.darkElevated,
                foregroundImage: info?.avatarUrl == null
                    ? null
                    : CachedNetworkImageProvider(
                        info!.avatarUrl!,
                        maxWidth: 228,
                        maxHeight: 228,
                      ),
                child: Text(
                  title.characters.firstOrNull ?? '?',
                  style: const TextStyle(fontSize: 26, color: Colors.white),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        meta,
                        style: TextStyle(fontSize: 13, color: muted, height: 1.3),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (info?.description != null) ...[
            const SizedBox(height: 12),
            MoreText(
              text: info!.description!,
              onMore: onAbout,
              style: TextStyle(fontSize: 13, color: muted, height: 1.35),
            ),
          ],
          if (info?.linkLabel != null) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: onAbout,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(Icons.link, size: 16, color: theme.colorScheme.primary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        info!.linkLabel!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: info == null
                ? const _SubscribePlaceholder()
                : SubscribePill(channel: info),
          ),
        ],
      ),
    );
  }
}

class _SubscribePlaceholder extends StatelessWidget {
  const _SubscribePlaceholder();

  @override
  Widget build(BuildContext context) => Container(
    height: 40,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(20),
    ),
  );
}

/// Subscribe / Subscribed, as YouTube draws it: a filled pill to subscribe;
/// once subscribed, a tonal "🔔 Subscribed ⌄" pill whose sheet holds
/// Unsubscribe, which asks before acting.
///
/// Local only: without a Google account there is nothing to sync to, so this
/// follows the channel on this device and drives the Subscriptions feed. The
/// bell is drawn because YouTube draws it, but there are no notifications to
/// choose between — the sheet says so rather than offering switches that do
/// nothing.
class SubscribePill extends StatefulWidget {
  const SubscribePill({super.key, required this.channel, this.compact = false});

  final ChannelInfo channel;

  /// Content-width rather than full-width.
  final bool compact;

  @override
  State<SubscribePill> createState() => _SubscribePillState();
}

class _SubscribePillState extends State<SubscribePill> {
  bool? _subscribed;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final yes = await context.read<AppDatabase>().isSubscribed(
      widget.channel.id,
    );
    if (mounted) setState(() => _subscribed = yes);
  }

  Future<void> _subscribe() async {
    final messenger = ScaffoldMessenger.of(context);
    await context.read<AppDatabase>().subscribe(widget.channel);
    messenger.showSnackBar(
      SnackBar(content: Text('Subscribed to ${widget.channel.title}')),
    );
    await _refresh();
  }

  Future<void> _manage() async {
    final unsubscribe = await showModalBottomSheet<bool>(
      useRootNavigator: true,
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              enabled: false,
              leading: Icon(Icons.notifications_off_outlined),
              title: Text('Notifications'),
              subtitle: Text(
                'Not available — they need a Google account, and '
                'subscriptions here live on this device only.',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.person_remove_outlined),
              title: const Text('Unsubscribe'),
              onTap: () => Navigator.pop(sheetContext, true),
            ),
          ],
        ),
      ),
    );
    if (unsubscribe != true || !mounted) return;
    final yes = await confirmAction(
      context,
      title: 'Unsubscribe from ${widget.channel.title}?',
      confirmLabel: 'Unsubscribe',
    );
    if (!yes || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    await context.read<AppDatabase>().unsubscribe(widget.channel.id);
    messenger.showSnackBar(
      SnackBar(content: Text('Unsubscribed from ${widget.channel.title}')),
    );
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subscribed = _subscribed ?? false;
    const shape = StadiumBorder();
    if (!subscribed) {
      return FilledButton(
        onPressed: _subscribed == null ? null : _subscribe,
        style: FilledButton.styleFrom(
          backgroundColor: scheme.onSurface,
          foregroundColor: scheme.surface,
          shape: shape,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 18),
        ),
        child: const Text('Subscribe', style: TextStyle(fontWeight: FontWeight.w600)),
      );
    }
    return FilledButton(
      onPressed: _manage,
      style: FilledButton.styleFrom(
        backgroundColor: scheme.onSurface.withValues(alpha: 0.1),
        foregroundColor: scheme.onSurface,
        shape: shape,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.notifications_none, size: 20),
          SizedBox(width: 6),
          Text('Subscribed', style: TextStyle(fontWeight: FontWeight.w600)),
          SizedBox(width: 2),
          Icon(Icons.keyboard_arrow_down, size: 20),
        ],
      ),
    );
  }
}

/// The About sheet: full description, links, and the "More info" facts,
/// fetched when opened (the header carries only a preview).
class _AboutSheet extends StatefulWidget {
  const _AboutSheet({required this.info});

  final ChannelInfo info;

  @override
  State<_AboutSheet> createState() => _AboutSheetState();
}

class _AboutSheetState extends State<_AboutSheet> {
  ChannelAbout? _about;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final token = widget.info.aboutToken;
    if (token == null) {
      _loading = false;
      return;
    }
    context.read<YtRepository>().channelAbout(token).then(
      (about) {
        if (!mounted) return;
        setState(() {
          _about = about;
          _loading = false;
        });
      },
      onError: (Object e) {
        debugPrint('AI BIT: channel about failed — $e');
        if (mounted) setState(() => _loading = false);
      },
    );
  }

  Future<void> _launch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $url')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final about = _about;
    final info = widget.info;
    final description = about?.description.isNotEmpty == true
        ? about!.description
        : (info.description ?? '');
    final facts = <(IconData, String)>[
      if (about?.canonicalUrl != null || info.handle != null)
        (
          Icons.public,
          about?.canonicalUrl?.replaceFirst(RegExp(r'^https?://'), '') ??
              'youtube.com/${info.handle}',
        ),
      if ((about?.subscriberText ?? info.subscriberLabel) != null)
        (Icons.person_outline, (about?.subscriberText ?? info.subscriberLabel)!),
      if ((about?.videoCountText ?? info.videoCountLabel) != null)
        (Icons.smart_display_outlined, (about?.videoCountText ?? info.videoCountLabel)!),
      if (about?.viewCountText != null)
        (Icons.trending_up, about!.viewCountText!),
      if (about?.joinedText != null) (Icons.info_outline, about!.joinedText!),
      if (about?.country != null) (Icons.language, about!.country!),
    ];

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          Text(
            'About',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          if (description.isNotEmpty) ...[
            Text('Description', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            SelectableText(description, style: const TextStyle(height: 1.4)),
            const SizedBox(height: 20),
          ],
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (about != null && about.links.isNotEmpty) ...[
            Text('Links', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            for (final link in about.links)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.link),
                title: Text(link.title),
                subtitle: Text(
                  link.url.replaceFirst(RegExp(r'^https?://'), ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: theme.colorScheme.primary),
                ),
                onTap: () => _launch(link.url),
              ),
            const SizedBox(height: 12),
          ],
          if (facts.isNotEmpty) ...[
            Text('More info', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            for (final (icon, text) in facts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(icon),
                title: Text(text),
              ),
          ],
        ],
      ),
    );
  }
}

/// Keeps the tab bar pinned below the header while the lists scroll.
class _TabBarHeader extends SliverPersistentHeaderDelegate {
  _TabBarHeader(this.tabBar, this.background);

  final TabBar tabBar;
  final Color background;

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      ColoredBox(color: background, child: tabBar);

  @override
  bool shouldRebuild(_TabBarHeader oldDelegate) =>
      oldDelegate.tabBar != tabBar || oldDelegate.background != background;
}
