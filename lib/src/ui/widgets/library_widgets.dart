import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../shorts_route.dart';

/// Pieces shared by the Subscriptions, You, channel and playlist pages:
/// playlist artwork with its stacked edge and count, a Short's 9:16 tile,
/// a confirmation dialog, and the one place that decides how a list of
/// Shorts is opened.

/// Asks before something that cannot be undone. Returns true only for an
/// explicit yes; dismissing the dialog is a no.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
}) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return yes ?? false;
}

/// Opens [shorts] in the vertical Shorts player at [index], swiping through
/// the rest of the list — a channel's Shorts tab or the Subscriptions shelf
/// plays as a Shorts feed, not as one long-form video.
///
/// One function so the route is decided in one place.
Future<void> openShortsList(
  BuildContext context,
  List<VideoBrief> shorts, {
  int index = 0,
}) {
  if (shorts.isEmpty) return Future.value();
  return ShortsRoute.open(
    context,
    shorts,
    startIndex: index.clamp(0, shorts.length - 1),
  );
}

/// A playlist's artwork: the 16:9 cover with a second card edge peeking out
/// above it and the video count badged bottom-end, as YouTube draws a
/// playlist so it reads as a collection rather than one video.
class PlaylistThumb extends StatelessWidget {
  const PlaylistThumb({
    super.key,
    this.imageUrl,
    this.count,
    this.icon = Icons.playlist_play,
    this.radius = 8,
  });

  final String? imageUrl;

  /// Shown in the badge; null shows "Playlist".
  final int? count;

  /// Drawn when there is no cover.
  final IconData icon;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 8, bottom: 8),
            child: Align(
              alignment: Alignment.topCenter,
              child: FractionallySizedBox(
                widthFactor: 1,
                heightFactor: 0.14,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.28),
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(radius),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: imageUrl == null
                  ? ColoredBox(
                      color: AppColors.darkElevated,
                      child: Icon(icon, color: Colors.white38, size: 32),
                    )
                  : CachedNetworkImage(
                      memCacheWidth: 640,
                      imageUrl: imageUrl!,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) =>
                          const ColoredBox(color: AppColors.darkElevated),
                    ),
            ),
          ),
          Positioned(
            right: 6,
            bottom: 6,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.playlist_play, size: 14, color: Colors.white),
                    const SizedBox(width: 3),
                    Text(
                      count == null ? 'Playlist' : '$count',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A playlist as a card: artwork, then up to two lines of title, then one
/// muted line under it, with an optional overflow menu.
class PlaylistCard extends StatelessWidget {
  const PlaylistCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.imageUrl,
    this.count,
    this.icon = Icons.playlist_play,
    this.onMenu,
    this.onLongPress,
  });

  final String title;
  final String subtitle;
  final String? imageUrl;
  final int? count;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onMenu;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PlaylistThumb(imageUrl: imageUrl, count: count, icon: icon),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (onMenu != null)
                SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    icon: const Icon(Icons.more_vert),
                    onPressed: onMenu,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A Short as YouTube tiles it: a rounded 9:16 poster with the view count
/// over its foot, and optionally the title over it too.
class ShortTile extends StatelessWidget {
  const ShortTile({
    super.key,
    required this.video,
    required this.onTap,
    this.showTitle = false,
    this.onMenu,
  });

  final VideoBrief video;
  final VoidCallback onTap;
  final bool showTitle;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    final views = video.viewCount == null
        ? null
        : '${compactCount(video.viewCount)} views';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: 9 / 16,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CachedNetworkImage(
                // The vertical frame Shorts have; the landscape one, cropped
                // to fill, when it is missing.
                imageUrl: 'https://i.ytimg.com/vi/${video.id}/oardefault.jpg',
                fit: BoxFit.cover,
                memCacheWidth: 360,
                placeholder: (_, _) =>
                    const ColoredBox(color: AppColors.darkElevated),
                errorWidget: (_, _, _) => CachedNetworkImage(
                  imageUrl: video.thumbUrl,
                  fit: BoxFit.cover,
                  memCacheWidth: 360,
                  errorWidget: (_, _, _) =>
                      const ColoredBox(color: AppColors.darkElevated),
                ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.center,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
              ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showTitle)
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                    if (views != null)
                      Text(
                        views,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          shadows: [Shadow(blurRadius: 4)],
                        ),
                      ),
                  ],
                ),
              ),
              if (onMenu != null)
                Positioned(
                  top: 2,
                  right: 0,
                  child: IconButton(
                    icon: const Icon(
                      Icons.more_vert,
                      color: Colors.white,
                      size: 18,
                      shadows: [Shadow(blurRadius: 4)],
                    ),
                    onPressed: onMenu,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A horizontal shelf of Shorts tiles, as the Subscriptions feed shows them.
class SubsShortsShelf extends StatelessWidget {
  const SubsShortsShelf({
    super.key,
    required this.shorts,
    required this.onOpen,
    this.title = 'Shorts',
  });

  final List<VideoBrief> shorts;
  final void Function(int index) onOpen;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
          child: Row(
            children: [
              const Icon(Icons.bolt, color: AppColors.brand),
              const SizedBox(width: 6),
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 280,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: shorts.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) => SizedBox(
              width: 280 * 9 / 16,
              child: ShortTile(
                video: shorts[i],
                showTitle: true,
                onTap: () => onOpen(i),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// A rounded section header with a trailing outlined "View all" pill, the
/// You tab's shelf heading.
class ShelfHeader extends StatelessWidget {
  const ShelfHeader({
    super.key,
    required this.title,
    this.onViewAll,
    this.trailing,
  });

  final String title;
  final VoidCallback? onViewAll;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ?trailing,
          if (onViewAll != null) ...[
            const SizedBox(width: 4),
            OutlinedButton(
              onPressed: onViewAll,
              style: OutlinedButton.styleFrom(
                shape: const StadiumBorder(),
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              child: const Text('View all'),
            ),
          ],
        ],
      ),
    );
  }
}

/// A horizontal row of filter chips drawn like Home's category chips (the
/// same colours, 8dp corners, 32dp chips in a 48dp row), for the
/// Subscriptions filters and a channel's Latest / Popular / Oldest.
class FeedChipRow extends StatelessWidget {
  const FeedChipRow({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  });

  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final chipColor = AppColors.chip(context);
    final selectedColor = AppColors.chipSelected(context);
    final text = AppColors.text(context);
    final selectedText = AppColors.chipSelectedText(context);
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: labels.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final isSelected = i == selected;
          return ChoiceChip(
            label: Text(labels[i]),
            selected: isSelected,
            showCheckmark: false,
            onSelected: (_) => onSelected(i),
            backgroundColor: chipColor,
            selectedColor: selectedColor,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(8)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            labelPadding: const EdgeInsets.symmetric(horizontal: 4),
            labelStyle: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: isSelected ? selectedText : text,
            ),
            side: BorderSide.none,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          );
        },
      ),
    );
  }
}

/// [text] cut to [maxLines] with a bold "...more" at the end of the last
/// line, as YouTube ends a channel or playlist description; the whole block
/// is the tap target. When the text fits, "...more" is still shown if
/// [alwaysShowMore] — the About sheet holds more than the preview even when
/// the preview is short.
class MoreText extends StatelessWidget {
  const MoreText({
    super.key,
    required this.text,
    required this.onMore,
    this.maxLines = 2,
    this.style,
    this.alwaysShowMore = true,
  });

  final String text;
  final VoidCallback onMore;
  final int maxLines;
  final TextStyle? style;
  final bool alwaysShowMore;

  static const _suffix = '...more';

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final strong = base.copyWith(fontWeight: FontWeight.w600);
    final flat = text.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
    return LayoutBuilder(
      builder: (context, constraints) {
        final direction = Directionality.of(context);
        final scaler = MediaQuery.textScalerOf(context);
        bool fits(String body, {bool withSuffix = true}) {
          final painter = TextPainter(
            text: TextSpan(
              style: base,
              children: [
                TextSpan(text: body),
                if (withSuffix) TextSpan(text: ' $_suffix', style: strong),
              ],
            ),
            maxLines: maxLines,
            textDirection: direction,
            textScaler: scaler,
          )..layout(maxWidth: constraints.maxWidth);
          final over = painter.didExceedMaxLines;
          painter.dispose();
          return !over;
        }

        var body = flat;
        final showMore = alwaysShowMore || !fits(flat, withSuffix: false);
        if (showMore && !fits(flat)) {
          // Longest prefix that leaves room for the suffix on the last line.
          var lo = 0;
          var hi = flat.length;
          while (lo < hi) {
            final mid = (lo + hi + 1) ~/ 2;
            if (fits('${flat.substring(0, mid).trimRight()}…')) {
              lo = mid;
            } else {
              hi = mid - 1;
            }
          }
          body = '${flat.substring(0, lo).trimRight()}…';
        }
        return InkWell(
          onTap: onMore,
          child: Text.rich(
            TextSpan(
              style: base,
              children: [
                TextSpan(text: body),
                if (showMore) TextSpan(text: ' $_suffix', style: strong),
              ],
            ),
            maxLines: maxLines,
          ),
        );
      },
    );
  }
}

/// "11 videos" / "1 video".
String videoCountLabel(int count) => count == 1 ? '1 video' : '$count videos';
