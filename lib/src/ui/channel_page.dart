import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/theme.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../data/yt_repository.dart';
import 'playlist_page.dart';
import 'watch_page.dart';
import 'widgets/responsive_feed.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// A channel's own page: header, its uploads, and its playlists.
///
/// Uploads and playlists load independently so a channel with no playlists —
/// or a playlist tab YouTube declines to serve — still shows its videos.
class ChannelPage extends StatefulWidget {
  const ChannelPage({super.key, required this.channelId, this.initialTitle});

  final String channelId;

  /// Shown in the app bar until the real header arrives, so the page never
  /// opens blank.
  final String? initialTitle;

  static Future<void> open(
    BuildContext context,
    String channelId, {
    String? title,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChannelPage(channelId: channelId, initialTitle: title),
      ),
    );
  }

  @override
  State<ChannelPage> createState() => _ChannelPageState();
}

class _ChannelPageState extends State<ChannelPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  ChannelInfo? _info;
  List<VideoBrief> _videos = const [];
  List<VideoBrief> _shorts = const [];
  List<VideoBrief> _live = const [];
  List<PlaylistBrief> _playlists = const [];
  bool _loadingVideos = true;
  bool _loadingPlaylists = true;
  // Shorts and Live are fetched alongside the rest; both tabs are commonly
  // empty for a given channel, which is a result rather than a failure.
  bool _loadingShorts = true;
  bool _loadingLive = true;
  String? _error;

  /// YouTube's own Popular sort needs a `params` value that no longer returns
  /// anything, so this reorders the fetched page instead. Honest about what it
  /// is: most-viewed of the videos loaded, not of all time.
  bool _byPopular = false;

  List<VideoBrief> get _sortedVideos {
    if (!_byPopular) return _videos;
    return _videos.toList()
      ..sort((a, b) => (b.viewCount ?? 0).compareTo(a.viewCount ?? 0));
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = context.read<YtRepository>();

    // Header first — it is the cheapest call and fills the page immediately.
    repo.channelInfo(widget.channelId).then(
      (info) {
        if (mounted) setState(() => _info = info);
      },
      // A missing header is survivable; the video list is the point.
      onError: (Object _) {},
    );

    repo.channelShorts(
      widget.channelId,
      channelTitle: widget.initialTitle ?? '',
    ).then(
      (shorts) {
        if (mounted) setState(() { _shorts = shorts; _loadingShorts = false; });
      },
      onError: (Object _) {
        if (mounted) setState(() => _loadingShorts = false);
      },
    );

    repo.channelLive(
      widget.channelId,
      channelTitle: widget.initialTitle ?? '',
    ).then(
      (live) {
        if (mounted) setState(() { _live = live; _loadingLive = false; });
      },
      onError: (Object _) {
        if (mounted) setState(() => _loadingLive = false);
      },
    );

    repo.channelUploads(
      widget.channelId,
      limit: 30,
      channelTitle: widget.initialTitle ?? '',
    ).then((videos) {
      if (mounted) {
        setState(() {
          _videos = videos;
          _loadingVideos = false;
        });
      }
    }, onError: (Object e) {
      if (mounted) {
        setState(() {
          _loadingVideos = false;
          _error = '$e';
        });
      }
    });

    repo.channelPlaylists(widget.channelId).then((playlists) {
      if (mounted) {
        setState(() {
          _playlists = playlists;
          _loadingPlaylists = false;
        });
      }
    }, onError: (Object _) {
      if (mounted) setState(() => _loadingPlaylists = false);
    });
  }

  void _playAll({bool shuffle = false}) {
    if (_videos.isEmpty) return;
    final list = _videos.toList();
    if (shuffle) list.shuffle();
    WatchPage.openQueue(context, list);
  }

  @override
  Widget build(BuildContext context) {
    final title = _info?.title ?? widget.initialTitle ?? 'Channel';

    return Scaffold(
      body: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverAppBar(
            pinned: true,
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
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
          SliverToBoxAdapter(child: _Header(info: _info, onPlayAll: _playAll)),
          SliverPersistentHeader(
            pinned: true,
            delegate: _TabBarHeader(
              TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  const Tab(text: 'Videos'),
                  Tab(text: _shorts.isEmpty ? 'Shorts' : 'Shorts (${_shorts.length})'),
                  Tab(text: _live.isEmpty ? 'Live' : 'Live (${_live.length})'),
                  Tab(
                    text: _playlists.isEmpty
                        ? 'Playlists'
                        : 'Playlists (${_playlists.length})',
                  ),
                ],
              ),
              Theme.of(context).scaffoldBackgroundColor,
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabs,
          children: [
            _buildVideos(),
            _buildVideoList(
              _shorts,
              _loadingShorts,
              'No Shorts',
              'This channel has not posted any.',
            ),
            _buildVideoList(
              _live,
              _loadingLive,
              'No streams',
              'This channel has not gone live.',
            ),
            _buildPlaylists(),
          ],
        ),
      ),
    );
  }

  /// Plain list used by the Shorts and Live tabs, which have no sort control.
  Widget _buildVideoList(
    List<VideoBrief> videos,
    bool loading,
    String emptyTitle,
    String emptyMessage,
  ) {
    if (loading) return const FeedSkeleton(count: 3);
    if (videos.isEmpty) {
      return EmptyState(
        icon: Icons.videocam_off_outlined,
        title: emptyTitle,
        message: emptyMessage,
      );
    }
    return ResponsiveVideoFeed(
      videos: videos,
      listItemBuilder: (context, i) {
        final video = videos[i];
        return VideoRow(
          video: video,
          onTap: () => WatchPage.open(context, video),
          onMenu: () => showVideoMenu(context, video),
        );
      },
      gridItemBuilder: (context, i) {
        final video = videos[i];
        return VideoCard(
          video: video,
          inGrid: true,
          onTap: () => WatchPage.open(context, video),
          onMenu: () => showVideoMenu(context, video),
        );
      },
    );
  }

  Widget _buildVideos() {
    if (_loadingVideos) return const FeedSkeleton(count: 3);
    if (_videos.isEmpty) {
      return EmptyState(
        icon: Icons.videocam_off_outlined,
        title: 'No videos',
        message: _error ?? 'This channel has nothing to show.',
      );
    }
    final videos = _sortedVideos;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Latest')),
                ButtonSegment(value: true, label: Text('Popular')),
              ],
              selected: {_byPopular},
              showSelectedIcon: false,
              onSelectionChanged: (s) =>
                  setState(() => _byPopular = s.first),
            ),
          ),
        ),
        Expanded(
          child: ResponsiveVideoFeed(
            videos: videos,
            listItemBuilder: (context, i) {
              final video = videos[i];
              return VideoRow(
                video: video,
                onTap: () => WatchPage.openQueue(context, videos, startAt: i),
                onMenu: () => showVideoMenu(context, video),
              );
            },
            gridItemBuilder: (context, i) {
              final video = videos[i];
              return VideoCard(
                video: video,
                inGrid: true,
                onTap: () => WatchPage.openQueue(context, videos, startAt: i),
                onMenu: () => showVideoMenu(context, video),
              );
            },
          ),
        ),
      ],
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
    return ListView.separated(
      itemCount: _playlists.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final playlist = _playlists[i];
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 84,
              height: 52,
              child: playlist.thumbnailUrl == null
                  ? const ColoredBox(
                      color: AppColors.darkElevated,
                      child: Icon(Icons.playlist_play, color: Colors.white38),
                    )
                  : CachedNetworkImage(memCacheWidth: 1080, 
                      imageUrl: playlist.thumbnailUrl!,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) =>
                          const ColoredBox(color: AppColors.darkElevated),
                    ),
            ),
          ),
          title: Text(
            playlist.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            playlist.videoCount == null
                ? 'Playlist'
                : '${playlist.videoCount} videos',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => PlaylistPage.open(context, playlist),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.info, required this.onPlayAll});

  final ChannelInfo? info;
  final void Function({bool shuffle}) onPlayAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: AppColors.darkElevated,
                backgroundImage: info?.avatarUrl == null
                    ? null
                    : CachedNetworkImageProvider(info!.avatarUrl!, maxWidth: 176, maxHeight: 176),
                child: info?.avatarUrl != null
                    ? null
                    : Text(
                        (info?.title ?? '?').characters.firstOrNull ?? '?',
                        style: const TextStyle(fontSize: 24),
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info?.title ?? '',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (info?.subscriberLabel != null)
                      Text(
                        info!.subscriberLabel!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (info != null) _SubscribeButton(channel: info!),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: () => onPlayAll(),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Play all'),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () => onPlayAll(shuffle: true),
                icon: const Icon(Icons.shuffle),
                tooltip: 'Shuffle',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Subscribe / Subscribed toggle.
///
/// Local only: without a Google account there is nothing to sync to, so this
/// follows the channel on this device and drives the Subscriptions feed. It is
/// worth having anyway — it is the only way to say "show me this channel's new
/// videos" when the account's real subscriptions are out of reach.
class _SubscribeButton extends StatefulWidget {
  const _SubscribeButton({required this.channel});

  final ChannelInfo channel;

  @override
  State<_SubscribeButton> createState() => _SubscribeButtonState();
}

class _SubscribeButtonState extends State<_SubscribeButton> {
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

  Future<void> _toggle() async {
    final db = context.read<AppDatabase>();
    final messenger = ScaffoldMessenger.of(context);
    if (_subscribed ?? false) {
      await db.unsubscribe(widget.channel.id);
      messenger.showSnackBar(
        SnackBar(content: Text('Unsubscribed from ${widget.channel.title}')),
      );
    } else {
      await db.subscribe(widget.channel);
      messenger.showSnackBar(
        SnackBar(content: Text('Subscribed to ${widget.channel.title}')),
      );
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final subscribed = _subscribed ?? false;
    final scheme = Theme.of(context).colorScheme;

    return FilledButton(
      onPressed: _subscribed == null ? null : _toggle,
      style: FilledButton.styleFrom(
        backgroundColor: subscribed
            ? scheme.onSurface.withValues(alpha: 0.12)
            : scheme.onSurface,
        foregroundColor: subscribed ? scheme.onSurface : scheme.surface,
        padding: const EdgeInsets.symmetric(horizontal: 18),
      ),
      child: Text(subscribed ? 'Subscribed' : 'Subscribe'),
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
