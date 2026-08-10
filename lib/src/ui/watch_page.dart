import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import '../core/format.dart';
import '../core/theme.dart';
import '../data/models.dart';
import '../data/preview_data.dart';
import '../data/settings.dart';
import '../data/yt_repository.dart';
import '../player/playback_controller.dart';
import 'widgets/player_gestures.dart';
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
  bool _descriptionExpanded = false;
  bool _loadingDetails = true;

  @override
  void initState() {
    super.initState();
    _start();
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
        _video = VideoBrief.fromYt(details);
        _loadingDetails = false;
      });
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
      _descriptionExpanded = false;
    });
    context.read<PlaybackController>().play(video);
    _loadDetails();
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    final isCurrent = playback.current?.id == _video.id;

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
            // The whole player area is the drag handle, matching the real app.
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragUpdate: _onDragUpdate,
              onVerticalDragEnd: _onDragEnd,
              child: Column(
                children: [
                  _GrabHandle(onClose: () => Navigator.of(context).maybePop()),
                  _PlayerSurface(showPlayer: isCurrent),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                physics: const ClampingScrollPhysics(),
                children: [
                  _Header(
                    video: _video,
                    details: _details,
                    expanded: _descriptionExpanded,
                    onToggleDescription: () => setState(
                      () => _descriptionExpanded = !_descriptionExpanded,
                    ),
                  ),
                  const _ActionRow(),
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
                // Gestures first so better_player's controls layer above them
                // and keep receiving their own taps.
                PlayerGestures(
                  onSeekBy: playback.skip,
                  onVolume: playback.setVolume,
                  currentVolume: playback.volume,
                ),
                BetterPlayer(key: playback.playerKey, controller: player),
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
    required this.expanded,
    required this.onToggleDescription,
  });

  final VideoBrief video;
  final yt.Video? details;
  final bool expanded;
  final VoidCallback onToggleDescription;

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
              timeAgo(video.uploadDate, raw: video.uploadRaw),
            ]),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: AppColors.darkElevated,
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
            ],
          ),
          if (description.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            InkWell(
              onTap: onToggleDescription,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      description,
                      maxLines: expanded ? null : 3,
                      overflow: expanded ? null : TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                    ),
                    Text(
                      expanded ? 'Show less' : 'Show more',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
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
    final video = playback.current;
    final sleep = playback.sleepRemaining;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
      child: Row(
        children: [
          _ActionChip(
            icon: Icons.speed,
            label: playback.speed == 1.0 ? 'Speed' : '${playback.speed}x',
            onTap: () => showSpeedSheet(context),
          ),
          _ActionChip(
            icon: Icons.hd_outlined,
            label: settings.preferredQuality,
            onTap: () => showQualitySheet(context),
          ),
          _ActionChip(
            icon: Icons.bedtime_outlined,
            label: sleep == null ? 'Sleep' : clockLabel(sleep),
            highlighted: sleep != null,
            onTap: () => showSleepTimerSheet(context),
          ),
          _ActionChip(
            icon: Icons.picture_in_picture_alt_outlined,
            label: 'PiP',
            onTap: playback.enterPictureInPicture,
          ),
          _ActionChip(
            icon: settings.autoplayNext
                ? Icons.playlist_play
                : Icons.playlist_remove,
            label: 'Autoplay',
            highlighted: settings.autoplayNext,
            onTap: () => settings.autoplayNext = !settings.autoplayNext,
          ),
          _ActionChip(
            icon: switch (playback.repeatMode) {
              PlaybackRepeat.one => Icons.repeat_one,
              _ => Icons.repeat,
            },
            label: switch (playback.repeatMode) {
              PlaybackRepeat.off => 'Repeat',
              PlaybackRepeat.one => 'Repeat 1',
              PlaybackRepeat.all => 'Repeat all',
            },
            highlighted: playback.repeatMode != PlaybackRepeat.off,
            onTap: playback.cycleRepeatMode,
          ),
          if (video != null)
            _ActionChip(
              icon: Icons.share_outlined,
              label: 'Share',
              onTap: () => SharePlus.instance.share(
                ShareParams(uri: Uri.parse('https://youtu.be/${video.id}')),
              ),
            ),
          _ActionChip(
            icon: settings.audioOnly ? Icons.headphones : Icons.headphones_outlined,
            label: 'Audio only',
            highlighted: settings.audioOnly,
            onTap: () {
              settings.audioOnly = !settings.audioOnly;
              playback.reloadCurrent();
            },
          ),
          if (video != null)
            _ActionChip(
              icon: Icons.playlist_add,
              label: 'Save',
              onTap: () => showSaveToPlaylistSheet(context, video),
            ),
        ],
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
