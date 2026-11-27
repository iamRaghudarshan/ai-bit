import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/db.dart';
import '../data/models.dart';
import '../data/subscription_activity.dart';
import 'channel_page.dart';
import 'widgets/library_widgets.dart';
import 'widgets/video_tile.dart';

/// Every followed channel, reached from "All" on the Subscriptions strip:
/// sortable the three ways YouTube offers, each row opening the channel,
/// with an unsubscribe that asks first.
class ManageSubscriptionsPage extends StatefulWidget {
  const ManageSubscriptionsPage({super.key});

  @override
  State<ManageSubscriptionsPage> createState() =>
      _ManageSubscriptionsPageState();
}

enum _Sort { relevant, activity, az }

class _ManageSubscriptionsPageState extends State<ManageSubscriptionsPage> {
  List<ChannelInfo> _channels = const [];
  Map<String, int> _latest = const {};
  Map<String, int> _watchCounts = const {};
  SubscriptionActivity? _activity;
  bool _loading = true;
  _Sort _sort = _Sort.relevant;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = context.read<AppDatabase>();
    final channels = await db.subscriptions();
    final counts = await db.channelWatchCounts();
    final activity = await SubscriptionActivity.load();
    if (!mounted) return;
    setState(() {
      _channels = channels;
      _watchCounts = counts;
      _latest = activity.latestUploads;
      _activity = activity;
      _loading = false;
    });
  }

  /// Most relevant: the channels watched most, then the ones posting most
  /// recently — the closest a device-local list gets to YouTube's own
  /// "most relevant", which is built from the same two signals.
  List<ChannelInfo> get _sorted {
    switch (_sort) {
      case _Sort.az:
        return _channels.toList()
          ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case _Sort.activity:
        return orderByActivity(_channels, _latest);
      case _Sort.relevant:
        final byActivity = orderByActivity(_channels, _latest);
        final rank = {for (var i = 0; i < byActivity.length; i++) byActivity[i].id: i};
        return byActivity.toList()
          ..sort((a, b) {
            final wa = _watchCounts[a.id] ?? 0;
            final wb = _watchCounts[b.id] ?? 0;
            if (wa != wb) return wb.compareTo(wa);
            return rank[a.id]!.compareTo(rank[b.id]!);
          });
    }
  }

  Future<void> _unsubscribe(ChannelInfo channel) async {
    final yes = await confirmAction(
      context,
      title: 'Unsubscribe from ${channel.title}?',
      message: 'Their uploads will stop appearing in Subscriptions.',
      confirmLabel: 'Unsubscribe',
    );
    if (!yes || !mounted) return;
    final db = context.read<AppDatabase>();
    final messenger = ScaffoldMessenger.of(context);
    await db.unsubscribe(channel.id);
    if (!mounted) return;
    setState(() => _channels = _channels.where((c) => c.id != channel.id).toList());
    messenger.showSnackBar(
      SnackBar(
        content: Text('Unsubscribed from ${channel.title}'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await db.subscribe(channel);
            _load();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final channels = _sorted;
    return Scaffold(
      appBar: AppBar(
        title: const Text('All subscriptions'),
        actions: [
          PopupMenuButton<_Sort>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort',
            initialValue: _sort,
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (_) => const [
              PopupMenuItem(value: _Sort.relevant, child: Text('Most relevant')),
              PopupMenuItem(value: _Sort.activity, child: Text('New activity')),
              PopupMenuItem(value: _Sort.az, child: Text('A–Z')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : channels.isEmpty
          ? const EmptyState(
              icon: Icons.subscriptions_outlined,
              title: 'No subscriptions',
              message: 'Channels you subscribe to on this device appear here.',
            )
          : ListView.builder(
              itemCount: channels.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Text(
                      switch (_sort) {
                        _Sort.relevant => 'Most relevant',
                        _Sort.activity => 'New activity',
                        _Sort.az => 'A–Z',
                      },
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                final channel = channels[i - 1];
                final unseen = _activity?.hasUnseen(channel.id) ?? false;
                return ListTile(
                  leading: CircleAvatar(
                    radius: 22,
                    backgroundColor:
                        theme.colorScheme.onSurface.withValues(alpha: 0.1),
                    foregroundImage: channel.avatarUrl == null
                        ? null
                        : CachedNetworkImageProvider(
                            channel.avatarUrl!,
                            maxWidth: 132,
                            maxHeight: 132,
                          ),
                    child: Text(
                      channel.title.isEmpty
                          ? '?'
                          : channel.title.substring(0, 1).toUpperCase(),
                    ),
                  ),
                  title: Text(
                    channel.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: unseen ? const Text('New uploads') : null,
                  trailing: FilledButton.tonal(
                    onPressed: () => _unsubscribe(channel),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    child: const Text('Subscribed'),
                  ),
                  onTap: () async {
                    await ChannelPage.open(context, channel.id, title: channel.title);
                    _load();
                  },
                );
              },
            ),
    );
  }
}
