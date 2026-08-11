import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../data/db.dart';
import '../data/download_manager.dart';
import '../data/models.dart';
import 'downloads_page.dart';
import 'history_page.dart';
import 'playlist_detail_page.dart';
import 'watch_page.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// Everything saved on this device: recent history plus local playlists.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => LibraryPageState();
}

class LibraryPageState extends State<LibraryPage> {
  late Future<_LibraryData> _future = _load();

  Future<_LibraryData> _load() async {
    final db = context.read<AppDatabase>();
    return (playlists: await db.playlists(), history: await db.history(limit: 12));
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          IconButton(
            icon: const Icon(Icons.playlist_add),
            tooltip: 'New playlist',
            onPressed: _createPlaylist,
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
                ListTile(
                  leading: const Icon(Icons.download_for_offline_outlined),
                  title: const Text('Downloads'),
                  subtitle: Text(
                    busyCount > 0
                        ? '$offlineCount offline • $busyCount in progress'
                        : offlineCount == 0
                        ? 'Save videos to watch without internet'
                        : '$offlineCount offline • '
                              '${formatBytes(downloads.storageUsed)}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const DownloadsPage()),
                  ),
                ),
                const Divider(height: 1),
                _SectionHeader(
                  title: 'History',
                  onSeeAll: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const HistoryPage()),
                    );
                    reload();
                  },
                ),
                if (data.history.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text('Videos you watch will show up here.'),
                  )
                else
                  SizedBox(
                    height: 168,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: data.history.length,
                      itemBuilder: (context, index) {
                        final entry = data.history[index];
                        return SizedBox(
                          width: 200,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: InkWell(
                              onTap: () async {
                                await WatchPage.open(context, entry.video);
                                reload();
                              },
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  VideoThumb(
                                    video: entry.video,
                                    progress: entry.progress,
                                    radius: 8,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    entry.video.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                const Divider(height: 32),
                const _SectionHeader(title: 'Playlists'),
                for (final playlist in data.playlists)
                  _PlaylistTile(
                    playlist: playlist,
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => PlaylistDetailPage(playlist: playlist),
                        ),
                      );
                      reload();
                    },
                    onDeleted: reload,
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

typedef _LibraryData = ({List<LocalPlaylist> playlists, List<HistoryEntry> history});

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.onSeeAll});

  final String title;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 8, 10),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        if (onSeeAll != null)
          TextButton(onPressed: onSeeAll, child: const Text('See all')),
      ],
    ),
  );
}

class _PlaylistTile extends StatelessWidget {
  const _PlaylistTile({
    required this.playlist,
    required this.onTap,
    required this.onDeleted,
  });

  final LocalPlaylist playlist;
  final VoidCallback onTap;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    final cover = playlist.coverVideoId;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 64,
          height: 40,
          child: cover == null
              ? ColoredBox(
                  color: AppColors.darkElevated,
                  child: Icon(
                    playlist.isWatchLater
                        ? Icons.watch_later_outlined
                        : Icons.playlist_play,
                    color: Colors.white38,
                  ),
                )
              : CachedNetworkImage(memCacheWidth: 480, 
                  imageUrl: 'https://i.ytimg.com/vi/$cover/hqdefault.jpg',
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) =>
                      const ColoredBox(color: AppColors.darkElevated),
                ),
        ),
      ),
      title: Text(playlist.name),
      subtitle: Text('${playlist.itemCount} videos'),
      trailing: playlist.isWatchLater
          ? null
          : IconButton(
              icon: const Icon(Icons.more_vert, size: 20),
              onPressed: () => _showPlaylistMenu(context),
            ),
      onTap: onTap,
    );
  }

  void _showPlaylistMenu(BuildContext context) {
    final db = context.read<AppDatabase>();
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () async {
                Navigator.pop(sheetContext);
                final name = await showNewPlaylistDialog(
                  context,
                  initial: playlist.name,
                );
                if (name == null) return;
                await db.renamePlaylist(playlist.id, name);
                onDeleted();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete playlist'),
              onTap: () async {
                Navigator.pop(sheetContext);
                await db.deletePlaylist(playlist.id);
                onDeleted();
              },
            ),
          ],
        ),
      ),
    );
  }
}
