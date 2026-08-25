import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/db.dart';
import '../../data/models.dart';
import '../../player/playback_controller.dart';
import 'sheets.dart';

/// The up-next queue: what is playing, what follows, and the ability to
/// reorder or drop entries.
///
/// Autoplay and the next button both consume this list, but until now there was
/// no way to see it — a queue you cannot inspect is one you cannot trust.
Future<void> showQueueSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const _QueueSheet(),
  );
}

/// Writes the visible queue — what is playing, then everything after it — into
/// a new local playlist.
///
/// A queue is throwaway state: it does not survive `replaceQueue`, and nothing
/// persists it across a restart. This is the one way to keep an up-next list
/// that took some assembling.
Future<void> _saveQueueAsPlaylist(BuildContext context) async {
  final playback = context.read<PlaybackController>();
  final db = context.read<AppDatabase>();
  // Captured before the await: a messenger looked up afterwards would come from
  // a context this sheet may already have been popped from.
  final messenger = ScaffoldMessenger.of(context);

  final current = playback.current;
  // De-duplicated by id, because `addToPlaylist` inserts with
  // ConflictAlgorithm.replace against the (playlist_id, video_id) primary key —
  // a video queued twice collapses to one row, and counting the raw list would
  // report a number the playlist does not contain.
  final seen = <String>{};
  final videos = <VideoBrief>[
    for (final video in [?current, ...playback.queue])
      if (seen.add(video.id)) video,
  ];
  if (videos.isEmpty) return;

  final name = await showNewPlaylistDialog(context);
  if (name == null) return;

  final id = await db.createPlaylist(name);
  // Written back to front, and serially, because `playlistItems` sorts on
  // `added_at DESC` and `addToPlaylist` stamps that from the clock as it
  // inserts: saving front to back would show the playlist reversed. Best
  // effort only — several inserts can land in the same millisecond, and rows
  // that tie on the sort key come back in no defined order.
  for (final video in videos.reversed) {
    await db.addToPlaylist(id, video);
  }

  messenger.showSnackBar(
    SnackBar(
      content: Text(
        'Saved ${videos.length} ${videos.length == 1 ? 'video' : 'videos'} '
        'to "$name"',
      ),
    ),
  );
}

class _QueueSheet extends StatelessWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    final current = playback.current;
    final queue = playback.queue;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Text('Up next', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 8),
                Text(
                  '${queue.length}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.playlist_add),
                  tooltip: 'Save queue as playlist',
                  // The currently playing video counts, so a queue of one that
                  // has just started is still worth saving.
                  onPressed: current == null && queue.isEmpty
                      ? null
                      : () => _saveQueueAsPlaylist(context),
                ),
                IconButton(
                  icon: const Icon(Icons.shuffle),
                  // Coloured while shuffled, because shuffleQueue is a toggle —
                  // without the state showing, the second tap looks like a
                  // second shuffle rather than the way back.
                  color: playback.isQueueShuffled
                      ? Theme.of(context).colorScheme.primary
                      : null,
                  tooltip: playback.isQueueShuffled
                      ? 'Restore the original order'
                      : 'Shuffle queue',
                  onPressed: queue.length < 2 && !playback.isQueueShuffled
                      ? null
                      : playback.shuffleQueue,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (current != null)
            _QueueRow(
              video: current,
              playing: true,
              onTap: playback.togglePlayPause,
            ),
          Expanded(
            child: queue.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Nothing queued.\nPlaying a channel or playlist fills '
                        'this automatically.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  )
                : ReorderableListView.builder(
                    scrollController: scroll,
                    itemCount: queue.length,
                    onReorderItem: playback.reorderQueue,
                    itemBuilder: (context, i) {
                      final video = queue[i];
                      return _QueueRow(
                        // ReorderableListView needs a stable key per row.
                        key: ValueKey('${video.id}_$i'),
                        video: video,
                        index: i,
                        onTap: () => playback.playFromQueue(i),
                        onRemove: () => playback.removeFromQueue(i),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    super.key,
    required this.video,
    this.index,
    this.playing = false,
    this.onTap,
    this.onRemove,
  });

  final VideoBrief video;
  final int? index;
  final bool playing;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 68,
          height: 40,
          child: CachedNetworkImage(memCacheWidth: 320, 
            imageUrl: video.thumbUrl,
            fit: BoxFit.cover,
            errorWidget: (_, _, _) =>
                const ColoredBox(color: AppColors.darkElevated),
          ),
        ),
      ),
      title: Text(
        video.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          fontWeight: playing ? FontWeight.w700 : FontWeight.w400,
          color: playing ? theme.colorScheme.primary : null,
        ),
      ),
      subtitle: Text(
        metaLine([
          if (playing) 'Now playing',
          video.author,
          clockLabel(video.duration),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
      ),
      trailing: onRemove == null
          ? const Icon(Icons.equalizer, size: 18)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Remove',
                  onPressed: onRemove,
                ),
                if (index != null)
                  ReorderableDragStartListener(
                    index: index!,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 4, right: 4),
                      child: Icon(Icons.drag_handle),
                    ),
                  ),
              ],
            ),
    );
  }
}
