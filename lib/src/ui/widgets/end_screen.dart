import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';

/// What YouTube shows over the last frame: a grid of suggestions, a replay
/// button, and a ring that counts down to the next video.
///
/// Without it a finished video just froze on its final frame with no
/// indication that anything else would happen.
class EndScreen extends StatelessWidget {
  const EndScreen({
    super.key,
    required this.suggestions,
    required this.countdown,
    required this.onReplay,
    required this.onCancel,
    required this.onPlay,
    required this.onDismiss,
  });

  final List<VideoBrief> suggestions;

  /// Seconds remaining; zero when nothing is counting down.
  final int countdown;

  final VoidCallback onReplay;
  final VoidCallback onCancel;
  final void Function(VideoBrief video) onPlay;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final next = suggestions.isEmpty ? null : suggestions.first;

    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.88),
      child: Stack(
        children: [
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              tooltip: 'Dismiss',
              onPressed: onDismiss,
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (countdown > 0 && next != null) ...[
                    Text(
                      'Up next in $countdown',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _CountdownRing(
                      seconds: countdown,
                      onTap: () => onPlay(next),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        next.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextButton(
                      onPressed: onCancel,
                      child: const Text('Cancel'),
                    ),
                  ] else ...[
                    IconButton.filled(
                      iconSize: 30,
                      icon: const Icon(Icons.replay),
                      tooltip: 'Replay',
                      onPressed: onReplay,
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (suggestions.length > 1)
                    SizedBox(
                      height: 96,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        shrinkWrap: true,
                        itemCount: suggestions.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, i) => _Suggestion(
                          video: suggestions[i],
                          onTap: () => onPlay(suggestions[i]),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The ring that empties as the countdown runs, tappable to skip the wait.
class _CountdownRing extends StatelessWidget {
  const _CountdownRing({required this.seconds, required this.onTap});

  final int seconds;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 52,
        height: 52,
        child: Stack(
          alignment: Alignment.center,
          children: [
            TweenAnimationBuilder<double>(
              // One second per step, matching the controller's timer, so the
              // ring lands on empty exactly when the next video starts.
              tween: Tween(begin: seconds / 10, end: (seconds - 1) / 10),
              duration: const Duration(seconds: 1),
              builder: (context, value, _) => SizedBox(
                width: 52,
                height: 52,
                child: CircularProgressIndicator(
                  value: value.clamp(0.0, 1.0),
                  strokeWidth: 3,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation(AppColors.brand),
                ),
              ),
            ),
            const Icon(Icons.play_arrow, color: Colors.white, size: 26),
          ],
        ),
      ),
    );
  }
}

class _Suggestion extends StatelessWidget {
  const _Suggestion({required this.video, required this.onTap});

  final VideoBrief video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        width: 120,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: CachedNetworkImage(
                  memCacheWidth: 240,
                  imageUrl: video.thumbUrl,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) =>
                      const ColoredBox(color: AppColors.darkElevated),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              video.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 11, height: 1.2),
            ),
            Text(
              compactCount(video.viewCount).isEmpty
                  ? video.author
                  : '${compactCount(video.viewCount)} views',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}
