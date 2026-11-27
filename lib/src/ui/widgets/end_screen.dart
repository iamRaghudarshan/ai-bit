import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';

/// How long the end-screen countdown runs. `PlaybackController` starts its
/// timer at this same value (`_startEndScreen`); the ring's fraction is read
/// against it, so the two must agree or the ring would start part-empty.
const kAutoplayCountdownSeconds = 10;

/// What YouTube shows over the last frame.
///
/// While autoplay counts down: an "Up next" card — the next video's
/// thumbnail with a ring emptying around a play button, its title and
/// channel, and Cancel / Play now. Once cancelled, or with autoplay off: a
/// replay button and a row of suggestions.
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
    final counting = countdown > 0 && next != null;

    return LayoutBuilder(
      builder: (context, box) {
        final large = box.maxWidth >= 600;
        return ColoredBox(
          color: Colors.black.withValues(alpha: 0.86),
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
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  // Scaled down rather than scrolled: an inline player is
                  // about 225dp tall, and a card that scrolls inside a
                  // video is not one anyone finds.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: counting
                        ? _UpNextCard(
                            video: next,
                            countdown: countdown,
                            large: large,
                            onCancel: onCancel,
                            onPlay: () => onPlay(next),
                          )
                        : _AfterCountdown(
                            suggestions: suggestions,
                            onReplay: onReplay,
                            onPlay: onPlay,
                            maxWidth: box.maxWidth - 32,
                          ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _UpNextCard extends StatelessWidget {
  const _UpNextCard({
    required this.video,
    required this.countdown,
    required this.large,
    required this.onCancel,
    required this.onPlay,
  });

  final VideoBrief video;
  final int countdown;
  final bool large;
  final VoidCallback onCancel;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final thumbW = large ? 192.0 : 128.0;
    return SizedBox(
      width: large ? 460 : 340,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Up next in $countdown',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: onPlay,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: thumbW,
                    height: thumbW * 9 / 16,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CachedNetworkImage(
                          memCacheWidth: 320,
                          imageUrl: video.thumbUrl,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) =>
                              const ColoredBox(color: AppColors.darkElevated),
                        ),
                        const ColoredBox(color: Color(0x66000000)),
                        Center(child: _CountdownRing(seconds: countdown)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      video.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: large ? 16 : 14,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      video.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _EndButton(label: 'Cancel', onTap: onCancel),
              const SizedBox(width: 10),
              _EndButton(label: 'Play now', onTap: onPlay, filled: true),
            ],
          ),
        ],
      ),
    );
  }
}

class _EndButton extends StatelessWidget {
  const _EndButton({
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: filled ? Colors.white : Colors.white.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          child: Text(
            label,
            style: TextStyle(
              color: filled ? Colors.black : Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// The ring that empties as the countdown runs, around a play button.
class _CountdownRing extends StatelessWidget {
  const _CountdownRing({required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) {
    const total = kAutoplayCountdownSeconds;
    return SizedBox(
      width: 46,
      height: 46,
      child: Stack(
        alignment: Alignment.center,
        children: [
          TweenAnimationBuilder<double>(
            // One second per step, matching the controller's timer, so the
            // ring lands on empty exactly when the next video starts.
            tween: Tween(begin: seconds / total, end: (seconds - 1) / total),
            duration: const Duration(seconds: 1),
            builder: (context, value, _) => SizedBox(
              width: 46,
              height: 46,
              child: CircularProgressIndicator(
                value: value.clamp(0.0, 1.0),
                strokeWidth: 3,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation(Colors.white),
              ),
            ),
          ),
          const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28),
        ],
      ),
    );
  }
}

class _AfterCountdown extends StatelessWidget {
  const _AfterCountdown({
    required this.suggestions,
    required this.onReplay,
    required this.onPlay,
    required this.maxWidth,
  });

  final List<VideoBrief> suggestions;
  final VoidCallback onReplay;
  final void Function(VideoBrief) onPlay;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filled(
          iconSize: 30,
          style: IconButton.styleFrom(
            backgroundColor: Colors.white.withValues(alpha: 0.18),
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.replay),
          tooltip: 'Replay',
          onPressed: onReplay,
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: maxWidth.clamp(200.0, 720.0),
            height: 96,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: suggestions.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) => _Suggestion(
                video: suggestions[i],
                onTap: () => onPlay(suggestions[i]),
              ),
            ),
          ),
        ],
      ],
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
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                height: 1.2,
              ),
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
