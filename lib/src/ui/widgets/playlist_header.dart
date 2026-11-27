import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'library_widgets.dart';

/// The top of a playlist page as YouTube's Android app draws it: the cover
/// blurred into a gradient behind everything, a large rounded 16:9 cover,
/// the title, the owner, "Playlist · N videos · N views", the description
/// with "...more", a row of round tonal action buttons, and two equal
/// pills — Play all filled, Shuffle tonal. It scrolls away with the list.
class PlaylistHeader extends StatelessWidget {
  const PlaylistHeader({
    super.key,
    required this.title,
    required this.meta,
    required this.onPlayAll,
    required this.onShuffle,
    this.coverUrl,
    this.owner,
    this.onOwner,
    this.description,
    this.actions = const [],
  });

  final String title;
  final String? coverUrl;
  final String? owner;
  final VoidCallback? onOwner;
  final String meta;
  final String? description;

  /// Round buttons, built with [PlaylistAction].
  final List<Widget> actions;
  final VoidCallback? onPlayAll;
  final VoidCallback? onShuffle;

  void _showDescription(BuildContext context) {
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            SelectableText(description ?? '', style: const TextStyle(height: 1.4)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = theme.scaffoldBackgroundColor;
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.7);

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: coverUrl == null
                    ? const ColoredBox(
                        color: AppColors.darkElevated,
                        child: Icon(
                          Icons.playlist_play,
                          size: 48,
                          color: Colors.white38,
                        ),
                      )
                    : CachedNetworkImage(
                        imageUrl: coverUrl!,
                        fit: BoxFit.cover,
                        memCacheWidth: 960,
                        errorWidget: (_, _, _) =>
                            const ColoredBox(color: AppColors.darkElevated),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
          if (owner != null && owner!.isNotEmpty) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: onOwner,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  owner!,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(meta, style: TextStyle(fontSize: 13, color: muted)),
          if (description != null && description!.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            MoreText(
              text: description!,
              alwaysShowMore: false,
              onMore: () => _showDescription(context),
              style: TextStyle(fontSize: 13, color: muted, height: 1.35),
            ),
          ],
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                for (final a in actions) ...[a, const SizedBox(width: 8)],
              ],
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: onPlayAll,
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.onSurface,
                    foregroundColor: theme.colorScheme.surface,
                    shape: const StadiumBorder(),
                    minimumSize: const Size(0, 42),
                  ),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text(
                    'Play all',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onShuffle,
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.onSurface.withValues(
                      alpha: 0.12,
                    ),
                    foregroundColor: theme.colorScheme.onSurface,
                    shape: const StadiumBorder(),
                    minimumSize: const Size(0, 42),
                  ),
                  icon: const Icon(Icons.shuffle),
                  label: const Text(
                    'Shuffle',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return Stack(
      children: [
        // The cover, blurred far past recognition into a wash of its own
        // colours, fading into the page — YouTube's playlist backdrop.
        if (coverUrl != null)
          Positioned.fill(
            child: ClipRect(
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 48, sigmaY: 48),
                child: CachedNetworkImage(
                  imageUrl: coverUrl!,
                  fit: BoxFit.cover,
                  memCacheWidth: 160,
                  errorWidget: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  background.withValues(alpha: 0.35),
                  background.withValues(alpha: 0.85),
                  background,
                ],
                stops: const [0, 0.6, 1],
              ),
            ),
          ),
        ),
        content,
      ],
    );
  }
}

/// A round tonal icon button for the playlist header's action row.
class PlaylistAction extends StatelessWidget {
  const PlaylistAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton.filledTonal(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: scheme.onSurface.withValues(alpha: 0.12),
        foregroundColor: scheme.onSurface,
        minimumSize: const Size(40, 40),
      ),
    );
  }
}
