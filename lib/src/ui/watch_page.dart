import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import '../core/chapters.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../data/db.dart';
import '../data/download_manager.dart';
import '../data/models.dart';
import '../data/preview_data.dart';
import '../data/ranker_trainer.dart';
import '../data/yt_repository.dart';
import '../player/playback_controller.dart';
import 'channel_page.dart';
import 'player_sheet_controller.dart';
import 'widgets/comments_sheet.dart';
import 'widgets/description_sheet.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// The watch page's content: title, channel row, actions, comments teaser and
/// Up next — everything below the video.
///
/// It is not a route any more. It is the expanded body of the one continuous
/// player sheet (`PlayerSheet`), which also owns the video surface and the
/// mini player; the sheet mounts one of these per video, keyed by its id, so
/// a new video — tapped, autoplayed, skipped to from the lock screen — always
/// arrives as a fresh page scrolled to the top.
class WatchPage extends StatefulWidget {
  const WatchPage({super.key, required this.video});

  final VideoBrief video;

  /// Plays [video] and expands the player sheet over whatever is showing.
  ///
  /// Completes when the sheet next collapses to the mini player or closes,
  /// which lets callers refresh history-dependent lists — the same moment the
  /// old pushed route used to complete at.
  static Future<void> open(BuildContext context, VideoBrief video) {
    final playback = context.read<PlaybackController>();
    final before = playback.current?.id;
    // Presented BEFORE play: play() moves the player's current video and
    // notifies synchronously, which is what fulfils the sheet's request. A
    // request made after that notification was never fulfilled, and pinned
    // the sheet to this video even once the player moved back to `before`.
    final presented = _present(video, currentBefore: before);
    // Only (re)start the stream if this video is not already the live one —
    // reopening what is in the mini player must not restart playback.
    if (before != video.id) unawaited(playback.play(video));
    return presented;
  }

  /// Brings the playing video back from the mini player.
  static Future<void> reopen(BuildContext context, VideoBrief video) {
    PlayerSheetController.instance?.expand();
    return Future.value();
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
    final playback = context.read<PlaybackController>();
    final before = playback.current?.id;
    // One play, carrying the queue. Calling [open] after it would issue a
    // second play without the queue whenever the first is still waiting
    // behind an older load, and the newer ticket would win. Presented first,
    // for the reason given in [open].
    final presented = _present(videos[index], currentBefore: before);
    unawaited(
      playback.play(videos[index], upNext: videos.skip(index + 1).toList()),
    );
    return presented;
  }

  static Future<void> _present(VideoBrief video, {String? currentBefore}) {
    // A search box left focused would keep the keyboard over the video.
    FocusManager.instance.primaryFocus?.unfocus();
    final sheet = PlayerSheetController.instance;
    if (sheet == null) return Future.value();
    return sheet.open(video, currentId: currentBefore);
  }

  @override
  State<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends State<WatchPage> with WidgetsBindingObserver {
  late VideoBrief _video = widget.video;
  yt.Video? _details;
  List<VideoBrief> _related = const [];
  bool _loadingDetails = true;

  PlaybackController? _playback;

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackController>()..addListener(_onPlayback);
    WidgetsBinding.instance.addObserver(this);
    _wasLandscape = _viewIsLandscape();
    _loadDetails();
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
    // Only from the expanded watch page. Turning the phone while browsing
    // with the mini player docked is not a request to fill the screen with
    // it, and YouTube does not treat it as one.
    final sheet = PlayerSheetController.instance;
    if (sheet == null || !sheet.isExpanded || sheet.animation.value < 1) {
      return;
    }
    final current = playback.current;
    if (current == null || current.id != _video.id || current.isShort) return;
    if (playback.error != null || playback.isLoading) return;
    // Nothing over the shell: a dialog, a bottom sheet or the lock pad.
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

  /// One-shot notices the controller leaves for the page. Following the
  /// player's video is no longer this page's job: the sheet mounts a new page
  /// per video, so autoplay, the end screen and the lock screen's skip
  /// buttons all arrive as a fresh page for the video actually playing.
  void _onPlayback() {
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
    _playback?.removeListener(_onPlayback);
    super.dispose();
  }

  void _openRelated(VideoBrief video) {
    // The sheet mounts a fresh page for it, keyed by its id.
    unawaited(WatchPage.open(context, video));
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    // Built only when the page's own data changes. The sheet moves and fades
    // this subtree as a whole during a drag; nothing here runs per frame.
    return ListView(
      padding: EdgeInsets.zero,
      // Its own controller: the sheet sits outside every content route, and
      // borrowing the shell route's primary controller would tie this list
      // to whatever else attaches to it.
      primary: false,
      physics: const ClampingScrollPhysics(),
      children: [
        _Header(
          video: _video,
          details: _details,
          onSeek: (to) => context.read<PlaybackController>().seek(to),
        ),
        _PillRow(video: _video, likeCount: _details?.engagement.likeCount),
        const SizedBox(height: 8),
        if (!YtRepository.isPreview) CommentsPreview(videoId: _video.id),
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
        // Phones get full-width cards with no heading, as YouTube draws its
        // watch-page feed; a tablet's wider page keeps compact rows, where a
        // card would be absurdly large.
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
        SizedBox(height: 32 + bottomInset),
      ],
    );
  }
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
      useRootNavigator: true,
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
