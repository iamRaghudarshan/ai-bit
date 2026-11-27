import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../channel_page.dart';
import 'responsive_feed.dart';
import 'tap_ahead.dart';

/// 16:9 thumbnail with the duration badge and an optional resume bar.
class VideoThumb extends StatelessWidget {
  const VideoThumb({
    super.key,
    required this.video,
    this.progress = 0,
    this.radius = 12,
  });

  final VideoBrief video;

  /// 0..1 watched fraction; hidden when zero.
  final double progress;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final placeholder = AppColors.chip(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CachedNetworkImage(
              imageUrl: video.thumbUrl,
              fit: BoxFit.cover,
              // Decode to roughly the size it is drawn at. Left alone, every
              // card holds a 1280x720 bitmap — about 3.5 MB each — and a
              // scrolled feed runs iOS out of memory and gets the app killed.
              memCacheWidth: 720,
              fadeInDuration: const Duration(milliseconds: 150),
              placeholder: (_, _) => ColoredBox(color: placeholder),
              errorWidget: (_, _, _) => ColoredBox(
                color: placeholder,
                child: Icon(
                  Icons.videocam_off_outlined,
                  color: AppColors.textSecondary(context),
                ),
              ),
            ),
            if (video.isLive || video.duration != null)
              Positioned(
                right: 8,
                // Lifted clear of the resume bar when there is one.
                bottom: progress > 0 ? 8 + ThumbBadge.barHeight : 8,
                child: ThumbBadge(
                  label: video.isLive ? 'LIVE' : clockLabel(video.duration),
                  live: video.isLive,
                ),
              ),
            if (progress > 0)
              Align(
                alignment: Alignment.bottomCenter,
                child: ResumeBar(progress: progress),
              ),
          ],
        ),
      ),
    );
  }
}

/// The duration (or LIVE) badge in a thumbnail's corner.
///
/// Public so the feed preview can draw the same badge counting down over the
/// moving picture, which covers the thumbnail's own.
class ThumbBadge extends StatelessWidget {
  const ThumbBadge({super.key, required this.label, this.live = false});

  final String label;
  final bool live;

  /// Height of [ResumeBar], which the badge sits above.
  static const barHeight = 3.0;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: live
            ? Theme.of(context).colorScheme.primary
            : Colors.black.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}

/// YouTube's resume bar: a 3dp accent line over a translucent white track.
class ResumeBar extends StatelessWidget {
  const ResumeBar({super.key, required this.progress, this.height = 3});

  final double progress;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: ColoredBox(
        color: Colors.white.withValues(alpha: 0.35),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: progress.clamp(0.0, 1.0),
          child: ColoredBox(color: Theme.of(context).colorScheme.primary),
        ),
      ),
    );
  }
}

/// Full-width feed card: big thumbnail above title and metadata.
class VideoCard extends StatelessWidget {
  const VideoCard({
    super.key,
    required this.video,
    required this.onTap,
    this.onMenu,
    this.progress = 0,
    this.inGrid = false,
    this.previewOverlay,
    this.onLongPress,
    this.avatarOpensChannel = true,
  });

  final VideoBrief video;
  final VoidCallback onTap;
  final VoidCallback? onMenu;
  final double progress;

  /// Long press on the card. Null falls back to [onMenu], which is what
  /// YouTube does — a long press opens the same sheet the ⋮ does.
  final VoidCallback? onLongPress;

  /// Whether tapping the avatar opens the channel. Off on a channel's own
  /// page, where it would only push the same channel again.
  final bool avatarOpensChannel;

  /// Drawn over the thumbnail while this card is previewing, or null.
  ///
  /// Passed in rather than built here so the widget that owns the preview
  /// player also owns its lifetime; a card is rebuilt constantly while
  /// scrolling and must not be able to create or destroy a player.
  final Widget? previewOverlay;

  /// True when the card is a cell in the tablet grid rather than a full-width
  /// phone row: the thumbnail gets YouTube's rounded corners (the gutters
  /// around the cell make square edges look unfinished) and the meta block
  /// aligns with the thumbnail edge instead of carrying its own inset.
  final bool inGrid;

  @override
  Widget build(BuildContext context) {
    final longPress = onLongPress ?? onMenu;
    final canOpenChannel = avatarOpensChannel && video.channelId.isNotEmpty;
    Widget avatar = CircleAvatar(
      radius: 18,
      backgroundColor: _avatarColor(video.channelId),
      foregroundImage: video.avatarUrl == null
          ? null
          : CachedNetworkImageProvider(
              video.avatarUrl!,
              maxWidth: 88,
              maxHeight: 88,
            ),
      child: Text(
        video.author.isEmpty ? '?' : video.author.substring(0, 1).toUpperCase(),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    if (canOpenChannel) {
      // Its own tap target, as on YouTube: the avatar goes to the channel,
      // the rest of the card plays the video.
      avatar = InkResponse(
        customBorder: const CircleBorder(),
        radius: 22,
        onTap: () => ChannelPage.open(
          context,
          video.channelId,
          title: video.author,
        ),
        child: avatar,
      );
    }
    return TapAhead(
      video: video,
      child: InkWell(
      onTap: onTap,
      onLongPress: longPress == null
          ? null
          : () {
              HapticFeedback.lightImpact();
              longPress();
            },
      // A flat wash on press rather than a ripple — YouTube's cards.
      splashFactory: NoSplash.splashFactory,
      highlightColor: AppColors.pressHighlight(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Edge-to-edge thumbnail on a phone, the way the YouTube home feed
          // shows it; rounded inside the tablet grid, also the way YouTube
          // shows it there.
          if (previewOverlay == null)
            VideoThumb(video: video, progress: progress, radius: inGrid ? 12 : 0)
          else
            ClipRRect(
              borderRadius: BorderRadius.circular(inGrid ? 12 : 0),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    VideoThumb(
                      video: video,
                      progress: progress,
                      radius: inGrid ? 12 : 0,
                    ),
                    previewOverlay!,
                  ],
                ),
              ),
            ),
          Padding(
            padding: inGrid
                ? const EdgeInsets.fromLTRB(0, 10, 0, 0)
                : const EdgeInsets.fromLTRB(12, 12, 4, 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The channel's real avatar, which search results carry under
                // channelThumbnailSupportedRenderers. The coloured initial is
                // only the fallback for rows that arrive without one.
                avatar,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // YouTube's title: 16sp, medium, two lines.
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          height: 1.35,
                          color: AppColors.text(context),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        metaLine([
                          video.author,
                          if (video.viewCount != null)
                            '${compactCount(video.viewCount)} views',
                          uploadLabel(video.uploadDate, raw: video.uploadRaw),
                        ]),
                        // Two lines: the date and its relative age no longer
                        // fit beside the channel and views on one.
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: AppColors.textSecondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                if (onMenu != null)
                  IconButton(
                    icon: Icon(
                      Icons.more_vert,
                      size: 20,
                      color: AppColors.text(context),
                    ),
                    tooltip: 'More',
                    onPressed: onMenu,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}

/// Stable per-channel colour so the same channel always gets the same avatar.
Color _avatarColor(String seed) {
  const palette = [
    Color(0xFF5C6BC0),
    Color(0xFF26A69A),
    Color(0xFFEF5350),
    Color(0xFFAB47BC),
    Color(0xFFFFA726),
    Color(0xFF42A5F5),
    Color(0xFF66BB6A),
    Color(0xFFEC407A),
  ];
  if (seed.isEmpty) return palette.first;
  final hash = seed.codeUnits.fold<int>(0, (a, b) => (a * 31 + b) & 0x7FFFFFFF);
  return palette[hash % palette.length];
}

/// Compact row used in search results, playlists, history and "up next".
class VideoRow extends StatelessWidget {
  const VideoRow({
    super.key,
    required this.video,
    required this.onTap,
    this.onMenu,
    this.progress = 0,
    this.selected,
    this.onLongPress,
  });

  final VideoBrief video;
  final VoidCallback onTap;
  final VoidCallback? onMenu;
  final double progress;

  /// Selection state for a list that lets several rows be picked at once.
  /// Null — the default — means the list is not in selection mode, and the row
  /// then builds exactly the tree it always did: no indicator, no tint, so
  /// every other feed is untouched. True or false shows the leading circle,
  /// because an unpicked row in selection mode still has to say what a tap
  /// would now do.
  final bool? selected;

  /// Long press on the whole row, which is how a selection starts. It belongs
  /// here rather than in a GestureDetector the caller wraps around the row:
  /// the two would then have to settle it in the gesture arena, and this way
  /// the press gets the same ink feedback as the tap.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSelected = selected ?? false;

    Widget content = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: VideoThumb(video: video, progress: progress, radius: 8),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  video.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.25),
                ),
                const SizedBox(height: 4),
                Text(
                  metaLine([
                    video.author,
                    if (video.viewCount != null)
                      '${compactCount(video.viewCount)} views',
                    uploadLabel(video.uploadDate, raw: video.uploadRaw),
                  ]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    color: AppColors.textSecondary(context),
                  ),
                ),
              ],
            ),
          ),
          if (onMenu != null)
            IconButton(
              icon: const Icon(Icons.more_vert, size: 18),
              onPressed: onMenu,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );

    if (selected != null) {
      // The circle sits outside the row's own padding and is centred against
      // the whole tile, which is where a list that is not selecting has
      // nothing at all — the thumbnail keeps its position and size either way.
      content = Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Icon(
              isSelected ? Icons.check_circle : Icons.circle_outlined,
              size: 22,
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
          Expanded(child: content),
        ],
      );
    }

    if (isSelected) {
      content = ColoredBox(
        color: theme.colorScheme.primary.withValues(alpha: 0.14),
        child: content,
      );
    }

    final row = InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      splashFactory: NoSplash.splashFactory,
      highlightColor: AppColors.pressHighlight(context),
      child: content,
    );
    // A list in selection mode is being edited, not browsed.
    return selected == null ? TapAhead(video: video, child: row) : row;
  }
}

/// Grey placeholder blocks shown while a feed loads.
///
/// Mirrors the loaded feed's layout: a column of blocks on a phone, the same
/// multi-column grid on wider screens — a single stretched skeleton on a
/// tablet would announce the wrong layout and then jump.
///
/// On a phone each block is the real card's shape — an edge-to-edge 16:9
/// block, square-cornered, then a 36dp circle beside two bars with the card's
/// own padding — so the feed arriving changes the colours, not the layout.
/// A gentle opacity pulse says "loading" without the cost of a shimmer
/// gradient repainting every block every frame.
class FeedSkeleton extends StatefulWidget {
  const FeedSkeleton({super.key, this.count = 4, this.sliver = false});

  final int count;

  /// Build as a sliver for a CustomScrollView rather than as its own
  /// scrollable list.
  final bool sliver;

  @override
  State<FeedSkeleton> createState() => _FeedSkeletonState();
}

class _FeedSkeletonState extends State<FeedSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  late final Animation<double> _opacity = Tween<double>(begin: 1, end: 0.55)
      .animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Widget _block(BuildContext context, {required bool grid}) {
    final base = AppColors.chip(context);
    Widget bar({required double height, double widthFactor = 1}) =>
        FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: widthFactor,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: base,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        );
    return FadeTransition(
      opacity: _opacity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: base,
                borderRadius: BorderRadius.circular(grid ? 12 : 0),
              ),
            ),
          ),
          Padding(
            // Matches VideoCard's meta padding exactly.
            padding: grid
                ? const EdgeInsets.fromLTRB(0, 10, 0, 0)
                : const EdgeInsets.fromLTRB(12, 12, 16, 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration:
                      BoxDecoration(color: base, shape: BoxShape.circle),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 2),
                      bar(height: 14),
                      const SizedBox(height: 8),
                      bar(height: 12, widthFactor: 0.6),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  SliverGridDelegate _gridDelegate(double width, int columns) {
    final cellWidth =
        (width - feedGridGutter * 2 - feedGridGutter * (columns - 1)) / columns;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      crossAxisSpacing: feedGridGutter,
      mainAxisSpacing: 8,
      mainAxisExtent: cellWidth * 9 / 16 + feedGridMetaHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.count;
    if (widget.sliver) {
      return SliverLayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.crossAxisExtent;
          final columns = feedColumnsFor(width);
          if (columns == 1) {
            return SliverList.builder(
              itemCount: count,
              itemBuilder: (context, _) => _block(context, grid: false),
            );
          }
          return SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              feedGridGutter, 8, feedGridGutter, 8),
            sliver: SliverGrid.builder(
              gridDelegate: _gridDelegate(width, columns),
              itemCount: count * columns,
              itemBuilder: (context, _) => _block(context, grid: true),
            ),
          );
        },
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = feedColumnsFor(width);
        if (columns == 1) {
          return ListView.builder(
            itemCount: count,
            itemBuilder: (context, _) => _block(context, grid: false),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(
            feedGridGutter, 8, feedGridGutter, 8),
          gridDelegate: _gridDelegate(width, columns),
          itemCount: count * columns,
          itemBuilder: (context, _) => _block(context, grid: true),
        );
      },
    );
  }
}

/// Shared empty / error state.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppColors.textSecondary(context)),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.textSecondary(context),
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}
