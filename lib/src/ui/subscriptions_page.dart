import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/db.dart';
import '../data/models.dart';
import '../data/yt_repository.dart';
import 'channel_page.dart';
import 'watch_page.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// Latest uploads from the channels followed on this device.
///
/// Not the account's real subscriptions — those need a signed-in Google
/// account. This is built from the local `subscriptions` table, which is the
/// only thing available and is genuinely useful: it answers "what's new from
/// the channels I care about".
class SubscriptionsPage extends StatefulWidget {
  const SubscriptionsPage({super.key});

  @override
  State<SubscriptionsPage> createState() => SubscriptionsPageState();
}

class SubscriptionsPageState extends State<SubscriptionsPage> {
  List<ChannelInfo> _channels = const [];
  List<VideoBrief> _videos = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// Called by the shell when this tab is selected, since a subscription may
  /// have been added from a channel page in the meantime.
  Future<void> reload() async {
    if (!mounted) return;
    setState(() => _loading = true);

    final db = context.read<AppDatabase>();
    final repo = context.read<YtRepository>();
    final channels = await db.subscriptions();
    if (!mounted) return;
    setState(() => _channels = channels);

    if (channels.isEmpty) {
      setState(() {
        _videos = const [];
        _loading = false;
      });
      return;
    }

    // Fetch every channel at once; one that fails should not empty the feed.
    final results = await Future.wait(
      channels.take(15).map(
        (c) async {
          try {
            return await repo.channelUploads(
              c.id,
              limit: 6,
              channelTitle: c.title,
            );
          } catch (_) {
            return <VideoBrief>[];
          }
        },
      ),
    );
    if (!mounted) return;

    // Newest first is impossible without a real date on every row — the API
    // gives "3 days ago" as text — so interleave instead, which keeps one
    // prolific channel from burying the rest.
    final merged = <VideoBrief>[];
    final seen = <String>{};
    final longest = results.fold(0, (m, r) => r.length > m ? r.length : m);
    for (var i = 0; i < longest; i++) {
      for (final list in results) {
        if (i >= list.length) continue;
        if (seen.add(list[i].id)) merged.add(list[i]);
      }
    }

    setState(() {
      _videos = merged;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Subscriptions')),
      body: RefreshIndicator(
        onRefresh: reload,
        child: Builder(
          builder: (context) {
            if (_loading && _videos.isEmpty) return const FeedSkeleton(count: 3);
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
            return Column(
              children: [
                _ChannelStrip(channels: _channels),
                const Divider(height: 1),
                Expanded(
                  child: _videos.isEmpty
                      ? const EmptyState(
                          icon: Icons.hourglass_empty,
                          title: 'Nothing new',
                          message: 'No recent uploads from these channels.',
                        )
                      : ListView.builder(
                          itemCount: _videos.length,
                          itemBuilder: (context, i) {
                            final video = _videos[i];
                            return VideoRow(
                              video: video,
                              onTap: () => WatchPage.openQueue(
                                context,
                                _videos,
                                startAt: i,
                              ),
                              onMenu: () => showVideoMenu(context, video),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Horizontal row of subscribed channel avatars, as in the real app.
class _ChannelStrip extends StatelessWidget {
  const _ChannelStrip({required this.channels});

  final List<ChannelInfo> channels;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 92,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        itemCount: channels.length,
        itemBuilder: (context, i) {
          final channel = channels[i];
          return InkWell(
            onTap: () =>
                ChannelPage.open(context, channel.id, title: channel.title),
            child: SizedBox(
              width: 74,
              child: Column(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.1),
                    backgroundImage: channel.avatarUrl == null
                        ? null
                        : CachedNetworkImageProvider(channel.avatarUrl!, maxWidth: 120, maxHeight: 120),
                    child: channel.avatarUrl != null
                        ? null
                        : Text(
                            channel.title.isEmpty
                                ? '?'
                                : channel.title.substring(0, 1).toUpperCase(),
                          ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    channel.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontSize: 10),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
