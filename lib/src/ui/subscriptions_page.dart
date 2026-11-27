import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/db.dart';
import '../data/models.dart';
import '../data/subscription_activity.dart';
import '../data/yt_repository.dart';
import 'channel_page.dart';
import 'manage_subscriptions_page.dart';
import 'watch_page.dart';
import 'widgets/library_widgets.dart';
import 'widgets/responsive_feed.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// Latest uploads from the channels followed on this device.
///
/// Not the account's real subscriptions — those need a signed-in Google
/// account. This is built from the local `subscriptions` table, which is the
/// only thing available and is genuinely useful: it answers "what's new from
/// the channels I care about".
///
/// Laid out as YouTube's Subscriptions tab is: an avatar strip ordered by
/// newest upload (a dot under a channel with something unseen, an "All"
/// button for the full list), filter chips, a Shorts shelf, then full-width
/// cards newest first.
///
/// **Every channel is reachable.** Each channel is its own browse request,
/// so not all of them can be fetched at once. This used to take the first
/// fifteen channels *alphabetically* and nothing else, so a subscription
/// named "Zack" never appeared at all. [subscriptionBatches] now fetches the
/// most recently active channels first, rotates a slice of the quieter ones
/// into the first batch on every refresh, and fetches the rest batch by
/// batch as the feed is scrolled. Tapping any avatar fetches that channel on
/// its own.
class SubscriptionsPage extends StatefulWidget {
  const SubscriptionsPage({super.key});

  @override
  State<SubscriptionsPage> createState() => SubscriptionsPageState();
}

class SubscriptionsPageState extends State<SubscriptionsPage> {
  static const _perChannel = 8;
  static const _shortsChannels = 6;

  static const _filterLabels = {
    SubsFilter.all: 'All',
    SubsFilter.today: 'Today',
    SubsFilter.videos: 'Videos',
    SubsFilter.shorts: 'Shorts',
    SubsFilter.continueWatching: 'Continue watching',
    SubsFilter.unwatched: 'Unwatched',
  };

  List<ChannelInfo> _channels = const [];
  SubscriptionActivity? _activity;
  List<List<ChannelInfo>> _batches = const [];
  int _nextBatch = 0;

  /// Every fetched long-form upload, newest first.
  List<VideoBrief> _videos = const [];

  /// Recent Shorts from the busiest channels, for the shelf and the chip.
  List<VideoBrief> _shorts = const [];

  /// Uploads per channel, for the in-place channel filter.
  final Map<String, List<VideoBrief>> _byChannel = {};

  Map<String, double> _progress = const {};
  Set<String> _watched = const {};

  bool _loading = true;
  bool _loadingMore = false;
  bool _loadingChannel = false;
  SubsFilter _filter = SubsFilter.all;
  String? _channelFilter;

  /// The highest feed row built so far. Rows fetched later are merged in
  /// only below it, so a batch arriving mid-scroll never shifts what the
  /// viewer is looking at.
  int _maxBuilt = 0;

  // No initState fetch: every tab is built at startup inside the shell's
  // IndexedStack, so loading here would fire a network request on launch while
  // the user is still on Home. The shell calls reload() when the tab is first
  // opened instead.

  /// Called by the shell when this tab is selected, since a subscription may
  /// have been added from a channel page in the meantime. The first call loads;
  /// this is what defers the startup fetch.
  Future<void> reload() async {
    if (!mounted) return;
    setState(() => _loading = true);

    final db = context.read<AppDatabase>();
    final channels = await db.subscriptions();
    final activity = await SubscriptionActivity.load();
    if (!mounted) return;
    activity
      ..retainOnly(channels.map((c) => c.id))
      ..rotation += 1;

    setState(() {
      _channels = channels;
      _activity = activity;
      _batches = subscriptionBatches(
        channels,
        activity.latestUploads,
        rotation: activity.rotation,
      );
      _nextBatch = 0;
      _videos = const [];
      _shorts = const [];
      _byChannel.clear();
      _maxBuilt = 0;
      if (_channelFilter != null &&
          !channels.any((c) => c.id == _channelFilter)) {
        _channelFilter = null;
      }
    });

    if (channels.isEmpty) {
      setState(() => _loading = false);
      return;
    }

    await _fetchNextBatch(first: true);
    if (!mounted) return;
    setState(() => _loading = false);
    _loadShorts();
    if (_channelFilter != null) _selectChannel(_channelFilter!, force: true);
  }

  /// Fetches one batch of channels and merges its uploads in.
  Future<void> _fetchNextBatch({bool first = false}) async {
    if (_nextBatch >= _batches.length) return;
    final batch = _batches[_nextBatch++];
    final repo = context.read<YtRepository>();
    final db = context.read<AppDatabase>();
    final now = DateTime.now();

    // Every channel at once; one that fails should not empty the feed, and
    // says why in the log rather than vanishing.
    final results = await Future.wait(
      batch.map((c) async {
        try {
          return await repo.channelUploads(
            c.id,
            limit: _perChannel,
            channelTitle: c.title,
          );
        } catch (e) {
          debugPrint('AI BIT: subscription fetch failed for ${c.title} — $e');
          return <VideoBrief>[];
        }
      }),
    );
    if (!mounted) return;

    final activity = _activity;
    final fresh = <VideoBrief>[];
    for (var i = 0; i < batch.length; i++) {
      final uploads = results[i];
      _byChannel.putIfAbsent(batch[i].id, () => uploads);
      activity?.recordUploads(batch[i].id, uploads, now);
      fresh.addAll(uploads);
    }
    activity?.save();

    final seen = _videos.map((v) => v.id).toSet();
    fresh.removeWhere((v) => !seen.add(v.id));
    final merged = first
        ? _newestFirst(fresh)
        : [
            ..._videos.take(_maxBuilt + 1),
            ..._newestFirst([..._videos.skip(_maxBuilt + 1), ...fresh]),
          ];

    final ids = merged.map((v) => v.id);
    final progress = await db.watchProgress(ids);
    final watched = await db.watchedVideoIds();
    if (!mounted) return;
    setState(() {
      _videos = merged;
      _progress = progress;
      _watched = watched;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _nextBatch >= _batches.length) return;
    setState(() => _loadingMore = true);
    try {
      await _fetchNextBatch();
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// Recent Shorts from the most active channels, interleaved so no one
  /// channel fills the shelf. A second request per channel, so it is kept to
  /// a handful of channels and never blocks the feed.
  Future<void> _loadShorts() async {
    final repo = context.read<YtRepository>();
    final channels = orderByActivity(
      _channels,
      _activity?.latestUploads ?? const {},
    ).take(_shortsChannels).toList();
    final lists = await Future.wait(
      channels.map((c) async {
        try {
          final shorts = await repo.channelShorts(c.id, channelTitle: c.title);
          return shorts.take(4).map((s) => s.asShort()).toList();
        } catch (e) {
          debugPrint('AI BIT: subscription shorts failed for ${c.title} — $e');
          return <VideoBrief>[];
        }
      }),
    );
    if (!mounted) return;
    final out = <VideoBrief>[];
    final longest = lists.fold(0, (m, l) => l.length > m ? l.length : m);
    for (var i = 0; i < longest; i++) {
      for (final l in lists) {
        if (i < l.length) out.add(l[i]);
      }
    }
    setState(() => _shorts = out);
  }

  static List<VideoBrief> _newestFirst(List<VideoBrief> videos) {
    const unknown = 1 << 40;
    final indexed = [
      for (var i = 0; i < videos.length; i++)
        (i: i, v: videos[i], age: YtRepository.uploadAgeSeconds(videos[i]) ?? unknown),
    ];
    indexed.sort((a, b) => a.age != b.age ? a.age.compareTo(b.age) : a.i.compareTo(b.i));
    return [for (final x in indexed) x.v];
  }

  /// Filters the feed to one channel in place; tapping the same avatar
  /// again clears it. Fetches the channel on its own when its batch has not
  /// been reached yet, or to show more than the handful the feed holds.
  Future<void> _selectChannel(String channelId, {bool force = false}) async {
    if (!force && _channelFilter == channelId) {
      setState(() => _channelFilter = null);
      return;
    }
    setState(() => _channelFilter = channelId);
    _activity
      ?..markViewed(channelId)
      ..save();
    final have = _byChannel[channelId];
    if (have != null && have.length > _perChannel && !force) return;

    final channel = _channels.firstWhere(
      (c) => c.id == channelId,
      orElse: () => ChannelInfo(id: channelId, title: ''),
    );
    setState(() => _loadingChannel = true);
    try {
      final videos = await context.read<YtRepository>().channelUploads(
        channelId,
        limit: 30,
        channelTitle: channel.title,
      );
      if (!mounted) return;
      final progress = await context.read<AppDatabase>().watchProgress(
        videos.map((v) => v.id),
      );
      if (!mounted) return;
      setState(() {
        _byChannel[channelId] = videos;
        _progress = {..._progress, ...progress};
      });
    } catch (e) {
      debugPrint('AI BIT: channel filter fetch failed for $channelId — $e');
    } finally {
      if (mounted) setState(() => _loadingChannel = false);
    }
  }

  Future<void> _openManage() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ManageSubscriptionsPage()),
    );
    if (!mounted) return;
    final now = await context.read<AppDatabase>().subscriptions();
    if (!mounted) return;
    if (now.length != _channels.length) reload();
  }

  List<VideoBrief> get _visible {
    final channel = _channelFilter;
    if (channel != null) {
      final rows = _byChannel[channel] ?? const <VideoBrief>[];
      return filterSubscriptionFeed(
        _filter == SubsFilter.shorts ? const [] : rows,
        _filter == SubsFilter.shorts ? SubsFilter.all : _filter,
        progress: _progress,
        watched: _watched,
        ageSeconds: YtRepository.uploadAgeSeconds,
      );
    }
    return filterSubscriptionFeed(
      _filter == SubsFilter.shorts ? _shorts : _videos,
      _filter,
      progress: _progress,
      watched: _watched,
      ageSeconds: YtRepository.uploadAgeSeconds,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Subscriptions')),
      body: RefreshIndicator(
        onRefresh: reload,
        child: Builder(
          builder: (context) {
            if (_loading && _videos.isEmpty && _channels.isEmpty) {
              return const FeedSkeleton(count: 3);
            }
            if (_channels.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 60),
                  EmptyState(
                    icon: Icons.subscriptions_outlined,
                    title: 'No subscriptions yet',
                    message:
                        'Open any channel and tap Subscribe. Their newest '
                        'videos will collect here.\n\nThese are stored on this '
                        'device — they are not your Google account\'s '
                        'subscriptions, which need a sign-in this app does '
                        'not have.',
                  ),
                ],
              );
            }
            return _buildFeed(context);
          },
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final ordered = orderByActivity(
      _channels,
      _activity?.latestUploads ?? const {},
    );
    final channel = _channelFilter == null
        ? null
        : _channels.where((c) => c.id == _channelFilter).firstOrNull;
    final showShelf = _filter == SubsFilter.all &&
        _channelFilter == null &&
        _shorts.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ChannelStrip(
          channels: ordered,
          selected: _channelFilter,
          hasUnseen: (id) => _activity?.hasUnseen(id) ?? false,
          onTap: _selectChannel,
          onAll: _openManage,
        ),
        FeedChipRow(
          labels: _filterLabels.values.toList(),
          selected: SubsFilter.values.indexOf(_filter),
          onSelected: (i) => setState(() => _filter = SubsFilter.values[i]),
        ),
        if (channel != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    channel.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => ChannelPage.open(
                    context,
                    channel.id,
                    title: channel.title,
                  ),
                  child: const Text('View channel'),
                ),
              ],
            ),
          ),
        if (showShelf)
          SubsShortsShelf(
            shorts: _shorts,
            onOpen: (i) => openShortsList(context, _shorts, index: i),
          ),
      ],
    );
  }

  Widget _buildFeed(BuildContext context) {
    final visible = _visible;
    final header = _buildHeader(context);
    final busy = _loading || _loadingChannel;

    if (_filter == SubsFilter.shorts && _channelFilter == null) {
      return CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: header),
          if (visible.isEmpty)
            SliverToBoxAdapter(
              child: busy
                  ? const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : const EmptyState(
                      icon: Icons.bolt,
                      title: 'No Shorts',
                      message: 'Your busiest channels have not posted any.',
                    ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  // Three on a phone, as YouTube's Shorts grids are.
                  crossAxisCount:
                      (MediaQuery.sizeOf(context).width / 130).floor().clamp(3, 8),
                  crossAxisSpacing: 6,
                  mainAxisSpacing: 6,
                  childAspectRatio: 9 / 16,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => ShortTile(
                    video: visible[i],
                    showTitle: true,
                    onTap: () => openShortsList(context, visible, index: i),
                  ),
                  childCount: visible.length,
                ),
              ),
            ),
        ],
      );
    }

    if (visible.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          header,
          if (busy)
            const Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox(height: 400, child: FeedSkeleton(count: 2)),
            )
          else
            EmptyState(
              icon: Icons.hourglass_empty,
              title: 'Nothing here',
              message: switch (_filter) {
                SubsFilter.today => 'Nothing posted in the last day.',
                SubsFilter.continueWatching =>
                  'Nothing started and left unfinished.',
                SubsFilter.unwatched => 'You have watched everything loaded.',
                _ => 'No recent uploads from these channels.',
              },
              action: _nextBatch < _batches.length && _channelFilter == null
                  ? OutlinedButton(
                      onPressed: _loadMore,
                      child: const Text('Look further'),
                    )
                  : null,
            ),
        ],
      );
    }

    final more = _channelFilter == null && _nextBatch < _batches.length;
    return ResponsiveVideoFeed(
      videos: visible,
      header: header,
      // Item builders run during a build; the fetch's setState must not.
      onNearEnd: more
          ? () => WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _loadMore();
            })
          : null,
      footer: more || _loadingMore
          ? const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            )
          : const SizedBox(height: 24),
      listItemBuilder: (context, i) {
        if (i > _maxBuilt && _filter == SubsFilter.all && _channelFilter == null) {
          _maxBuilt = i;
        }
        final video = visible[i];
        return VideoCard(
          video: video,
          progress: _progress[video.id] ?? 0,
          onTap: () => _open(visible, i),
          onMenu: () => showVideoMenu(context, video),
        );
      },
      gridItemBuilder: (context, i) {
        if (i > _maxBuilt && _filter == SubsFilter.all && _channelFilter == null) {
          _maxBuilt = i;
        }
        final video = visible[i];
        return VideoCard(
          video: video,
          inGrid: true,
          progress: _progress[video.id] ?? 0,
          onTap: () => _open(visible, i),
          onMenu: () => showVideoMenu(context, video),
        );
      },
    );
  }

  Future<void> _open(List<VideoBrief> list, int i) async {
    await WatchPage.openQueue(context, list, startAt: i);
    if (!mounted) return;
    // Back from watching: refresh the progress bars and the Unwatched chip.
    final db = context.read<AppDatabase>();
    final progress = await db.watchProgress(_videos.map((v) => v.id));
    final watched = await db.watchedVideoIds();
    if (!mounted) return;
    setState(() {
      _progress = {..._progress, ...progress};
      _watched = watched;
    });
  }
}

/// Horizontal row of subscribed channel avatars, newest upload first, with an
/// "All" button pinned to its end, as in the real app.
class _ChannelStrip extends StatelessWidget {
  const _ChannelStrip({
    required this.channels,
    required this.selected,
    required this.hasUnseen,
    required this.onTap,
    required this.onAll,
  });

  final List<ChannelInfo> channels;
  final String? selected;
  final bool Function(String channelId) hasUnseen;
  final ValueChanged<String> onTap;
  final VoidCallback onAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 108,
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(8, 8, 0, 4),
              itemCount: channels.length,
              itemBuilder: (context, i) {
                final channel = channels[i];
                final isSelected = channel.id == selected;
                final dimmed = selected != null && !isSelected;
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onTap(channel.id),
                  onLongPress: () =>
                      ChannelPage.open(context, channel.id, title: channel.title),
                  child: Opacity(
                    opacity: dimmed ? 0.45 : 1,
                    child: SizedBox(
                      width: 72,
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                width: 2,
                                color: isSelected
                                    ? theme.colorScheme.onSurface
                                    : Colors.transparent,
                              ),
                            ),
                            child: CircleAvatar(
                              radius: 26,
                              backgroundColor: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.1),
                              foregroundImage: channel.avatarUrl == null
                                  ? null
                                  : CachedNetworkImageProvider(
                                      channel.avatarUrl!,
                                      maxWidth: 160,
                                      maxHeight: 160,
                                    ),
                              child: Text(
                                channel.title.isEmpty
                                    ? '?'
                                    : channel.title.substring(0, 1).toUpperCase(),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  channel.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          // The unseen-upload dot, where YouTube puts it.
                          Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: hasUnseen(channel.id)
                                  ? const Color(0xFF3EA6FF)
                                  : Colors.transparent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          TextButton(
            onPressed: onAll,
            child: const Text('All'),
          ),
        ],
      ),
    );
  }
}
