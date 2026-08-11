import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/playback_controller.dart';

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
                  icon: const Icon(Icons.shuffle),
                  tooltip: 'Shuffle queue',
                  onPressed: queue.length < 2 ? null : playback.shuffleQueue,
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
          child: CachedNetworkImage(
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
