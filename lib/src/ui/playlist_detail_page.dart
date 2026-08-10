import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/db.dart';
import '../data/models.dart';
import '../player/playback_controller.dart';
import 'watch_page.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({super.key, required this.playlist});

  final LocalPlaylist playlist;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  late Future<List<VideoBrief>> _future = _load();

  Future<List<VideoBrief>> _load() =>
      context.read<AppDatabase>().playlistItems(widget.playlist.id);

  void _reload() => setState(() => _future = _load());

  /// Plays the first item and queues the rest, so a playlist behaves like one.
  void _playAll(List<VideoBrief> items) {
    if (items.isEmpty) return;
    context.read<PlaybackController>().play(
      items.first,
      upNext: items.skip(1).toList(),
    );
    WatchPage.open(context, items.first);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.playlist.name)),
      body: FutureBuilder<List<VideoBrief>>(
        future: _future,
        builder: (context, snapshot) {
          final items = snapshot.data;
          if (items == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.playlist_play,
              title: 'Playlist is empty',
              message: 'Use "Save to…" on any video to add it here.',
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    FilledButton.icon(
                      onPressed: () => _playAll(items),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play all'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: () {
                        final shuffled = items.toList()..shuffle();
                        _playAll(shuffled);
                      },
                      icon: const Icon(Icons.shuffle),
                      label: const Text('Shuffle'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final video = items[index];
                    return VideoRow(
                      video: video,
                      onTap: () {
                        context.read<PlaybackController>().play(
                          video,
                          upNext: items.skip(index + 1).toList(),
                        );
                        WatchPage.open(context, video);
                      },
                      onMenu: () => showVideoMenu(
                        context,
                        video,
                        removeLabel: 'Remove from ${widget.playlist.name}',
                        onRemove: () async {
                          await context.read<AppDatabase>().removeFromPlaylist(
                            widget.playlist.id,
                            video.id,
                          );
                          _reload();
                        },
                      ),
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
}
