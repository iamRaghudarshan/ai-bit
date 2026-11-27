import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import '../core/format.dart';
import '../data/comments_client.dart';
import '../data/db.dart';
import '../data/interests.dart';
import '../data/models.dart';
import '../data/ranker_trainer.dart';
import '../data/recommender.dart';
import '../data/settings.dart';
import '../data/yt_repository.dart';
import '../player/playback_controller.dart';
import 'channel_page.dart';
import 'widgets/comments_sheet.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// One page of the Shorts feed, ranked as the Shorts tab ranks it.
///
/// Shared by the tab, the Home shelf and `ShortsRoute`'s top-up, so all three
/// order Shorts identically: against the Shorts-only taste profile (never the
/// long-form one), or — in Kids mode — curated from the Kids topics with no
/// personal signal at all. [firstPage] false is the cheaper "more of the same"
/// request used when a swipe nears the end of the list.
Future<List<VideoBrief>> loadShortsFeed(
  BuildContext context, {
  int refreshToken = 0,
  bool firstPage = true,
}) async {
  // Everything read from the tree before the first await.
  final db = context.read<AppDatabase>();
  final settings = context.read<SettingsService>();
  final repo = context.read<YtRepository>();
  final trainer = context.read<RankerTrainer>();
  final kids = settings.kidsMode;

  if (!firstPage) {
    // shorts: true here as well as on the first page — the two paths have
    // drifted apart before, and a later page ranked against the long-form
    // profile would quietly undo the split a few swipes in.
    final profile =
        kids ? TasteProfile.empty : await db.tasteProfile(shorts: true);
    return repo.shortsFeed(
      profile: profile,
      weights: trainer.weights,
      refreshToken: refreshToken,
      kids: kids,
    );
  }

  final searches = await db.recentSearches(limit: 2);
  // Ranked like every other feed. Shorts was the last surface still ordered
  // by shuffle(), which meant the one people scroll fastest made the least
  // use of what the app knew about them. Exploration and the rotating seed
  // keep it different on every visit, which was the only thing shuffling was
  // buying.
  final chosenInterests = kids ? const <String>[] : settings.interestTopics;
  final profile = kids
      ? TasteProfile.empty
      : await db.tasteProfile(
          interestQueries: interestQueries(chosenInterests),
          // The Shorts profile, not the long-form one. Watching Shorts should
          // shape Shorts and nothing else.
          shorts: true,
        );
  final impressions =
      kids ? const <String, ImpressionCount>{} : await db.feedImpressions();
  return repo.shortsFeed(
    searches: searches,
    interests: chosenInterests,
    feedLanguages: kids ? const [] : settings.feedLanguages,
    profile: profile,
    impressions: impressions,
    weights: trainer.weights,
    refreshToken: refreshToken,
    kids: kids,
  );
}

/// "1.2K Comments" → "1.2K", for the rail's label. Null when YouTube gave no
/// count, so the rail says "Comments" instead.
String? shortsCountLabel(String? totalLabel) {
  final text = totalLabel?.trim() ?? '';
  if (text.isEmpty) return null;
  final match = RegExp(r'^[\d.,]+\s*[KMBkmb]?').firstMatch(text);
  final count = match?.group(0)?.replaceAll(' ', '');
  return (count == null || count.isEmpty) ? null : count;
}

/// The vertical poster for a Short, best first.
///
/// `oardefault` is YouTube's 1080x1920 vertical frame and exists for Shorts
/// (measured: 200 on every Short sampled, 404 on a long-form video); `hq720`
/// and `hqdefault` are the landscape fallbacks every video has, cropped to
/// fill. A letterboxed `hqdefault` under a full-bleed video was the hard cut
/// from bars to picture on every swipe.
List<String> shortPosterUrls(String videoId) => [
      'https://i.ytimg.com/vi/$videoId/oardefault.jpg',
      'https://i.ytimg.com/vi/$videoId/hq720.jpg',
      'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
    ];

/// A Short's poster frame, falling back down [shortPosterUrls].
class ShortPoster extends StatelessWidget {
  const ShortPoster({
    super.key,
    required this.videoId,
    this.memCacheWidth = 720,
  });

  final String videoId;
  final int memCacheWidth;

  @override
  Widget build(BuildContext context) => _attempt(shortPosterUrls(videoId), 0);

  Widget _attempt(List<String> urls, int i) => CachedNetworkImage(
        imageUrl: urls[i],
        memCacheWidth: memCacheWidth,
        fit: BoxFit.cover,
        fadeInDuration: const Duration(milliseconds: 120),
        placeholder: (_, _) => const ColoredBox(color: Colors.black),
        errorWidget: (_, _, _) => i + 1 < urls.length
            ? _attempt(urls, i + 1)
            : const ColoredBox(color: Colors.black),
      );
}

/// When a swipe settled on each Short, so the first frame can be timed.
class _ShortsTiming {
  static final _settledAt = <String, Stopwatch>{};

  static void settled(String id) => _settledAt[id] = Stopwatch()..start();

  static void firstFrame(String id) {
    final watch = _settledAt.remove(id);
    if (watch == null) return;
    debugPrint('AI BIT start: $id shorts first frame '
        '${watch.elapsedMilliseconds}ms after the swipe settled');
  }
}

const _shortsRed = Color(0xFFFF0033);
const _textShadow = [Shadow(blurRadius: 6, color: Colors.black54)];

/// Vertical swipe feed: the Shorts tab, and the body of `ShortsRoute`.
///
/// Only the page in view gets the player — there is one player for the whole
/// app, so neighbouring pages show their poster until swiped to. That also
/// stops three videos buffering at once.
///
/// With [initial] it plays that list from [startIndex] and tops up from the
/// feed at the end (the route). Without it, it is the tab and loads the feed
/// itself on first visit.
class ShortsPage extends StatefulWidget {
  const ShortsPage({super.key, this.initial, this.startIndex = 0});

  final List<VideoBrief>? initial;
  final int startIndex;

  @override
  State<ShortsPage> createState() => ShortsPageState();
}

class ShortsPageState extends State<ShortsPage> {
  late final PageController _pages;
  List<VideoBrief> _shorts = [];
  bool _loading = true;
  int _index = 0;
  int _refreshToken = 0;

  /// True once this tab has been visited. Until then nothing is fetched and
  /// nothing plays — the tab is built at startup along with every other.
  bool _activated = false;

  /// The Kids/normal mode the loaded shorts belong to, so a mode switch on the
  /// Home tab forces a reload rather than showing the previous mode's shorts.
  bool _loadedKids = false;

  /// The index [_startCurrent] last started, so a scroll that ends where it
  /// began does not restart the Short.
  int _startedIndex = -1;

  /// A backstop for [_startCurrent] when no ScrollEndNotification follows a
  /// page change (a programmatic jump).
  Timer? _settleFallback;

  /// "Clear screen": every overlay hidden until the next tap.
  bool _clean = false;

  /// The comments sheet is up; the Short shrinks into the space above it.
  bool _commentsOpen = false;

  bool _appending = false;

  late final PlaybackController _playback;

  bool get _standalone => widget.initial != null;

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackController>();
    final initial = widget.initial;
    if (initial != null && initial.isNotEmpty) {
      _shorts = [for (final s in initial) s.isShort ? s : s.asShort()];
      _index = widget.startIndex.clamp(0, _shorts.length - 1);
      _activated = true;
      _loading = false;
      _loadedKids = context.read<SettingsService>().kidsMode;
    }
    _pages = PageController(initialPage: _index);
    if (_standalone) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _prefetchAhead();
        _startCurrent(force: true);
        if (_index >= _shorts.length - 3) _appendMore();
      });
    }
  }

  @override
  void dispose() {
    _settleFallback?.cancel();
    // Leaving the route stops the Short rather than pausing it: a Short in
    // the mini player is not something YouTube ever shows.
    // Deferred: stop() notifies listeners at once, and dispose runs while the
    // tree is locked, where a rebuild request is an assertion failure.
    if (_standalone) {
      final ours = {for (final s in _shorts) s.id};
      final playback = _playback;
      Future.microtask(() {
        final current = playback.current;
        if (current != null && current.isShort && ours.contains(current.id)) {
          unawaited(playback.stop());
        }
      });
    }
    _pages.dispose();
    super.dispose();
  }

  /// Called by the shell when the tab is selected.
  Future<void> onTabOpened() async {
    final kids = context.read<SettingsService>().kidsMode;
    if (_activated && kids == _loadedKids && _shorts.isNotEmpty) {
      // Returning to the tab starts whatever is on screen again.
      _startCurrent(force: true);
      return;
    }
    // A mode switch: clear the old shorts so the loader shows while the new
    // set fetches, rather than the previous mode's shorts lingering.
    if (_activated) setState(() => _shorts = []);
    _activated = true;
    await _load();
  }

  /// Called by the shell when leaving the tab. The Short is stopped, not
  /// paused, so it does not reappear in the mini player under the Home feed.
  void onTabClosed() {
    _settleFallback?.cancel();
    _stopIfOurs();
    _startedIndex = -1;
  }

  /// Back to the first Short and a fresh feed — pull-to-refresh at the top,
  /// and what the shell calls when the Shorts tab is tapped while showing.
  Future<void> refresh() async {
    if (!_activated) return onTabOpened();
    if (_pages.hasClients && _index != 0) _pages.jumpToPage(0);
    _refreshToken++;
    await _load();
  }

  void _stopIfOurs() {
    final current = _playback.current;
    if (current == null || !current.isShort) return;
    if (!_shorts.any((s) => s.id == current.id)) return;
    unawaited(_playback.stop());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _loadedKids = context.read<SettingsService>().kidsMode;
      final shorts = await loadShortsFeed(
        context,
        refreshToken: _refreshToken,
      );
      if (!mounted) return;
      setState(() {
        _shorts = shorts.toList();
        _loading = false;
        _index = 0;
        _startedIndex = -1;
      });
      if (_pages.hasClients && (_pages.page ?? 0) != 0) _pages.jumpToPage(0);
      _prefetchAhead();
      _startCurrent(force: true);
    } catch (e) {
      debugPrint('AI BIT: shorts feed failed — $e');
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// Starts the Short in view. Called when a swipe has finished settling, not
  /// when the page index flips half-way through it: the source swap is a
  /// decoder release and reconfigure on the platform thread, and landing it
  /// mid-fling read as the swipe catching.
  void _startCurrent({bool force = false}) {
    _settleFallback?.cancel();
    if (_shorts.isEmpty || !mounted) return;
    final video = _shorts[_index];
    if (!force &&
        _startedIndex == _index &&
        _playback.current?.id == video.id) {
      return;
    }
    _startedIndex = _index;
    _ShortsTiming.settled(video.id);
    debugPrint('AI BIT start: ${video.id} shorts swipe settled');
    unawaited(
      _playback.play(video, shortsSurface: true).then((_) {
        if (!mounted || _playback.current?.id != video.id) return;
        // After this one has started, so pre-buffering never competes with it.
        final ahead = [
          for (var n = _index + 1; n <= _index + 2 && n < _shorts.length; n++)
            _shorts[n],
        ];
        unawaited(_playback.preCacheShorts(ahead));
      }),
    );
  }

  /// Warms the stream cache for the next few shorts, so swiping to them is a
  /// cache hit rather than a fresh resolve — the way YouTube preloads ahead.
  void _prefetchAhead() {
    final repo = context.read<YtRepository>();
    // Three ahead rather than two: a fast swiper outruns two, and a resolve
    // that has not finished is exactly the pause being complained about.
    for (var ahead = 1; ahead <= 3; ahead++) {
      final next = _index + ahead;
      if (next < _shorts.length) repo.prefetch(_shorts[next].id);
    }
    // And one behind, because swiping back up is common.
    final previous = _index - 1;
    if (previous >= 0) repo.prefetch(_shorts[previous].id);
  }

  void _onPageChanged(int i) {
    final leaving = _index < _shorts.length ? _shorts[_index] : null;
    setState(() {
      _index = i;
      _clean = false;
    });
    // The previous Short goes quiet the moment the page flips, rather than
    // talking over the next one until the new source is attached.
    if (leaving != null && _playback.current?.id == leaving.id) {
      unawaited(_playback.player?.pause());
    }
    _prefetchAhead();
    _settleFallback?.cancel();
    _settleFallback = Timer(const Duration(milliseconds: 700), _startCurrent);
    // Top up before the end so swiping never hits a wall.
    if (i >= _shorts.length - 3) _appendMore();
  }

  Future<void> _appendMore() async {
    if (_appending) return;
    _appending = true;
    _refreshToken++;
    try {
      final more = await loadShortsFeed(
        context,
        refreshToken: _refreshToken,
        firstPage: false,
      );
      if (!mounted) return;
      final seen = _shorts.map((s) => s.id).toSet();
      setState(() => _shorts.addAll(more.where((s) => seen.add(s.id))));
    } catch (e) {
      // Running out of new Shorts is not worth an error; the feed just ends.
      debugPrint('AI BIT: more shorts failed — $e');
    } finally {
      _appending = false;
    }
  }

  Future<void> _openChannel(VideoBrief video) async {
    if (video.channelId.isEmpty) return;
    // Stopped rather than paused: the channel page would otherwise paint the
    // now-playing bar with this Short in it.
    _settleFallback?.cancel();
    await _playback.stop();
    _startedIndex = -1;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChannelPage(
          channelId: video.channelId,
          initialTitle: video.author,
        ),
      ),
    );
    if (mounted) _startCurrent(force: true);
  }

  Future<void> _openComments(
    VideoBrief video,
    Future<CommentPage> comments,
  ) async {
    setState(() => _commentsOpen = true);
    try {
      await showCommentsSheetLoading(
        context,
        video.id,
        comments,
        initialSize: 0.6,
        barrierColor: Colors.black26,
      );
    } finally {
      if (mounted) setState(() => _commentsOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading && _shorts.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    if (_shorts.isEmpty) {
      return EmptyState(
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
      );
    }

    Widget pages = NotificationListener<ScrollEndNotification>(
      onNotification: (n) {
        if (n.depth == 0 && n.metrics.axis == Axis.vertical) _startCurrent();
        return false;
      },
      child: PageView.builder(
        controller: _pages,
        scrollDirection: Axis.vertical,
        // Builds the adjacent pages instead of only the visible one, so the
        // next short's poster is already decoded when the swipe lands rather
        // than appearing as a black frame first.
        allowImplicitScrolling: true,
        physics: _commentsOpen ? const NeverScrollableScrollPhysics() : null,
        itemCount: _shorts.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, i) => _ShortView(
          video: _shorts[i],
          isActive: i == _index,
          clean: _clean,
          commentsOpen: _commentsOpen,
          onClearScreen: () => setState(() => _clean = true),
          onRestoreScreen: () => setState(() => _clean = false),
          onOpenChannel: _openChannel,
          onOpenComments: _openComments,
        ),
      ),
    );

    // Pull-to-refresh only on the tab: the route plays a list it was handed,
    // and replacing that with a fresh feed would lose the viewer's place.
    if (!_standalone) {
      pages = RefreshIndicator(
        onRefresh: refresh,
        color: Colors.white,
        backgroundColor: Colors.black87,
        child: pages,
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // While comments are open the Short shrinks into the space above the
        // sheet, as YouTube does, instead of hiding behind it.
        AnimatedScale(
          scale: _commentsOpen ? 0.4 : 1,
          alignment: Alignment.topCenter,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: pages,
        ),
        const _KidsTimeUp(),
      ],
    );
  }
}

/// Kids mode's daily allowance, spent. The controller pauses; this says why.
class _KidsTimeUp extends StatelessWidget {
  const _KidsTimeUp();

  @override
  Widget build(BuildContext context) {
    final reached = context.select<PlaybackController, bool>(
      (p) => p.kidsLimitReached,
    );
    if (!reached) return const SizedBox.shrink();
    return const ColoredBox(
      color: Colors.black87,
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bedtime_outlined, color: Colors.white, size: 56),
              SizedBox(height: 16),
              Text(
                "Time's up for today",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Come back tomorrow for more Shorts.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One Short: poster, player, gestures, overlays.
class _ShortView extends StatefulWidget {
  const _ShortView({
    required this.video,
    required this.isActive,
    required this.clean,
    required this.commentsOpen,
    required this.onClearScreen,
    required this.onRestoreScreen,
    required this.onOpenChannel,
    required this.onOpenComments,
  });

  final VideoBrief video;
  final bool isActive;
  final bool clean;
  final bool commentsOpen;
  final VoidCallback onClearScreen;
  final VoidCallback onRestoreScreen;
  final Future<void> Function(VideoBrief) onOpenChannel;
  final Future<void> Function(VideoBrief, Future<CommentPage>) onOpenComments;

  @override
  State<_ShortView> createState() => _ShortViewState();
}

class _ShortViewState extends State<_ShortView> {
  /// The Short with whatever its details added (channel, duration) — search
  /// results carry neither.
  late VideoBrief _video = widget.video;
  yt.Video? _details;
  bool _liked = false;
  bool? _subscribed;
  String? _avatar;
  Future<CommentPage>? _comments;
  String? _commentCount;

  /// Waits out a fling before spending requests on a Short.
  Timer? _dwell;

  /// Single-tap is held this long in case it is the first half of a double.
  static const _doubleTapWindow = Duration(milliseconds: 250);
  Timer? _tapTimer;
  Offset? _firstTap;

  final _bursts = <_Burst>[];
  int _burstSeq = 0;

  /// The pause/play glyph flash, bumped on each tap.
  int _glyphSeq = 0;

  /// Where a scrub would land, while one is in progress.
  final _scrub = ValueNotifier<Duration?>(null);

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _scheduleDetails();
  }

  @override
  void didUpdateWidget(_ShortView old) {
    super.didUpdateWidget(old);
    if (old.video.id != widget.video.id) {
      _video = widget.video;
      _details = null;
      _comments = null;
      _commentCount = null;
      _subscribed = null;
      _avatar = null;
      _liked = false;
    }
    if (widget.isActive && !old.isActive) _scheduleDetails();
    if (!widget.isActive) _dwell?.cancel();
  }

  @override
  void dispose() {
    _dwell?.cancel();
    _tapTimer?.cancel();
    _scrub.dispose();
    super.dispose();
  }

  void _scheduleDetails() {
    _dwell?.cancel();
    _dwell = Timer(const Duration(milliseconds: 350), _loadDetails);
  }

  /// Counts, channel and like state — for the Short in view only.
  Future<void> _loadDetails() async {
    if (!mounted || !widget.isActive) return;
    final repo = context.read<YtRepository>();
    final db = context.read<AppDatabase>();
    final playback = context.read<PlaybackController>();
    final id = widget.video.id;

    unawaited(db.isLiked(id).then((v) {
      if (mounted && widget.video.id == id) setState(() => _liked = v);
    }, onError: (Object e) => debugPrint('AI BIT: like state - $e')));

    _comments ??= repo.comments(id);
    unawaited(_comments!.then((page) {
      if (mounted && widget.video.id == id) {
        setState(() => _commentCount = shortsCountLabel(page.totalLabel));
      }
    }, onError: (Object e) => debugPrint('AI BIT: shorts comments - $e')));

    if (_details != null) return;
    try {
      final details = await repo.videoDetails(id);
      if (!mounted || widget.video.id != id) return;
      final rich = VideoBrief.fromYt(details);
      final merged = VideoBrief(
        id: id,
        title: _video.title.isNotEmpty ? _video.title : rich.title,
        author: _video.author.isNotEmpty ? _video.author : rich.author,
        channelId:
            _video.channelId.isNotEmpty ? _video.channelId : rich.channelId,
        duration: _video.duration ?? rich.duration,
        viewCount: _video.viewCount ?? rich.viewCount,
        uploadDate: _video.uploadDate ?? rich.uploadDate,
        uploadRaw: _video.uploadRaw ?? rich.uploadRaw,
        isShort: true,
        isKids: _video.isKids,
        avatarUrl: _video.avatarUrl,
      );
      setState(() {
        _details = details;
        _video = merged;
      });
      // The history row and the Shorts profile get the channel too.
      playback.enrichCurrent(merged);
      final channelId = merged.channelId;
      if (channelId.isEmpty) return;
      final subscribed = await db.isSubscribed(channelId);
      if (mounted && widget.video.id == id) {
        setState(() => _subscribed = subscribed);
      }
      if (merged.avatarUrl == null) {
        final info = await repo.channelInfo(channelId);
        if (mounted && widget.video.id == id && info.avatarUrl != null) {
          setState(() => _avatar = info.avatarUrl);
        }
      }
    } catch (e) {
      debugPrint('AI BIT: shorts details failed for $id — $e');
    }
  }

  // ------------------------------------------------------------- gestures

  void _onTapUp(TapUpDetails details) {
    if (widget.commentsOpen) {
      Navigator.of(context).maybePop();
      return;
    }
    final first = _firstTap;
    if (_tapTimer?.isActive ?? false) {
      _tapTimer!.cancel();
      _firstTap = null;
      if (first != null &&
          (first - details.localPosition).distance < 80) {
        _doubleTap(details.localPosition);
        return;
      }
    }
    _firstTap = details.localPosition;
    _tapTimer = Timer(_doubleTapWindow, () {
      _firstTap = null;
      _singleTap();
    });
  }

  void _singleTap() {
    if (!mounted) return;
    if (widget.clean) {
      widget.onRestoreScreen();
      return;
    }
    final playback = context.read<PlaybackController>();
    // Not mid-load: the native player still holds the previous Short then,
    // and "play" would bring its audio back.
    if (playback.current?.id != widget.video.id || playback.isLoading) return;
    unawaited(playback.togglePlayPause());
    setState(() => _glyphSeq++);
  }

  void _doubleTap(Offset at) {
    setState(() => _bursts.add(_Burst(++_burstSeq, at)));
    if (!_liked) unawaited(_setLiked(true));
  }

  Future<void> _setLiked(bool liked) async {
    setState(() => _liked = liked);
    try {
      await context.read<AppDatabase>().setLiked(_video, liked);
    } catch (e) {
      debugPrint('AI BIT: like not saved — $e');
      if (mounted) setState(() => _liked = !liked);
    }
  }

  Future<void> _toggleSubscribe() async {
    final db = context.read<AppDatabase>();
    final messenger = ScaffoldMessenger.of(context);
    final channel = ChannelInfo(
      id: _video.channelId,
      title: _video.author,
      avatarUrl: _video.avatarUrl ?? _avatar,
    );
    if (channel.id.isEmpty) return;
    final was = _subscribed ?? false;
    setState(() => _subscribed = !was);
    try {
      if (was) {
        await db.unsubscribe(channel.id);
      } else {
        await db.subscribe(channel);
      }
      messenger.showSnackBar(SnackBar(
        content: Text(was
            ? 'Unsubscribed from ${channel.title}'
            : 'Subscribed to ${channel.title}'),
      ));
    } catch (e) {
      debugPrint('AI BIT: subscribe failed — $e');
      if (mounted) setState(() => _subscribed = was);
    }
  }

  Future<void> _openMenu() async {
    final playback = context.read<PlaybackController>();
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.fullscreen),
              title: const Text('Clear screen'),
              subtitle: const Text('Hide everything over the Short'),
              onTap: () => Navigator.pop(sheet, 'clear'),
            ),
            ListTile(
              leading: Icon(playback.shortsMuted
                  ? Icons.volume_up_outlined
                  : Icons.volume_off_outlined),
              title: Text(playback.shortsMuted ? 'Unmute' : 'Mute'),
              onTap: () => Navigator.pop(sheet, 'mute'),
            ),
            ListTile(
              leading: const Icon(Icons.more_horiz),
              title: const Text('More options'),
              onTap: () => Navigator.pop(sheet, 'more'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'clear':
        widget.onClearScreen();
      case 'mute':
        unawaited(playback.setShortsMuted(!playback.shortsMuted));
      case 'more':
        await showVideoMenu(context, _video);
    }
  }

  @override
  Widget build(BuildContext context) {
    final held = context.select<PlaybackController, bool>((p) => p.speedHeld);
    final speedHeld = widget.isActive && held;
    final hideOverlay = widget.clean || speedHeld || widget.commentsOpen;

    return Stack(
      fit: StackFit.expand,
      children: [
        // The poster sits underneath always: it fills the frame while the
        // stream resolves, so a swipe never lands on a black rectangle. It
        // does not watch playback, so the pages either side of the active one
        // never repaint as the player ticks.
        RepaintBoundary(child: ShortPoster(videoId: widget.video.id)),

        // Only the active short watches the player, so its per-frame rebuilds
        // are confined to this one page instead of every visible page.
        if (widget.isActive) _ActiveShortPlayer(video: widget.video),

        // Taps, double-taps and hold-for-2x, here rather than on the player
        // surface so they work while the Short is still loading. Vertical
        // drags are left alone for the PageView.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _onTapUp,
          onLongPressStart: (_) {
            final playback = context.read<PlaybackController>();
            if (playback.current?.id == widget.video.id) {
              unawaited(playback.holdSpeed(true));
            }
          },
          onLongPressEnd: (_) =>
              unawaited(context.read<PlaybackController>().holdSpeed(false)),
          onLongPressCancel: () =>
              unawaited(context.read<PlaybackController>().holdSpeed(false)),
        ),

        if (widget.isActive)
          IgnorePointer(
            child: _CentreGlyph(video: widget.video, seq: _glyphSeq),
          ),

        if (speedHeld)
          const IgnorePointer(
            child: SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: _Pill(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '2x',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(width: 4),
                        Icon(Icons.fast_forward, color: Colors.white, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

        for (final burst in _bursts)
          _HeartBurst(
            key: ValueKey(burst.id),
            at: burst.at,
            onDone: () => setState(() => _bursts.remove(burst)),
          ),

        IgnorePointer(
          ignoring: hideOverlay,
          child: AnimatedOpacity(
            opacity: hideOverlay ? 0 : 1,
            duration: const Duration(milliseconds: 180),
            child: _Overlay(
              video: _video,
              avatar: _video.avatarUrl ?? _avatar,
              liked: _liked,
              likeCount: _details?.engagement.likeCount,
              commentCount: _commentCount,
              subscribed: _subscribed,
              isActive: widget.isActive,
              onLike: () => _setLiked(!_liked),
              onComments: () {
                final comments =
                    _comments ??= context.read<YtRepository>().comments(
                          widget.video.id,
                        );
                widget.onOpenComments(_video, comments);
              },
              onSubscribe: _toggleSubscribe,
              onChannel: () => widget.onOpenChannel(_video),
              onMenu: _openMenu,
            ),
          ),
        ),

        if (widget.isActive && !widget.clean)
          _MuteButton(video: widget.video),

        ValueListenableBuilder<Duration?>(
          valueListenable: _scrub,
          builder: (context, to, _) {
            if (to == null) return const SizedBox.shrink();
            final total = context.read<PlaybackController>().duration;
            return IgnorePointer(
              child: Center(
                child: Text(
                  '${clockLabel(to)} / ${clockLabel(total)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    shadows: _textShadow,
                  ),
                ),
              ),
            );
          },
        ),

        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: widget.isActive && !widget.commentsOpen
              ? _ShortProgress(video: widget.video, scrub: _scrub)
              : const SizedBox(height: 2),
        ),
      ],
    );
  }
}

class _Burst {
  _Burst(this.id, this.at);
  final int id;
  final Offset at;
}

/// The player surface for the Short on screen. Fades in on its first frame
/// over the poster rather than cutting to it.
class _ActiveShortPlayer extends StatefulWidget {
  const _ActiveShortPlayer({required this.video});

  final VideoBrief video;

  @override
  State<_ActiveShortPlayer> createState() => _ActiveShortPlayerState();
}

class _ActiveShortPlayerState extends State<_ActiveShortPlayer> {
  /// A spinner only after this long: most Shorts start before it would show,
  /// and a spinner flashed for 200ms reads as stutter.
  static const _spinnerDelay = Duration(milliseconds: 600);
  Timer? _spinnerTimer;
  bool _spinnerDue = false;
  bool _logged = false;

  @override
  void initState() {
    super.initState();
    _armSpinner();
  }

  @override
  void didUpdateWidget(_ActiveShortPlayer old) {
    super.didUpdateWidget(old);
    if (old.video.id != widget.video.id) {
      _logged = false;
      _armSpinner();
    }
  }

  void _armSpinner() {
    _spinnerTimer?.cancel();
    _spinnerDue = false;
    _spinnerTimer = Timer(_spinnerDelay, () {
      if (mounted) setState(() => _spinnerDue = true);
    });
  }

  @override
  void dispose() {
    _spinnerTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    final onThis = playback.current?.id == widget.video.id;
    final ready = onThis &&
        !kIsWeb &&
        playback.player != null &&
        playback.onShortsSurface &&
        !playback.isLoading;
    final started =
        ready && (playback.isPlaying || playback.position > Duration.zero);
    if (started && !_logged) {
      _logged = true;
      _ShortsTiming.firstFrame(widget.video.id);
    }
    final failed = onThis && playback.error != null;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (ready)
          AnimatedOpacity(
            opacity: started ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            // The Shorts page owns every gesture; the player is only a
            // picture here.
            child: IgnorePointer(
              child: BetterPlayer(
                key: playback.playerKey,
                controller: playback.player!,
              ),
            ),
          ),
        if (failed)
          const Center(
            child: Text(
              'This Short could not be played',
              style: TextStyle(color: Colors.white, shadows: _textShadow),
            ),
          )
        else if (!started && _spinnerDue)
          const Center(
            child: CircularProgressIndicator(color: Colors.white),
          ),
      ],
    );
  }
}

/// Play glyph while paused; a brief pause/play flash on each tap.
class _CentreGlyph extends StatelessWidget {
  const _CentreGlyph({required this.video, required this.seq});

  final VideoBrief video;
  final int seq;

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    final onThis = playback.current?.id == video.id &&
        playback.player != null &&
        !playback.isLoading;
    final paused = onThis && !playback.isPlaying;
    return Center(
      child: _Flash(
        key: ValueKey(seq),
        enabled: seq > 0,
        hold: paused,
        child: Container(
          width: 72,
          height: 72,
          decoration: const BoxDecoration(
            color: Colors.black38,
            shape: BoxShape.circle,
          ),
          child: Icon(
            paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            color: Colors.white,
            size: 48,
          ),
        ),
      ),
    );
  }
}

/// Scales and fades [child] in over ~200ms; stays while [hold], otherwise
/// fades out again.
class _Flash extends StatefulWidget {
  const _Flash({
    super.key,
    required this.enabled,
    required this.hold,
    required this.child,
  });

  final bool enabled;
  final bool hold;
  final Widget child;

  @override
  State<_Flash> createState() => _FlashState();
}

class _FlashState extends State<_Flash> {
  bool _shown = false;
  Timer? _off;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _shown = true);
      });
      _off = Timer(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => _shown = false);
      });
    }
  }

  @override
  void dispose() {
    _off?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.hold || _shown;
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      child: AnimatedScale(
        scale: visible ? 1 : 1.3,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// The double-tap heart, rising and fading where the finger landed.
class _HeartBurst extends StatefulWidget {
  const _HeartBurst({super.key, required this.at, required this.onDone});

  final Offset at;
  final VoidCallback onDone;

  @override
  State<_HeartBurst> createState() => _HeartBurstState();
}

class _HeartBurstState extends State<_HeartBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..forward().whenComplete(widget.onDone);

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const size = 96.0;
    return Positioned(
      left: widget.at.dx - size / 2,
      top: widget.at.dy - size / 2,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _anim,
          builder: (context, child) {
            final t = _anim.value;
            final scale = t < 0.3 ? 0.6 + t / 0.3 * 0.6 : 1.2 - (t - 0.3) * 0.3;
            final opacity = t < 0.6 ? 1.0 : 1 - (t - 0.6) / 0.4;
            return Transform.translate(
              offset: Offset(0, -40 * t),
              child: Transform.scale(
                scale: scale,
                child: Opacity(opacity: opacity.clamp(0.0, 1.0), child: child),
              ),
            );
          },
          child: const Icon(
            Icons.favorite,
            color: _shortsRed,
            size: size,
            shadows: _textShadow,
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: child,
        ),
      );
}

/// The speaker toggle YouTube shows on a paused Short. Session only.
class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.video});

  final VideoBrief video;

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    final onThis = playback.current?.id == video.id && !playback.isLoading;
    final show = onThis && (!playback.isPlaying || playback.shortsMuted);
    if (!show) return const SizedBox.shrink();
    return SafeArea(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: IconButton(
            tooltip: playback.shortsMuted ? 'Unmute' : 'Mute',
            onPressed: () => playback.setShortsMuted(!playback.shortsMuted),
            icon: Icon(
              playback.shortsMuted
                  ? Icons.volume_off_rounded
                  : Icons.volume_up_rounded,
              color: Colors.white,
              size: 28,
              shadows: _textShadow,
            ),
          ),
        ),
      ),
    );
  }
}

/// The thin red bar at the foot of a Short, which thickens and grows a thumb
/// under the finger or while paused, and scrubs on a horizontal drag. The
/// 24dp hit strip only claims horizontal gestures, so the vertical swipe to
/// the next Short still belongs to the PageView.
class _ShortProgress extends StatefulWidget {
  const _ShortProgress({required this.video, required this.scrub});

  final VideoBrief video;
  final ValueNotifier<Duration?> scrub;

  @override
  State<_ShortProgress> createState() => _ShortProgressState();
}

class _ShortProgressState extends State<_ShortProgress> {
  bool _touching = false;

  Duration _at(double dx, double width, Duration total) {
    final f = (dx / width).clamp(0.0, 1.0);
    return Duration(milliseconds: (total.inMilliseconds * f).round());
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    final onThis = playback.current?.id == widget.video.id;
    final player = onThis ? playback.player : null;
    final Listenable? video = player?.videoPlayerController;
    final paused = onThis && !playback.isPlaying && !playback.isLoading;
    final thick = _touching || paused;

    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) {
            final total = playback.duration;
            if (!onThis || total <= Duration.zero) return;
            setState(() => _touching = true);
            widget.scrub.value = _at(d.localPosition.dx, width, total);
          },
          onHorizontalDragUpdate: (d) {
            final total = playback.duration;
            if (!_touching || total <= Duration.zero) return;
            widget.scrub.value = _at(d.localPosition.dx, width, total);
          },
          onHorizontalDragEnd: (_) {
            final to = widget.scrub.value;
            widget.scrub.value = null;
            setState(() => _touching = false);
            if (to != null) unawaited(playback.seek(to));
          },
          onHorizontalDragCancel: () {
            widget.scrub.value = null;
            setState(() => _touching = false);
          },
          onTapUp: (d) {
            final total = playback.duration;
            if (!onThis || total <= Duration.zero) return;
            unawaited(playback.seek(_at(d.localPosition.dx, width, total)));
          },
          child: SizedBox(
            height: 24,
            width: width,
            child: AnimatedBuilder(
              animation: Listenable.merge([
                widget.scrub,
                ?video,
              ]),
              builder: (context, _) {
                final total = playback.duration;
                final dynamic controller = player?.videoPlayerController;
                final VideoPlayerValue? value =
                    controller?.value as VideoPlayerValue?;
                final position =
                    widget.scrub.value ?? value?.position ?? Duration.zero;
                final f = total > Duration.zero
                    ? (position.inMilliseconds / total.inMilliseconds)
                        .clamp(0.0, 1.0)
                    : 0.0;
                return _Bar(fraction: f, thick: thick);
              },
            ),
          ),
        );
      },
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.fraction, required this.thick});

  final double fraction;
  final bool thick;

  @override
  Widget build(BuildContext context) {
    final height = thick ? 4.0 : 2.0;
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.bottomLeft,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: height,
              width: width,
              color: Colors.white24,
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: height,
              width: width * fraction,
              color: _shortsRed,
            ),
            if (thick)
              Positioned(
                left: (width * fraction - 6).clamp(0.0, width - 12),
                bottom: height / 2 - 6,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: const BoxDecoration(
                    color: _shortsRed,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Channel, title and the action rail, over the video.
class _Overlay extends StatelessWidget {
  const _Overlay({
    required this.video,
    required this.avatar,
    required this.liked,
    required this.likeCount,
    required this.commentCount,
    required this.subscribed,
    required this.isActive,
    required this.onLike,
    required this.onComments,
    required this.onSubscribe,
    required this.onChannel,
    required this.onMenu,
  });

  final VideoBrief video;
  final String? avatar;
  final bool liked;
  final int? likeCount;
  final String? commentCount;
  final bool? subscribed;
  final bool isActive;
  final VoidCallback onLike;
  final VoidCallback onComments;
  final VoidCallback onSubscribe;
  final VoidCallback onChannel;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        // Clear of the progress strip at the bottom edge.
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 28),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ChannelLine(
                    video: video,
                    avatar: avatar,
                    subscribed: subscribed,
                    onChannel: onChannel,
                    onSubscribe: onSubscribe,
                  ),
                  const SizedBox(height: 10),
                  _ExpandableTitle(
                    key: ValueKey(video.id),
                    title: video.title,
                    views: video.viewCount,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _ActionRail(
              video: video,
              liked: liked,
              likeCount: likeCount,
              commentCount: commentCount,
              onLike: onLike,
              onComments: onComments,
              onMenu: onMenu,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelLine extends StatelessWidget {
  const _ChannelLine({
    required this.video,
    required this.avatar,
    required this.subscribed,
    required this.onChannel,
    required this.onSubscribe,
  });

  final VideoBrief video;
  final String? avatar;
  final bool? subscribed;
  final VoidCallback onChannel;
  final VoidCallback onSubscribe;

  @override
  Widget build(BuildContext context) {
    final name = video.author.trim();
    final handle = name.isEmpty
        ? ''
        : (name.startsWith('@') ? name : '@${name.replaceAll(' ', '')}');
    final initial = name.isEmpty ? '' : name.characters.first.toUpperCase();
    return Row(
      children: [
        GestureDetector(
          onTap: onChannel,
          child: CircleAvatar(
            radius: 16,
            backgroundColor: Colors.white24,
            backgroundImage:
                avatar == null ? null : CachedNetworkImageProvider(avatar!),
            child: avatar == null
                ? Text(
                    initial,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  )
                : null,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: GestureDetector(
            onTap: onChannel,
            child: Text(
              handle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                shadows: _textShadow,
              ),
            ),
          ),
        ),
        if (video.channelId.isNotEmpty && subscribed != null) ...[
          const SizedBox(width: 10),
          GestureDetector(
            onTap: onSubscribe,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: subscribed! ? Colors.white24 : Colors.white,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                subscribed! ? 'Subscribed' : 'Subscribe',
                style: TextStyle(
                  color: subscribed! ? Colors.white : Colors.black,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ExpandableTitle extends StatefulWidget {
  const _ExpandableTitle({super.key, required this.title, this.views});

  final String title;
  final int? views;

  @override
  State<_ExpandableTitle> createState() => _ExpandableTitleState();
}

class _ExpandableTitleState extends State<_ExpandableTitle> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: Colors.white,
      fontSize: 14,
      shadows: _textShadow,
    );
    return GestureDetector(
      onTap: () => setState(() => _open = !_open),
      child: AnimatedSize(
        duration: const Duration(milliseconds: 150),
        alignment: Alignment.bottomLeft,
        child: _open
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.title, style: style),
                  if (widget.views != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${compactCount(widget.views)} views',
                      style: style.copyWith(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ],
              )
            : LayoutBuilder(
                builder: (context, box) {
                  final painter = TextPainter(
                    text: TextSpan(text: widget.title, style: style),
                    maxLines: 1,
                    textDirection: Directionality.of(context),
                  )..layout(maxWidth: box.maxWidth);
                  final overflows = painter.didExceedMaxLines;
                  painter.dispose();
                  if (!overflows) {
                    return Text(widget.title, maxLines: 1, style: style);
                  }
                  return Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style,
                        ),
                      ),
                      Text(
                        'more',
                        style: style.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

class _ActionRail extends StatelessWidget {
  const _ActionRail({
    required this.video,
    required this.liked,
    required this.likeCount,
    required this.commentCount,
    required this.onLike,
    required this.onComments,
    required this.onMenu,
  });

  final VideoBrief video;
  final bool liked;
  final int? likeCount;
  final String? commentCount;
  final VoidCallback onLike;
  final VoidCallback onComments;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RailButton(
          icon: Icon(
            liked ? Icons.favorite : Icons.favorite_border,
            color: liked ? _shortsRed : Colors.white,
            size: 32,
            shadows: _textShadow,
          ),
          label: likeCount == null ? 'Like' : compactCount(likeCount),
          onTap: onLike,
        ),
        _RailButton(
          icon: const Icon(
            Icons.mode_comment_outlined,
            color: Colors.white,
            size: 32,
            shadows: _textShadow,
          ),
          label: commentCount ?? 'Comments',
          onTap: onComments,
        ),
        _RailButton(
          icon: Transform.flip(
            flipX: true,
            child: const Icon(
              Icons.reply_rounded,
              color: Colors.white,
              size: 32,
              shadows: _textShadow,
            ),
          ),
          label: 'Share',
          onTap: () => SharePlus.instance.share(
            ShareParams(
              uri: Uri.parse('https://youtube.com/shorts/${video.id}'),
            ),
          ),
        ),
        _RailButton(
          icon: const Icon(
            Icons.playlist_add_rounded,
            color: Colors.white,
            size: 32,
            shadows: _textShadow,
          ),
          label: 'Save',
          onTap: () => showSaveToPlaylistSheet(context, video),
        ),
        _RailButton(
          icon: const Icon(
            Icons.more_vert,
            color: Colors.white,
            size: 32,
            shadows: _textShadow,
          ),
          label: '',
          onTap: onMenu,
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

  final Widget icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkResponse(
        onTap: onTap,
        radius: 32,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              icon,
              if (label.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    shadows: _textShadow,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
