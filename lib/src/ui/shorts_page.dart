import 'package:better_player_plus/better_player_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/format.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../data/yt_repository.dart';
import '../player/playback_controller.dart';
import 'widgets/comments_sheet.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// Vertical swipe feed, the Shorts tab.
///
/// Only the page in view gets the player — there is one player for the whole
/// app, so neighbouring pages show their thumbnail until swiped to. That also
/// stops three videos buffering at once.
class ShortsPage extends StatefulWidget {
  const ShortsPage({super.key});

  @override
  State<ShortsPage> createState() => ShortsPageState();
}

class ShortsPageState extends State<ShortsPage> {
  final _pages = PageController();
  List<VideoBrief> _shorts = const [];
  bool _loading = true;
  int _index = 0;
  int _refreshToken = 0;

  /// True once this tab has been visited. Until then nothing is fetched and
  /// nothing plays — the tab is built at startup along with every other.
  bool _activated = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// Called by the shell when the tab is selected.
  Future<void> onTabOpened() async {
    if (_activated) {
      // Returning to the tab resumes whatever is on screen.
      _playCurrent();
      return;
    }
    _activated = true;
    await _load();
  }

  /// Called by the shell when leaving the tab, so a Short does not keep
  /// playing under the Home feed.
  void onTabClosed() {
    final playback = context.read<PlaybackController>();
    if (_shorts.isNotEmpty && playback.current?.id == _shorts[_index].id) {
      playback.player?.pause();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final db = context.read<AppDatabase>();
      final searches = await db.recentSearches(limit: 2);
      if (!mounted) return;
      final shorts = await context.read<YtRepository>().shortsFeed(
        searches: searches,
        refreshToken: _refreshToken,
      );
      if (!mounted) return;
      setState(() {
        _shorts = shorts;
        _loading = false;
        _index = 0;
      });
      _playCurrent();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _playCurrent() {
    if (_shorts.isEmpty || !mounted) return;
    // Shorts loop, so the queue is left empty and repeat handles the rest.
    context.read<PlaybackController>().play(_shorts[_index]);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _shorts.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_shorts.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: EmptyState(
          icon: Icons.smart_display_outlined,
          title: 'No Shorts right now',
          message: 'Pull down to try again.',
          action: FilledButton(
            onPressed: () {
              _refreshToken++;
              _load();
            },
            child: const Text('Retry'),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        controller: _pages,
        scrollDirection: Axis.vertical,
        itemCount: _shorts.length,
        onPageChanged: (i) {
          setState(() => _index = i);
          _playCurrent();
          // Top up before the end so swiping never hits a wall.
          if (i >= _shorts.length - 3) _appendMore();
        },
        itemBuilder: (context, i) =>
            _ShortView(video: _shorts[i], isActive: i == _index),
      ),
    );
  }

  Future<void> _appendMore() async {
    _refreshToken++;
    try {
      final more = await context.read<YtRepository>().shortsFeed(
        refreshToken: _refreshToken,
      );
      if (!mounted) return;
      final seen = _shorts.map((s) => s.id).toSet();
      setState(() => _shorts.addAll(more.where((s) => seen.add(s.id))));
    } catch (_) {
      // Running out of new Shorts is not worth an error; the feed just ends.
    }
  }
}

class _ShortView extends StatelessWidget {
  const _ShortView({required this.video, required this.isActive});

  final VideoBrief video;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    final showPlayer =
        isActive && playback.current?.id == video.id && !kIsWeb;

    return Stack(
      fit: StackFit.expand,
      children: [
        // The thumbnail sits underneath always: it fills the frame while the
        // stream resolves, so a swipe never lands on a black rectangle.
        CachedNetworkImage(
          imageUrl: video.thumbUrl,
          fit: BoxFit.cover,
          errorWidget: (_, _, _) => const ColoredBox(color: Colors.black),
        ),
        const ColoredBox(color: Colors.black26),

        if (showPlayer && playback.player != null && !playback.isLoading)
          GestureDetector(
            onTap: playback.togglePlayPause,
            child: BetterPlayer(
              key: playback.playerKey,
              controller: playback.player!,
            ),
          )
        else if (isActive)
          const Center(child: CircularProgressIndicator(color: Colors.white)),

        if (isActive && !playback.isPlaying && !playback.isLoading)
          const Center(
            child: Icon(Icons.play_arrow, size: 64, color: Colors.white70),
          ),

        _Overlay(video: video),
      ],
    );
  }
}

/// Title, channel and the action rail, over the video.
class _Overlay extends StatelessWidget {
  const _Overlay({required this.video});

  final VideoBrief video;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Shorts',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (video.viewCount != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${compactCount(video.viewCount)} views',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                _ActionRail(video: video),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionRail extends StatelessWidget {
  const _ActionRail({required this.video});

  final VideoBrief video;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RailButton(
          icon: Icons.comment_outlined,
          label: 'Comments',
          onTap: () async {
            final repo = context.read<YtRepository>();
            final messenger = ScaffoldMessenger.of(context);
            try {
              final page = await repo.comments(video.id);
              if (!context.mounted) return;
              if (page.comments.isEmpty) {
                messenger.showSnackBar(
                  const SnackBar(content: Text('No comments on this Short')),
                );
                return;
              }
              await showCommentsSheet(context, video.id, page);
            } catch (_) {
              messenger.showSnackBar(
                const SnackBar(content: Text('Comments unavailable')),
              );
            }
          },
        ),
        _RailButton(
          icon: Icons.reply_outlined,
          label: 'Share',
          onTap: () => SharePlus.instance.share(
            ShareParams(uri: Uri.parse('https://youtube.com/shorts/${video.id}')),
          ),
        ),
        _RailButton(
          icon: Icons.playlist_add,
          label: 'Save',
          onTap: () => showSaveToPlaylistSheet(context, video),
        ),
        _RailButton(
          icon: Icons.more_vert,
          label: '',
          onTap: () => showVideoMenu(context, video),
        ),
      ],
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            children: [
              Icon(icon, color: Colors.white, size: 28),
              if (label.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
