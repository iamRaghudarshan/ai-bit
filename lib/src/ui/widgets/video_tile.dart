import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';

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
              placeholder: (_, _) => const ColoredBox(color: AppColors.darkElevated),
              errorWidget: (_, _, _) => const ColoredBox(
                color: AppColors.darkElevated,
                child: Icon(Icons.videocam_off_outlined, color: Colors.white24),
              ),
            ),
            if (video.isLive || video.duration != null)
              Positioned(
                right: 6,
                bottom: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: video.isLive
                        ? AppColors.brand
                        : Colors.black.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    child: Text(
                      video.isLive ? 'LIVE' : clockLabel(video.duration),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            if (progress > 0)
              Align(
                alignment: Alignment.bottomCenter,
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation(AppColors.brand),
                ),
              ),
          ],
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
  });

  final VideoBrief video;
  final VoidCallback onTap;
  final VoidCallback? onMenu;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Edge-to-edge thumbnail, the way the YouTube home feed shows it.
          VideoThumb(video: video, progress: progress, radius: 0),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The channel's real avatar, which search results carry under
                // channelThumbnailSupportedRenderers. The coloured initial is
                // only the fallback for rows that arrive without one.
                CircleAvatar(
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
                    video.author.isEmpty
                        ? '?'
                        : video.author.substring(0, 1).toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // YouTube's title: 15px, medium, two lines.
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        metaLine([
                          video.author,
                          if (video.viewCount != null)
                            '${compactCount(video.viewCount)} views',
                          timeAgo(video.uploadDate, raw: video.uploadRaw),
                        ]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                if (onMenu != null)
                  IconButton(
                    icon: const Icon(Icons.more_vert, size: 20),
                    onPressed: onMenu,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        ],
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
  });

  final VideoBrief video;
  final VoidCallback onTap;
  final VoidCallback? onMenu;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
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
                      timeAgo(video.uploadDate, raw: video.uploadRaw),
                    ]),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
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
      ),
    );
  }
}

/// Grey placeholder blocks shown while a feed loads.
class FeedSkeleton extends StatelessWidget {
  const FeedSkeleton({super.key, this.count = 4});

  final int count;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.07);
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8),
      itemCount: count,
      itemBuilder: (_, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: base,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(height: 12, width: double.infinity, color: base),
            const SizedBox(height: 6),
            Container(height: 12, width: 180, color: base),
          ],
        ),
      ),
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
            Icon(icon, size: 48, color: theme.colorScheme.onSurface.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
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
