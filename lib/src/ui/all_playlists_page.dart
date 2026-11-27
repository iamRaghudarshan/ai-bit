import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_navigator.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../data/saved_playlists.dart';
import 'playlist_detail_page.dart';
import 'playlist_page.dart';
import 'widgets/library_widgets.dart';
import 'widgets/responsive_feed.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// One entry on the You tab's playlist shelf: a playlist on this device or a
/// YouTube playlist bookmarked from its page.
class LibraryPlaylist {
  const LibraryPlaylist.local(LocalPlaylist this.local) : remote = null;
  const LibraryPlaylist.remote(PlaylistBrief this.remote) : local = null;

  final LocalPlaylist? local;
  final PlaylistBrief? remote;

  String get title => local?.name ?? remote!.title;

  String? get imageUrl => local != null
      ? (local!.coverVideoId == null
            ? null
            : 'https://i.ytimg.com/vi/${local!.coverVideoId}/hqdefault.jpg')
      : remote!.thumbnailUrl;

  int? get count => local?.itemCount ?? remote!.videoCount;

  String get subtitle => local != null
      ? (local!.isWatchLater ? 'Private · On this device' : 'Playlist · On this device')
      : (remote!.author ?? 'Playlist');

  IconData get icon =>
      local?.isWatchLater == true ? Icons.watch_later_outlined : Icons.playlist_play;
}

/// Local playlists (Watch later first) followed by saved YouTube playlists.
Future<List<LibraryPlaylist>> loadLibraryPlaylists(AppDatabase db) async {
  final local = await db.playlists();
  final saved = await SavedPlaylists.all();
  return [
    for (final p in local) LibraryPlaylist.local(p),
    for (final p in saved) LibraryPlaylist.remote(p),
  ];
}

/// Opens [entry]; completes when the viewer comes back.
Future<void> openLibraryPlaylist(BuildContext context, LibraryPlaylist entry) {
  if (entry.local != null) {
    return pushContent(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PlaylistDetailPage(playlist: entry.local!),
      ),
    );
  }
  return PlaylistPage.open(context, entry.remote!);
}

/// The ⋮ menu for a shelf or grid entry. Deleting asks first — it used to
/// be one tap in this menu, with nothing to undo it — and forgetting a saved
/// playlist offers Undo, since it is only a bookmark.
Future<void> showLibraryPlaylistMenu(
  BuildContext context,
  LibraryPlaylist entry, {
  required VoidCallback onChanged,
}) {
  final db = context.read<AppDatabase>();
  final local = entry.local;
  return showModalBottomSheet<void>(
    useRootNavigator: true,
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (local != null && !local.isWatchLater) ...[
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename'),
              onTap: () async {
                Navigator.pop(sheetContext);
                final name = await showNewPlaylistDialog(
                  context,
                  initial: local.name,
                );
                if (name == null) return;
                await db.renamePlaylist(local.id, name);
                onChanged();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete playlist'),
              onTap: () async {
                Navigator.pop(sheetContext);
                final yes = await confirmAction(
                  context,
                  title: 'Delete ${local.name}?',
                  message: 'The playlist and its list of '
                      '${videoCountLabel(local.itemCount)} are removed from '
                      'this device.',
                  confirmLabel: 'Delete',
                );
                if (!yes) return;
                await db.deletePlaylist(local.id);
                onChanged();
              },
            ),
          ],
          if (local != null && local.isWatchLater)
            const ListTile(
              enabled: false,
              leading: Icon(Icons.watch_later_outlined),
              title: Text('Watch later cannot be renamed or deleted'),
            ),
          if (entry.remote != null)
            ListTile(
              leading: const Icon(Icons.bookmark_remove_outlined),
              title: const Text('Remove from library'),
              onTap: () async {
                Navigator.pop(sheetContext);
                final messenger = ScaffoldMessenger.of(context);
                await SavedPlaylists.toggle(entry.remote!);
                onChanged();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text('Removed ${entry.remote!.title}'),
                    action: SnackBarAction(
                      label: 'Undo',
                      onPressed: () async {
                        await SavedPlaylists.toggle(entry.remote!);
                        onChanged();
                      },
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    ),
  );
}

/// Every playlist as a grid, from "View all" on the You tab.
class AllPlaylistsPage extends StatefulWidget {
  const AllPlaylistsPage({super.key});

  @override
  State<AllPlaylistsPage> createState() => _AllPlaylistsPageState();
}

enum _Sort { recent, az }

class _AllPlaylistsPageState extends State<AllPlaylistsPage> {
  List<LibraryPlaylist>? _entries;
  _Sort _sort = _Sort.recent;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final entries = await loadLibraryPlaylists(context.read<AppDatabase>());
    if (mounted) setState(() => _entries = entries);
  }

  Future<void> _create() async {
    final name = await showNewPlaylistDialog(context);
    if (name == null || !mounted) return;
    await context.read<AppDatabase>().createPlaylist(name);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final sorted = entries == null
        ? null
        : _sort == _Sort.recent
        ? entries
        : (entries.toList()
            ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase())));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Playlists'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New playlist',
            onPressed: _create,
          ),
          PopupMenuButton<_Sort>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort',
            initialValue: _sort,
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (_) => const [
              PopupMenuItem(value: _Sort.recent, child: Text('Recently added')),
              PopupMenuItem(value: _Sort.az, child: Text('A–Z')),
            ],
          ),
        ],
      ),
      body: sorted == null
          ? const Center(child: CircularProgressIndicator())
          : sorted.isEmpty
          ? const EmptyState(icon: Icons.playlist_play, title: 'No playlists')
          : LayoutBuilder(
              builder: (context, constraints) {
                final columns =
                    (feedColumnsFor(constraints.maxWidth) + 1).clamp(2, 5);
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
                  itemCount: sorted.length,
                  itemBuilder: (context, i) {
                    final entry = sorted[i];
                    void menu() => showLibraryPlaylistMenu(
                      context,
                      entry,
                      onChanged: _reload,
                    );
                    return PlaylistCard(
                      title: entry.title,
                      subtitle: entry.subtitle,
                      imageUrl: entry.imageUrl,
                      count: entry.count,
                      icon: entry.icon,
                      onTap: () async {
                        await openLibraryPlaylist(context, entry);
                        _reload();
                      },
                      onMenu: menu,
                      onLongPress: menu,
                    );
                  },
                );
              },
            ),
    );
  }
}
