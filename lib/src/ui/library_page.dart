import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/db.dart';
import '../data/download_manager.dart';
import '../data/models.dart';
import '../data/yt_repository.dart';
import 'all_playlists_page.dart';
import 'downloads_page.dart';
import 'history_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'watch_page.dart';
import 'widgets/library_transfer.dart';
import 'widgets/library_widgets.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// The You tab, in YouTube's order: History as a shelf, Playlists as a
/// shelf, then the rows — Downloads, Surprise me and the Takeout import.
///
/// Everything here is on this device: there is no account behind it.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => LibraryPageState();
}

class LibraryPageState extends State<LibraryPage> {
  late Future<_LibraryData> _future = _load();

  /// True while Surprise me is fetching. The tile shows a spinner and stops
  /// accepting taps — the fetch is fifteen browse requests, long enough that a
  /// second tap would otherwise queue a second one.
  bool _surprising = false;

  /// Picks a random video from the subscribed channels that is not in watch
  /// history, and opens it.
  ///
  /// Every unhappy path says which one it is. "Nothing happened" would be
  /// indistinguishable between no subscriptions, a failed fetch and having
  /// genuinely watched everything, and a control that silently does nothing is
  /// how a dead feature hides.
  Future<void> _surpriseMe() async {
    if (_surprising) return;
    setState(() => _surprising = true);
    final db = context.read<AppDatabase>();
    final repo = context.read<YtRepository>();
    try {
      final channels = await db.subscriptions();
      if (!mounted) return;
      if (channels.isEmpty) {
        _say(
          'Subscribe to a channel first — Surprise me picks from your '
          'subscriptions.',
        );
        return;
      }

      final watched = await db.watchedVideoIds();
      // A random fifteen rather than the first fifteen alphabetically, so
      // every subscription can be the one picked from.
      final videos = await repo.subscribedFeed(
        channels: channels.toList()..shuffle(),
      );
      if (!mounted) return;
      if (videos.isEmpty) {
        _say('Could not reach your subscriptions. Check your connection.');
        return;
      }

      final unwatched = videos.where((v) => !watched.contains(v.id)).toList();
      if (unwatched.isEmpty) {
        _say('You have already watched everything recent from your channels.');
        return;
      }

      // Random rather than "the newest one", so tapping twice is worth doing.
      final pick = unwatched[Random().nextInt(unwatched.length)];
      await WatchPage.open(context, pick);
      reload();
    } catch (e) {
      // Left visible on purpose: the alternative is a tile that shrugs.
      debugPrint('AI BIT: surprise me failed — $e');
      if (mounted) _say('Surprise me could not load anything just now.');
    } finally {
      if (mounted) setState(() => _surprising = false);
    }
  }

  void _say(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<_LibraryData> _load() async {
    final db = context.read<AppDatabase>();
    return (
      playlists: await loadLibraryPlaylists(db),
      history: await db.history(limit: 20, shorts: false, kids: false),
    );
  }

  /// Called by the shell when this tab becomes visible again, so a video
  /// watched on another tab shows up here immediately.
  void reload() {
    if (mounted) setState(() => _future = _load());
  }

  Future<void> _createPlaylist() async {
    final name = await showNewPlaylistDialog(context);
    if (name == null || !mounted) return;
    await context.read<AppDatabase>().createPlaylist(name);
    reload();
  }

  Future<void> _importFromTakeout() =>
      importFromTakeout(context, onDone: reload);

  Future<void> _push(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    reload();
  }

  void _historyMenu(HistoryEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove from watch history'),
              onTap: () async {
                Navigator.pop(sheetContext);
                final db = context.read<AppDatabase>();
                final messenger = ScaffoldMessenger.of(context);
                await db.deleteHistoryEntry(entry.video.id);
                reload();
                messenger.showSnackBar(
                  const SnackBar(content: Text('Removed from watch history')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.more_horiz),
              title: const Text('More options'),
              onTap: () {
                Navigator.pop(sheetContext);
                showVideoMenu(context, entry.video);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'You',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search',
            onPressed: () => _push(const SearchPage()),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => _push(const SettingsPage()),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => reload(),
        child: FutureBuilder<_LibraryData>(
          future: _future,
          builder: (context, snapshot) {
            final data = snapshot.data;
            if (data == null) {
              return const Center(child: CircularProgressIndicator());
            }
            final downloads = context.watch<DownloadManager>();
            final offlineCount = downloads.all.where((r) => r.isComplete).length;
            final busyCount = downloads.all.where((r) => !r.isComplete).length;

            return ListView(
              children: [
                ShelfHeader(
                  title: 'History',
                  onViewAll: () => _push(const HistoryPage()),
                ),
                if (data.history.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text('Videos you watch will show up here.'),
                  )
                else
                  SizedBox(
                    height: 168,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: data.history.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (context, index) => _HistoryCard(
                        entry: data.history[index],
                        onTap: () async {
                          await WatchPage.open(context, data.history[index].video);
                          reload();
                        },
                        onMenu: () => _historyMenu(data.history[index]),
                      ),
                    ),
                  ),
                ShelfHeader(
                  title: 'Playlists',
                  trailing: IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'New playlist',
                    onPressed: _createPlaylist,
                  ),
                  onViewAll: () => _push(const AllPlaylistsPage()),
                ),
                SizedBox(
                  height: 178,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: data.playlists.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, i) {
                      final entry = data.playlists[i];
                      void menu() => showLibraryPlaylistMenu(
                        context,
                        entry,
                        onChanged: reload,
                      );
                      return SizedBox(
                        width: 160,
                        child: PlaylistCard(
                          title: entry.title,
                          subtitle: entry.subtitle,
                          imageUrl: entry.imageUrl,
                          count: entry.count,
                          icon: entry.icon,
                          onTap: () async {
                            await openLibraryPlaylist(context, entry);
                            reload();
                          },
                          onMenu: menu,
                          onLongPress: menu,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('Downloads'),
                  subtitle: Text(
                    busyCount > 0
                        ? '$offlineCount offline • $busyCount in progress'
                        : offlineCount == 0
                        ? 'Save videos to watch without internet'
                        : '$offlineCount offline • '
                              '${formatBytes(downloads.storageUsed)}',
                  ),
                  onTap: () => _push(const DownloadsPage()),
                ),
                ListTile(
                  leading: _surprising
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.shuffle),
                  title: const Text('Surprise me'),
                  subtitle: const Text(
                    'A random video you have not watched, from your '
                    'subscriptions',
                  ),
                  onTap: _surprising ? null : _surpriseMe,
                ),
                ListTile(
                  leading: const Icon(Icons.drive_folder_upload_outlined),
                  title: const Text('Import from Google Takeout'),
                  subtitle: const Text(
                    'Bring in playlists, subscriptions and history',
                  ),
                  onTap: _importFromTakeout,
                ),
                const SizedBox(height: 24),
              ],
            );
          },
        ),
      ),
    );
  }
}

typedef _LibraryData = ({
  List<LibraryPlaylist> playlists,
  List<HistoryEntry> history,
});

/// A 150dp history card: thumbnail with the resume bar, two lines of title,
/// the channel, and a ⋮.
class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    required this.entry,
    required this.onTap,
    required this.onMenu,
  });

  final HistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 150,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        onLongPress: onMenu,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            VideoThumb(video: entry.video, progress: entry.progress, radius: 8),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.video.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11.5,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 24,
                  height: 24,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    icon: const Icon(Icons.more_vert),
                    onPressed: onMenu,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
