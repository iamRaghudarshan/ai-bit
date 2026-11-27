import 'package:flutter/material.dart';

import '../../core/chapters.dart';
import '../../core/theme.dart';

/// The seek bar YouTube draws since its 2025 redesign: one thin line across
/// the full width of the video at its bottom edge, a red thumb only while the
/// controls are up, and a thicker line while it is being dragged.
///
/// Painted rather than built from a `Slider`: a slider insets its track by the
/// thumb radius on both ends, so it could never reach the edges, and its
/// track, thumb and overlay are themed as one object where YouTube's are
/// three different sizes in three different states.
///
/// The touch target is the whole [height] strip, much taller than the line,
/// because a 3dp line over a moving video is not something a thumb can aim
/// at. Scrubbing state lives with the caller, which also draws the time bubble
/// and storyboard frame above the thumb.
class PlayerSeekBar extends StatelessWidget {
  const PlayerSeekBar({
    super.key,
    required this.fraction,
    required this.bufferedFraction,
    required this.totalMs,
    required this.chapters,
    required this.showThumb,
    required this.scrubbing,
    required this.onScrubStart,
    required this.onScrubUpdate,
    required this.onScrubEnd,
    this.enabled = true,
    this.height = 28,
  });

  /// Played fraction 0..1 (the scrub target while scrubbing).
  final double fraction;
  final double bufferedFraction;
  final double totalMs;
  final List<VideoChapter> chapters;
  final bool showThumb;
  final bool scrubbing;
  final bool enabled;
  final double height;

  final ValueChanged<double> onScrubStart;
  final ValueChanged<double> onScrubUpdate;
  final ValueChanged<double> onScrubEnd;

  /// Distance from the strip's bottom to the line's centre while the thumb is
  /// up, so the whole 12dp thumb sits inside the video instead of being cut
  /// in half by its bottom edge. With the controls hidden the line drops to
  /// the very edge, as a hairline.
  static const thumbLift = 6.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        double frac(Offset local) =>
            box.maxWidth <= 0 ? 0 : (local.dx / box.maxWidth).clamp(0.0, 1.0);
        final painter = _SeekBarPainter(
          fraction: fraction,
          buffered: bufferedFraction,
          totalMs: totalMs,
          chapters: chapters,
          showThumb: showThumb,
          scrubbing: scrubbing,
        );
        final bar = SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(painter: painter),
        );
        if (!enabled) return IgnorePointer(child: bar);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) => onScrubStart(frac(d.localPosition)),
          onHorizontalDragUpdate: (d) => onScrubUpdate(frac(d.localPosition)),
          onHorizontalDragEnd: (_) => onScrubEnd(fraction),
          onHorizontalDragCancel: () => onScrubEnd(fraction),
          // A tap on the bar jumps there, as on YouTube.
          onTapUp: (d) {
            final f = frac(d.localPosition);
            onScrubStart(f);
            onScrubEnd(f);
          },
          child: bar,
        );
      },
    );
  }
}

class _SeekBarPainter extends CustomPainter {
  _SeekBarPainter({
    required this.fraction,
    required this.buffered,
    required this.totalMs,
    required this.chapters,
    required this.showThumb,
    required this.scrubbing,
  });

  final double fraction;
  final double buffered;
  final double totalMs;
  final List<VideoChapter> chapters;
  final bool showThumb;
  final bool scrubbing;

  @override
  void paint(Canvas canvas, Size size) {
    final lineH = scrubbing ? 5.0 : 3.0;
    final centreY = showThumb
        ? size.height - PlayerSeekBar.thumbLift
        : size.height - lineH / 2;
    final top = centreY - lineH / 2;
    final w = size.width;
    final played = fraction.clamp(0.0, 1.0) * w;
    final loaded = buffered.clamp(0.0, 1.0) * w;

    final paint = Paint();
    paint.color = Colors.white.withValues(alpha: 0.28);
    canvas.drawRect(Rect.fromLTWH(0, top, w, lineH), paint);
    if (loaded > played) {
      paint.color = Colors.white.withValues(alpha: 0.5);
      canvas.drawRect(Rect.fromLTRB(played, top, loaded, top + lineH), paint);
    }
    paint.color = AppColors.brand;
    canvas.drawRect(Rect.fromLTWH(0, top, played, lineH), paint);

    // Chapter boundaries are gaps in the line, YouTube's way, rather than
    // white ticks over it.
    if (chapters.length > 1 && totalMs > 0) {
      final gap = Paint()
        ..color = Colors.black
        ..blendMode = BlendMode.srcOver;
      for (final c in chapters) {
        final f = c.start.inMilliseconds / totalMs;
        if (f <= 0 || f >= 1) continue;
        final x = f * w;
        canvas.drawRect(Rect.fromLTWH(x - 1, top, 2, lineH), gap);
      }
    }

    if (showThumb || scrubbing) {
      paint.color = AppColors.brand;
      canvas.drawCircle(Offset(played.clamp(6.0, w - 6.0), centreY),
          scrubbing ? 8 : 6, paint);
    }
  }

  @override
  bool shouldRepaint(_SeekBarPainter old) =>
      old.fraction != fraction ||
      old.buffered != buffered ||
      old.totalMs != totalMs ||
      old.chapters != chapters ||
      old.showThumb != showThumb ||
      old.scrubbing != scrubbing;
}
