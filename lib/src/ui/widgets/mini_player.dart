import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_navigator.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../player/floating_player.dart';
import '../../player/playback_controller.dart';

/// The right-hand part of the docked mini player: title, channel, pop-out,
/// play/pause and close, with the progress line under them.
///
/// The left-hand part is the live video itself, which `PlayerSheet` scales
/// into place beside this — there is no thumbnail here, and no second copy of
/// the player. Taps on the text fall through to the sheet, which expands;
/// the buttons take their own taps.
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({super.key, required this.video, required this.onClose});

  /// What the sheet is showing. The sheet builds a new bar per video, so
  /// autoplay and skips arrive here as a new [video].
  final VideoBrief video;

  /// Stops playback and takes the player away.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    final shown = video;
    final theme = Theme.of(context);
    final total = playback.duration.inMilliseconds;

    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shown.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      shown.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // The Android overlay window (or PiP on iOS). Kept on the bar
              // because it is the one place that is on screen on every route.
              const FloatingPlayerButton(size: 20),
              // Every control keeps its place while a video loads. The
              // spinner used to replace the play button, so the row shifted
              // under the finger and a second tap fell through to the bar.
              SizedBox(
                width: 44,
                height: 48,
                child: playback.isLoading
                    ? GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {}, // a tap here must not open the page
                        child: const Padding(
                          padding: EdgeInsets.all(13),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: Icon(
                          playback.isPlaying ? Icons.pause : Icons.play_arrow,
                        ),
                        tooltip: tooltipIfPossible(
                          context,
                          playback.isPlaying ? 'Pause' : 'Play',
                        ),
                        onPressed: playback.togglePlayPause,
                      ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: tooltipIfPossible(context, 'Close'),
                onPressed: onClose,
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
    );
  }
}
