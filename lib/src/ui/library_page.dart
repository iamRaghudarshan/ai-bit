import 'dart:async';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../data/db.dart';
import '../data/download_manager.dart';
import '../data/models.dart';
import '../data/takeout_service.dart';
import '../data/yt_repository.dart';
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
      final videos = await repo.subscribedFeed(channels: channels);
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
    return (playlists: await db.playlists(), history: await db.history(limit: 12, shorts: false, kids: false));
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

  /// Imports playlists exported from a Google account through Takeout.
  ///
  /// Takeout rather than a Google sign-in on purpose: signing in would put a
  /// real account behind a client that violates YouTube's terms, and this
  /// reaches private playlists without ever authenticating.
  Future<void> _importFromTakeout() async {
    final messenger = ScaffoldMessenger.of(context);
    final service = TakeoutService(
      database: context.read<AppDatabase>(),
      repository: context.read<YtRepository>(),
    );

    // Matches how storage_page calls the picker: this version exposes it
    // statically and returns a plain list.
    final picked = await FilePicker.pickFiles(
      // Not FileType.custom with a csv extension: on some Android providers
      // that filter hides the very files it is meant to show, and a picker
      // that appears empty reads as a broken feature. Multi-select is the
      // default here; an export has one file per playlist.
      type: FileType.any,
    );
    if (picked.isEmpty || !mounted) return;

    final paths = picked.map((f) => f.path).whereType<String>().toList();
    if (paths.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No files could be read.')),
      );
      return;
    }

    final progress = ValueNotifier<TakeoutProgress?>(null);
    // Not dismissible: the import writes playlist rows as it goes, so letting
    // it be dismissed would leave a half-filled playlist with no indication
    // that it is still growing.
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _TakeoutProgressDialog(progress: progress),
      ),
    );

    TakeoutResult result;
    try {
      result = await service.importFiles(
        paths,
        onProgress: (p) => progress.value = p,
      );
    } catch (e) {
      result = const TakeoutResult(playlists: 0, imported: 0, failed: 0);
      debugPrint('AI BIT: takeout import failed - $e');
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();
    reload();

    // Said plainly, including what did not come through: an import that
    // silently drops deleted or private videos looks like it worked.
    final message = result.isEmpty && result.skippedFiles > 0
        ? 'Those files held nothing to import. Pick the "-videos.csv" '
              'playlist files, subscriptions.csv, or watch-history.html.'
        : result.summary;
    messenger.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
    );
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
          IconButton(
            icon: const Icon(Icons.drive_folder_upload_outlined),
            tooltip: 'Import from Google Takeout',
            onPressed: _importFromTakeout,
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
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _surprising ? null : _surpriseMe,
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


/// Progress while a Takeout import runs.
///
/// Shows the playlist being filled and a count, because the slow part is one
/// network lookup per video - Takeout gives ids and nothing else - and a bare
/// spinner for two minutes reads as a hang.
class _TakeoutProgressDialog extends StatelessWidget {
  const _TakeoutProgressDialog({required this.progress});

  final ValueNotifier<TakeoutProgress?> progress;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Importing'),
      content: ValueListenableBuilder<TakeoutProgress?>(
        valueListenable: progress,
        builder: (context, value, _) {
          final total = value?.total ?? 0;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value?.playlistName ?? 'Reading the export…',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                // Indeterminate until the first file is parsed, because a bar
                // sitting at zero looks stuck.
                value: total == 0 ? null : (value!.done / total),
              ),
              const SizedBox(height: 8),
              Text(
                total == 0
                    ? 'Looking up every video, one at a time.'
                    : '${value!.done} of $total'
                          '${value.failed > 0 ? ' — ${value.failed} unavailable' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
    );
  }
}
