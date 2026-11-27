import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../data/search_client.dart';
import 'channel_page.dart';
import 'playlist_page.dart';
import 'shorts_route.dart';
import 'watch_page.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// The cards the search screen draws for each [SearchItem] that is not a
/// plain video — videos reuse Home's `VideoCard` / `VideoRow` unchanged.

/// A channel result: large avatar, name, "@handle · N subscribers", and a
/// Subscribe button backed by the app's local subscriptions table.
class SearchChannelCard extends StatefulWidget {
  const SearchChannelCard({super.key, required this.channel});

  final SearchChannelItem channel;

  @override
  State<SearchChannelCard> createState() => _SearchChannelCardState();
}

class _SearchChannelCardState extends State<SearchChannelCard> {
  bool? _subscribed;

  @override
  void initState() {
    super.initState();
    context.read<AppDatabase>().isSubscribed(widget.channel.id).then((v) {
      if (mounted) setState(() => _subscribed = v);
    });
  }

  Future<void> _toggle() async {
    final db = context.read<AppDatabase>();
    final messenger = ScaffoldMessenger.of(context);
    final c = widget.channel;
    if (_subscribed ?? false) {
      await db.unsubscribe(c.id);
      messenger.showSnackBar(
        SnackBar(content: Text('Unsubscribed from ${c.title}')),
      );
    } else {
      await db.subscribe(c.info);
      messenger.showSnackBar(SnackBar(content: Text('Subscribed to ${c.title}')));
    }
    if (mounted) setState(() => _subscribed = !(_subscribed ?? false));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.channel;
    final subtitle = [
      if (c.handle != null) c.handle!,
      if (c.subscriberLabel != null) c.subscriberLabel!,
    ].join(' · ');
    final subscribed = _subscribed ?? false;
    return InkWell(
      onTap: () => ChannelPage.open(context, c.id, title: c.title),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Row(
          children: [
            // YouTube gives a channel result a much larger avatar than a
            // video's, and centres it where a thumbnail would be.
            SizedBox(
              width: 136,
              child: Center(
                child: CircleAvatar(
                  radius: 44,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  foregroundImage: c.avatarUrl == null
                      ? null
                      : CachedNetworkImageProvider(
                          c.avatarUrl!,
                          maxWidth: 176,
                          maxHeight: 176,
                        ),
                  child: Text(
                    c.title.substring(0, 1).toUpperCase(),
                    style: theme.textTheme.headlineSmall,
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
                    c.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 36,
                    child: subscribed
                        ? FilledButton.tonal(
                            onPressed: _subscribed == null ? null : _toggle,
                            child: const Text('Subscribed'),
                          )
                        : FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: theme.colorScheme.onSurface,
                              foregroundColor: theme.colorScheme.surface,
                            ),
                            onPressed: _subscribed == null ? null : _toggle,
                            child: const Text('Subscribe'),
                          ),
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

/// A playlist (or Mix) result: full-width artwork with the stacked-card edge
/// and the count badge, then the title and byline.
///
/// The artwork is the channel page's `_PlaylistCard` drawing, copied rather
/// than shared so the Library agent's file is not edited for it.
class SearchPlaylistCard extends StatelessWidget {
  const SearchPlaylistCard({super.key, required this.item, this.compact = false});

  final SearchPlaylistItem item;

  /// A row with a 160dp thumbnail, for the tablet list.
  final bool compact;

  void _open(BuildContext context) {
    // A Mix is generated per viewer and cannot be browsed, so it plays.
    if (item.isMix && item.firstVideoId != null) {
      WatchPage.open(
        context,
        VideoBrief(
          id: item.firstVideoId!,
          title: item.playlist.title,
          author: '',
          channelId: '',
        ),
      );
      return;
    }
    PlaylistPage.open(context, item.playlist);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final art = _StackedArtwork(item: item);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.playlist.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          item.byline ?? (item.isMix ? 'Mix' : 'Playlist'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          item.isMix ? 'Play mix' : 'View full playlist',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
          ),
        ),
      ],
    );
    return InkWell(
      onTap: () => _open(context),
      child: compact
          ? Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 160, child: art),
                  const SizedBox(width: 10),
                  Expanded(child: text),
                ],
              ),
            )
          : Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [art, const SizedBox(height: 10), text],
              ),
            ),
    );
  }
}

class _StackedArtwork extends StatelessWidget {
  const _StackedArtwork({required this.item});

  final SearchPlaylistItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playlist = item.playlist;
    final label = playlist.videoCount != null
        ? '${playlist.videoCount} videos'
        : (item.isMix ? 'Mix' : (item.badge ?? 'Playlist'));
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The stacked-card edge that makes a playlist read as a collection.
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
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(8),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: playlist.thumbnailUrl == null
                  ? const ColoredBox(
                      color: AppColors.darkElevated,
                      child: Icon(Icons.playlist_play, color: Colors.white38),
                    )
                  : CachedNetworkImage(
                      memCacheWidth: 1080,
                      imageUrl: playlist.thumbnailUrl!,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) =>
                          const ColoredBox(color: AppColors.darkElevated),
                    ),
            ),
          ),
          Positioned(
            right: 8,
            bottom: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      item.isMix ? Icons.podcasts : Icons.playlist_play,
                      size: 14,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      label,
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

/// A shelf of Shorts: a header, then a horizontal row of 9:16 tiles — or,
/// for a big shelf (the Shorts chip's page, the 20-tile grid YouTube puts
/// lower in the results), a two-column grid that opens collapsed.
class SearchShortsShelfView extends StatefulWidget {
  const SearchShortsShelfView({
    super.key,
    required this.shelf,
    this.startExpanded = false,
  });

  final SearchShortsShelf shelf;

  /// For a page that is nothing but this shelf, where collapsing it would
  /// hide the page.
  final bool startExpanded;

  /// Above this many tiles the shelf is drawn as a grid.
  static const gridThreshold = 10;

  @override
  State<SearchShortsShelfView> createState() => _SearchShortsShelfViewState();
}

class _SearchShortsShelfViewState extends State<SearchShortsShelfView> {
  late bool _expanded = widget.startExpanded;

  @override
  Widget build(BuildContext context) {
    final shelf = widget.shelf;
    if (shelf.shorts.length <= SearchShortsShelfView.gridThreshold) {
      return _row(context);
    }
    final theme = Theme.of(context);
    final shown = _expanded ? shelf.shorts : shelf.shorts.take(4).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(theme),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = (constraints.maxWidth / 180).floor().clamp(2, 6);
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: shown.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                    childAspectRatio: 9 / 16,
                  ),
                  itemBuilder: (context, i) => _ShortTile(
                    video: shown[i],
                    width: null,
                    onTap: () =>
                        ShortsRoute.open(context, shelf.shorts, startIndex: i),
                  ),
                );
              },
            ),
          ),
          if (!_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => setState(() => _expanded = true),
                  icon: const Icon(Icons.expand_more, size: 20),
                  label: const Text('Show more'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
    child: Row(
      children: [
        Icon(Icons.bolt, color: theme.colorScheme.primary, size: 22),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            widget.shelf.title.isEmpty ? 'Shorts' : widget.shelf.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium,
          ),
        ),
      ],
    ),
  );

  Widget _row(BuildContext context) {
    final theme = Theme.of(context);
    final shelf = widget.shelf;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(theme),
          SizedBox(
            height: 284,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: shelf.shorts.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, i) => _ShortTile(
                video: shelf.shorts[i],
                onTap: () =>
                    ShortsRoute.open(context, shelf.shorts, startIndex: i),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShortTile extends StatelessWidget {
  const _ShortTile({required this.video, required this.onTap, this.width = 160});

  final VideoBrief video;
  final VoidCallback onTap;

  /// Fixed in a horizontal shelf; null fills a grid cell.
  final double? width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: () => showVideoMenu(context, video.asShort()),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // hqdefault is a letterboxed 4:3 frame of the vertical video;
              // covering a 9:16 box crops the bars away and keeps the picture.
              CachedNetworkImage(
                imageUrl: video.thumbUrl,
                memCacheWidth: 480,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) =>
                    const ColoredBox(color: AppColors.darkElevated),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.55, 1],
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
                    if (video.viewCount != null)
                      Text(
                        '${compactCount(video.viewCount)} views',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11.5,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A titled shelf of videos ("Latest from …"): the first few as rows, the
/// rest behind a "Show more" the way YouTube collapses it.
class SearchShelfView extends StatefulWidget {
  const SearchShelfView({super.key, required this.shelf});

  final SearchShelf shelf;

  @override
  State<SearchShelfView> createState() => _SearchShelfViewState();
}

class _SearchShelfViewState extends State<SearchShelfView> {
  static const _collapsed = 3;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final videos = widget.shelf.videos;
    final shown = _expanded ? videos : videos.take(_collapsed).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.shelf.title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Text(
                widget.shelf.title,
                style: theme.textTheme.titleMedium,
              ),
            ),
          for (final v in shown)
            VideoRow(
              video: v,
              onTap: () => WatchPage.open(context, v),
              onMenu: () => showVideoMenu(context, v),
            ),
          if (videos.length > _collapsed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                  ),
                  label: Text(
                    _expanded
                        ? 'Show less'
                        : 'Show ${videos.length - _collapsed} more',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The chip bar above the results. 32dp, radius 8, the selected chip
/// inverted (onSurface fill), as YouTube draws it.
class SearchChipBar extends StatelessWidget {
  const SearchChipBar({
    super.key,
    required this.chips,
    required this.selected,
    required this.onSelected,
  });

  final List<SearchChip> chips;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final on = i == selected;
          return Material(
            color: on ? scheme.onSurface : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onSelected(i),
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                child: Text(
                  chips[i].label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: on ? scheme.surface : scheme.onSurface,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// "Showing results for X / Search instead for Y", or "Did you mean X".
class SearchCorrectionBanner extends StatelessWidget {
  const SearchCorrectionBanner({
    super.key,
    required this.correction,
    required this.onSearch,
  });

  final SearchCorrection correction;

  /// Runs a query, with the `params` YouTube supplied for it when there were
  /// any (the "search instead" one tells it not to correct again).
  final void Function(String query, {String? params}) onSearch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final link = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w600,
      fontStyle: FontStyle.italic,
    );
    final c = correction;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: c.autoCorrected
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    text: 'Showing results for ',
                    style: muted,
                    children: [
                      TextSpan(
                        text: c.corrected,
                        style: muted?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontStyle: FontStyle.italic,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                if (c.original != null)
                  InkWell(
                    onTap: () =>
                        onSearch(c.original!, params: c.originalParams),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text.rich(
                        TextSpan(
                          text: 'Search instead for ',
                          style: muted,
                          children: [TextSpan(text: c.original, style: link)],
                        ),
                      ),
                    ),
                  ),
              ],
            )
          : InkWell(
              onTap: () => onSearch(c.corrected),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text.rich(
                  TextSpan(
                    text: 'Did you mean: ',
                    style: muted,
                    children: [TextSpan(text: c.corrected, style: link)],
                  ),
                ),
              ),
            ),
    );
  }
}
