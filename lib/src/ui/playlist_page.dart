import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/db.dart';
import '../data/models.dart';
import '../data/yt_repository.dart';
import 'watch_page.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// A YouTube playlist — someone else's, as opposed to the local ones in
/// [PlaylistDetailPage].
///
/// Playing any entry queues the rest behind it, so a playlist behaves like a
/// playlist rather than a list of unrelated videos.
class PlaylistPage extends StatefulWidget {
  const PlaylistPage({super.key, required this.playlist});

  final PlaylistBrief playlist;

  static Future<void> open(BuildContext context, PlaylistBrief playlist) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PlaylistPage(playlist: playlist)),
    );
  }

  /// Opens by id alone, for a pasted playlist link.
  static Future<void> openById(BuildContext context, String playlistId) {
    return open(
      context,
      PlaylistBrief(id: playlistId, title: 'Playlist'),
    );
  }

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  List<VideoBrief> _videos = const [];
  bool _loading = true;
  String? _error;
  String? _title;

  @override
  void initState() {
    super.initState();
    _title = widget.playlist.title;
    _load();
  }

  Future<void> _load() async {
    final repo = context.read<YtRepository>();

    // Only fetch the header when the caller could not supply a real one.
    if (_title == null || _title == 'Playlist') {
      repo.playlistInfo(widget.playlist.id).then(
        (info) {
          if (mounted) setState(() => _title = info.title);
        },
        // The list still loads without a title; leave the placeholder.
        onError: (Object _) {},
      );
    }

    try {
      final videos = await repo.remotePlaylist(widget.playlist.id);
      if (!mounted) return;
      setState(() {
        _videos = videos;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title ?? 'Playlist', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Share playlist',
            onPressed: () => SharePlus.instance.share(
              ShareParams(uri: Uri.parse(widget.playlist.shareUrl)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.library_add_outlined),
            tooltip: 'Save all to a local playlist',
            onPressed: _videos.isEmpty ? null : _saveAll,
          ),
        ],
      ),
      body: Builder(
        builder: (context) {
          if (_loading) return const FeedSkeleton(count: 3);
          if (_videos.isEmpty) {
            return EmptyState(
              icon: Icons.playlist_remove,
              title: 'Nothing to play',
              message: _error ?? 'This playlist is empty or unavailable.',
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    FilledButton.icon(
                      onPressed: () => WatchPage.openQueue(context, _videos),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play all'),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      onPressed: () {
                        final shuffled = _videos.toList()..shuffle();
                        WatchPage.openQueue(context, shuffled);
                      },
                      icon: const Icon(Icons.shuffle),
                      label: const Text('Shuffle'),
                    ),
                    const Spacer(),
                    Text(
                      '${_videos.length}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: _videos.length,
                  itemBuilder: (context, i) {
                    final video = _videos[i];
                    return VideoRow(
                      video: video,
                      onTap: () =>
                          WatchPage.openQueue(context, _videos, startAt: i),
                      onMenu: () => showVideoMenu(context, video),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _saveAll() async {
    final db = context.read<AppDatabase>();
    final messenger = ScaffoldMessenger.of(context);
    final name = await showNewPlaylistDialog(context, initial: _title);
    if (name == null) return;
    final id = await db.createPlaylist(name);
    for (final video in _videos) {
      await db.addToPlaylist(id, video);
    }
    messenger.showSnackBar(
      SnackBar(content: Text('Saved ${_videos.length} videos to "$name"')),
    );
  }
}
