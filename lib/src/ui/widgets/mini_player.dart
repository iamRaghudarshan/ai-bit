import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme.dart';
import '../../player/playback_controller.dart';
import '../watch_page.dart';

/// Persistent bar above the navigation bar showing whatever is playing.
///
/// It exists precisely because the player outlives the watch page: after you
/// back out of a video the audio keeps going, and this is the handle to get
/// back to it (or stop it).
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    final video = playback.current;
    if (video == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final total = playback.duration.inMilliseconds;

    return Material(
      color: theme.brightness == Brightness.dark
          ? AppColors.darkElevated
          : AppColors.lightSurface,
      child: InkWell(
        onTap: () => WatchPage.open(context, video),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 58,
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: CachedNetworkImage(memCacheWidth: 240, 
                        imageUrl: video.thumbUrl,
                        width: 78,
                        height: 46,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) =>
                            const ColoredBox(color: Colors.black26),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          video.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          video.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11,
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (playback.isLoading)
                    const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    IconButton(
                      icon: Icon(
                        playback.isPlaying ? Icons.pause : Icons.play_arrow,
                      ),
                      onPressed: playback.togglePlayPause,
                    ),
                  // Only when there is somewhere to go — a permanently dead
                  // button costs space the title could use.
                  if (playback.hasNext)
                    IconButton(
                      icon: const Icon(Icons.skip_next),
                      tooltip: 'Next',
                      onPressed: playback.playNext,
                    ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Stop',
                    onPressed: playback.stop,
                  ),
                ],
              ),
            ),
            // Only this line moves every second; the row above it does not.
            ValueListenableBuilder<Duration>(
              valueListenable: playback.ticker,
              builder: (context, position, _) => LinearProgressIndicator(
                value: total > 0
                    ? (position.inMilliseconds / total).clamp(0.0, 1.0)
                    : 0.0,
                minHeight: 2,
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation(AppColors.brand),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
