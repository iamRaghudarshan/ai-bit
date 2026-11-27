import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_navigator.dart';
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
        onTap: () => WatchPage.reopen(context, video),
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
                  // Every control keeps its place while a video loads. The
                  // spinner used to replace the play button and Next vanished
                  // until the new queue arrived, so the row shifted under the
                  // finger: a second tap on Next landed on the spinner, fell
                  // through to the bar and opened the watch page instead.
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: playback.isLoading
                        ? GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {}, // a tap here must not open the page
                            child: const Padding(
                              padding: EdgeInsets.all(14),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : IconButton(
                            icon: Icon(
                              playback.isPlaying ? Icons.pause : Icons.play_arrow,
                            ),
                            onPressed: playback.togglePlayPause,
                          ),
                  ),
                  // Greyed out, not removed, when nothing follows yet — and a
                  // tap on it then does nothing rather than opening the page.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: IconButton(
                      icon: const Icon(Icons.skip_next),
                      tooltip: tooltipIfPossible(context, 'Next'),
                      onPressed: playback.hasNext ? playback.playNext : null,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: tooltipIfPossible(context, 'Close'),
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
