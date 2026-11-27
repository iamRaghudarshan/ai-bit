import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:better_player_plus/better_player_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import '../core/app_navigator.dart';
import '../core/chapters.dart';
import '../core/format.dart';
import '../core/seek_session.dart' show swipeEntersFullscreen;
import '../core/theme.dart';
import '../data/db.dart';
import '../data/download_manager.dart';
import '../data/models.dart';
import '../data/preview_data.dart';
import '../data/ranker_trainer.dart';
import '../data/yt_repository.dart';
import '../player/playback_controller.dart';
import 'channel_page.dart';
import 'widgets/comments_sheet.dart';
import 'widgets/description_sheet.dart';
import 'widgets/now_playing_overlay.dart';
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
        // Named so RouteStackObserver can tell the player's own screens apart
        // from every other pushed route: the persistent now-playing bar must
        // not be painted over the watch page or over the fullscreen route the
        // player pushes above it.
        settings: const RouteSettings(name: RouteStackObserver.watchRouteName),
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

  /// Brings the playing video back from the now-playing bar.
  ///
  /// Two ways this used to fail, both reported as "tapping the minimised video
  /// does nothing". The bar painted over pushed screens is built in
  /// `MaterialApp.builder`, *outside* the Navigator, so `Navigator.of` threw
  /// there and the tap was lost — the app's own navigator is used instead. And
  /// a watch page left underneath a channel or playlist opened from it would
  /// have had a second one stacked on top; it is removed first, so there is
  /// only ever one watch page and it shows what is actually playing.
  static Future<void> reopen(BuildContext context, VideoBrief video) {
    final navigator = navigatorFor(context);
    if (navigator == null) return Future.value();
    for (final buried in appRouteStack.watchRoutes) {
      if (buried.isActive && !buried.isCurrent) navigator.removeRoute(buried);
    }
    return open(navigator.context, video);
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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// How far down the sheet must travel before releasing minimises it.
  static const _dismissDistance = 130.0;
  static const _dismissVelocity = 700.0;

  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  /// How far the sheet has been dragged down, in pixels.
  ///
  /// A notifier rather than a field under `setState`: the drag fires on every
  /// pointer move, and rebuilding the whole page — header, pill row, comments
  /// preview, twenty up-next rows — per move was the stutter in the one
  /// gesture made after nearly every tap. Only the translate listens now.
  final ValueNotifier<double> _drag = ValueNotifier(0);

  late VideoBrief _video = widget.video;
  yt.Video? _details;
  List<VideoBrief> _related = const [];
  bool _loadingDetails = true;

  PlaybackController? _playback;

  /// Where the spring-back started, read by the settle listener.
  double _settleFrom = 0;

  @override
  void initState() {
    super.initState();
    // Attached once. It used to be added inside _onDragEnd, which stacked a
    // fresh listener on every spring-back and never removed any of them.
    _settle.addListener(() {
      _drag.value =
          _settleFrom * (1 - Curves.easeOutCubic.transform(_settle.value));
    });
    _start();
    // Follow the player when it moves on by itself.
    _playback = context.read<PlaybackController>()..addListener(_followPlayer);
    WidgetsBinding.instance.addObserver(this);
    _wasLandscape = _viewIsLandscape();
  }

  // ------------------------------------------------------------ rotation

  /// True while fullscreen is one that turning the phone opened, which is
  /// the only kind turning it back closes. Fullscreen from the button keeps
  /// landscape however the phone is held — the plugin locks the orientation
  /// for it — which is YouTube's behaviour too.
  bool _fullscreenByRotation = false;
  bool? _wasLandscape;

  /// From the view rather than `MediaQuery`, because this runs from
  /// [didChangeMetrics], and on the binding's schedule rather than a build's.
  static ui.FlutterView? get _view {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    return views.isEmpty ? null : views.first;
  }

  static bool? _viewIsLandscape() {
    final size = _view?.physicalSize;
    if (size == null || size.isEmpty) return null;
    return size.width > size.height;
  }

  @override
  void didChangeMetrics() {
    final landscape = _viewIsLandscape();
    if (landscape == null) return;
    final was = _wasLandscape;
    _wasLandscape = landscape;
    // Only a real turn counts. Metrics also change when the system bars come
    // and go around fullscreen, and reacting to "is landscape" rather than
    // "became landscape" would re-enter fullscreen the moment the user left
    // it while still holding the phone sideways.
    if (was == null || was == landscape) return;
    _onRotated(landscape);
  }

  void _onRotated(bool landscape) {
    final playback = _playback;
    final player = playback?.player;
    if (!mounted || playback == null || player == null) return;
    if (!landscape) {
      if (_fullscreenByRotation && player.isFullScreen) player.exitFullScreen();
      _fullscreenByRotation = false;
      return;
    }
    if (player.isFullScreen) return;
    _fullscreenByRotation = false;
    final current = playback.current;
    if (current == null || current.id != _video.id || current.isShort) return;
    if (playback.error != null || playback.isLoading) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
    // A tablet has the room for the page beside the video; turning one is
    // not a request for fullscreen.
    final view = _view;
    if (view != null &&
        view.physicalSize.shortestSide / view.devicePixelRatio >= 600) {
      return;
    }
    _fullscreenByRotation = true;
    player.enterFullScreen();
    // The plugin locks a fullscreen route to landscape once it has pushed
    // it. Reopen portrait afterwards, or turning the phone back could never
    // be seen and so could never close what turning it opened.
    Future.delayed(const Duration(milliseconds: 700), () {
      if (_fullscreenByRotation && player.isFullScreen) {
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
    });
  }

  /// An upward swipe on the inline video.
  void _enterFullscreen() {
    final playback = _playback;
    final player = playback?.player;
    if (player == null || player.isFullScreen) return;
    if (playback?.current?.id != _video.id) return;
    _fullscreenByRotation = false;
    player.enterFullScreen();
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
    // A SponsorBlock auto-skip leaves a one-shot notice; show it and clear it.
    final notice = _playback?.sponsorSkipNotice;
    if (notice != null && mounted) {
      _playback?.sponsorSkipNotice = null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Skipped $notice'),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    final current = _playback?.current;
    if (!mounted) return;
    if (current == null) {
      // Closed from the now-playing bar while this page sat underneath a
      // channel or playlist opened from it. Left in place, backing out of that
      // page landed on a dead player for a video nobody is watching.
      final route = ModalRoute.of(context);
      if (route != null && route.isActive && !route.isCurrent) {
        Future.microtask(() {
          if (route.isActive && !route.isCurrent) {
            route.navigator?.removeRoute(route);
          }
        });
      }
      return;
    }
    if (current.id == _video.id) {
      // The player is on our video: anything after this is a real move.
      _following = true;
      return;
    }
    if (!_following) return;
    // Opening another video pushes a second watch page over this one; only the
    // page on top should adopt the change, or the one underneath refetches
    // details nobody is looking at.
    //
    // "On top" includes having the player's own fullscreen route above it:
    // autoplay and the end screen's Play now both move on while fullscreen,
    // and the page underneath must still adopt the new video, or leaving
    // fullscreen landed on the previous video's details.
    if (!(ModalRoute.of(context)?.isCurrent ?? true) &&
        !(_playback?.player?.isFullScreen ?? false)) {
      return;
    }
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

    final videoId = _video.id;
    // Details and the up-next list are independent requests, fetched
    // together and allowed to fail separately. They used to be chained —
    // details first, then related — and the details call is a scrape of the
    // watch page that a bot-check or consent interstitial breaks outright,
    // so one refused HTML page emptied the rail and, because the queue is
    // filled from the rail, killed autoplay with it. The `next` endpoint the
    // rail actually needs was healthy the whole time.
    final detailsFuture = repo
        .videoDetails(videoId)
        .timeout(const Duration(seconds: 15));
    final relatedFuture = repo.related(
      videoId,
      channelId: _video.channelId,
      title: _video.title,
      channelTitle: _video.author,
    );

    yt.Video? details;
    try {
      details = await detailsFuture;
    } catch (e) {
      debugPrint('AI BIT: video details failed for $videoId - $e');
    }
    List<VideoBrief> rawRelated = const [];
    try {
      rawRelated = await relatedFuture;
    } catch (e) {
      debugPrint('AI BIT: up next failed for $videoId - $e');
    }
    if (!mounted || _video.id != videoId) return;

    // YouTube's related list is a recommendation for everybody; this makes
    // it one for this viewer. Already-watched videos sink, followed and
    // well-watched channels rise, and the channel already on screen is
    // damped so autoplay stops walking down one uploader's back catalogue.
    // The same ordering feeds both the visible Up-next list and the queue,
    // so what autoplay plays is what the list said it would. Its own try:
    // a database or ranking fault must cost the personalisation, not the
    // twenty rows already in hand.
    var related = rawRelated;
    if (rawRelated.isNotEmpty) {
      try {
        final db = context.read<AppDatabase>();
        final trainer = context.read<RankerTrainer>();
        // Every related list YouTube returns is a sample of what people watch
        // after this video. Recording it builds the local co-visitation
        // graph, which is the one collaborative signal an account-less app
        // can keep.
        unawaited(
          db
              .recordCoVisits(videoId, [for (final v in rawRelated) v.id])
              .then((_) => db.pruneCoVisits())
              // The rows themselves, not just the edges. Without these the
              // graph can only boost a video the feed already fetched; with
              // them it can offer one outright, with no request at all.
              .then((_) => db.cacheVideos(rawRelated))
              .then((_) => db.pruneVideoCache())
              .catchError((Object e) {
            debugPrint('AI BIT: co-visits not recorded - $e');
          }),
        );
        final profile = await db.tasteProfile(coVisitSeeds: [videoId]);
        final impressions = await db.feedImpressions();
        if (!mounted || _video.id != videoId) return;
        related = repo.personalisedUpNext(
          current: _video,
          related: rawRelated,
          // Seeded on the video being watched, so the co-visitation term
          // answers "what do people watch after THIS" rather than "after any
          // of the last eight things", which is the home feed's question.
          profile: profile,
          impressions: impressions,
          // What this sitting has already played, so autoplay stops circling
          // back to the same handful of videos.
          recentlyPlayed: _playback?.playedThisSession ?? const [],
          weights: trainer.weights,
        );
      } catch (e) {
        debugPrint('AI BIT: up next shown unranked - $e');
        related = rawRelated;
      }
    }
    if (!mounted || _video.id != videoId) return;

    try {
      setState(() {
        _details = details;
        _related = related;
        // Keep the avatar the feed row arrived with. VideoBrief.fromYt builds
        // from the player response, which carries no channel thumbnail, so
        // replacing wholesale made the picture appear and then vanish a moment
        // later as the details landed.
        if (details != null) {
          _video = VideoBrief.fromYt(details).withAvatar(_video.avatarUrl);
        }
        _loadingDetails = false;
      });
      // Hand parsed chapters to the controller so the seek bar can mark them.
      if (details != null &&
          context.read<PlaybackController>().current?.id == _video.id) {
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
      // Only over a suggested queue: a playlist or a queue the user built is
      // theirs, and opening its video used to throw it away for suggestions.
      if (related.isNotEmpty &&
          mounted &&
          context.read<PlaybackController>().current?.id == _video.id &&
          context.read<PlaybackController>().queueIsSuggested) {
        context.read<PlaybackController>().replaceQueue(related);
      }
    } catch (e) {
      debugPrint('AI BIT: watch page details not applied - $e');
      if (!mounted) return;
      setState(() => _loadingDetails = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _playback?.removeListener(_followPlayer);
    _settle.dispose();
    _drag.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    // Downward only — dragging up should not lift the sheet off the top.
    _drag.value = (_drag.value + details.delta.dy).clamp(0.0, 2000.0);
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    if (_drag.value > _dismissDistance || velocity > _dismissVelocity) {
      // Playback deliberately continues — popping only hides the surface, and
      // the mini player takes over.
      Navigator.of(context).maybePop();
      return;
    }
    // Spring back to rest.
    _settleFrom = _drag.value;
    _settle
      ..reset()
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

    // The sheet is built once per real change and handed in as `child`; the
    // drag only moves it. No opacity fade any more: an Opacity below 1 over a
    // subtree holding the platform video texture forces a saveLayer of the
    // whole page on every frame of the gesture, which is the most expensive
    // thing the compositor can be asked for on a mid-range phone. The
    // translation alone reads as minimising.
    return ValueListenableBuilder<double>(
      valueListenable: _drag,
      child: _buildSheet(isCurrent),
      builder: (context, drag, child) => Transform.translate(
        offset: Offset(0, drag),
        child: child,
      ),
    );
  }

  Widget _buildSheet(bool isCurrent) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // The video sits directly under the status bar, as in the real
            // app. There used to be a grab-handle strip above it; dragging
            // the video itself minimises, and the minimise chevron is in the
            // player's own top bar.
            //
            // The bottom strip is excluded because that is where the seek bar
            // lives: putting the whole player in a vertical-drag detector meant
            // any scrub starting with slight downward movement was claimed by
            // the sheet, and the seek bar could not be dragged at all.
            _DragToMinimise(
              onUpdate: _onDragUpdate,
              onEnd: _onDragEnd,
              onSwipeUp: _enterFullscreen,
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
                  const SizedBox(height: 8),
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
                  // Phones get full-width cards with no heading, as YouTube
                  // draws its watch-page feed; a tablet's wider page keeps
                  // compact rows, where a card would be absurdly large.
                  else if (MediaQuery.sizeOf(context).width < 600) ...[
                    for (final video in _related)
                      VideoCard(
                        video: video,
                        onTap: () => _openRelated(video),
                        onMenu: () => showVideoMenu(context, video),
                      ),
                  ] else ...[
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

    // 16:9 at full width — except on a phone held sideways outside
    // fullscreen (the user left fullscreen without turning back), where a
    // full-width 16:9 box is taller than the screen and pushed the rest of
    // the page off it. Capped, and centred on black.
    final screen = MediaQuery.sizeOf(context);
    final height = math.min(screen.width * 9 / 16, screen.height * 0.62);
    return SizedBox(
      width: double.infinity,
      height: height,
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Builder(
          builder: (context) {
            if (playback.error != null) {
              return _PlaybackError(
                message: playback.error!,
                onRetry: playback.reloadCurrent,
              );
            }
            if (kIsWeb) return const _PreviewSurface();
            final loading = playback.isLoading && !playback.isRebuilding;
            if (player == null || !showPlayer || loading) {
              // The thumbnail under the spinner, as YouTube does, rather than
              // a black box: the page reads as the video arriving instead of
              // as something failing to load.
              final thumb = playback.current?.thumbUrl;
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (thumb != null && thumb.isNotEmpty)
                    CachedNetworkImage(
                      imageUrl: thumb,
                      fit: BoxFit.cover,
                      fadeInDuration: Duration.zero,
                      errorWidget: (_, _, _) => const SizedBox.shrink(),
                    ),
                  const ColoredBox(color: Color(0x55000000)),
                  const Center(
                    child: CircularProgressIndicator(color: AppColors.brand),
                  ),
                ],
              );
            }
            // Always mounted, including in audio mode.
            //
            // Returning the artwork *instead* of this widget left iOS with
            // no render surface to attach to, so the native player failed
            // every audio-only load with "Failed to load video: unknown
            // error". The artwork is painted by the controls, never in place
            // of the player.
            //
            // Nothing else is stacked here any more. The gestures, the stats
            // panel and the end screen are drawn by VideoControls, which the
            // plugin builds inline and in its fullscreen route alike; layered
            // here they existed only inline.
            return BetterPlayer(key: playback.playerKey, controller: player);
          },
            ),
          ),
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
    required this.onSwipeUp,
  });

  final Widget child;
  final void Function(DragUpdateDetails) onUpdate;
  final void Function(DragEndDetails) onEnd;

  /// An upward swipe past 80dp or 600dp/s: enter fullscreen, as on YouTube.
  /// Handled here, on the same recogniser as minimising, rather than by a
  /// second vertical-drag detector inside the player — two would fight over
  /// every vertical drag and the inner one would win, killing minimise.
  final VoidCallback onSwipeUp;

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

  /// Net vertical travel of the current drag; negative is upwards. The sheet
  /// itself clamps at zero, so an upward drag moves nothing until released.
  double _dy = 0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        // translucent, so taps still reach the player's own controls.
        behavior: HitTestBehavior.translucent,
        onVerticalDragDown: (d) {
          _accepting = d.localPosition.dy < box.maxHeight - _controlsZone;
          _dy = 0;
        },
        onVerticalDragUpdate: (d) {
          if (!_accepting) return;
          _dy += d.delta.dy;
          widget.onUpdate(d);
        },
        onVerticalDragEnd: (d) {
          if (_accepting) {
            widget.onEnd(d);
            if (swipeEntersFullscreen(_dy, d.velocity.pixelsPerSecond.dy)) {
              widget.onSwipeUp();
            }
          }
          _accepting = false;
        },
        onVerticalDragCancel: () => _accepting = false,
        child: widget.child,
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
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    // The title and the line under it are one tap target that opens the
    // description, as on YouTube; the separate grey description card is
    // gone. The exact upload date and the like count moved into the sheet,
    // where there is room for them — the line here is the short form.
    void openDescription() => showDescriptionSheet(
      context,
      title: video.title,
      description: description,
      onSeek: onSeek,
      stats: [
        if (video.viewCount != null) '${compactCount(video.viewCount)} views',
        if (likes != null) '${compactCount(likes)} likes',
        uploadLabel(video.uploadDate, raw: video.uploadRaw),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: openDescription,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: metaLine([
                            if (video.viewCount != null)
                              '${compactCount(video.viewCount)} views',
                            timeAgo(video.uploadDate, raw: video.uploadRaw),
                          ]),
                        ),
                        TextSpan(
                          text: '  ...more',
                          style: TextStyle(
                            color: theme.colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: _ChannelRow(video: video),
          ),
        ],
      ),
    );
  }
}

/// The channel row under a video: avatar, channel name with its subscriber
/// count directly after it, then a Subscribe toggle — the layout the real app
/// uses. Tapping the avatar or name opens the channel; the button is its own
/// tap target.
///
/// The subscriber count and the button's subscribed state both need data the
/// video row does not carry, so this loads them lazily: the channel's info for
/// the count, the local subscriptions table for the toggle. It shows the name
/// immediately and fills the rest in as it arrives, rather than blocking the
/// whole header on a network call.
class _ChannelRow extends StatefulWidget {
  const _ChannelRow({required this.video});

  final VideoBrief video;

  @override
  State<_ChannelRow> createState() => _ChannelRowState();
}

class _ChannelRowState extends State<_ChannelRow> {
  ChannelInfo? _info;
  bool? _subscribed;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ChannelRow old) {
    super.didUpdateWidget(old);
    // The watch page reuses one _Header across videos in the queue, so a new
    // video reaches this row through a rebuild rather than a fresh mount.
    if (old.video.channelId != widget.video.channelId) {
      setState(() {
        _info = null;
        _subscribed = null;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final id = widget.video.channelId;
    if (id.isEmpty) return;
    final db = context.read<AppDatabase>();
    final repo = context.read<YtRepository>();

    final subbed = await db.isSubscribed(id);
    if (mounted) setState(() => _subscribed = subbed);

    try {
      final info = await repo.channelInfo(id);
      if (mounted && id == widget.video.channelId) {
        setState(() => _info = info);
      }
    } catch (_) {
      // No subscriber count then — the name and button still work.
    }
  }

  /// Prefer the fetched channel info, but fall back to what the video carries
  /// so Subscribe works even before (or without) the info call.
  ChannelInfo get _channel =>
      _info ??
      ChannelInfo(
        id: widget.video.channelId,
        title: widget.video.author,
        avatarUrl: widget.video.avatarUrl,
      );

  Future<void> _toggle() async {
    final db = context.read<AppDatabase>();
    final messenger = ScaffoldMessenger.of(context);
    final channel = _channel;
    if (_subscribed ?? false) {
      await db.unsubscribe(channel.id);
      messenger.showSnackBar(
        SnackBar(content: Text('Unsubscribed from ${channel.title}')),
      );
    } else {
      await db.subscribe(channel);
      messenger.showSnackBar(
        SnackBar(content: Text('Subscribed to ${channel.title}')),
      );
    }
    if (mounted) setState(() => _subscribed = !(_subscribed ?? false));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final video = widget.video;
    final scheme = theme.colorScheme;
    final subscribed = _subscribed ?? false;
    final subLabel = _info?.subscriberLabel;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          // The avatar and the name open the channel; kept inside their own
          // InkWell so the Subscribe button beside them stays a separate tap.
          Expanded(
            child: InkWell(
              onTap: video.channelId.isEmpty
                  ? null
                  : () => ChannelPage.open(
                      context,
                      video.channelId,
                      title: video.author,
                    ),
              child: Row(
                children: [
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
                  // Name on top, subscriber count directly beneath it — the
                  // count sits with the name rather than anywhere else.
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          video.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (subLabel != null)
                          Text(
                            subLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 11,
                              color: scheme.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (video.channelId.isNotEmpty) ...[
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _subscribed == null ? null : _toggle,
              style: FilledButton.styleFrom(
                backgroundColor: subscribed
                    ? scheme.onSurface.withValues(alpha: 0.12)
                    : scheme.onSurface,
                foregroundColor: subscribed ? scheme.onSurface : scheme.surface,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                visualDensity: VisualDensity.compact,
              ),
              child: Text(subscribed ? 'Subscribed' : 'Subscribe'),
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
          // One segmented pill, [like | dislike], as YouTube draws it.
          _LikeDislikePill(
            likeLabel: _likeLabel(context),
            onLike: () => _explainSignIn(context, 'Liking'),
            onDislike: () => _explainSignIn(context, 'Disliking'),
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
              if (isDownloaded || isDownloading) {
                // Asked, not done. One tap on "Downloaded" deleted the file
                // outright — found on an emulator, where a single stray tap
                // threw away a 44 MB download with no way back. YouTube asks
                // first; so does this, for a running download too.
                final confirmed = await _confirmDownloadAction(
                  context,
                  downloaded: isDownloaded,
                );
                if (!confirmed) return;
                if (isDownloaded) {
                  await downloads.remove(video.id);
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Download removed')),
                  );
                } else {
                  await downloads.cancel(video.id);
                }
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

  /// A bottom sheet asking whether to delete (or stop) the download.
  static Future<bool> _confirmDownloadAction(
    BuildContext context, {
    required bool downloaded,
  }) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                downloaded ? Icons.delete_outline : Icons.close,
              ),
              title: Text(downloaded ? 'Delete from downloads' : 'Stop download'),
              subtitle: Text(
                downloaded
                    ? 'The video will no longer play offline.'
                    : 'What has downloaded so far is discarded.',
              ),
              onTap: () => Navigator.of(sheet).pop(true),
            ),
            ListTile(
              leading: const Icon(Icons.arrow_back),
              title: const Text('Keep it'),
              onTap: () => Navigator.of(sheet).pop(false),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }

  void _explainSignIn(BuildContext context, String action) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$action needs a signed-in Google account, which '
            'AI BIT does not use.'),
      ),
    );
  }
}

/// Like and dislike as one rounded pill split by a hairline.
///
/// Voting needs a signed-in account this app does not have, so both halves
/// explain that on tap — but the icon still bounces, because a control that
/// does not acknowledge a press reads as broken before the message is read.
class _LikeDislikePill extends StatelessWidget {
  const _LikeDislikePill({
    required this.likeLabel,
    required this.onLike,
    required this.onDislike,
  });

  final String likeLabel;
  final VoidCallback onLike;
  final VoidCallback onDislike;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: scheme.onSurface.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _BounceTap(
              onTap: onLike,
              padding: const EdgeInsets.fromLTRB(14, 9, 12, 9),
              icon: Icons.thumb_up_outlined,
              label: likeLabel,
            ),
            Container(
              width: 1,
              height: 22,
              color: scheme.onSurface.withValues(alpha: 0.2),
            ),
            _BounceTap(
              onTap: onDislike,
              padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
              icon: Icons.thumb_down_outlined,
            ),
          ],
        ),
      ),
    );
  }
}

class _BounceTap extends StatefulWidget {
  const _BounceTap({
    required this.onTap,
    required this.padding,
    required this.icon,
    this.label,
  });

  final VoidCallback onTap;
  final EdgeInsets padding;
  final IconData icon;
  final String? label;

  @override
  State<_BounceTap> createState() => _BounceTapState();
}

class _BounceTapState extends State<_BounceTap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bounce = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1, end: 1.25), weight: 1),
    TweenSequenceItem(tween: Tween(begin: 1.25, end: 1), weight: 1),
  ]).animate(CurvedAnimation(parent: _bounce, curve: Curves.easeOut));

  @override
  void dispose() {
    _bounce.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: () {
        _bounce.forward(from: 0);
        widget.onTap();
      },
      child: Padding(
        padding: widget.padding,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ScaleTransition(
              scale: _scale,
              child: Icon(widget.icon, size: 19, color: color),
            ),
            if (widget.label != null) ...[
              const SizedBox(width: 7),
              Text(
                widget.label!,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ],
        ),
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
