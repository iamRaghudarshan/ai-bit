import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/db.dart';
import '../data/models.dart';
import '../data/yt_repository.dart';
import 'watch_page.dart';
import 'widgets/library_widgets.dart';
import 'widgets/playlist_header.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// One of the playlists stored on this device, Watch later included.
///
/// The same header as a YouTube playlist, plus what an owner can do: drag to
/// reorder (persisted), sort the view, rename and delete (asking first), and
/// on Watch later, clear out what has been watched.
class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({super.key, required this.playlist});

  final LocalPlaylist playlist;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

enum _Order { manual, popular, newest, oldest, title }

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  final _scroll = ScrollController();
  bool _collapsed = false;
  List<VideoBrief>? _items;
  Map<String, double> _progress = const {};
  late String _name = widget.playlist.name;
  _Order _order = _Order.manual;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final collapsed = _scroll.hasClients && _scroll.offset > 280;
      if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
    });
    _reload();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final db = context.read<AppDatabase>();
    final items = await db.playlistItems(widget.playlist.id);
    final progress = await db.watchProgress(items.map((v) => v.id));
    if (!mounted) return;
    setState(() {
      _items = items;
      _progress = progress;
    });
  }

  List<VideoBrief> get _ordered {
    final items = _items ?? const <VideoBrief>[];
    int age(VideoBrief v) => YtRepository.uploadAgeSeconds(v) ?? (1 << 40);
    return switch (_order) {
      _Order.manual => items,
      _Order.popular => items.toList()
        ..sort((a, b) => (b.viewCount ?? 0).compareTo(a.viewCount ?? 0)),
      _Order.newest => items.toList()..sort((a, b) => age(a).compareTo(age(b))),
      _Order.oldest => items.toList()..sort((a, b) => age(b).compareTo(age(a))),
      _Order.title => items.toList()
        ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase())),
    };
  }

  /// Through the same queue path as every other list, so the playlist is
  /// followed in order rather than replaced by suggestions.
  void _play(List<VideoBrief> items, {int at = 0}) async {
    if (items.isEmpty) return;
    await WatchPage.openQueue(context, items, startAt: at);
    _reload();
  }

  Future<void> _onReorder(int from, int to) async {
    // onReorderItem has already adjusted [to] for the removed row.
    final items = (_items ?? const <VideoBrief>[]).toList();
    final moved = items.removeAt(from);
    items.insert(to, moved);
    setState(() => _items = items);
    await context.read<AppDatabase>().reorderPlaylist(
      widget.playlist.id,
      items.map((v) => v.id).toList(),
    );
  }

  Future<void> _removeWatched() async {
    final items = _items ?? const <VideoBrief>[];
    final watched = items.where((v) => (_progress[v.id] ?? 0) >= 0.9).toList();
    if (watched.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing here has been watched to the end.')),
      );
      return;
    }
    final yes = await confirmAction(
      context,
      title: 'Remove ${watched.length} watched '
          '${watched.length == 1 ? 'video' : 'videos'}?',
      message: 'Videos watched at least 90% of the way through are removed '
          'from $_name.',
      confirmLabel: 'Remove',
    );
    if (!yes || !mounted) return;
    final db = context.read<AppDatabase>();
    for (final v in watched) {
      await db.removeFromPlaylist(widget.playlist.id, v.id);
    }
    _reload();
  }

  Future<void> _rename() async {
    final name = await showNewPlaylistDialog(context, initial: _name);
    if (name == null || !mounted) return;
    await context.read<AppDatabase>().renamePlaylist(widget.playlist.id, name);
    if (mounted) setState(() => _name = name);
  }

  Future<void> _delete() async {
    final yes = await confirmAction(
      context,
      title: 'Delete $_name?',
      message: 'The playlist and its list of videos are removed from this '
          'device. The videos themselves are not affected.',
      confirmLabel: 'Delete',
    );
    if (!yes || !mounted) return;
    await context.read<AppDatabase>().deletePlaylist(widget.playlist.id);
    if (mounted) Navigator.of(context).pop();
  }

  void _showMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.playlist.isWatchLater)
              ListTile(
                leading: const Icon(Icons.playlist_remove),
                title: const Text('Remove watched videos'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _removeWatched();
                },
              ),
            if (!widget.playlist.isWatchLater) ...[
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _rename();
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete playlist'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _delete();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, List<VideoBrief> items, int i) {
    final video = items[i];
    return VideoRow(
      video: video,
      progress: _progress[video.id] ?? 0,
      onTap: () => _play(items, at: i),
      onMenu: () => showVideoMenu(
        context,
        video,
        removeLabel: 'Remove from $_name',
        onRemove: () async {
          await context.read<AppDatabase>().removeFromPlaylist(
            widget.playlist.id,
            video.id,
          );
          _reload();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final ordered = _ordered;
    final count = items?.length ?? widget.playlist.itemCount;
    final cover = ordered.firstOrNull?.thumbUrl ??
        (widget.playlist.coverVideoId == null
            ? null
            : 'https://i.ytimg.com/vi/${widget.playlist.coverVideoId}/hqdefault.jpg');

    final header = PlaylistHeader(
      title: _name,
      coverUrl: cover,
      owner: 'On this device',
      meta: ['Playlist', videoCountLabel(count), 'Private'].join(' · '),
      actions: [
        PopupMenuButton<_Order>(
          tooltip: 'Sort',
          initialValue: _order,
          onSelected: (o) => setState(() => _order = o),
          itemBuilder: (_) => const [
            PopupMenuItem(value: _Order.manual, child: Text('Manual')),
            PopupMenuItem(value: _Order.popular, child: Text('Most popular')),
            PopupMenuItem(value: _Order.newest, child: Text('Date published (newest)')),
            PopupMenuItem(value: _Order.oldest, child: Text('Date published (oldest)')),
            PopupMenuItem(value: _Order.title, child: Text('Title')),
          ],
          child: const IgnorePointer(
            child: PlaylistAction(icon: Icons.sort, tooltip: 'Sort', onPressed: _noop),
          ),
        ),
        PlaylistAction(
          icon: Icons.more_vert,
          tooltip: 'More',
          onPressed: _showMenu,
        ),
      ],
      onPlayAll: ordered.isEmpty ? null : () => _play(ordered),
      onShuffle: ordered.isEmpty ? null : () => _play(ordered.toList()..shuffle()),
    );

    return Scaffold(
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverAppBar(
            pinned: true,
            title: AnimatedOpacity(
              opacity: _collapsed ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
          SliverToBoxAdapter(child: header),
          if (items == null)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (items.isEmpty)
            const SliverToBoxAdapter(
              child: EmptyState(
                icon: Icons.playlist_play,
                title: 'Playlist is empty',
                message: 'Use "Save to…" on any video to add it here.',
              ),
            )
          else if (_order == _Order.manual)
            // Drag by the handle to reorder, as on YouTube's own playlists.
            SliverReorderableList(
              itemCount: ordered.length,
              onReorderItem: _onReorder,
              proxyDecorator: (child, _, _) =>
                  Material(elevation: 6, child: child),
              itemBuilder: (context, i) => Row(
                key: ValueKey(ordered[i].id),
                children: [
                  ReorderableDragStartListener(
                    index: i,
                    child: const Padding(
                      padding: EdgeInsets.fromLTRB(8, 24, 0, 24),
                      child: Icon(Icons.drag_handle, size: 20),
                    ),
                  ),
                  Expanded(child: _row(context, ordered, i)),
                ],
              ),
            )
          else
            SliverList.builder(
              itemCount: ordered.length,
              itemBuilder: (context, i) => _row(context, ordered, i),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}

void _noop() {}
