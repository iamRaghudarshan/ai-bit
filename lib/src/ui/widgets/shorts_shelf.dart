import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../core/format.dart';
import '../../data/models.dart';
import '../../data/settings.dart';
import '../shorts_page.dart';
import '../shorts_route.dart';
import 'sheets.dart';

/// A "Shorts" header and a sideways row of 9:16 cards, as YouTube puts in its
/// home feed. Tapping a card opens [ShortsRoute] at that Short.
///
/// Loads its own Shorts through [loadShortsFeed], so they are ranked exactly as
/// the Shorts tab ranks them — or curated from the Kids topics in Kids mode.
/// Lazy on purpose: nothing is fetched until the shelf is actually scrolled on
/// screen, so it never competes with the home feed for the cold start.
class ShortsShelf extends StatefulWidget {
  const ShortsShelf({super.key});

  @override
  State<ShortsShelf> createState() => _ShortsShelfState();
}

class _ShortsShelfState extends State<ShortsShelf> {
  List<VideoBrief> _shorts = const [];
  bool _requested = false;
  bool _failed = false;
  bool? _loadedKids;

  /// Unique per state, as VisibilityDetector requires.
  late final Key _visibilityKey = UniqueKey();

  Future<void> _load() async {
    _requested = true;
    final kids = context.read<SettingsService>().kidsMode;
    _loadedKids = kids;
    try {
      final shorts = await loadShortsFeed(context);
      if (!mounted) return;
      setState(() {
        _shorts = shorts.take(12).toList();
        _failed = shorts.isEmpty;
      });
    } catch (e) {
      debugPrint('AI BIT: shorts shelf failed — $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A Kids-mode switch while the shelf is alive reloads it, so the adult's
    // Shorts are never left on screen after the mode turns on.
    final kids = context.select<SettingsService, bool>((s) => s.kidsMode);
    if (_requested && _loadedKids != null && kids != _loadedKids) {
      _requested = false;
      _shorts = const [];
      _failed = false;
    }
    // Nothing to show and nothing coming: take no room in the feed.
    if (_failed && _shorts.isEmpty) return const SizedBox.shrink();

    final width = MediaQuery.sizeOf(context).width;
    // About 0.42 of a phone's width, as YouTube sizes them; capped so a tablet
    // does not get cards half a metre tall.
    final cardWidth = (width * 0.42).clamp(120.0, 220.0);
    final cardHeight = cardWidth * 16 / 9;

    return VisibilityDetector(
      key: _visibilityKey,
      onVisibilityChanged: (info) {
        if (!_requested && info.visibleFraction > 0 && mounted) _load();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(
                children: [
                  Icon(
                    Icons.smart_display,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Shorts',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: cardHeight,
              child: _shorts.isEmpty
                  ? _ShelfSkeleton(width: cardWidth, height: cardHeight)
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _shorts.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, i) => _ShortCard(
                        video: _shorts[i],
                        width: cardWidth,
                        onTap: () =>
                            ShortsRoute.open(context, _shorts, startIndex: i),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShortCard extends StatelessWidget {
  const _ShortCard({
    required this.video,
    required this.width,
    required this.onTap,
  });

  final VideoBrief video;
  final double width;
  final VoidCallback onTap;

  static const _textShadow = [Shadow(blurRadius: 4, color: Colors.black87)];

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return SizedBox(
      width: width,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Material(
          color: Colors.black,
          child: InkWell(
            onTap: onTap,
            onLongPress: () => showVideoMenu(context, video),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ShortPoster(
                  videoId: video.id,
                  memCacheWidth: (width * dpr).round(),
                ),
                // Legibility gradient under the caption.
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
                          shadows: _textShadow,
                        ),
                      ),
                      if (video.viewCount != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          '${compactCount(video.viewCount)} views',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            shadows: _textShadow,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: IconButton(
                    tooltip: 'More',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(
                      Icons.more_vert,
                      color: Colors.white,
                      size: 20,
                      shadows: _textShadow,
                    ),
                    onPressed: () => showVideoMenu(context, video),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ShelfSkeleton extends StatelessWidget {
  const _ShelfSkeleton({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: 4,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (_, _) => Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}
