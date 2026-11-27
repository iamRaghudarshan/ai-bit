import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../data/custom_feeds.dart';
import '../data/interests.dart';
import '../data/kids_guard.dart';
import '../data/settings.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../data/yt_repository.dart';
import 'app_lock_page.dart';
import 'interests_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'watch_page.dart';
import '../data/battery_service.dart';
import '../data/network_service.dart';
import '../data/ranker_trainer.dart';
import '../player/playback_controller.dart';
import 'widgets/cast_button.dart';
import 'widgets/feed_impressions.dart';
import 'widgets/feed_preview.dart';
import 'widgets/responsive_feed.dart';
import 'widgets/sheets.dart';
import 'widgets/shorts_shelf.dart';
import 'widgets/video_tile.dart';

/// Landing screen — opens straight into a feed, the way the YouTube app does.
///
/// The feed is personalised from local watch history (recent channels first)
/// and topped up with popular topics, so a fresh install still shows something.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage>
    with AutomaticKeepAliveClientMixin {
  List<VideoBrief> _feed = const [];
  List<HistoryEntry> _continue = const [];
  bool _loading = true;
  String? _error;
  int _refreshToken = 0;
  String _category = _CategoryChips.all;

  /// True when the Subscribed chip found nothing followed on this device.
  ///
  /// Kept apart from [_error] because it is not a failure: an empty feed here
  /// needs an invitation to subscribe, not a Retry button that would fetch
  /// nothing again.
  bool _noSubscriptions = false;

  /// The interest signals the visible feed was built from.
  ///
  /// The tab is built once at startup and kept alive, so a feed loaded before
  /// the user had searched for anything stayed on screen for the rest of the
  /// session — which read as "recommendations don't work". Coming back to Home
  /// now compares the signals and refetches only when they have moved, so a
  /// plain tab switch stays instant.
  String _signals = '';

  /// Owns the muted feed preview. Built here rather than provided globally
  /// because it must die with this screen: a preview player outliving the feed
  /// is a decoder nobody can see and nobody can stop.
  FeedPreviewCoordinator? _previews;

  /// Feature vectors for the feed currently on screen, keyed by video id.
  ///
  /// Held until a card is actually seen — an offer the user never scrolled to
  /// is not an observation about the ranker's judgement, and training on it
  /// would teach the model that its own unseen suggestions were rejected.
  /// Mutable on purpose: entries are removed as they are used.
  Map<String, List<double>> _pendingFeatures = <String, List<double>>{};

  /// True while another page is being fetched, so the near-end callback —
  /// which fires on every build of the last few rows, not once — does not
  /// start a dozen overlapping loads.
  bool _loadingMore = false;

  /// Set when a page comes back with nothing new to add, so the feed stops
  /// asking. Without it, reaching a genuine end means retrying for ever
  /// against sources that have no more to give.
  bool _feedExhausted = false;

  /// How many consecutive pages may add nothing before giving up.
  ///
  /// Not one: the sources rotate per page, so a single barren page is normal
  /// — a different window of the same channels can legitimately be all
  /// duplicates — while three in a row means there is genuinely nothing left.
  static const _emptyPagesBeforeStopping = 3;
  int _emptyPages = 0;

  /// Counts which feed cards were actually on screen, for the ranker's
  /// impression feature. Built here and disposed with the screen so a pending
  /// batch is flushed rather than dropped on the way out.
  FeedImpressionRecorder? _impressions;

  /// The feed's one scroll view, header included — re-tapping Home uses it to
  /// go back to the top.
  final _scroll = ScrollController();
  final _refreshKey = GlobalKey<RefreshIndicatorState>();

  /// Watched fraction per video id, for the red resume bar on each card.
  /// Read in one query for the whole feed and refreshed on arrival and on
  /// the way back from a video, rather than looked up per card.
  Map<String, double> _progress = const {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    // Asked once, after the first frame so the feed is already loading behind
    // it. Without this the interests screen was buried in Settings and
    // defaulted to empty, which meant the ranker had nothing to work with on
    // a fresh install and the feed looked exactly as it did before the
    // recommender existed — reported, accurately, as "recommendations are not
    // working".
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAskInterests());
  }

  /// Offers the interests picker on first launch.
  ///
  /// Skipped in Kids mode, which does not consult interests at all, and
  /// recorded as asked either way so declining is respected rather than
  /// re-prompted on every launch.
  Future<void> _maybeAskInterests() async {
    if (!mounted) return;
    final settings = context.read<SettingsService>();
    if (settings.askedForInterests || settings.kidsMode) return;
    if (settings.interestTopics.isNotEmpty) {
      // Already chosen some other way; nothing to ask.
      settings.askedForInterests = true;
      return;
    }
    settings.askedForInterests = true;

    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('What do you want to watch?'),
        content: const Text(
          'Pick a few topics and your home feed starts off relevant instead '
          'of generic. You can change them any time in Settings, and it also '
          'learns from what you actually watch.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Pick topics'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await InterestsPage.open(context);
    // Reload so the choice shows immediately rather than on the next visit.
    if (mounted) await _load(reset: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _previews ??= FeedPreviewCoordinator(
      repository: context.read<YtRepository>(),
      settings: context.read<SettingsService>(),
      playback: context.read<PlaybackController>(),
      network: _networkOrNull(),
      battery: _batteryOrNull(),
    );
    _impressions ??= FeedImpressionRecorder(
      database: context.read<AppDatabase>(),
      settings: context.read<SettingsService>(),
    );
  }

  /// NetworkService is optional the way the other injected services are, so a
  /// harness that provides only the essentials still renders Home.
  NetworkService? _networkOrNull() {
    try {
      return context.read<NetworkService>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  BatteryService? _batteryOrNull() {
    try {
      return context.read<BatteryService>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  void dispose() {
    _previews?.dispose();
    _impressions?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    setState(() {
      // A mode or category change is a different feed, so show the skeleton
      // rather than leaving the old rows up while the new ones fetch. A plain
      // refresh keeps them (the pull-to-refresh spinner covers that).
      _loading = reset || _feed.isEmpty;
      if (reset) _feed = const [];
      // A new feed is not exhausted, whatever the old one was.
      _feedExhausted = false;
      _emptyPages = 0;
      _error = null;
      _noSubscriptions = false;
    });
    try {
      final repo = context.read<YtRepository>();

      // The Continue-watching shelf belongs only to the personalised feed.
      if (context.read<SettingsService>().kidsMode ||
          _category != _CategoryChips.all) {
        _continue = const [];
      }

      // Kids mode takes over the whole feed, regardless of the chosen category
      // chip, so nothing but curated kid content shows.
      if (context.read<SettingsService>().kidsMode) {
        final feed = await repo.homeFeed(
          refreshToken: _refreshToken,
          kids: true,
        );
        if (!mounted) return;
        setState(() {
          _feed = feed;
          _loading = false;
          _error = feed.isEmpty ? 'Nothing came back.' : null;
        });
        return;
      }

      // Subscribed builds the feed only from channels followed on this
      // device — the local subscriptions table, since there is no account to
      // read real subscriptions from.
      if (_category == _CategoryChips.subscribed) {
        final channels = await context.read<AppDatabase>().subscriptions();
        if (!mounted) return;
        if (channels.isEmpty) {
          setState(() {
            _feed = const [];
            _loading = false;
            _noSubscriptions = true;
          });
          return;
        }
        final feed = await repo.subscribedFeed(channels: channels);
        if (!mounted) return;
        setState(() {
          _feed = feed;
          _loading = false;
          _error = feed.isEmpty
              ? 'No recent uploads from the channels you follow.'
              : null;
        });
        return;
      }

      // A feed the user described themselves. Ranked like every other feed —
      // the words decide what is fetched, not how it is ordered — so it still
      // sinks what has been watched and spreads the channels out rather than
      // being a search results page with a chip on it.
      if (_CategoryChips.isCustom(_category)) {
        final name = _CategoryChips.customName(_category);
        final feed = context
            .read<SettingsService>()
            .customFeeds
            .where((f) => f.name == name)
            .firstOrNull;
        if (feed == null) {
          // Deleted while selected. Fall back rather than showing an error
          // for a chip that is no longer there.
          setState(() {
            _category = _CategoryChips.all;
            _loading = true;
          });
          await _load(reset: true);
          return;
        }
        final settingsNow = context.read<SettingsService>();
        final db = context.read<AppDatabase>();
        final profile = await db.tasteProfile(
          interestQueries: interestQueries(settingsNow.interestTopics),
        );
        final impressions = await db.feedImpressions();
        if (!mounted) return;
        final rows = await repo.customFeed(
          queries: feed.queries,
          profile: profile,
          impressions: impressions,
          weights: context.read<RankerTrainer>().weights,
          feedLanguages: settingsNow.feedLanguages,
          refreshToken: _refreshToken,
        );
        if (!mounted) return;
        setState(() {
          _feed = rows;
          _loading = false;
          _error = rows.isEmpty
              ? 'Nothing came back for "${feed.name}". Try different words.'
              : null;
        });
        return;
      }

      // Trending is the closest thing available without the official Data API:
      // several popular topics, each sorted by view count, interleaved.
      if (_category == _CategoryChips.trending) {
        final feed = await repo.trending(refreshToken: _refreshToken);
        if (!mounted) return;
        setState(() {
          _feed = feed;
          _loading = false;
          _error = feed.isEmpty ? 'Nothing trending came back.' : null;
        });
        return;
      }

      // Any other chosen category is a topic search; "All" is the
      // personalised feed.
      if (_category != _CategoryChips.all) {
        final feed = await repo.search(_category, sortByViews: true);
        if (!mounted) return;
        setState(() {
          _feed = feed;
          _loading = false;
          _error = feed.isEmpty ? 'Nothing came back for $_category.' : null;
        });
        return;
      }

      final db = context.read<AppDatabase>();
      final seeds = await db.feedSeeds();
      final searches = await db.recentSearches();
      if (!mounted) return;
      _signals = _signature(searches, seeds.channelIds);
      final resumeable = await db.continueWatching();
      if (!mounted) return;
      _continue = resumeable;
      final subscribed = await db.subscriptions();
      if (!mounted) return;
      // What the ranker orders against. Built here and passed down rather than
      // read inside the repository, so the repository stays a thing that
      // fetches videos and knows nothing about the database.
      // Kids mode never consults the adult's declared interests, for the same
      // reason it never consults their history.
      final settingsNow = context.read<SettingsService>();
      final kidsNow = settingsNow.kidsMode;
      final chosenInterests =
          kidsNow ? const <String>[] : settingsNow.interestTopics;
      final profile = await db.tasteProfile(
        interestQueries: interestQueries(chosenInterests),
      );
      final impressions = await db.feedImpressions();
      final graph = kidsNow
          ? const <VideoBrief>[]
          : await db.coVisitCandidates(seeds.videoIds);
      if (!mounted) return;
      final trainer = context.read<RankerTrainer>();
      // The features each card was scored on, captured as it is ranked. They
      // have to be taken now rather than recomputed when the user acts: by
      // then the profile has moved and the numbers would describe a different
      // world from the one they reacted to.
      final features = <String, List<double>>{};
      final feed = await repo.homeFeed(
        channelIds: seeds.channelIds,
        searches: searches,
        subscribedIds: [for (final c in subscribed) c.id],
        // Recently watched videos, used to ask YouTube what people watch after
        // them. The strongest candidate source available without an account.
        coWatchSeeds: seeds.videoIds,
        profile: profile,
        impressions: impressions,
        weights: trainer.weights,
        featuresOut: features,
        interests: chosenInterests,
        feedLanguages: kidsNow ? const [] : settingsNow.feedLanguages,
        graphCandidates: graph,
        refreshToken: _refreshToken,
        kids: kidsNow,
      );
      if (!mounted) return;
      setState(() {
        _feed = feed;
        _loading = false;
        _error = feed.isEmpty ? 'Nothing came back from YouTube.' : null;
      });
      _pendingFeatures = features;
      // Trained after the feed is on screen, never before it: a training pass
      // is cheap but nothing the user is waiting for should queue behind it.
      unawaited(trainer.train());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the feed. Check your connection.';
      });
    } finally {
      // Every path above — including its early returns — lands a new feed,
      // and the resume bars are per video, so they are re-read for it.
      if (mounted) unawaited(_refreshProgress());
    }
  }

  /// Re-reads the resume bars for every video in the feed, in one query.
  Future<void> _refreshProgress() async {
    final ids = [for (final v in _feed) v.id];
    if (ids.isEmpty) return;
    try {
      final progress = await context.read<AppDatabase>().watchProgress(ids);
      if (!mounted) return;
      if (_sameProgress(progress, _progress)) return;
      setState(() => _progress = progress);
    } catch (e) {
      // A missing bar is cosmetic; the feed itself is fine. Logged so a bar
      // that never appears is traceable.
      debugPrint('AI BIT: resume bars not read - $e');
    }
  }

  static bool _sameProgress(Map<String, double> a, Map<String, double> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  Future<void> _refresh() async {
    _refreshToken++;
    await _load();
  }

  /// Asks for a name and some topics, and saves a custom feed.
  Future<void> _createCustomFeed() async {
    final settings = context.read<SettingsService>();
    if (settings.customFeeds.length >= maxCustomFeeds) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That is as many feeds as the row will hold.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final created = await _feedDialog();
    if (created == null || !mounted) return;
    settings.customFeeds = [...settings.customFeeds, created];
    setState(() => _category = _CategoryChips.customKey(created.name));
    await _load(reset: true);
  }

  /// Long-press on a custom chip: rename, change the topics, or delete.
  Future<void> _editCustomFeed(CustomFeed feed) async {
    final action = await showModalBottomSheet<String>(
      useRootNavigator: true,
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text('Edit "${feed.name}"'),
              onTap: () => Navigator.pop(sheetContext, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete feed'),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final settings = context.read<SettingsService>();

    if (action == 'delete') {
      settings.customFeeds =
          settings.customFeeds.where((f) => f.name != feed.name).toList();
      if (!mounted) return;
      setState(() => _category = _CategoryChips.all);
      await _load(reset: true);
      return;
    }

    final edited = await _feedDialog(existing: feed);
    if (edited == null || !mounted) return;
    settings.customFeeds = [
      for (final f in settings.customFeeds)
        if (f.name == feed.name) edited else f,
    ];
    setState(() => _category = _CategoryChips.customKey(edited.name));
    await _load(reset: true);
  }

  /// The name-and-topics dialog, shared by create and edit.
  ///
  /// Returns null when cancelled or when what was typed cannot make a feed —
  /// the Save button is disabled in that case, so this is belt and braces.
  Future<CustomFeed?> _feedDialog({CustomFeed? existing}) {
    final nameController = TextEditingController(text: existing?.name ?? '');
    final queryController = TextEditingController(text: existing?.query ?? '');
    return showDialog<CustomFeed>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (builderContext, setDialogState) {
          final candidate = CustomFeed(
            name: nameController.text,
            query: queryController.text,
          );
          return AlertDialog(
            title: Text(existing == null ? 'New feed' : 'Edit feed'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: existing == null,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'Homelab',
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: queryController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Topics',
                    hintText: 'self hosting, proxmox, home server',
                    helperText: 'Separate different topics with commas',
                    helperMaxLines: 2,
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: candidate.isUsable
                    ? () => Navigator.pop(dialogContext, candidate)
                    : null,
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
      // Disposed here rather than in the builder: the builder runs on every
      // keystroke, and disposing a controller still in use is a crash.
    ).whenComplete(() {
      nameController.dispose();
      queryController.dispose();
    });
  }

  /// The strip under the last row: a spinner while loading, a quiet line when
  /// there is genuinely nothing more, and nothing at all otherwise.
  Widget? _feedFooter() {
    if (_category != _CategoryChips.all) return null;
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_feedExhausted && _feed.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Center(
          child: Text(
            'That is everything for now. Pull down to refresh.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      );
    }
    return null;
  }

  /// Fetches another page and appends what is new.
  ///
  /// The home feed had no pagination at all: it showed one batch and then
  /// simply ended, while Shorts had loaded more on scroll since it was
  /// written. Scrolling to a hard stop after a screen or two is itself a
  /// complaint about recommendations — there were more to be had, the app
  /// just never asked.
  ///
  /// Pages come from advancing the refresh token, which is what rotates the
  /// window over every candidate source, so each page consults different
  /// channels, searches and co-watch seeds rather than re-ranking the same
  /// pool.
  Future<void> _loadMore() async {
    if (_loadingMore || _feedExhausted || _loading) return;
    if (_category != _CategoryChips.all) return;
    if (_feed.isEmpty) return;
    _loadingMore = true;
    setState(() {});

    try {
      final repo = context.read<YtRepository>();
      final db = context.read<AppDatabase>();
      final settingsNow = context.read<SettingsService>();
      final kidsNow = settingsNow.kidsMode;
      final seeds = await db.feedSeeds();
      final searches = await db.recentSearches();
      if (!mounted) return;
      final subscribed = await db.subscriptions();
      if (!mounted) return;
      final chosenInterests =
          kidsNow ? const <String>[] : settingsNow.interestTopics;
      final profile = await db.tasteProfile(
        interestQueries: interestQueries(chosenInterests),
      );
      final impressions = await db.feedImpressions();
      final graph = kidsNow
          ? const <VideoBrief>[]
          : await db.coVisitCandidates(seeds.videoIds);
      if (!mounted) return;

      _refreshToken++;
      final features = <String, List<double>>{};
      final page = await repo.homeFeed(
        channelIds: seeds.channelIds,
        searches: searches,
        subscribedIds: [for (final c in subscribed) c.id],
        coWatchSeeds: seeds.videoIds,
        profile: profile,
        impressions: impressions,
        weights: context.read<RankerTrainer>().weights,
        featuresOut: features,
        interests: chosenInterests,
        feedLanguages: kidsNow ? const [] : settingsNow.feedLanguages,
        graphCandidates: graph,
        refreshToken: _refreshToken,
        kids: kidsNow,
      );
      if (!mounted) return;

      final seen = _feed.map((v) => v.id).toSet();
      final fresh = [for (final v in page) if (seen.add(v.id)) v];
      if (fresh.isEmpty) {
        _emptyPages++;
        if (_emptyPages >= _emptyPagesBeforeStopping) _feedExhausted = true;
      } else {
        _emptyPages = 0;
        _pendingFeatures.addAll(features);
      }
      setState(() => _feed = [..._feed, ...fresh]);
      if (fresh.isNotEmpty) unawaited(_refreshProgress());
    } catch (e) {
      // Running out is not an error worth a banner: the rows already on
      // screen are fine and the user is mid-scroll. Logged rather than
      // swallowed so a permanently failing page is findable.
      debugPrint('AI BIT: could not load more feed - $e');
      _emptyPages++;
      if (_emptyPages >= _emptyPagesBeforeStopping) _feedExhausted = true;
    } finally {
      _loadingMore = false;
      if (mounted) setState(() {});
    }
  }

  /// One feed card came far enough onto the screen to count as offered.
  ///
  /// Only the personalised feed counts. A topic chip, Trending and the
  /// Subscribed list are not recommendations, so nothing in them should be
  /// demoted for having appeared — the recorder itself additionally refuses
  /// while incognito or Kids mode is on.
  /// Removes a dismissed video, and anything else from the same channel if
  /// the whole channel was dismissed, without refetching.
  ///
  /// Only the visible list is touched. The dismissal itself is already in the
  /// database, so the next load excludes it at ranking time whether or not
  /// this ran.
  void _dismissFromFeed(VideoBrief video) {
    if (!mounted) return;
    setState(() {
      _feed = [for (final v in _feed) if (v.id != video.id) v];
    });
  }

  void _onCardSeen(String videoId, int rank) {
    if (_category != _CategoryChips.all) return;
    _impressions?.markSeen(videoId, rank);

    // The same moment is when this card becomes a training example: it was
    // offered, it was seen, and whether it gets opened is the label.
    //
    // Taken out of the pending map as it is used, so scrolling a card off and
    // back on issues one write rather than one per sighting. The insert
    // ignores duplicates anyway, but a fling should not queue a dozen of them.
    final features = _pendingFeatures.remove(videoId);
    if (features == null || !mounted) return;
    final settings = context.read<SettingsService>();
    if (settings.incognito || settings.kidsMode) return;
    unawaited(
      context
          .read<AppDatabase>()
          .recordRankingExamples({videoId: features}).catchError((Object e) {
        debugPrint('AI BIT: ranking example not recorded - $e');
      }),
    );
  }

  static String _signature(List<String> searches, List<String> channelIds) =>
      '${searches.join('|')}##${channelIds.join('|')}';

  /// Tapping Home while already on Home: reload, the way the real app does.
  ///
  /// Distinct from [onTabOpened], which is a cheap "did anything change?"
  /// check for arriving from another tab. This one is a deliberate ask for
  /// fresh rows, so it rotates the window as a pull-to-refresh would rather
  /// than returning the identical feed and looking broken.
  Future<void> reloadFeed() async {
    _refreshToken++;
    await _load(reset: true);
  }

  /// Tapping Home while already on Home, YouTube's way: scrolled down, it
  /// glides back to the top (the floating header comes back with it); already
  /// at the top, it refreshes in place under the pull-to-refresh spinner —
  /// the rows stay up while the new ones fetch, rather than wiping to the
  /// skeleton the way [reloadFeed] does.
  void onReselected() {
    if (_scroll.hasClients && _scroll.offset > 0) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    final indicator = _refreshKey.currentState;
    if (indicator != null) {
      indicator.show();
    } else {
      _refresh();
    }
  }

  /// Called by the shell when Home is selected again.
  Future<void> onTabOpened() async {
    // Something may have been watched from another tab.
    unawaited(_refreshProgress());
    // Coming back to an empty Subscribed feed is almost always the return trip
    // from a channel page where something was just subscribed to, so refetch
    // that one case. A populated Subscribed feed is left alone: refetching it
    // is fifteen browse requests, too expensive for a plain tab switch.
    if (_category == _CategoryChips.subscribed) {
      if (_feed.isEmpty) await _load(reset: true);
      return;
    }
    if (_category != _CategoryChips.all) return;
    final db = context.read<AppDatabase>();
    final seeds = await db.feedSeeds();
    final searches = await db.recentSearches();
    if (!mounted) return;
    if (_signature(searches, seeds.channelIds) == _signals) return;
    await _load();
  }

  /// The Kids allowance tracker, or null when the app was built without one
  /// in the widget tree.
  ///
  /// KidsGuard is injected by main.dart the same way PlaybackController takes
  /// it — optionally. Looked up with a catch rather than assumed present so
  /// Home still renders in a harness that provides only the essentials, and
  /// logged rather than swallowed, because a countdown that silently never
  /// appears is exactly the dead feature a bare catch has hidden here before.
  KidsGuard? _kidsGuard(BuildContext context) {
    try {
      return Provider.of<KidsGuard>(context);
    } on ProviderNotFoundException {
      // Once per session, not once per rebuild: this runs on every build of
      // Home, and a line repeated that often would drown the log it exists to
      // help.
      if (!_loggedMissingGuard) {
        _loggedMissingGuard = true;
        debugPrint('AI BIT: no KidsGuard provided - daily limit UI is off.');
      }
      return null;
    }
  }

  static bool _loggedMissingGuard = false;

  /// Heights of the pieces under the toolbar, fixed so the floating header
  /// is a known size — a SliverAppBar's bottom must declare its height up
  /// front, and the pull-to-refresh spinner is offset by the same total.
  static const _toolbarHeight = 48.0;
  static const _chipsHeight = 48.0;
  static const _kidsBarHeight = 28.0;
  static const _previewBannerHeight = 32.0;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // `select`, not `watch`: SettingsService notifies on every setter — a
    // quality change or a remembered speed on the watch page — and watching
    // it rebuilt the whole Home scaffold and feed under the player each time.
    final settings = context.read<SettingsService>();
    final kids = context.select<SettingsService, bool>((s) => s.kidsMode);
    final guard = _kidsGuard(context);
    // A spent allowance replaces the feed rather than the whole screen, so the
    // mode switch stays reachable for a grown-up with the PIN.
    final timeUp = kids && (guard?.limitReached ?? false);
    final showKidsBar = kids && guard != null && guard.hasLimit && !timeUp;

    final double bottomHeight =
        (YtRepository.isPreview ? _previewBannerHeight : 0.0) +
            (showKidsBar ? _kidsBarHeight : 0.0) +
            (kids ? 0.0 : _chipsHeight);

    final appBar = SliverAppBar(
      // The bar and the chip row scroll away together on the way down and
      // snap back whole on the first movement up — YouTube's header. One
      // scroll view for header and feed is what makes that possible.
      floating: true,
      snap: true,
      // The status bar is kept clear by the SafeArea around the scroll view,
      // so content never scrolls up underneath the clock.
      primary: false,
      toolbarHeight: _toolbarHeight,
      titleSpacing: 12,
      title: _ModeSwitch(
        kids: kids,
        onChanged: (wantsKids) async {
          // The one and only write site for kidsMode, so the guard below is
          // the whole rule and cannot be walked around from elsewhere.
          //
          // Turning Kids mode ON is free. Turning it OFF is the move a child
          // makes to get out of it, so that is the direction the PIN guards.
          // AppLockPage.confirmKidsPin is the same PIN pad the app lock uses
          // — a second, free-text prompt for this used to live here, and two
          // different-looking asks for one action read as a bug. It returns
          // true when no Kids PIN is set, which is exactly the unguarded
          // case, so there is no separate branch for it.
          if (!wantsKids && !await AppLockPage.confirmKidsPin(context)) {
            // Cancelled or wrong: stay in Kids mode, and say nothing more —
            // the pad already reported the wrong PIN without dismissing.
            return;
          }
          if (!mounted) return;
          settings.kidsMode = wantsKids;
          // Reset to All and reload with the skeleton, so the switch reads as
          // an instant change rather than a frozen old feed.
          _category = _CategoryChips.all;
          _load(reset: true);
        },
      ),
      actions: [
        if (CastButton.isSupported)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Center(child: CastButton(size: 24)),
          ),
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'Search',
          onPressed: () => SearchPage.open(context),
        ),
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: 'Settings',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
          ),
        ),
        const SizedBox(width: 4),
      ],
      bottom: bottomHeight == 0
          ? null
          : PreferredSize(
              preferredSize: Size.fromHeight(bottomHeight),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (YtRepository.isPreview)
                    const SizedBox(
                      height: _previewBannerHeight,
                      child: _PreviewBanner(),
                    ),
                  // The countdown is a thin strip, not a dialog: it should be
                  // glanceable without interrupting anything. Hidden once the
                  // time is up, since the panel below then says so in full.
                  if (showKidsBar)
                    SizedBox(
                      height: _kidsBarHeight,
                      child: _KidsTimeBar(
                        remainingSeconds: guard.remainingSeconds,
                      ),
                    ),
                  // Category chips are meaningless in Kids mode, where the
                  // whole feed is curated. No divider under them: YouTube's
                  // chip row sits straight on the feed.
                  if (!kids)
                    SizedBox(
                      height: _chipsHeight,
                      child: _CategoryChips(
                        selected: _category,
                        customFeeds: decodeCustomFeeds(
                          context.select<SettingsService, String>(
                            (s) => s.customFeedsRaw,
                          ),
                        ),
                        onCreateFeed: _createCustomFeed,
                        onEditFeed: _editCustomFeed,
                        onSelected: (value) {
                          setState(() => _category = value);
                          _load(reset: true);
                        },
                      ),
                    ),
                ],
              ),
            ),
    );

    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        // Previews follow the scroll: silenced the moment a drag or fling
        // starts and allowed again only once it has settled. See
        // FeedPreviewCoordinator.onScrolling. Depth 0 is the feed's own
        // scroll view, which now also carries the header; the shelves and
        // the chip row are horizontal and nested, and are ignored.
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
            if (n is ScrollStartNotification) _previews?.onScrolling(true);
            if (n is ScrollEndNotification) _previews?.onScrolling(false);
            return false;
          },
          child: RefreshIndicator(
            key: _refreshKey,
            onRefresh: _refresh,
            // Drawn under the header rather than over the mode switch.
            edgeOffset: _toolbarHeight + bottomHeight,
            // Neutral, as YouTube's is; the accent is for progress, not for
            // a spinner.
            color: scheme.onSurface,
            backgroundColor: scheme.surfaceContainerHigh,
            notificationPredicate: (n) =>
                n.depth == 0 && n.metrics.axis == Axis.vertical,
            child: CustomScrollView(
              controller: _scroll,
              // Pull-to-refresh has to work on a short page too — the
              // skeleton, an error, or a feed of three.
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                appBar,
                if (timeUp)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: _KidsTimeUp(),
                  )
                else
                  ..._feedSlivers(kids: kids),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The feed under the header: skeleton, empty state, or the cards.
  List<Widget> _feedSlivers({required bool kids}) {
    if (_loading) return const [FeedSkeleton(count: 4, sliver: true)];
    if (_feed.isEmpty) {
      // Nothing followed yet is not a broken feed, so it gets an invitation
      // and a way back to All rather than a Retry that would fetch nothing
      // again.
      final empty = _noSubscriptions
          ? EmptyState(
              icon: Icons.subscriptions_outlined,
              title: 'No subscriptions yet',
              message: 'Open any channel and tap Subscribe. Their newest '
                  'videos will fill this feed.\n\nSubscriptions live on this '
                  'device only, not in a Google account — this app has no '
                  'sign-in.',
              action: FilledButton(
                onPressed: () {
                  setState(() => _category = _CategoryChips.all);
                  _load(reset: true);
                },
                child: const Text('Back to All'),
              ),
            )
          : EmptyState(
              icon: Icons.wifi_off_outlined,
              title: 'Feed unavailable',
              message: _error,
              action: FilledButton(
                onPressed: _refresh,
                child: const Text('Retry'),
              ),
            );
      return [
        SliverToBoxAdapter(
          child: Padding(padding: const EdgeInsets.only(top: 80), child: empty),
        ),
      ];
    }

    final previews = _previews;
    // The rank a card is drawn at is what decides how much a skipped
    // impression costs, so it has to come from the feed order rather than be
    // guessed at from the video.
    final rankOf = <String, int>{
      for (var i = 0; i < _feed.length; i++) _feed[i].id: i,
    };
    Widget card(VideoBrief video, {bool inGrid = false}) {
      void menu() => showVideoMenu(
            context,
            video,
            // Taking the card away is the feedback. A dismissal that left the
            // row sitting there reads as the button having done nothing, and
            // the next feed load is the soonest it would otherwise disappear.
            onDismissed: () => _dismissFromFeed(video),
          );
      final tile = VideoCard(
        video: video,
        inGrid: inGrid,
        progress: _progress[video.id] ?? 0,
        onTap: () async {
          // Stopped before opening: the watch page is about to take the audio
          // session, and two players negotiating it at once is how the
          // notification ends up showing the wrong video.
          previews?.stop();
          await WatchPage.open(context, video);
          // Back from the video (or minimised it): its resume bar moved.
          if (mounted) unawaited(_refreshProgress());
        },
        onMenu: menu,
        previewOverlay: previews == null
            ? null
            : FeedPreviewSurface(video: video, coordinator: previews),
      );
      // Always wrapped, even with no preview coordinator: the slot is also
      // how an impression gets counted, and that has to work on every
      // platform previews do not.
      return FeedPreviewSlot(
        video: video,
        coordinator: previews,
        onSeen: _onCardSeen,
        rank: rankOf[video.id] ?? 0,
        seenFraction: FeedImpressionRecorder.seenFraction,
        child: tile,
      );
    }

    final footer = _feedFooter();
    return [
      if (_continue.isNotEmpty)
        SliverToBoxAdapter(
          child: _ContinueWatchingShelf(
            entries: _continue,
            onOpened: () async {
              // Refresh the shelf when returning from a video.
              final resumeable =
                  await context.read<AppDatabase>().continueWatching();
              if (mounted) setState(() => _continue = resumeable);
              unawaited(_refreshProgress());
            },
          ),
        ),
      // Phones keep a single column; wider screens (tablets, foldables,
      // landscape) fan the feed out into a multi-column grid the way YouTube
      // does on a big screen.
      SliverVideoFeed(
        videos: _feed,
        onNearEnd: _category == _CategoryChips.all ? _loadMore : null,
        insert: _shortsShelf(kids: kids),
        insertAfter: 2,
        listItemBuilder: (context, index) => card(_feed[index]),
        gridItemBuilder: (context, index) => card(_feed[index], inGrid: true),
      ),
      if (footer != null) SliverToBoxAdapter(child: footer),
    ];
  }

  /// The Shorts shelf, on the personalised feed and in Kids mode only — a
  /// topic chip, Trending and Subscribed are lists the user asked for by
  /// name, and a row of Shorts in them would be noise.
  Widget? _shortsShelf({required bool kids}) {
    if (!kids && _category != _CategoryChips.all) return null;
    return const ShortsShelf();
  }
}

/// Horizontal topic filter across the top of the feed, mirroring the real
/// app's chip row.
/// Horizontal "Continue watching" row of partly-watched videos with a resume
/// bar, shown at the top of the personalised feed.
class _ContinueWatchingShelf extends StatelessWidget {
  const _ContinueWatchingShelf({required this.entries, required this.onOpened});

  final List<HistoryEntry> entries;
  final Future<void> Function() onOpened;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Text(
            'Continue watching',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.text(context),
            ),
          ),
        ),
        SizedBox(
          height: 168,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final entry = entries[i];
              return SizedBox(
                width: 200,
                // InkWell rather than a bare GestureDetector, so a press shows
                // the same flat highlight as every other card.
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  splashFactory: NoSplash.splashFactory,
                  highlightColor: AppColors.pressHighlight(context),
                  onTap: () async {
                    await WatchPage.open(context, entry.video);
                    await onOpened();
                  },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      VideoThumb(video: entry.video, progress: entry.progress),
                      const SizedBox(height: 6),
                      Text(
                        entry.video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                          color: AppColors.text(context),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const Divider(height: 24),
      ],
    );
  }
}

/// The pill toggle in the top bar: normal AI BIT on the left, Kids on the
/// right. Default is normal; tapping a side switches the whole app's feed.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.kids, required this.onChanged});

  final bool kids;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      // 32dp, the height of YouTube's top-bar pills and chips.
      height: 32,
      decoration: BoxDecoration(
        color: AppColors.chip(context),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segment(context, label: 'AI BIT', icon: Icons.play_arrow_rounded, selected: !kids, onTap: () => onChanged(false)),
          _segment(context, label: 'Kids', icon: Icons.child_care, selected: kids, onTap: () => onChanged(true)),
        ],
      ),
    );
  }

  Widget _segment(
    BuildContext context, {
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final fg = AppColors.text(context);
    // Kids side gets a friendly green; normal side the brand red.
    final activeColor = label == 'Kids' ? const Color(0xFF34A853) : AppColors.brand;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? activeColor : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: selected ? Colors.white : fg),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
                color: selected ? Colors.white : fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryChips extends StatelessWidget {
  const _CategoryChips({
    required this.selected,
    required this.onSelected,
    this.customFeeds = const [],
    this.onCreateFeed,
    this.onEditFeed,
  });

  static const all = 'All';
  static const trending = 'Trending';
  static const subscribed = 'Subscribed';

  /// Prefix marking a chip as one of the user's own feeds.
  ///
  /// The selected category is a plain string throughout this screen, so a
  /// custom feed needs to be distinguishable from a topic search of the same
  /// name — somebody will call a feed "Music". The prefix is a character a
  /// name cannot contain, because the picker trims it.
  static const customPrefix = '\u0001custom:';

  static String customKey(String name) => '$customPrefix$name';
  static bool isCustom(String category) => category.startsWith(customPrefix);
  static String customName(String category) =>
      category.substring(customPrefix.length);

  static const _categories = [
    all,
    subscribed,
    trending,
    'Music',
    'Gaming',
    'News',
    'Movies',
    'Live',
    'Sports',
    'Learning',
    'Podcasts',
    'Comedy',
  ];

  final String selected;
  final ValueChanged<String> onSelected;

  /// The user's own feeds, shown right after All so they are reachable
  /// without scrolling — they are the ones that were asked for by name.
  final List<CustomFeed> customFeeds;

  final VoidCallback? onCreateFeed;

  /// Long-press on a custom chip. Rename and delete live there rather than on
  /// an always-visible X, which would be easy to hit while scrolling the row.
  final ValueChanged<CustomFeed>? onEditFeed;

  @override
  Widget build(BuildContext context) {
    final chipColor = AppColors.chip(context);
    final selectedColor = AppColors.chipSelected(context);
    final text = AppColors.text(context);
    final selectedText = AppColors.chipSelectedText(context);
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(8)),
    );
    const labelPadding = EdgeInsets.symmetric(horizontal: 4);
    const padding = EdgeInsets.symmetric(horizontal: 8);

    // All, then the user's own feeds, then the built-ins, then the + button.
    final entries = <({String key, String label, CustomFeed? custom})>[
      (key: all, label: all, custom: null),
      for (final feed in customFeeds)
        (key: customKey(feed.name), label: feed.name, custom: feed),
      for (final c in _categories.skip(1))
        (key: c, label: c, custom: null),
    ];

    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        // 32dp chips centred in the 48dp row.
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: entries.length + (onCreateFeed == null ? 0 : 1),
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index == entries.length) {
            return ActionChip(
              avatar: Icon(Icons.add, size: 18, color: text),
              label: const Text('New feed'),
              onPressed: onCreateFeed,
              backgroundColor: chipColor,
              shape: shape,
              padding: padding,
              labelPadding: labelPadding,
              labelStyle: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: text,
              ),
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            );
          }

          final entry = entries[index];
          final isSelected = entry.key == selected;
          final chip = ChoiceChip(
            label: Text(entry.label),
            avatar: entry.custom == null
                ? null
                : Icon(
                    Icons.auto_awesome,
                    size: 15,
                    color: isSelected ? selectedText : text,
                  ),
            selected: isSelected,
            showCheckmark: false,
            onSelected: (_) => onSelected(entry.key),
            backgroundColor: chipColor,
            selectedColor: selectedColor,
            shape: shape,
            padding: padding,
            labelPadding: labelPadding,
            labelStyle: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: isSelected ? selectedText : text,
            ),
            side: BorderSide.none,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          );

          final custom = entry.custom;
          final shown = _RevealWhenSelected(selected: isSelected, child: chip);
          if (custom == null || onEditFeed == null) return shown;
          return GestureDetector(
            onLongPress: () => onEditFeed!(custom),
            child: shown,
          );
        },
      ),
    );
  }
}

/// Scrolls the chip row so the selected chip is on screen.
///
/// Creating a feed from the "+" at the far end of the row selected its new
/// chip, which sits near the start — so the row stayed scrolled to the end
/// with the active feed out of sight, and nothing said which feed was
/// showing. Seen on an emulator.
class _RevealWhenSelected extends StatefulWidget {
  const _RevealWhenSelected({required this.selected, required this.child});

  final bool selected;
  final Widget child;

  @override
  State<_RevealWhenSelected> createState() => _RevealWhenSelectedState();
}

class _RevealWhenSelectedState extends State<_RevealWhenSelected> {
  @override
  void initState() {
    super.initState();
    if (widget.selected) _reveal();
  }

  @override
  void didUpdateWidget(_RevealWhenSelected old) {
    super.didUpdateWidget(old);
    if (widget.selected && !old.selected) _reveal();
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Only the chip row's own scroll view, never the ones above it.
      // Scrollable.ensureVisible walks EVERY enclosing scrollable, and since
      // the chips moved into the feed's floating header that included the
      // feed itself: the header rebuilds while scrolling, the selected chip
      // asked to be revealed again, and the whole feed was dragged back to
      // the top — Home could not be scrolled at all (found on AIBitPhone).
      final row = Scrollable.maybeOf(context);
      final box = context.findRenderObject();
      if (row == null || box == null) return;
      row.position.ensureVisible(
        box,
        alignment: 0.3,
        duration: const Duration(milliseconds: 250),
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Only ever shown in a browser build.
class _PreviewBanner extends StatelessWidget {
  const _PreviewBanner();

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.brand,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 16, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Preview — sample data, no playback.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.white,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}


/// Thin strip under the app bar counting down the Kids allowance.
///
/// Deliberately quiet — a child should be able to ignore it and a parent
/// should be able to check it at a glance. It refreshes when KidsGuard
/// notifies, which happens as playback records time, so there is no ticker
/// burning a frame a second on a screen that is mostly idle.
class _KidsTimeBar extends StatelessWidget {
  const _KidsTimeBar({required this.remainingSeconds});

  final int remainingSeconds;

  /// "8 min left today". Minutes round **up** so the last 30 seconds still
  /// read as "1 min left" rather than a "0 min left" that sits there while
  /// the video keeps playing.
  static String label(int seconds) {
    if (seconds <= 0) return 'No time left today';
    if (seconds >= 3600) {
      final hours = seconds ~/ 3600;
      final minutes = (seconds % 3600) ~/ 60;
      final tail = minutes == 0 ? '' : ' $minutes min';
      return '$hours hr$tail left today';
    }
    return '${(seconds / 60).ceil()} min left today';
  }

  @override
  Widget build(BuildContext context) {
    // The same green the Kids side of the mode switch uses, so the strip reads
    // as part of Kids mode rather than as a warning.
    const kidsGreen = Color(0xFF34A853);
    return Container(
      width: double.infinity,
      color: kidsGreen.withValues(alpha: 0.12),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          const Icon(Icons.timer_outlined, size: 15, color: kidsGreen),
          const SizedBox(width: 6),
          Text(
            label(remainingSeconds),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: kidsGreen,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown in place of the Kids feed once the daily allowance is spent.
///
/// Replaces only the feed, not the whole screen: the mode switch stays in the
/// app bar so a grown-up with the PIN can still leave Kids mode, and Settings
/// stays reachable to raise the limit.
class _KidsTimeUp extends StatelessWidget {
  const _KidsTimeUp();

  @override
  Widget build(BuildContext context) => const EmptyState(
    icon: Icons.bedtime_outlined,
    title: "That's all for today",
    message:
        'Kids time is up. More videos tomorrow.\n\nA grown-up can change the '
        'daily limit in Settings.',
  );
}
