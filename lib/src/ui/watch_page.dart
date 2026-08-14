import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:better_player_plus/better_player_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import '../core/chapters.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../data/download_manager.dart';
import '../data/models.dart';
import '../data/preview_data.dart';
import '../data/settings.dart';
import '../data/yt_repository.dart';
import '../player/playback_controller.dart';
import 'channel_page.dart';
import 'widgets/comments_sheet.dart';
import 'widgets/end_screen.dart';
import 'widgets/stats_overlay.dart';
import 'widgets/cast_button.dart';
import 'widgets/description_sheet.dart';
import 'widgets/player_gestures.dart';
import 'widgets/queue_sheet.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// Full-screen watch experience: player surface, metadata, actions, up next.
class WatchPage extends StatefulWidget {
  const WatchPage({super.key, required this.video});

  final VideoBrief video;

  /// Opens the watch page over whatever is showing.
  ///
  /// Uses a non-opaque route that slides up from the bottom, so the page
  /// underneath stays visible while the player is dragged down to minimise —
  /// the interaction the real app is built around. Completes when the user
  /// dismisses it, which lets callers refresh history-dependent lists.
  static Future<void> open(BuildContext context, VideoBrief video) {
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black26,
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, _, _) => WatchPage(video: video),
        transitionsBuilder: (_, animation, _, child) => SlideTransition(
          position: Tween(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
          ),
          child: child,
        ),
      ),
    );
  }

  /// Starts [videos] at [startAt] and queues everything after it, so a channel
  /// or playlist plays through instead of stopping at one video.
  static Future<void> openQueue(
    BuildContext context,
    List<VideoBrief> videos, {
    int startAt = 0,
  }) {
    if (videos.isEmpty) return Future.value();
    final index = startAt.clamp(0, videos.length - 1);
    context.read<PlaybackController>().play(
      videos[index],
      upNext: videos.skip(index + 1).toList(),
    );
    return open(context, videos[index]);
  }

  @override
  State<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends State<WatchPage>
    with SingleTickerProviderStateMixin {
  /// How far down the sheet must travel before releasing minimises it.
  static const _dismissDistance = 130.0;
  static const _dismissVelocity = 700.0;

  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  double _drag = 0;

  late VideoBrief _video = widget.video;
  yt.Video? _details;
  List<VideoBrief> _related = const [];
  bool _loadingDetails = true;

  PlaybackController? _playback;

  @override
  void initState() {
    super.initState();
    _start();
    // Follow the player when it moves on by itself.
    _playback = context.read<PlaybackController>()..addListener(_followPlayer);
  }

  /// Adopts whatever the player switched to.
  ///
  /// The page decides whether to show the video surface by comparing its own
  /// video to the player's. Autoplay, the end-screen countdown and the lock
  /// screen's skip buttons all change the player's video without telling the
  /// page, so it stopped recognising what was playing and hid the surface
  /// behind a spinner — the next video's audio played while the picture never
  /// came back.
  /// False until the player has actually reached this page's video.
  ///
  /// The listener is attached before [_start]'s own `play` has landed, so a
  /// notification in that window still carries the *previous* video — and
  /// following it would make the page adopt whatever was playing before,
  /// fetch its details, then flip back a moment later.
  bool _following = false;

  void _followPlayer() {
    final current = _playback?.current;
    if (!mounted || current == null) return;
    if (current.id == _video.id) {
      // The player is on our video: anything after this is a real move.
      _following = true;
      return;
    }
    if (!_following) return;
    // Opening another video pushes a second watch page over this one; only the
    // page on top should adopt the change, or the one underneath refetches
    // details nobody is looking at.
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    setState(() {
      _video = current;
      _details = null;
      _related = const [];
    });
    unawaited(_loadDetails());
  }

  Future<void> _start() async {
    final playback = context.read<PlaybackController>();
    // Only (re)start the stream if this video is not already the live one —
    // reopening from the mini player must not restart playback.
    if (playback.current?.id != _video.id) {
      unawaited(playback.play(_video));
    }
    await _loadDetails();
  }

  Future<void> _loadDetails() async {
    setState(() => _loadingDetails = true);
    final repo = context.read<YtRepository>();

    // The browser preview cannot reach YouTube, so populate "Up next" from the
    // sample set instead of leaving the section empty.
    if (YtRepository.isPreview) {
      setState(() {
        _related = previewVideos.where((v) => v.id != _video.id).toList();
        _loadingDetails = false;
      });
      return;
    }

    try {
      final details = await repo.videoDetails(_video.id);
      final related = await repo.related(details);
      if (!mounted) return;
      setState(() {
        _details = details;
        _related = related;
        // Keep the avatar the feed row arrived with. VideoBrief.fromYt builds
        // from the player response, which carries no channel thumbnail, so
        // replacing wholesale made the picture appear and then vanish a moment
        // later as the details landed.
        _video = VideoBrief.fromYt(details).withAvatar(_video.avatarUrl);
        _loadingDetails = false;
      });
      // Hand parsed chapters to the controller so the seek bar can mark them.
      if (context.read<PlaybackController>().current?.id == _video.id) {
        context
            .read<PlaybackController>()
            .setChapters(parseChapters(details.description));
      }
      // A row that arrived without an avatar — anything opened from a source
      // that does not carry one — gets it from the channel itself, so the
      // header is never left showing an initial.
      if (_video.avatarUrl == null && _video.channelId.isNotEmpty) {
        unawaited(
          repo.channelInfo(_video.channelId).then((info) {
            if (mounted && info.avatarUrl != null) {
              setState(() => _video = _video.withAvatar(info.avatarUrl));
            }
          }, onError: (Object _) {}),
        );
      }

      // Now that the real "up next" list exists, hand it to the queue so
      // autoplay has something to advance to.
      if (mounted && context.read<PlaybackController>().current?.id == _video.id) {
        context.read<PlaybackController>().replaceQueue(related);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingDetails = false);
    }
  }

  @override
  void dispose() {
    _playback?.removeListener(_followPlayer);
    _settle.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    // Downward only — dragging up should not lift the sheet off the top.
    setState(() => _drag = (_drag + details.delta.dy).clamp(0.0, 2000.0));
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (_drag > _dismissDistance || velocity > _dismissVelocity) {
      // Playback deliberately continues — popping only hides the surface, and
      // the mini player takes over.
      Navigator.of(context).maybePop();
      return;
    }
    // Spring back to rest.
    final from = _drag;
    _settle
      ..reset()
      ..addListener(() {
        setState(() => _drag = from * (1 - Curves.easeOutCubic.transform(_settle.value)));
      })
      ..forward();
  }

  void _openRelated(VideoBrief video) {
    setState(() {
      _video = video;
      _details = null;
      _related = const [];
    });
    context.read<PlaybackController>().play(video);
    _loadDetails();
  }

  @override
  Widget build(BuildContext context) {
    // `select`, not `watch`: this build needs one boolean, and watching the
    // whole controller rebuilt the entire page — description, comment preview
    // and up-next list — on every play, pause, quality change and caption
    // toggle. It now rebuilds only when the answer actually changes.
    final isCurrent = context.select<PlaybackController, bool>(
      (playback) => playback.current?.id == _video.id,
    );

    // Fades the page out slightly as it is dragged away, so minimising reads
    // as a transition rather than a stutter.
    final dismissProgress = (_drag / (_dismissDistance * 2)).clamp(0.0, 1.0);

    return Transform.translate(
      offset: Offset(0, _drag),
      child: Opacity(
        opacity: 1 - dismissProgress * 0.35,
        child: _buildSheet(isCurrent),
      ),
    );
  }

  Widget _buildSheet(bool isCurrent) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: _onDragUpdate,
              onVerticalDragEnd: _onDragEnd,
              child: _GrabHandle(
                onClose: () => Navigator.of(context).maybePop(),
              ),
            ),
            // Dragging the video itself minimises too, which is how the real
            // app behaves — reaching for a small handle first is not.
            //
            // The bottom strip is excluded because that is where the seek bar
            // lives: putting the whole player in a vertical-drag detector meant
            // any scrub starting with slight downward movement was claimed by
            // the sheet, and the seek bar could not be dragged at all.
            _DragToMinimise(
              onUpdate: _onDragUpdate,
              onEnd: _onDragEnd,
              child: _PlayerSurface(showPlayer: isCurrent),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                physics: const ClampingScrollPhysics(),
                children: [
                  _Header(
                    video: _video,
                    details: _details,
                    onSeek: (to) =>
                        context.read<PlaybackController>().seek(to),
                  ),
                  _PillRow(
                    video: _video,
                    likeCount: _details?.engagement.likeCount,
                  ),
                  const _ActionRow(),
                  if (!YtRepository.isPreview)
                    CommentsPreview(videoId: _video.id),
                  const Divider(height: 24),
                  if (_loadingDetails && _related.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_related.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No suggestions available for this video.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  else ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Text(
                        'Up next',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    for (final video in _related)
                      VideoRow(
                        video: video,
                        onTap: () => _openRelated(video),
                        onMenu: () => showVideoMenu(context, video),
                      ),
                  ],
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Hosts the actual video surface, or a placeholder while streams resolve.
class _PlayerSurface extends StatelessWidget {
  const _PlayerSurface({required this.showPlayer});

  final bool showPlayer;

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    final player = playback.player;

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ColoredBox(
        color: Colors.black,
        child: Builder(
          builder: (context) {
            if (playback.error != null) {
              return _PlaybackError(
                message: playback.error!,
                onRetry: playback.reloadCurrent,
              );
            }
            if (kIsWeb) return const _PreviewSurface();
            if (player == null || !showPlayer || playback.isLoading) {
              return const Center(
                child: CircularProgressIndicator(color: AppColors.brand),
              );
            }
            return Stack(
              fit: StackFit.expand,
              children: [
                // Always mounted, including in audio mode.
                //
                // Returning the artwork *instead* of this widget left iOS with
                // no render surface to attach to, so the native player failed
                // every audio-only load with "Failed to load video: unknown
                // error". The artwork is painted over the player, never in
                // place of it.
                BetterPlayer(key: playback.playerKey, controller: player),
                // Above the player, not below it. Underneath, every pointer was
                // claimed by the controls before this layer saw it.
                PlayerGestures(onSeekBy: playback.skip),
                // Refreshes with the clock, so buffer health actually moves.
                if (playback.showStats)
                  ValueListenableBuilder<Duration>(
                    valueListenable: playback.ticker,
                    builder: (context, _, _) => StatsOverlay(
                      stats: playback.stats,
                      onClose: playback.toggleStats,
                    ),
                  ),
                // Over everything else: a finished video used to freeze on its
                // last frame with no sign that anything came next.
                if (playback.showEndScreen)
                  Positioned.fill(
                    child: EndScreen(
                      suggestions: playback.endScreenSuggestions,
                      countdown: playback.autoplayCountdown,
                      onReplay: playback.replay,
                      onCancel: playback.cancelAutoplay,
                      onDismiss: playback.dismissEndScreen,
                      onPlay: (video) {
                        playback.dismissEndScreen();
                        WatchPage.open(context, video);
                      },
                    ),
                  ),
                // Audio-only has no picture, so the player draws a black
                // rectangle — which reads as a failure rather than a feature.
                // Transparent to touch, so the controls underneath still take
                // taps for play, seek and the rest.
                if (playback.isAudioOnly)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: _AudioArtwork(video: playback.current),
                    ),
                  ),
                if (playback.isAudioOnly)
                  IgnorePointer(
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 5,
                            ),
                            child: Text(
                              playback.isAudioFallback
                                  ? 'Audio only — no video stream available'
                                  : 'Audio only',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Makes the video draggable to minimise, without stealing the seek bar.
///
/// A plain vertical-drag detector around the player competes with the seek bar
/// for every touch, and the sheet usually wins — which is what made the seek bar
/// undraggable. This one refuses to start a drag that begins in the bottom
/// strip, so the two never contend.
class _DragToMinimise extends StatefulWidget {
  const _DragToMinimise({
    required this.child,
    required this.onUpdate,
    required this.onEnd,
  });

  final Widget child;
  final void Function(DragUpdateDetails) onUpdate;
  final void Function(DragEndDetails) onEnd;

  @override
  State<_DragToMinimise> createState() => _DragToMinimiseState();
}

class _DragToMinimiseState extends State<_DragToMinimise> {
  /// Height at the bottom reserved for the seek bar and its controls.
  static const _controlsZone = 64.0;

  /// False when the gesture began over the seek bar, in which case every
  /// update is ignored until the finger lifts.
  ///
  /// That strip is the only exception left. Brightness and volume used to take
  /// a vertical drag on each half of the video, which made every downward
  /// swipe ambiguous; with those gone, dragging anywhere on the picture
  /// minimises, and only scrubbing is carved out.
  bool _accepting = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        // translucent, so taps still reach the player's own controls.
        behavior: HitTestBehavior.translucent,
        onVerticalDragDown: (d) {
          _accepting = d.localPosition.dy < box.maxHeight - _controlsZone;
        },
        onVerticalDragUpdate: (d) {
          if (_accepting) widget.onUpdate(d);
        },
        onVerticalDragEnd: (d) {
          if (_accepting) widget.onEnd(d);
          _accepting = false;
        },
        onVerticalDragCancel: () => _accepting = false,
        child: widget.child,
      ),
    );
  }
}

/// The pill and close button above the video, hinting that the sheet can be
/// dragged away.
class _GrabHandle extends StatelessWidget {
  const _GrabHandle({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tint = Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      height: 34,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down, size: 26),
              tooltip: 'Minimise',
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
            ),
          ),
        ],
      ),
    );
  }
}

/// What the player area shows in audio-only mode.
///
/// An audio asset has no video track, so the player surface is simply black.
/// Blurred artwork with the thumbnail on top makes it obvious that something is
/// playing, and matches what every music player does.
class _AudioArtwork extends StatelessWidget {
  const _AudioArtwork({required this.video});

  final VideoBrief? video;

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    final url = video?.thumbUrl;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (url != null)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: CachedNetworkImage(memCacheWidth: 720, imageUrl: url, fit: BoxFit.cover),
          ),
        const ColoredBox(color: Colors.black54),
        Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (url != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(memCacheWidth: 720, 
                    imageUrl: url,
                    width: 140,
                    fit: BoxFit.cover,
                  ),
                ),
              const SizedBox(width: 16),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.headphones, color: Colors.white, size: 18),
                      SizedBox(width: 6),
                      Text(
                        'Audio only',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  IconButton.filled(
                    icon: Icon(
                      playback.isPlaying ? Icons.pause : Icons.play_arrow,
                    ),
                    iconSize: 30,
                    onPressed: playback.togglePlayPause,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Stand-in for the video surface in the browser preview, where the native
/// player plugin does not exist.
class _PreviewSurface extends StatelessWidget {
  const _PreviewSurface();

  @override
  Widget build(BuildContext context) {
    final video = context.watch<PlaybackController>().current;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (video != null)
          Image.network(
            video.thumbUrl,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black),
          ),
        const ColoredBox(color: Colors.black54),
        const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.play_circle_outline, size: 48, color: Colors.white70),
              SizedBox(height: 8),
              Text(
                'Playback is not available in the browser preview',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Text(
                'Video plays on iOS and Android',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlaybackError extends StatelessWidget {
  const _PlaybackError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.cloud_off_outlined, color: Colors.white54, size: 30),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 10),
        TextButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.video,
    required this.details,
    required this.onSeek,
  });

  final VideoBrief video;
  final yt.Video? details;

  /// Jumps the player to a chapter timestamp.
  final void Function(Duration) onSeek;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = details?.description ?? '';
    final likes = details?.engagement.likeCount;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            video.title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            metaLine([
              if (video.viewCount != null) '${compactCount(video.viewCount)} views',
              if (likes != null) '${compactCount(likes)} likes',
              // Full date here rather than "3 days ago": the watch page is
              // where the exact upload time is actually wanted.
              formatDateTime(video.uploadDate).isNotEmpty
                  ? formatDateTime(video.uploadDate)
                  : timeAgo(video.uploadDate, raw: video.uploadRaw),
            ]),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 12),
          // The whole row opens the channel — the same affordance the real app
          // gives, and the only way to reach a channel from here.
          InkWell(
            onTap: video.channelId.isEmpty
                ? null
                : () => ChannelPage.open(
                    context,
                    video.channelId,
                    title: video.author,
                  ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  // The real avatar, with the initial only as a fallback.
                  // This row was hardcoded to the letter and never showed a
                  // picture at all, whatever the video carried.
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: AppColors.darkElevated,
                    foregroundImage: video.avatarUrl == null
                        ? null
                        : CachedNetworkImageProvider(
                            video.avatarUrl!,
                            maxWidth: 96,
                            maxHeight: 96,
                          ),
                    child: Text(
                      video.author.isEmpty
                          ? '?'
                          : video.author.substring(0, 1).toUpperCase(),
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      video.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (video.channelId.isNotEmpty)
                    const Icon(Icons.chevron_right, size: 18),
                ],
              ),
            ),
          ),
          if (description.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            // A card that opens a sheet, rather than expanding inline: a long
            // description otherwise pushes the whole page out of reach.
            Material(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => showDescriptionSheet(
                  context,
                  title: video.title,
                  description: description,
                  onSeek: onSeek,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '...more',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The pill row directly under the video: Like · Dislike · Share · Download ·
/// Save, laid out the way the real app does.
///
/// Like and Dislike show the counts but cannot be pressed — voting needs a
/// signed-in Google account, and this app has none. They are drawn disabled
/// rather than omitted, so the row reads as the familiar one and the reason is
/// visible on tap instead of silently missing.
class _PillRow extends StatelessWidget {
  const _PillRow({required this.video, this.likeCount});

  final VideoBrief video;

  /// From the watch page's already-loaded details; null until they arrive.
  final int? likeCount;

  @override
  Widget build(BuildContext context) {
    final downloads = context.watch<DownloadManager>();
    final record = downloads.recordFor(video.id);
    final isDownloaded = record?.isComplete ?? false;
    final isDownloading = downloads.isActive(video.id);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Row(
        children: [
          _Pill(
            icon: Icons.thumb_up_outlined,
            label: _likeLabel(context),
            onTap: () => _explainSignIn(context, 'Liking'),
          ),
          _Pill(
            icon: Icons.thumb_down_outlined,
            onTap: () => _explainSignIn(context, 'Disliking'),
          ),
          _Pill(
            icon: Icons.reply_outlined,
            label: 'Share',
            onTap: () => SharePlus.instance.share(
              ShareParams(uri: Uri.parse('https://youtu.be/${video.id}')),
            ),
          ),
          _Pill(
            icon: isDownloaded
                ? Icons.download_done
                : isDownloading
                ? Icons.downloading
                : Icons.download_outlined,
            label: isDownloaded
                ? 'Downloaded'
                : isDownloading
                ? 'Downloading'
                : 'Download',
            highlighted: isDownloaded,
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              if (isDownloaded) {
                await downloads.remove(video.id);
                messenger.showSnackBar(
                  const SnackBar(content: Text('Download removed')),
                );
              } else if (isDownloading) {
                await downloads.cancel(video.id);
              } else {
                showDownloadSheet(context, video);
              }
            },
          ),
          _Pill(
            icon: Icons.playlist_add,
            label: 'Save',
            onTap: () => showSaveToPlaylistSheet(context, video),
          ),
        ],
      ),
    );
  }

  String _likeLabel(BuildContext context) =>
      likeCount == null ? 'Like' : compactCount(likeCount);

  void _explainSignIn(BuildContext context, String action) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$action needs a signed-in Google account, which '
            'AI BIT does not use.'),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.icon,
    required this.onTap,
    this.label,
    this.highlighted = false,
  });

  final IconData icon;
  final String? label;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = highlighted ? Colors.white : scheme.onSurface;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: highlighted
            ? AppColors.brand
            : scheme.onSurface.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: label == null ? 12 : 14,
              vertical: 9,
            ),
            child: Row(
              children: [
                Icon(icon, size: 19, color: foreground),
                if (label != null) ...[
                  const SizedBox(width: 7),
                  Text(
                    label!,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: foreground,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Speed / quality / sleep timer / PiP / save — the "premium" controls.
class _ActionRow extends StatelessWidget {
  const _ActionRow();

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    final settings = context.watch<SettingsService>();

    // The four most-used controls stay inline; everything else is one tap
    // away under "More", the way YouTube keeps its player settings in an
    // overflow rather than a long scrolling row.
    // The most-used controls stay inline; everything else is one tap away
    // under "More", the way YouTube keeps its player settings in an overflow
    // rather than a long scrolling row. Wrap, not a Row, so a narrow screen
    // flows the chips to a second line instead of overflowing.
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 14, 8, 0),
      child: Wrap(
        children: [
          _ActionChip(
            icon: Icons.hd_outlined,
            label: playback.activeQuality ?? settings.preferredQuality,
            onTap: () => showQualitySheet(context),
          ),
          _ActionChip(
            icon: Icons.speed,
            label: playback.speed == 1.0 ? 'Speed' : '${playback.speed}x',
            onTap: () => showSpeedSheet(context),
          ),
          _ActionChip(
            icon: Icons.closed_caption_outlined,
            label: 'Captions',
            highlighted: playback.activeCaptions != null,
            onTap: () => showCaptionsSheet(context),
          ),
          _ActionChip(
            icon: Icons.more_horiz,
            label: 'More',
            onTap: () => _showMoreOptions(context),
          ),
        ],
      ),
    );
  }

  /// Everything that used to sit in the sideways-scrolling row, as a tidy
  /// selectable list — YouTube's player overflow.
  void _showMoreOptions(BuildContext context) {
    final playback = context.read<PlaybackController>();
    final settings = context.read<SettingsService>();
    final video = playback.current;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([playback, settings]),
          builder: (context, _) {
            final sleep = playback.sleepRemaining;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Text(
                    'Options',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.bedtime_outlined),
                        title: const Text('Sleep timer'),
                        trailing: sleep == null
                            ? null
                            : Text(clockLabel(sleep)),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          showSleepTimerSheet(context);
                        },
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.headphones_outlined),
                        title: const Text('Audio only'),
                        value: settings.audioOnly,
                        onChanged: (v) {
                          settings.audioOnly = v;
                          playback.reloadCurrent();
                        },
                      ),
                      SwitchListTile(
                        secondary: const Icon(Icons.playlist_play),
                        title: const Text('Autoplay next'),
                        value: settings.autoplayNext,
                        onChanged: (v) => settings.autoplayNext = v,
                      ),
                      ListTile(
                        leading: Icon(switch (playback.repeatMode) {
                          PlaybackRepeat.one => Icons.repeat_one,
                          _ => Icons.repeat,
                        }),
                        title: const Text('Repeat'),
                        trailing: Text(switch (playback.repeatMode) {
                          PlaybackRepeat.off => 'Off',
                          PlaybackRepeat.one => 'This video',
                          PlaybackRepeat.all => 'Queue',
                        }),
                        onTap: playback.cycleRepeatMode,
                      ),
                      ListTile(
                        leading: Icon(
                          playback.hasLoop
                              ? Icons.repeat_on
                              : Icons.compare_arrows,
                        ),
                        title: const Text('Loop A–B'),
                        subtitle: Text(
                          playback.hasLoop
                              ? 'Looping ${clockLabel(playback.loopA)} – '
                                    '${clockLabel(playback.loopB)}'
                              : playback.loopA != null
                                  ? 'Start ${clockLabel(playback.loopA)} — '
                                        'set the end point'
                                  : 'Repeat a section between two points',
                        ),
                        trailing: playback.hasLoop || playback.loopA != null
                            ? TextButton(
                                onPressed: playback.clearLoop,
                                child: const Text('Clear'),
                              )
                            : null,
                        onTap: () {
                          if (playback.loopA == null) {
                            playback.setLoopStart();
                          } else if (playback.loopB == null) {
                            playback.setLoopEnd();
                          } else {
                            playback.clearLoop();
                          }
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.queue_music),
                        title: const Text('Queue'),
                        trailing: playback.queue.isEmpty
                            ? null
                            : Text('${playback.queue.length}'),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          showQueueSheet(context);
                        },
                      ),
                      ListTile(
                        leading: const Icon(
                          Icons.picture_in_picture_alt_outlined,
                        ),
                        title: const Text('Picture in picture'),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          playback.enterPictureInPicture();
                        },
                      ),
                      if (CastButton.isSupported)
                        ListTile(
                          leading: const SizedBox(
                            width: 24,
                            height: 24,
                            child: Center(child: CastButton(size: 22)),
                          ),
                          title: const Text('Cast / AirPlay'),
                        ),
                      SwitchListTile(
                        secondary: const Icon(Icons.analytics_outlined),
                        title: const Text('Stats for nerds'),
                        value: playback.showStats,
                        onChanged: (_) {
                          playback.toggleStats();
                          Navigator.pop(sheetContext);
                        },
                      ),
                      if (video != null)
                        ListTile(
                          leading: const Icon(Icons.playlist_add),
                          title: const Text('Save to playlist'),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            showSaveToPlaylistSheet(context, video);
                          },
                        ),
                      if (video != null)
                        ListTile(
                          leading: const Icon(Icons.share_outlined),
                          title: const Text('Share'),
                          onTap: () {
                            Navigator.pop(sheetContext);
                            SharePlus.instance.share(
                              ShareParams(
                                uri: Uri.parse('https://youtu.be/${video.id}'),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}



class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        avatar: Icon(
          icon,
          size: 18,
          color: highlighted ? Colors.white : theme.colorScheme.onSurface,
        ),
        label: Text(label),
        backgroundColor: highlighted ? AppColors.brand : null,
        labelStyle: TextStyle(
          fontSize: 13,
          color: highlighted ? Colors.white : theme.colorScheme.onSurface,
        ),
        onPressed: onTap,
      ),
    );
  }
}
