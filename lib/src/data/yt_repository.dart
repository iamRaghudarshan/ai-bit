import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import '../core/format.dart';
import 'attestation/attestation_service.dart';
import 'attestation/web_formats.dart';
import 'browse_client.dart';
import 'comments_client.dart';
import 'dash_manifest.dart';
import 'hls_manifest.dart';
import 'hls_server.dart';
import 'interests.dart';
import 'models.dart';
import 'player_client.dart';
import 'preview_data.dart';
import 'recommender.dart';
import 'search_client.dart';

/// Wraps `youtube_explode_dart` and hides its client-selection quirks behind a
/// small task-shaped API.
///
/// Streams are resolved straight from YouTube's player endpoint, which is what
/// makes playback ad-free: we never load the web player, so there is no ad
/// break to serve. The trade-off is that YouTube changes these endpoints
/// occasionally — [resolve] therefore walks a fallback chain of API clients
/// instead of trusting a single one.
class YtRepository {
  YtRepository({WebAttestation? attestation})
    : _yt = yt.YoutubeExplode(),
      _search = YoutubeSearchClient(),
      _player = YoutubePlayerClient(),
      _browse = YoutubeBrowseClient(),
      _comments = YoutubeCommentsClient(),
      // ignore: prefer_initializing_formals
      _attestation = attestation;

  final yt.YoutubeExplode _yt;
  final YoutubeSearchClient _search;
  final YoutubePlayerClient _player;
  final YoutubeBrowseClient _browse;
  final YoutubeCommentsClient _comments;

  /// Mints the proof-of-origin token the web client needs. Optional: without
  /// it (and on the web preview) resolution stops at the routes that need no
  /// token, exactly as before it existed.
  final WebAttestation? _attestation;

  /// Settings → Playback → "HD on every video". Bound from main.dart.
  bool hdUnlockEnabled = true;

  /// Signed CDN URLs stay valid for roughly six hours; expire ours well before
  /// that so a long-lived app never hands a dead URL to the player.
  static const _streamTtl = Duration(hours: 2);

  final _streamCache = <String, ({PlaybackSources sources, DateTime at})>{};
  final _detailCache = <String, yt.Video>{};

  /// True in a browser build. `youtube_explode_dart` does not survive dart2js
  /// compilation, so the web target serves sample rows purely so the interface
  /// can be reviewed. Never true on iOS or Android.
  static bool get isPreview => kIsWeb;

  List<VideoBrief> _previewRows(int refreshToken) {
    final rows = [...previewVideos];
    if (refreshToken > 0) {
      // Make pull-to-refresh visibly do something.
      final shift = refreshToken % rows.length;
      return [...rows.sublist(shift), ...rows.sublist(0, shift)];
    }
    return rows;
  }

  /// Broad, evergreen topics used to fill the home feed before there is any
  /// watch history to personalise against.
  static const _coldStartTopics = [
    'music',
    'technology',
    'documentary',
    'podcast',
    'gaming',
    'news today',
    'cooking',
    'travel',
    'science explained',
    'football highlights',
  ];

  /// Kid-friendly topics for the home feed in Kids mode. Evergreen, broadly
  /// safe search terms — the app cannot enforce YouTube's own age gating, so
  /// this curates rather than filters.
  static const _kidsTopics = [
    'nursery rhymes',
    'kids cartoon',
    'cocomelon',
    'kids learning videos',
    'peppa pig',
    'kids songs',
    'chota bheem',
    'kids science experiments',
    'abc for kids',
    'moral stories for kids',
  ];

  static const _kidsShortsTopics = [
    'kids cartoon',
    'nursery rhyme',
    'funny animals',
    'kids learning',
    'kids craft',
    'cartoon',
  ];

  /// Points every endpoint at a language and region.
  ///
  /// One call rather than four because they must agree: a search answered in
  /// Hindi and a browse answered in English produce a feed that looks like two
  /// different apps stitched together. Called from the app whenever the
  /// setting changes, and once at startup.
  void setLocale({required String language, required String region}) {
    _search.setLocale(language: language, region: region);
    _player.setLocale(language: language, region: region);
    _browse.setLocale(language: language, region: region);
    _comments.setLocale(language: language, region: region);
  }

  void dispose() {
    _yt.close();
    _search.close();
    _player.close();
    _browse.close();
    _comments.close();
    // Unawaited on purpose: dispose is synchronous for every other dependency
    // and the socket closing a moment later harms nothing.
    unawaited(_hlsServer.dispose());
  }

  // ------------------------------------------------------------------ feed

  /// Home feed: candidate generation, then ranking.
  ///
  /// This is stage one of the two-stage shape described in `recommender.dart`.
  /// Its job is to produce a few hundred *plausible* videos from every source
  /// the app can reach, cheaply and in parallel, and then hand the whole pile
  /// to [rankFeed] to be ordered. It deliberately does not try to be clever
  /// about which source deserves which slot — that used to be this function's
  /// entire ordering strategy, and it is exactly what the ranker replaces.
  ///
  /// [refreshToken] still rotates which channels and queries are *consulted*,
  /// because a refresh should reach for material the last one did not fetch at
  /// all. What it no longer does is shift a window into an unranked list and
  /// call that a new feed: the ranker's impression penalty is what makes a
  /// refresh surface things the user has not already been shown.
  ///
  /// [coWatchSeeds] are recently watched video ids. Asking YouTube what it
  /// lists as related to each of them is the nearest thing this app has to the
  /// co-watch graph the real recommender is trained on, and it is by some way
  /// the best candidate source here — it was previously fetched only on the
  /// watch page and never used to build the feed at all.
  Future<List<VideoBrief>> homeFeed({
    List<String> channelIds = const [],
    List<String> searches = const [],
    List<String> subscribedIds = const [],
    List<String> coWatchSeeds = const [],
    TasteProfile profile = TasteProfile.empty,
    Map<String, ImpressionCount> impressions = const {},
    RankerWeights weights = RankerWeights.prior,
    Map<String, List<double>>? featuresOut,
    List<String> interests = const [],
    List<String> feedLanguages = const [],
    /// Videos the local co-visitation graph already knows are watched
    /// alongside the user's recent viewing. Passed in rather than fetched
    /// here because they come from the database, which this file does not
    /// touch — the same reason [profile] is injected.
    List<VideoBrief> graphCandidates = const [],
    int refreshToken = 0,
    bool kids = false,
    DateTime? now,
  }) async {
    if (isPreview) return _previewRows(refreshToken);

    // Kids mode ignores every personal signal and draws only from the curated
    // kid topics, so nothing from normal watch history can leak in — which is
    // also why it does not go through the ranker: ranking against a profile
    // built from the adult's viewing is precisely what must not happen here.
    if (kids) {
      final topics = _rotate(_kidsTopics, refreshToken).take(6).toList();
      final results = await Future.wait([
        for (var i = 0; i < topics.length; i++)
          _safe(() => _recentTopicSearch(topics[i], refreshToken + i)),
      ]);
      return _interleave(results, skip: refreshToken);
    }

    final rotatedSearches = _rotate(searches, refreshToken);
    final rotatedChannels = _rotate(channelIds, refreshToken);
    final rotatedSubs = _rotate(subscribedIds, refreshToken);
    final rotatedSeeds = _rotate(coWatchSeeds, refreshToken);

    // Every source is fetched concurrently and tagged with where it came from.
    // The tag is all the ordering information the ranker needs from this
    // stage; everything else it works out from the videos themselves.
    final tasks = <Future<(CandidateSource, List<VideoBrief>)>>[
      // Subscriptions, widened from six channels to eight. Somebody following
      // thirty channels had at most thirty-six subscription candidates in a
      // pool of several hundred, which is a thin showing for the one signal
      // the user stated outright by pressing Subscribe — and the rotation
      // meant most of the list simply was not asked about on any given load.
      for (final id in rotatedSubs.take(8))
        _tagged(CandidateSource.subscription, () => channelUploads(id, limit: 6)),
      // The co-watch graph. Several seeds rather than one because a single
      // recent video biases the whole feed towards one evening's mood, and
      // because this is the strongest source available — widening it is the
      // cheapest real improvement to the feed, since ranking can only ever
      // order what candidate generation found.
      for (final videoId in rotatedSeeds.take(6))
        _tagged(CandidateSource.coWatch, () => _browse.related(videoId)),
      // Two hops out: what people watch after the things people watch after
      // what you watched. One hop only ever reaches YouTube's immediate
      // neighbours, which for a well-known video is the same handful of
      // obvious choices every time — the second hop is where anything the
      // user has not already been offered actually comes from.
      //
      // Only two seeds, and only their top neighbour each, because the
      // breadth is multiplicative and this is the most expensive source here.
      for (final videoId in rotatedSeeds.take(2))
        _tagged(CandidateSource.coWatch, () => _relatedTwoHops(videoId)),
      for (final id in rotatedChannels.take(5))
        _tagged(CandidateSource.watchedChannel, () => channelUploads(id, limit: 8)),
      // What the user searched for, kept inside a recent window like the topic
      // sources below. On the search *screen* an all-time relevance ranking is
      // right — somebody looking something up wants the best answer, whenever
      // it was posted. As a feed source it is not: "what's new about the thing
      // I was looking into" is the useful reading, and the all-time version
      // simply re-offers the same canonical video every refresh for as long as
      // the query stays in history.
      for (final (i, q) in rotatedSearches.take(4).indexed)
        _tagged(
          CandidateSource.search,
          () => _recentTopicSearch(q, refreshToken + i),
        ),
    ];

    // What the user actually said they want, when they have said anything.
    //
    // This is the answer to cold start, which is the one case the ranker
    // cannot help with: on a fresh install there is no behaviour to rank
    // against, and the evergreen filler below describes nobody in particular.
    // Declared interests get a real share of the feed rather than a single
    // filler slot, and they keep it — somebody who ticked "AI" did not mean
    // "until you have watched enough for me to stop asking".
    final chosen = _rotate(
      withLanguages(interestQueries(interests), feedLanguages),
      refreshToken,
    );
    tasks.addAll(
      chosen.take(6).indexed.map(
            ((int, String) e) => _tagged(
              CandidateSource.interest,
              () => _recentTopicSearch(e.$2, refreshToken + e.$1),
            ),
          ),
    );

    // Filler, kept deliberately small, and smaller still once there is
    // anything personal to go on. A fresh install with no interests chosen has
    // no signals at all and would otherwise show an empty screen.
    final hasSignals = searches.isNotEmpty ||
        channelIds.isNotEmpty ||
        subscribedIds.isNotEmpty ||
        coWatchSeeds.isNotEmpty ||
        chosen.isNotEmpty;
    final topics = _rotate(_coldStartTopics, refreshToken);
    tasks.addAll(
      topics.take(hasSignals ? 1 : 4).indexed.map(
            ((int, String) e) => _tagged(
              CandidateSource.topic,
              () => _recentTopicSearch(e.$2, refreshToken + e.$1),
            ),
          ),
    );

    final sections = await Future.wait(tasks);

    // Free candidates: no request was made for these. They are videos the app
    // has already seen, which the graph says are co-watched with what the user
    // has been watching, so they get the co-watch prior.
    final withGraph = <(CandidateSource, List<VideoBrief>)>[
      ...sections,
      if (graphCandidates.isNotEmpty)
        (CandidateSource.coWatch, graphCandidates),
    ];

    // NOTE: there used to be a bypass here — an empty profile returned the
    // plain round-robin instead of ranking. It was wrong, and it was reported
    // as "recommendations are not working", which was accurate: a fresh
    // install has no history and, unless someone had found the interests
    // screen, no declared interests either, so the ranker was skipped
    // entirely and the feed was exactly what it had been before any of this
    // was built. The reasoning for the bypass — that with every personal term
    // at zero the order collapses onto source prior and popularity — was also
    // wrong: freshness, the channel-repeat cost and the MMR topic spread all
    // still apply, and together they order a cold feed better than fetch
    // order does. Rank always.

    return rankFeed(
      candidates: [
        for (final (source, videos) in withGraph)
          for (final video in videos) Candidate(video: video, source: source),
      ],
      profile: profile,
      now: now ?? DateTime.now(),
      impressions: impressions,
      // Raised with pagination: the cap used to be the whole feed, so 120 was
      // also the point at which scrolling hit a wall. Now it is a page size,
      // and a page wants to be a comfortable scroll rather than an afternoon.
      limit: 80,
      // The refresh is what varies the exploration. Pulling down therefore
      // reshuffles the near-ties and offers a different set of novel channels,
      // rather than returning the same order with two rows moved.
      seed: refreshToken,
      weights: weights,
      featuresOut: featuresOut,
    );
  }

  /// Related videos two hops from [videoId].
  ///
  /// Hop one is YouTube's related list for the video itself. Hop two takes the
  /// strongest entry from that list and asks for *its* related list, which
  /// reaches material the first hop cannot: for a popular video the immediate
  /// neighbours are the same obvious choices for everybody, and the interesting
  /// stuff is one step further out.
  ///
  /// The first hop's results are returned too, so this is strictly a widening.
  /// Hop two failing is not an error — the hop-one list is still a perfectly
  /// good answer, which is why it is caught here rather than left to abort the
  /// whole source.
  Future<List<VideoBrief>> _relatedTwoHops(String videoId) async {
    final first = await _browse.related(videoId);
    if (first.isEmpty) return first;
    // The top entry rather than a random one: it is the strongest co-watch
    // edge YouTube reported, so its own neighbourhood is the most likely to be
    // relevant rather than merely different.
    try {
      final second = await _browse.related(first.first.id);
      return [...first, ...second];
    } catch (e) {
      debugPrint('AI BIT: second co-watch hop failed for $videoId — $e');
      return first;
    }
  }

  /// Runs a candidate source and labels what came back, swallowing failures
  /// the way [_safe] does — one dead source must not empty the whole feed.
  Future<(CandidateSource, List<VideoBrief>)> _tagged(
    CandidateSource source,
    Future<List<VideoBrief>> Function() task,
  ) async => (source, await _safe(task));

  /// Orders a video's "Up next" list for this viewer.
  ///
  /// [related] is YouTube's own list and is kept as a strong prior — it is the
  /// co-watch signal, and discarding it to re-derive something from local
  /// history alone would throw away the only view of what everybody else does.
  /// What this adds is the person holding the phone. See [rankUpNext].
  List<VideoBrief> personalisedUpNext({
    required VideoBrief current,
    required List<VideoBrief> related,
    required TasteProfile profile,
    Map<String, ImpressionCount> impressions = const {},
    List<VideoBrief> recentlyPlayed = const [],
    RankerWeights weights = RankerWeights.prior,
    DateTime? now,
  }) =>
      rankUpNext(
        current: current,
        related: related,
        profile: profile,
        now: now ?? DateTime.now(),
        impressions: impressions,
        recentlyPlayed: recentlyPlayed,
        weights: weights,
      );

  /// A feed built from search terms the user typed.
  ///
  /// Backs the custom feeds described in `custom_feeds.dart`. It goes through
  /// the ranker like everything else, so a custom feed still sinks what has
  /// been watched, spreads channels out and explores — the queries decide
  /// WHAT is fetched, not how it is ordered. Without that it would be a
  /// search results page wearing a chip's clothes.
  Future<List<VideoBrief>> customFeed({
    required List<String> queries,
    TasteProfile profile = TasteProfile.empty,
    Map<String, ImpressionCount> impressions = const {},
    RankerWeights weights = RankerWeights.prior,
    List<String> feedLanguages = const [],
    int refreshToken = 0,
    int limit = 80,
    DateTime? now,
  }) async {
    if (isPreview) return _previewRows(refreshToken);
    if (queries.isEmpty) return const [];

    final expanded = _rotate(
      withLanguages(queries, feedLanguages),
      refreshToken,
    );
    final results = await Future.wait(
      expanded.take(6).map((q) => _safe(() => search(q))),
    );
    final candidates = <Candidate>[
      for (final section in results)
        for (final video in section)
          Candidate(video: video, source: CandidateSource.interest),
    ];
    if (candidates.isEmpty) return const [];

    return rankFeed(
      candidates: candidates,
      profile: profile,
      now: now ?? DateTime.now(),
      impressions: impressions,
      weights: weights,
      limit: limit,
      seed: refreshToken,
    );
  }

  /// Newest uploads from the channels followed on this device, for the
  /// "Subscribed" chip on Home.
  ///
  /// [channels] comes from the local `subscriptions` table — there is no
  /// Google account here, so "subscribed" only ever means "followed on this
  /// phone". An empty [channels] returns an empty list rather than throwing:
  /// having subscribed to nothing is a normal state the caller shows an
  /// invitation for, not a failure.
  ///
  /// Deliberately takes no refreshToken. Every other feed rotates its topic
  /// window on pull-to-refresh because it is assembling a selection; this one
  /// has a single correct order — newest first — so a refresh means "go and
  /// see whether anything new was posted", and shifting the window would only
  /// hide the newest upload the user pulled down to find.
  Future<List<VideoBrief>> subscribedFeed({
    List<ChannelInfo> channels = const [],
    int perChannel = 8,
  }) async {
    if (isPreview) return _previewRows(0);
    if (channels.isEmpty) return const [];

    // Each channel is its own browse request, so cap the fan-out the way the
    // Subscriptions tab does; beyond ~15 the feed is longer than anyone
    // scrolls and the request burst starts getting throttled.
    final results = await Future.wait(
      channels.take(15).map(
        (c) => _safe(
          () => channelUploads(c.id, limit: perChannel, channelTitle: c.title),
        ),
      ),
    );
    // Round-robin first so the recency sort has a sensible tiebreak order for
    // rows whose age we cannot read, then order by age.
    return _newestFirst(_interleave(results));
  }

  /// Rough age in seconds of [video], or null when YouTube gave nothing
  /// usable.
  ///
  /// The browse endpoint returns "3 days ago" as text and no timestamp, which
  /// is why the Subscriptions tab settles for interleaving instead of sorting.
  /// Parsing that phrase back is coarse — every month counts as 30 days — but
  /// it is enough to put today's upload above last year's, which is the whole
  /// job. Pure and static so it can be unit-tested without a network.
  /// Delegates to [parseRelativeAgeSeconds] rather than keeping its own copy.
  ///
  /// It used to be a second implementation of the same rule, with a comment
  /// saying the two must agree. They did not: the recommender's copy learnt to
  /// read YouTube's abbreviated `17y ago` form and this one would have been
  /// left reading only `17 years ago`, so the Subscriptions tab would have
  /// sorted by an age the feed disagreed about. One rule, one place.
  static int? uploadAgeSeconds(VideoBrief video) {
    final date = video.uploadDate;
    if (date != null) {
      final seconds = DateTime.now().difference(date).inSeconds;
      return seconds < 0 ? 0 : seconds;
    }
    return parseRelativeAgeSeconds(video.uploadRaw);
  }

  /// Orders a merged feed newest-first.
  ///
  /// Rows whose age cannot be read sink to the bottom rather than floating to
  /// the top: an unreadable date is far more likely to be an odd renderer
  /// than a brand-new upload. Ties keep their incoming order — the sort is
  /// decorated with the original index because Dart's List.sort is not stable,
  /// and without that the round-robin interleave would collapse and one
  /// prolific channel could take the whole top of the feed.
  static List<VideoBrief> _newestFirst(List<VideoBrief> videos) {
    const unknownAge = 1 << 40;
    final ranked = <({int age, int index, VideoBrief video})>[
      for (var i = 0; i < videos.length; i++)
        (
          age: uploadAgeSeconds(videos[i]) ?? unknownAge,
          index: i,
          video: videos[i],
        ),
    ];
    ranked.sort(
      (a, b) =>
          a.age != b.age ? a.age.compareTo(b.age) : a.index.compareTo(b.index),
    );
    return [for (final r in ranked) r.video];
  }

  /// Most-viewed *recent* videos across a rotating topic — the closest thing
  /// to a "Trending" tab available without the official Data API.
  ///
  /// The window is the chip's whole meaning. Sorted by view count with no
  /// window this asked for the most-watched videos of all time about three
  /// evergreen topics, which is a fixed list that cannot trend: it returned
  /// the same decade-old music videos every time and changed only when the
  /// topic rotation did.
  Future<List<VideoBrief>> trending({int refreshToken = 0}) async {
    if (isPreview) return _previewRows(refreshToken);
    final topics = _rotate(_coldStartTopics, refreshToken).take(3).toList();
    final results = await Future.wait([
      for (final t in topics)
        _safe(
          () => search(
            t,
            sortByViews: true,
            uploadedWithin: YoutubeSearchClient.uploadedThisWeek,
          ),
        ),
    ]);
    final pooled = _interleave(results);
    // A quiet week on a narrow topic can return nothing at all; falling back
    // to the month keeps the chip from looking broken.
    if (pooled.isNotEmpty) return pooled;
    final wider = await Future.wait([
      for (final t in topics)
        _safe(
          () => search(
            t,
            sortByViews: true,
            uploadedWithin: YoutubeSearchClient.uploadedThisMonth,
          ),
        ),
    ]);
    return _interleave(wider);
  }

  /// Vertical-video feed for the Shorts tab.
  ///
  /// YouTube exposes no Shorts feed this app can reach: the channel Shorts tab
  /// returns nothing, and search yields no `reelItemRenderer`. Shorts do come
  /// back from an ordinary search — as `shortsLockupViewModel`, a renderer
  /// nothing else here parses — so the feed is assembled from several topic
  /// searches, led by whatever the user has been searching for.
  ///
  /// The selection is therefore ours rather than YouTube's algorithm. It is
  /// shuffled so the tab is not identical on every visit.
  Future<List<VideoBrief>> shortsFeed({
    List<String> searches = const [],
    List<String> interests = const [],
    List<String> feedLanguages = const [],
    TasteProfile profile = TasteProfile.empty,
    Map<String, ImpressionCount> impressions = const {},
    RankerWeights weights = RankerWeights.prior,
    int refreshToken = 0,
    bool kids = false,
    DateTime? now,
  }) async {
    if (isPreview) return _previewRows(refreshToken);

    // Kids mode draws only from kid-friendly shorts topics.
    final topics = kids
        ? _rotate(_kidsShortsTopics, refreshToken).take(4).toList()
        : <String>[
            ...searches.take(2),
            // Chosen interests steer Shorts as well. A tab that ignored them
            // while the home feed honoured them would read as the setting only
            // half working, which is worse than not having it.
            ..._rotate(
              withLanguages(interestQueries(interests), feedLanguages),
              refreshToken,
            ).take(2),
            ..._rotate(_shortsTopics, refreshToken).take(2),
          ];

    final results = await Future.wait(
      topics.map((t) => _safeShorts(() => _search.searchShorts('$t shorts'))),
    );
    final pooled = _interleave(results).map((v) => v.asShort()).toList();

    // Kids mode ranks nothing, for the same reason the Kids home feed does
    // not: it curates from a fixed topic list and must not consult a profile
    // built from the adult's viewing.
    // Kids mode ranks nothing, for the same reason the Kids home feed does
    // not: it curates from a fixed topic list and must not consult a profile
    // built from the adult's viewing. Everything else is ranked, including a
    // cold profile — see the note in homeFeed about why the empty-profile
    // bypass was a mistake.
    if (kids) return pooled..shuffle();

    // Everything else goes through the ranker. Shorts were the last feed in
    // the app still ordered by shuffle(), which meant the one surface people
    // scroll fastest was the one making the least use of what it knew.
    // Exploration is on and the seed rotates, so the tab is still different on
    // every visit - that was the only thing shuffle() was buying.
    return rankFeed(
      candidates: [
        for (final video in pooled)
          Candidate(video: video, source: CandidateSource.search),
      ],
      profile: profile,
      now: now ?? DateTime.now(),
      impressions: impressions,
      weights: weights,
      seed: refreshToken,
    );
  }

  Future<List<VideoBrief>> _safeShorts(
    Future<List<VideoBrief>> Function() task,
  ) async {
    try {
      return await task();
    } catch (e) {
      debugPrint('AI BIT: shorts section failed — $e');
      return const [];
    }
  }

  static const _shortsTopics = [
    'funny',
    'satisfying',
    'life hack',
    'football',
    'cooking',
    'dance',
    'animals',
    'science',
  ];

  // ---------------------------------------------------------------- search

  Future<List<VideoBrief>> search(
    String query, {
    bool sortByViews = false,

    /// Restrict results to videos uploaded inside a window — one of
    /// [YoutubeSearchClient.uploadedThisWeek] and friends. Null means any
    /// time, which is right for the search screen and wrong for the feed.
    int? uploadedWithin,
    String? params,
  }) async {
    if (isPreview) {
      // Only ever real matches against the sample set. Returning everything on
      // a miss made search look like it was ignoring the query.
      final needle = query.toLowerCase();
      return previewVideos
          .where(
            (v) =>
                v.title.toLowerCase().contains(needle) ||
                v.author.toLowerCase().contains(needle),
          )
          .toList();
    }

    // Deliberately not _yt.search.search — see YoutubeSearchClient for why the
    // package's own parser cannot read YouTube's current search response.
    return _search.search(
      query,
      params: params ??
          (uploadedWithin != null
              ? YoutubeSearchClient.buildParams(
                  sortBy: sortByViews ? 3 : null,
                  uploadDate: uploadedWithin,
                )
              : sortByViews
                  ? YoutubeSearchClient.filterByViewCount
                  : YoutubeSearchClient.filterVideosOnly),
    );
  }

  /// Windows a topic search to recent uploads, widening only if it has to.
  ///
  /// This is the candidate-generation half of "the feed keeps showing me
  /// six-year-old videos". A topic query sorted by view count returns the
  /// all-time most-watched video about that topic, and for most topics that is
  /// something from years ago with tens of millions of views — which then
  /// *also* looks like the most popular candidate in the pool, because raw
  /// view counts accumulate with age. Asking YouTube for a window fixes it at
  /// source instead of trying to out-weight it in the ranker.
  ///
  /// The window rotates with [index] so the feed mixes "biggest this week"
  /// with "biggest this year" rather than being one or the other, and so a
  /// pull-to-refresh changes which it asks for.
  ///
  /// The widening matters as much as the window: a narrow topic — a declared
  /// interest like "self-hosting homelab tutorials" — can genuinely have
  /// nothing from the last week, and a strict window would then contribute
  /// nothing at all. Only an *empty* result widens, so the common case stays
  /// one request.
  Future<List<VideoBrief>> _recentTopicSearch(String query, int index) async {
    // Month and week only. "This year" was a third slot here and it was the
    // wrong tool for a primary query: measured with tool/check_home_feed.dart
    // it returns a median age of three months and puts half its results past
    // sixty days, which is how a feed that had stopped showing six-year-old
    // video started showing five-month-old video instead. It stays below as
    // the widening step, which is what it is actually for — a last resort for
    // a narrow topic with nothing recent, not a third of every feed.
    const windows = [
      YoutubeSearchClient.uploadedThisMonth,
      YoutubeSearchClient.uploadedThisWeek,
    ];
    final window = windows[index.abs() % windows.length];
    final windowed = await search(
      query,
      sortByViews: true,
      uploadedWithin: window,
    );
    if (windowed.isNotEmpty) return windowed;
    if (window != YoutubeSearchClient.uploadedThisYear) {
      final wider = await search(
        query,
        sortByViews: true,
        uploadedWithin: YoutubeSearchClient.uploadedThisYear,
      );
      if (wider.isNotEmpty) return wider;
    }
    // Nothing recent exists for this query. An evergreen answer beats an empty
    // section.
    return search(query, sortByViews: true);
  }

  Future<List<String>> suggestions(String query) async {
    if (query.trim().isEmpty) return const [];
    if (isPreview) {
      final needle = query.toLowerCase();
      return previewVideos
          .where((v) => v.title.toLowerCase().contains(needle))
          .map((v) => v.title)
          .take(6)
          .toList();
    }
    // Ours, not the package's: its getQuerySuggestions fails the same way its
    // search does, and the failure was swallowed here — so the suggestion list
    // was always empty and nothing ever said why.
    return _search.suggestions(query);
  }

  // --------------------------------------------------------------- details

  Future<yt.Video> videoDetails(String videoId) async {
    final cached = _detailCache[videoId];
    if (cached != null) return cached;
    final video = await _yt.videos.get(videoId);
    _detailCache[videoId] = video;
    return video;
  }

  /// The "Up next" list under the player. Needs the full [yt.Video] because
  /// the related-video token only exists on the watch page.
  ///
  /// Takes the id, not the package's `Video`: the `next` endpoint needs
  /// nothing else, and requiring the details first chained the rail to the
  /// watch-page scrape that a bot-check interstitial breaks. [details], when
  /// the caller has them, only feed the package fallback.
  Future<List<VideoBrief>> related(
    String videoId, {
    yt.Video? details,
    String channelId = '',
  }) async {
    // Own `next`-endpoint parser first: the package's getRelatedVideos throws
    // on YouTube's current lockup format, and even when it worked it dropped
    // the duration. This keeps the duration badge on every suggestion.
    final viaNext = await _safe(() => _browse.related(videoId));
    if (viaNext.isNotEmpty) return viaNext;

    try {
      if (details == null) throw StateError('no details for the fallback');
      final list = await _yt.videos.getRelatedVideos(details);
      if (list == null || list.isEmpty) return const [];
      return list.map(VideoBrief.fromYt).toList();
    } catch (_) {
      // Last resort: same-channel uploads (which also carry their duration).
      final channel = details?.channelId.value ?? channelId;
      if (channel.isEmpty) return const [];
      return _safe(() => channelUploads(channel, limit: 12));
    }
  }

  /// A channel's uploads.
  ///
  /// The browse endpoint is tried first because `channels.getUploads` returns
  /// an empty stream — zero videos for every channel measured. The package call
  /// is kept only as a fallback in case that ever starts working again.
  /// A channel's Live tab: past and current streams.
  Future<List<VideoBrief>> channelLive(
    String channelId, {
    String channelTitle = '',
  }) async {
    if (isPreview) return const [];
    return _browse.channelVideos(
      channelId,
      channelTitle: channelTitle,
      live: true,
    );
  }

  /// A channel's Shorts tab.
  Future<List<VideoBrief>> channelShorts(
    String channelId, {
    String channelTitle = '',
  }) async {
    if (isPreview) return const [];
    return _browse.channelShorts(channelId, channelTitle: channelTitle);
  }

  Future<List<VideoBrief>> channelUploads(
    String channelId, {
    int limit = 20,
    String channelTitle = '',
  }) async {
    try {
      final videos = await _browse.channelVideos(
        channelId,
        channelTitle: channelTitle,
      );
      if (videos.isNotEmpty) return videos.take(limit).toList();
    } catch (e) {
      debugPrint('AI BIT: channel videos browse failed for $channelId — $e');
    }
    final videos = await _yt.channels.getUploads(channelId).take(limit).toList();
    return videos.map(VideoBrief.fromYt).toList();
  }

  /// Channel header. Falls back to the package when the browse endpoint
  /// returns nothing useful, since the two read different shapes and each
  /// occasionally comes back empty.
  Future<ChannelInfo> channelInfo(String channelId) async {
    try {
      final info = await _browse.channel(channelId);
      if (info.title.isNotEmpty) return info;
    } catch (e) {
      debugPrint('AI BIT: channel browse failed for $channelId — $e');
    }
    final channel = await _yt.channels.get(channelId);
    return ChannelInfo(
      id: channelId,
      title: channel.title,
      avatarUrl: channel.logoUrl,
      subscriberLabel: channel.subscribersCount == null
          ? null
          : '${compactCount(channel.subscribersCount)} subscribers',
    );
  }

  /// First page of a video's comments.
  Future<CommentPage> comments(String videoId) => _comments.fetch(videoId);

  /// A further page, using [CommentPage.continuation].
  Future<CommentPage> moreComments(String continuation) =>
      _comments.more(continuation);

  /// Replies to one comment.
  Future<List<VideoComment>> commentReplies(String token) =>
      _comments.replies(token);

  /// Playlists published by a channel.
  Future<List<PlaylistBrief>> channelPlaylists(String channelId) =>
      _browse.channelPlaylists(channelId);

  /// Title and length of a YouTube playlist.
  Future<PlaylistBrief> playlistInfo(String playlistId) async {
    final p = await _yt.playlists.get(playlistId);
    return PlaylistBrief(
      id: playlistId,
      title: p.title,
      videoCount: p.videoCount,
      channelId: null,
    );
  }

  /// Videos in a YouTube playlist.
  ///
  /// Browse first: `playlists.getVideos` returns an empty stream for every
  /// playlist measured, which is why opening a channel playlist showed nothing.
  Future<List<VideoBrief>> remotePlaylist(String playlistId, {int limit = 100}) async {
    try {
      final videos = await _browse.playlistVideos(playlistId);
      if (videos.isNotEmpty) return videos.take(limit).toList();
    } catch (e) {
      debugPrint('AI BIT: playlist browse failed for $playlistId — $e');
    }
    final videos = await _yt.playlists.getVideos(playlistId).take(limit).toList();
    return videos.map(VideoBrief.fromYt).toList();
  }

  // --------------------------------------------------------------- streams

  /// Pulls a playlist id out of a `?list=…` URL, or accepts a bare one.
  ///
  /// Checked before the video id: a `watch?v=…&list=…` link carries both, and
  /// opening the playlist is the more specific intent.
  static String? parsePlaylistId(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    final uri = Uri.tryParse(trimmed);
    final fromQuery = uri?.queryParameters['list'];
    if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;

    // A bare id. "LL" (liked) and "WL" (watch later) need an account, so they
    // are deliberately not accepted.
    if (RegExp(r'^(PL|UU|OL|RD|FL)[\w-]{10,}$').hasMatch(trimmed)) {
      return trimmed;
    }
    return null;
  }

  /// Accepts a bare id, a `youtu.be/…` link, or a full watch URL.
  static String? parseVideoId(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    return yt.VideoId.parseVideoId(trimmed) ??
        (RegExp(r'^[\w-]{11}$').hasMatch(trimmed) ? trimmed : null);
  }

  /// Resolves playable stream URLs for [videoId].
  ///
  /// Preference order, and why:
  ///
  ///   1. **HLS ladder** from [YoutubePlayerClient]. Adaptive, muxed, and goes
  ///      to 2160p for on-demand video and 1080p for live. It is also the only
  ///      thing that plays a live stream at all.
  ///   2. **Progressive muxed MP4**, capped by YouTube at 360p. Only reached
  ///      when no ladder is offered.
  ///   3. **Audio only**, rather than failing outright.
  ///
  /// An earlier version went straight to (2) because `youtube_explode_dart`
  /// never surfaces `hlsManifestUrl`, which made 360p look like a hard ceiling.
  /// It was not.
  ///
  /// Re-check the ordering with `dart run tool/probe_clients.dart` if playback
  /// quality or reliability ever regresses.
  /// Warms the stream cache for [videoId] without playing it, so a following
  /// [resolve] returns instantly. Used to preload the next Shorts the way
  /// YouTube does, turning the network round-trip on swipe into a cache hit.
  ///
  /// Fire-and-forget: failures are swallowed, and a video already cached is
  /// skipped so this costs nothing when called repeatedly.
  void prefetch(String videoId) {
    if (_streamCache.containsKey('$videoId:false')) return;
    if (!_prefetching.add(videoId)) return;
    unawaited(
      resolve(videoId).then((_) {}, onError: (Object _) {}).whenComplete(
        () => _prefetching.remove(videoId),
      ),
    );
  }

  final _prefetching = <String>{};

  /// Whether this platform can play a generated DASH manifest.
  ///
  /// Android's ExoPlayer has first-class DASH support and the vendored plugin
  /// already wires `DashMediaSource` to the `dash` format hint, so this costs
  /// no native code. AVPlayer has never supported DASH and Apple is not adding
  /// it. Web has no native player at all.
  static bool get canUseDash => !kIsWeb && Platform.isAndroid;

  /// Whether this platform can play a generated HLS manifest instead.
  ///
  /// The iOS answer to the same problem: AVPlayer will not take DASH, but it
  /// has played fragmented MP4 over HLS with byte-range segments since iOS 10,
  /// and that is a shape the adaptive tracks can be described in. See
  /// `hls_manifest.dart`.
  static bool get canUseGeneratedHls => !kIsWeb && Platform.isIOS;

  /// Playlists for generated HLS, served to AVPlayer over loopback.
  ///
  /// Created eagerly but bound lazily — nothing listens on a port until the
  /// first video actually needs one.
  final _hlsServer = GeneratedHlsServer();

  /// A clip no longer than this cannot run past the cap described in
  /// [_adaptiveTracksPlayThroughout], so it needs no probe.
  ///
  /// Well under the measured 60 seconds, because the boundary is approximate
  /// and the penalty for being wrong is a video that dies mid-play, while the
  /// penalty for being conservative is one extra ranged request.
  static const _definitelyUncappedMs = 40 * 1000;

  /// Does googlevideo serve the WHOLE of these tracks, or only the start?
  ///
  /// This is the question that decides between HD and 360p, and it has to be
  /// asked rather than assumed. YouTube now serves a byte-range adaptive URL
  /// for only the **first ~60 seconds** of a video unless the request carries
  /// a proof-of-origin token, which an app with no sign-in has no way to mint.
  /// Past that offset every range comes back `403`. Measured with
  /// `tool/check_stream_limits.dart`, on both the iOS and Android clients, and
  /// on the URLs `youtube_explode_dart` produces too — the cut lands at 60s of
  /// media on a 5-minute video and at 62s on a 16-minute one, so it is keyed
  /// to playback position rather than to bytes or to elapsed time.
  ///
  /// This is the defect behind "no videos are playing properly". A generated
  /// manifest made the whole 144p–2160p ladder available and playback *looked*
  /// fixed, because everything that is easy to check — the manifest, the
  /// ladder, the init and index ranges — lives in the first few kilobytes of
  /// the file and is served perfectly. The video then stops about a minute in,
  /// which reads as a buffering fault rather than as a resolution bug. A
  /// progressive 360p stream, which is *not* capped, would have played to the
  /// end: the HD route was strictly worse than the one it replaced.
  ///
  /// So the choice is measured per video, by asking for two bytes from the end
  /// of the file, rather than hardcoding YouTube's current policy. That costs
  /// one small request on the videos where it matters and buys two things a
  /// constant could not: HD keeps working for the videos that genuinely serve
  /// in full, and the day a token arrives — or YouTube changes its mind — the
  /// app uses the full ladder again with no code change.
  ///
  /// Unknowns resolve to "capped". A missing `clen`, a timeout or a network
  /// error all mean the app cannot show that HD will work, and 360p that plays
  /// to the end beats HD that might not.
  Future<bool> _adaptiveTracksPlayThroughout(
    List<AdaptiveFormat> formats,
  ) async {
    final videos = [
      for (final f in formats)
        if (f.isVideo && f.isUsable) f,
    ]..sort((a, b) => b.height.compareTo(a.height));
    if (videos.isEmpty) return false;
    final probe = videos.first;

    // A short clip cannot reach the cap. This is what keeps HD working on
    // Shorts, where it is both safe and most worth having.
    if (probe.durationMs > 0 && probe.durationMs <= _definitelyUncappedMs) {
      return true;
    }

    final clen = int.tryParse(
      Uri.parse(probe.url).queryParameters['clen'] ?? '',
    );
    if (clen == null || clen < 4) return false;

    final client = http.Client();
    try {
      final response = await client
          .get(
            Uri.parse(probe.url),
            headers: {'Range': 'bytes=${clen - 2}-${clen - 1}'},
          )
          .timeout(const Duration(seconds: 8));
      final served = response.statusCode == 200 || response.statusCode == 206;
      if (!served) {
        debugPrint(
          'AI BIT: adaptive tracks are capped (HTTP ${response.statusCode} '
          'at the end of the file) — using the progressive stream',
        );
      }
      return served;
    } catch (e) {
      debugPrint('AI BIT: could not test the adaptive tracks — $e');
      return false;
    } finally {
      client.close();
    }
  }

  /// Builds and publishes a generated HLS manifest for iOS, or null.
  ///
  /// The index ranges are fetched in parallel, so this costs one round trip
  /// rather than one per rendition. A rendition whose `sidx` cannot be read is
  /// dropped rather than failing the set — a ladder missing its 144p rung is
  /// still a working ladder.
  Future<String?> _publishGeneratedHls(
    String videoId,
    List<AdaptiveFormat> formats,
  ) async {
    final candidates = hlsCandidates(formats);
    if (candidates.isEmpty) return null;

    final client = http.Client();
    try {
      final indexes = await Future.wait([
        for (final f in candidates) _segmentIndex(client, f),
      ]);
      final tracks = <HlsTrack>[];
      for (var i = 0; i < candidates.length; i++) {
        final index = indexes[i];
        if (index != null) tracks.add(HlsTrack(candidates[i], index));
      }
      final built = buildHls(tracks);
      if (built == null) return null;
      _generatedLadder = built.ladder;
      return await _hlsServer.publish(videoId, built);
    } catch (e) {
      debugPrint('AI BIT: could not generate HLS for $videoId — $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// The ladder of the last generated HLS set, so [resolve] can report it.
  List<String> _generatedLadder = const [];

  Future<SegmentIndex?> _segmentIndex(
    http.Client client,
    AdaptiveFormat format,
  ) async {
    try {
      final response = await client
          .get(
            Uri.parse(format.url),
            headers: {'Range': 'bytes=${format.indexStart}-${format.indexEnd}'},
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200 && response.statusCode != 206) return null;
      return parseSegmentIndex(
        response.bodyBytes,
        indexStart: format.indexStart,
      );
    } catch (_) {
      // Logged by the caller if the whole set fails; one missing rung is not
      // worth a line of its own.
      return null;
    }
  }

  /// Writes a generated DASH manifest to the cache directory and returns its
  /// `file://` URL, or null when these formats cannot make one.
  ///
  /// On disk rather than in memory because the player is handed a URL, not a
  /// document. It goes in the **cache** directory on purpose: the segment URLs
  /// inside expire within hours, so a manifest is worthless the next day and
  /// the OS is welcome to reclaim it. One file per video, overwritten on
  /// re-resolve, so a long session cannot accumulate them.
  ///
  /// A generated manifest over [formats] — DASH for ExoPlayer, HLS for
  /// AVPlayer — as cached playback sources, or null when neither can be built.
  ///
  /// The caller has already established that the tracks serve to the end;
  /// this only puts them back together into the one URL the player takes.
  Future<PlaybackSources?> _generatedSources(
    String key,
    String videoId,
    List<AdaptiveFormat> formats, {
    required String? audioOnlyUrl,
    required String? fallbackUrl,
  }) async {
    if (canUseDash) {
      final dashUrl = await _writeDashManifest(videoId, formats);
      if (dashUrl != null) {
        return _cache(key, PlaybackSources(
          url: dashUrl,
          qualities: const {},
          ladder: dashLadder(formats),
          audioOnlyUrl: audioOnlyUrl,
          isDash: true,
          // The one certain alternative if the manifest will not play.
          fallbackUrl: fallbackUrl,
        ));
      }
    }
    if (canUseGeneratedHls) {
      final hlsUrl = await _publishGeneratedHls(videoId, formats);
      if (hlsUrl != null) {
        return _cache(key, PlaybackSources(
          url: hlsUrl,
          qualities: const {},
          ladder: _generatedLadder,
          audioOnlyUrl: audioOnlyUrl,
          isHls: true,
          fallbackUrl: fallbackUrl,
        ));
      }
    }
    return null;
  }

  /// Whether the HD-unlock route is on, possible here, and not backed off.
  bool get _hdUnlockWorthTrying =>
      _attestation != null &&
      hdUnlockEnabled &&
      WebAttestation.isSupported &&
      DateTime.now().isAfter(_hdUnlockPausedUntil);

  /// After a failure that is not about one video — no token, or every web
  /// client refusing the token — the route is left alone for a while. Every
  /// capped video would otherwise pay the full cost of rediscovering that.
  DateTime _hdUnlockPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  static const _hdUnlockBackoff = Duration(minutes: 10);

  /// How long an upgrade may take before the viewer is left at 360p. The
  /// stream is already playing, so this bounds wasted work, not waiting.
  static const _hdUpgradeBudget = Duration(seconds: 60);

  /// The [PlaybackSources.upgrade] hook for one capped video: starts the route
  /// on first call, shares the attempt with any caller that arrives while it
  /// runs, and forgets a failed one so the next open — after the route's
  /// pause has lapsed — can try again instead of being pinned to 360p for the
  /// stream cache's lifetime. Checks `_hdUnlockWorthTrying` at call time, not
  /// at resolve time, so a video resolved during the pause is not written off.
  Future<PlaybackSources?> Function() _lazyUpgrade(
    String key,
    String videoId,
    PlayerStreams streams,
  ) {
    Future<PlaybackSources?>? inFlight;
    return () {
      final running = inFlight;
      if (running != null) return running;
      if (!_hdUnlockWorthTrying) return Future.value(null);
      final attempt = _upgradeToHd(key, videoId, streams);
      inFlight = attempt;
      attempt.then((result) {
        if (result == null) inFlight = null;
      }).catchError((Object _) {
        inFlight = null;
      });
      return attempt;
    };
  }

  /// Runs the HD-unlock route for an already-playing video and, if it yields
  /// tracks that serve to the end, replaces the cache entry with the HD
  /// sources and completes with them. Null on any failure.
  Future<PlaybackSources?> _upgradeToHd(
    String key,
    String videoId,
    PlayerStreams streams,
  ) async {
    debugPrint('AI BIT HD: upgrade started for $videoId');
    // The same step log the Settings test prints, kept here too so a stall
    // on a phone names its step in logcat rather than only "timed out".
    final steps = <String>[];
    try {
      return await () async {
        final attested = await _attestedStreams(videoId, log: steps);
        if (attested == null) {
          debugPrint('AI BIT HD: no attested streams - ${steps.join(' | ')}');
          return null;
        }
        if (attested.hlsUrl != null) {
          return _cache(key, PlaybackSources(
            url: attested.hlsUrl!,
            qualities: const {},
            audioOnlyUrl: streams.audioUrl,
            isHls: true,
            isLive: attested.isLive,
            fallbackUrl: streams.muxedUrl,
          ));
        }
        if (attested.adaptiveFormats.isEmpty ||
            !await _adaptiveTracksPlayThroughout(attested.adaptiveFormats)) {
          return null;
        }
        return _generatedSources(
          key,
          videoId,
          attested.adaptiveFormats,
          audioOnlyUrl: streams.audioUrl,
          fallbackUrl: streams.muxedUrl,
        );
      }()
          .timeout(_hdUpgradeBudget);
    } catch (e) {
      debugPrint('AI BIT: HD upgrade for $videoId did not complete — $e'
          ' — steps so far: ${steps.join(' | ')}');
      return null;
    }
  }

  /// Mints the token, loads the solver and reads the player build ahead of
  /// the first video, so the first upgrade costs one player request rather
  /// than a bot check. Fire-and-forget; failures are reported through the
  /// attestation's own status.
  void warmUpHd() {
    if (!_hdUnlockWorthTrying) return;
    unawaited(_attestation!.warmUp());
  }

  /// The web client's tracks for [videoId], resolved and stamped with a
  /// proof-of-origin token — or null when the route is off, unsupported, or
  /// fails anywhere along the way.
  ///
  /// Walks the web-family clients in order and takes the first that answers
  /// OK with formats a URL can be made from. A client answering with
  /// server-side streaming only (no URLs at all, which is what the web client
  /// did for a signed-in session when measured) is skipped, not treated as
  /// an error. Every reason for moving on is appended to [log] when given,
  /// which is how Settings → "Test HD unlock" explains itself.
  Future<PlayerStreams?> _attestedStreams(
    String videoId, {
    List<String>? log,
  }) async {
    final attestation = _attestation;
    if (attestation == null ||
        !hdUnlockEnabled ||
        !WebAttestation.isSupported) {
      return null;
    }
    try {
      final session = await attestation.session();
      if (session == null) {
        log?.add('No token: ${attestation.status}');
        _pauseHdUnlock('no token');
        return null;
      }
      final player = await attestation.player();
      log?.add('Player build: ${Uri.parse(player.url).pathSegments[2]}, '
          'sts ${player.signatureTimestamp}');

      var refusals = 0;
      var noUrls = 0;
      for (final client in YoutubePlayerClient.webClients) {
        final response = await _player.fetchWeb(
          videoId,
          client: client,
          visitorData: session.visitorData,
          poToken: session.poToken,
          signatureTimestamp: player.signatureTimestamp,
        );
        if (!response.isOk) {
          log?.add('${client.name}: ${response.status} '
              '${response.reason ?? ''}'.trim());
          // A token demand with a token attached means the token is not
          // being accepted; a video-specific refusal says something else.
          if (response.status == 'LOGIN_REQUIRED' ||
              (response.reason ?? '').contains('reloaded')) {
            refusals++;
          }
          continue;
        }
        if (!response.hasAddressableFormats) {
          log?.add('${client.name}: '
              '${response.serverAbr ? 'server-side streaming only, no URLs' : 'no formats'}');
          if (response.serverAbr) noUrls++;
          continue;
        }
        final solved =
            await attestation.solve(player.url, response.rawAdaptiveFormats);
        final formats = <AdaptiveFormat>[];
        for (final raw in response.rawAdaptiveFormats) {
          if (raw is! Map) continue;
          final resolved = resolveFormat(
            raw,
            solvedN: solved.n,
            solvedSig: solved.sig,
            poToken: session.poToken,
          );
          final parsed = parseAdaptiveFormat(resolved);
          if (parsed != null) formats.add(parsed);
        }
        final hasVideo = formats.any((f) => f.isVideo && f.isUsable);
        final hasAudio = formats.any((f) => f.isAudio);
        if (!hasVideo || !hasAudio) {
          log?.add('${client.name}: ${formats.length} of '
              '${response.rawAdaptiveFormats.length} tracks resolved — '
              'challenges unsolved');
          continue;
        }
        var top = 0;
        for (final f in formats) {
          if (f.isVideo && f.height > top) top = f.height;
        }
        log?.add('${client.name}: ${formats.length} tracks, up to ${top}p'
            '${response.hlsUrl != null ? ', plus an HLS ladder' : ''}');
        return PlayerStreams(
          hlsUrl: response.hlsUrl,
          audioUrl: _bestAacUrl(formats),
          adaptiveFormats: formats,
          isLive: response.isLive,
        );
      }
      if (refusals == YoutubePlayerClient.webClients.length) {
        _pauseHdUnlock('every web client refused the token');
      } else if (refusals + noUrls == YoutubePlayerClient.webClients.length) {
        // Measured on an emulator, 20 November 2026: with a freshly minted,
        // accepted token, WEB and MWEB answer with server-side streaming only
        // (formats, no URLs) and TVHTML5 with "The page needs to be
        // reloaded". That is a policy, not a blip — no URL means nothing to
        // build a manifest from — so the route rests for hours, not minutes,
        // instead of spending three player requests on every video.
        _pauseHdUnlock(
          'web clients answer with server-side streaming only',
          pauseFor: const Duration(hours: 6),
        );
      }
    } catch (e) {
      log?.add('Failed: $e');
      debugPrint('AI BIT: attestation route failed for $videoId — $e');
    }
    return null;
  }

  void _pauseHdUnlock(String why, {Duration pauseFor = _hdUnlockBackoff}) {
    _hdUnlockPausedUntil = DateTime.now().add(pauseFor);
    debugPrint('AI BIT: HD unlock paused for ${pauseFor.inMinutes} min — $why');
  }

  /// Highest-bitrate AAC track, or any audio, as the audio-only URL. The
  /// same preference as the player client's: AVPlayer decodes no Opus.
  static String? _bestAacUrl(List<AdaptiveFormat> formats) {
    AdaptiveFormat? best;
    AdaptiveFormat? any;
    for (final f in formats) {
      if (!f.isAudio) continue;
      if (any == null || f.bitrate > any.bitrate) any = f;
      if (f.codecFamily == 'aac' && (best == null || f.bitrate > best.bitrate)) {
        best = f;
      }
    }
    return (best ?? any)?.url;
  }

  /// Runs the whole HD-unlock chain on one long video and reports each step.
  ///
  /// This is the on-device diagnostic for a route that cannot be exercised
  /// on the development machine (no WebView there, and the bot check runs
  /// only in a real browser engine). It forces a fresh token, so it also
  /// answers "is the token itself still being issued" rather than reusing one
  /// from this morning.
  Future<List<String>> testHdUnlock({String videoId = 'aqz-KE-bpKQ'}) async {
    final log = <String>[];
    final attestation = _attestation;
    if (attestation == null || !WebAttestation.isSupported) {
      log.add('Not available on this platform');
      return log;
    }
    // A deliberate test is the one caller that should not be told "paused".
    _hdUnlockPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);
    final watch = Stopwatch()..start();
    final session = await attestation.session(force: true);
    if (session == null) {
      log.add('Token: FAILED — ${attestation.status}');
      return log;
    }
    log.add('Token: minted in ${watch.elapsed.inSeconds}s');
    final streams = await _attestedStreams(videoId, log: log);
    if (streams == null) {
      log.add('Result: no usable HD streams from any web client');
      return log;
    }
    if (streams.adaptiveFormats.isEmpty) {
      log.add('Result: HLS ladder only; HD will play through it');
      return log;
    }
    final full = await _adaptiveTracksPlayThroughout(streams.adaptiveFormats);
    log.add(full
        ? 'End of file: SERVED — HD will play in full'
        : 'End of file: REFUSED — still capped, so HD stays off');
    return log;
  }

  /// Failures return null rather than throwing: the caller's next step is the
  /// 360p stream, which is exactly the right answer when the manifest cannot
  /// be written.
  Future<String?> _writeDashManifest(
    String videoId,
    List<AdaptiveFormat> formats,
  ) async {
    final manifest = buildDashManifest(formats);
    if (manifest == null) return null;
    try {
      final dir = Directory(
        '${(await getTemporaryDirectory()).path}/dash',
      );
      await dir.create(recursive: true);
      // The .mpd extension is not cosmetic. ExoPlayer is told the format
      // explicitly, but better_player's own `isDataSourceDash` sniffs the URL
      // for "mpd" to decide a source is adaptive, and the plugin's fallback
      // content-type inference reads the path extension too.
      final file = File('${dir.path}/$videoId.mpd');
      await file.writeAsString(manifest, flush: true);
      return file.uri.toString();
    } catch (e) {
      debugPrint('AI BIT: could not write DASH manifest for $videoId — $e');
      return null;
    }
  }

  Future<PlaybackSources> resolve(
    String videoId, {
    bool audioOnly = false,
    bool force = false,
  }) async {
    final key = '$videoId:$audioOnly';
    // `force` skips the cache, for recovery after a playback failure. A
    // googlevideo URL can stop serving before the cache entry expires — it is
    // bound to an expiry stamp of YouTube's choosing and can be refused
    // outright mid-session — and handing the player the same dead URL again is
    // the one certain way to fail twice.
    if (force) {
      _streamCache.remove(key);
    } else {
      final cached = _streamCache[key];
      if (cached != null && DateTime.now().difference(cached.at) < _streamTtl) {
        return cached.sources;
      }
    }

    // Ask YouTube's player endpoint first. It is the only source of the HLS
    // ladder, which is both the way to get above 360p and the only way to play
    // a live stream at all.
    try {
      final streams = await _player.fetch(videoId);
      if (streams != null) {
        if (audioOnly && streams.audioUrl != null) {
          return _cache(key, PlaybackSources(
            url: streams.audioUrl!,
            qualities: const {},
            audioOnlyUrl: streams.audioUrl,
          ));
        }
        if (streams.hlsUrl != null) {
          return _cache(key, PlaybackSources(
            url: streams.hlsUrl!,
            // Quality is chosen inside the ladder; better_player reads the
            // variants off the manifest and offers them natively.
            qualities: const {},
            audioOnlyUrl: streams.audioUrl,
            isHls: true,
            isLive: streams.isLive,
          ));
        }
        // No ladder from YouTube, but the separate tracks are there. They can
        // be put back together into one URL — a DASH manifest for ExoPlayer,
        // an HLS one for AVPlayer — which is what lifts playback off the 360p
        // floor.
        //
        // Only when the tracks really serve to the end of the file, though.
        // See _adaptiveTracksPlayThroughout: a generated manifest over capped
        // tracks plays about a minute and then dies, which is worse than the
        // progressive stream below. The check is skipped entirely when neither
        // platform could use the result.
        if ((canUseDash || canUseGeneratedHls) &&
            streams.adaptiveFormats.isNotEmpty &&
            await _adaptiveTracksPlayThroughout(streams.adaptiveFormats)) {
          final generated = await _generatedSources(
            key,
            videoId,
            streams.adaptiveFormats,
            audioOnlyUrl: streams.audioUrl,
            fallbackUrl: streams.muxedUrl,
          );
          if (generated != null) return generated;
        }
        if (streams.muxedUrl != null) {
          // The tracks are capped, so the progressive stream plays NOW — and
          // the last route to HD runs behind it: ask as the web client with a
          // proof-of-origin token from YouTube's own bot check (see
          // attestation_service.dart). It takes seconds, and making playback
          // wait for it put every capped video on a spinner. Its tracks go
          // through exactly the same end-of-file test before the player is
          // switched over: the token is supposed to lift the cap, and
          // "supposed to" is not a reason to skip the measurement.
          final sources = PlaybackSources(
            url: streams.muxedUrl!,
            // Without these the picker showed only "Auto" on every video that
            // has no HLS ladder, which reads as broken rather than as "this
            // video only comes in one size".
            qualities: streams.muxedQualities,
            audioOnlyUrl: streams.audioUrl,
            upgrade: canUseDash || canUseGeneratedHls
                ? _lazyUpgrade(key, videoId, streams)
                : null,
          );
          return _cache(key, sources);
        }
      }
    } catch (e) {
      debugPrint('AI BIT: player endpoint failed for $videoId — $e');
    }

    Object? lastError;
    String? audioFallback;

    for (final client in _clientChain) {
      try {
        final manifest = await _yt.videos.streamsClient.getManifest(
          videoId,
          ytClients: [client],
        );
        final audioUrl = manifest.audioOnly.isEmpty
            ? null
            : manifest.audioOnly.withHighestBitrate().url.toString();

        if (audioOnly) {
          if (audioUrl != null) {
            return _cache(key, PlaybackSources(
              url: audioUrl,
              qualities: const {},
              audioOnlyUrl: audioUrl,
            ));
          }
          continue;
        }

        final combined = _combinedSources(manifest, audioUrl);
        if (combined != null) return _cache(key, combined);

        // This client has audio but no combined video track. Remember it and
        // keep looking rather than silently dropping the user to audio.
        audioFallback ??= audioUrl;
      } catch (e) {
        lastError = e;
        debugPrint('AI BIT: stream client failed for $videoId — $e');
      }
    }

    if (audioFallback != null) {
      return _cache(key, PlaybackSources(
        url: audioFallback,
        qualities: const {},
        audioOnlyUrl: audioFallback,
        videoUnavailable: true,
      ));
    }
    throw StreamResolutionException(videoId, lastError);
  }

  // ------------------------------------------------------------- downloads

  /// Picks the rendition to save for offline playback.
  ///
  /// Same constraint as [resolve]: the file has to be self-contained, so video
  /// downloads use the combined stream (360p today) while audio downloads get
  /// the highest available bitrate.
  Future<DownloadTarget> downloadTarget(
    String videoId, {
    bool audioOnly = false,
    bool hd = false,
    bool toMp3 = false,
    int? requestedHeight,
  }) async {
    Object? lastError;
    for (final client in _clientChain) {
      try {
        final manifest = await _yt.videos.streamsClient.getManifest(
          videoId,
          ytClients: [client],
        );

        final capped = await _downloadTracksCapped(videoId, manifest);

        if (audioOnly) {
          if (capped) {
            // The audio track would stop about a minute in, so the sound is
            // taken from the uncapped 360p file instead and cut out on the
            // device — a copy for "Audio", a re-encode for MP3.
            final muxed = _bestMuxed(manifest);
            if (muxed == null) continue;
            return DownloadTarget(
              handle: muxed,
              totalBytes: muxed.size.totalBytes,
              quality: toMp3 ? 'MP3' : 'Audio',
              fileExtension: toMp3 ? 'mp3' : 'm4a',
              audioOnly: true,
              toMp3: toMp3,
              extractAudio: !toMp3,
            );
          }
          if (manifest.audioOnly.isEmpty) continue;
          final best = _bestPlayableAudio(manifest.audioOnly);
          return DownloadTarget(
            handle: best,
            totalBytes: best.size.totalBytes,
            quality: toMp3 ? 'MP3' : 'Audio',
            // The download lands as whatever YouTube served; the extension only
            // becomes .mp3 once the conversion has actually run.
            fileExtension: toMp3 ? 'mp3' : best.container.name,
            audioOnly: true,
            toMp3: toMp3,
          );
        }

        // HD: video-only and audio-only, joined after both arrive.
        //
        // YouTube retired combined streams above 360p, so this is the only way
        // to get 1080p or better. Both tracks are copied into one container
        // without re-encoding, which is quick and loses nothing.
        // Not when the tracks are capped: that download would stop about a
        // minute in and then be joined into a truncated file. The 360p file
        // below is what plays to the end.
        if (hd &&
            !capped &&
            manifest.videoOnly.isNotEmpty &&
            manifest.audioOnly.isNotEmpty) {
          final videos = _downloadableVideos(manifest);
          if (videos.isNotEmpty) {
            // The requested height exactly where it exists, otherwise the
            // nearest below it, otherwise the best there is — so a picker entry
            // always resolves to something rather than failing.
            final video = requestedHeight == null
                ? videos.first
                : (videos.firstWhere(
                    (v) => v.videoResolution.height == requestedHeight,
                    orElse: () => videos.firstWhere(
                      (v) => v.videoResolution.height <= requestedHeight,
                      orElse: () => videos.last,
                    ),
                  ));
            final audio = _bestPlayableAudio(manifest.audioOnly);
            return DownloadTarget(
              handle: video,
              totalBytes: video.size.totalBytes,
              quality: video.qualityLabel,
              fileExtension: 'mp4',
              audioOnly: false,
              audioHandle: audio,
              audioBytes: audio.size.totalBytes,
            );
          }
        }

        final muxed = manifest.muxed.toList()
          ..sort(
            (a, b) => b.videoResolution.height.compareTo(a.videoResolution.height),
          );
        if (muxed.isEmpty) continue;
        return DownloadTarget(
          handle: muxed.first,
          totalBytes: muxed.first.size.totalBytes,
          quality: muxed.first.qualityLabel,
          fileExtension: muxed.first.container.name,
          audioOnly: false,
        );
      } catch (e) {
        lastError = e;
        debugPrint('AI BIT: download client failed for $videoId — $e');
      }
    }
    throw StreamResolutionException(videoId, lastError);
  }

  /// Video-only MP4 renditions to offer for HD download, tallest first, with
  /// H.264/AVC preferred over AV1.
  ///
  /// YouTube serves 1440p and 2160p **only** as AV1, and Apple's Photos and
  /// AVPlayer reject AV1 on most iPhones — a 4K download saves and then fails
  /// to play or export ("unsupported format", which is exactly what a 4K
  /// download hit). Preferring AVC caps HD at a universally compatible 1080p,
  /// the same "playable beats bigger" rule as [_bestPlayableAudio]. AV1 is used
  /// only when a video offers nothing else.
  static List<yt.VideoOnlyStreamInfo> _downloadableVideos(
    yt.StreamManifest manifest,
  ) {
    final mp4 = manifest.videoOnly
        .where((v) => v.container.name == 'mp4')
        .toList();
    final avc = mp4
        .where((v) => v.videoCodec.toLowerCase().startsWith('avc'))
        .toList();
    final chosen = avc.isNotEmpty ? avc : mp4;
    chosen.sort(
      (a, b) => b.videoResolution.height.compareTo(a.videoResolution.height),
    );
    return chosen;
  }

  /// Picks AAC-in-MP4 over the higher-bitrate Opus track.
  ///
  /// Same reasoning as [YoutubePlayerClient]: iOS decodes neither WebM nor
  /// Opus, so a downloaded Opus file would save successfully and then refuse
  /// to play — a worse failure than a slightly smaller bitrate.
  static yt.AudioOnlyStreamInfo _bestPlayableAudio(
    List<yt.AudioOnlyStreamInfo> tracks,
  ) {
    final aac = tracks
        .where(
          (t) =>
              t.container.name.toLowerCase().contains('mp4') ||
              t.codec.subtype.toLowerCase().contains('mp4'),
        )
        .toList();
    final pool = aac.isNotEmpty ? aac : tracks;
    return pool.reduce(
      (a, b) => a.bitrate.compareTo(b.bitrate) >= 0 ? a : b,
    );
  }

  /// Whether this video's separate audio and video tracks stop partway.
  ///
  /// The serving cap that limits HD playback (see
  /// [_adaptiveTracksPlayThroughout]) applies to a download exactly as it does
  /// to a player: the bytes past about a minute of media come back 403. Found
  /// on an emulator, 20 November 2026 — every option in the download picker
  /// except 360p was a track that would have died partway. Measured the same
  /// way, with two bytes from the end of the audio track, which shares the
  /// policy with the video tracks and is the cheapest to ask about. Unknowns
  /// count as capped, and the answer is remembered for the session.
  Future<bool> _downloadTracksCapped(
    String videoId,
    yt.StreamManifest manifest,
  ) async {
    final known = _downloadCapped[videoId];
    if (known != null) return known;
    if (manifest.audioOnly.isEmpty) return true;
    final track = _bestPlayableAudio(manifest.audioOnly);
    final total = track.size.totalBytes;
    var capped = true;
    if (total > 4) {
      final client = http.Client();
      try {
        final response = await client
            .get(track.url, headers: {'Range': 'bytes=${total - 2}-${total - 1}'})
            .timeout(const Duration(seconds: 8));
        capped = response.statusCode != 200 && response.statusCode != 206;
      } catch (e) {
        debugPrint('AI BIT: could not test the download tracks — $e');
      } finally {
        client.close();
      }
    }
    if (capped) {
      debugPrint('AI BIT: download tracks capped for $videoId — 360p only');
    }
    _downloadCapped[videoId] = capped;
    return capped;
  }

  final _downloadCapped = <String, bool>{};

  /// The tallest combined (video with sound) stream, or null.
  static yt.MuxedStreamInfo? _bestMuxed(yt.StreamManifest manifest) {
    final muxed = manifest.muxed.toList()
      ..sort(
        (a, b) => b.videoResolution.height.compareTo(a.videoResolution.height),
      );
    return muxed.isEmpty ? null : muxed.first;
  }

  /// Every rendition that can actually be downloaded, with real sizes, so the
  /// picker shows the choice before anything transfers.
  ///
  /// One combined 360p file needs no processing. Everything above it is a
  /// video-only track joined to audio, and audio can be converted to MP3 —
  /// both need FFmpeg, so they are only offered when [allowFfmpeg] is true and
  /// flagged with `needsFfmpeg` either way.
  Future<List<DownloadOption>> downloadOptions(
    String videoId, {
    required bool allowFfmpeg,
  }) async {
    for (final client in _clientChain) {
      try {
        final manifest = await _yt.videos.streamsClient.getManifest(
          videoId,
          ytClients: [client],
        );

        final options = <DownloadOption>[];
        final audio = manifest.audioOnly.isEmpty
            ? null
            : _bestPlayableAudio(manifest.audioOnly);
        final audioBytes = audio?.size.totalBytes ?? 0;
        final capped = await _downloadTracksCapped(videoId, manifest);
        final muxed = _bestMuxed(manifest);

        // HD renditions, tallest first, only where they can be joined — and
        // only where YouTube serves those tracks in full. Offered while capped,
        // every one of them downloaded the first minute and then failed.
        if (allowFfmpeg && audio != null && !capped) {
          final videos = _downloadableVideos(manifest);
          final seen = <int>{};
          for (final v in videos) {
            final h = v.videoResolution.height;
            // Every rendition except 360p, which the combined stream below
            // covers without a mux. This includes 144p/240p, so the smallest
            // sizes are downloadable for data saving.
            if (h == 360 || !seen.add(h)) continue;
            options.add(DownloadOption(
              audioOnly: false,
              quality: '${h}p',
              label: '${h}p',
              detail: 'Video with sound, joined on device',
              bytes: v.size.totalBytes + audioBytes,
              fileExtension: 'mp4',
              needsFfmpeg: true,
            ));
          }
        }

        // The one combined file, which always works.
        if (muxed != null) {
          final m = muxed;
          options.add(DownloadOption(
            audioOnly: false,
            quality: m.qualityLabel,
            label: m.qualityLabel,
            detail: 'Video with sound',
            bytes: m.size.totalBytes,
            fileExtension: m.container.name,
          ));
        }

        // Capped: the sound comes out of the 360p file instead, which needs
        // FFmpeg for both. The size shown is what crosses the network.
        if (capped && allowFfmpeg && muxed != null) {
          for (final (quality, label, detail, ext) in const [
            ('Audio', 'Audio only', 'Sound from the 360p file', 'm4a'),
            ('MP3', 'MP3', 'Converted for older players', 'mp3'),
          ]) {
            options.add(DownloadOption(
              audioOnly: true,
              quality: quality,
              label: label,
              detail: detail,
              bytes: muxed.size.totalBytes,
              fileExtension: ext,
              needsFfmpeg: true,
            ));
          }
        }

        // Audio, and MP3 where it can be converted.
        if (audio != null && !capped) {
          options.add(DownloadOption(
            audioOnly: true,
            quality: 'Audio',
            label: 'Audio only',
            detail: 'Best audio, no video',
            bytes: audioBytes,
            fileExtension: audio.container.name,
          ));
          if (allowFfmpeg) {
            options.add(DownloadOption(
              audioOnly: true,
              quality: 'MP3',
              label: 'MP3',
              detail: 'Audio converted for older players',
              bytes: audioBytes,
              fileExtension: 'mp3',
              needsFfmpeg: true,
            ));
          }
        }

        if (options.isNotEmpty) return options;
      } catch (e) {
        debugPrint('AI BIT: download options failed for $videoId — $e');
      }
    }
    return const [];
  }

  /// Opens the byte stream for [target]. The caller writes it to disk and
  /// tracks progress.
  /// Bytes for one half of a download. [audio] selects the separate audio
  /// track that HD downloads have to fetch alongside the video.
  Stream<List<int>> downloadBytes(DownloadTarget target, {bool audio = false}) {
    final handle = (audio ? target.audioHandle : target.handle) as yt.StreamInfo;
    return _rangedDownload(handle);
  }

  /// Fetches a progressive stream in bounded ranged chunks instead of one long
  /// open request.
  ///
  /// The one-request approach was the whole cause of "download stalled — no
  /// data received": YouTube throttles a single sustained googlevideo request
  /// down to nothing after the first burst, so on a phone the transfer would
  /// hang and the watchdog killed it. Asking for ~8 MB at a time keeps every
  /// request short enough to run at full speed. A chunk that stalls or errors
  /// is retried from exactly where it stopped — the bytes already yielded are
  /// on disk — so a hiccup costs one chunk, not the whole download.
  ///
  /// Anything this cannot range over — fragmented DASH, or a stream whose size
  /// YouTube did not report — falls back to the package's own streaming.
  Stream<List<int>> _rangedDownload(yt.StreamInfo info) async* {
    final total = info.size.totalBytes;
    if (total <= 0 || info.fragments.isNotEmpty) {
      yield* _yt.videos.streamsClient.get(info);
      return;
    }

    const chunkSize = 8 * 1024 * 1024; // 8 MB per request.
    const chunkTimeout = Duration(seconds: 25);
    const maxAttempts = 3;

    final client = http.Client();
    try {
      var received = 0;
      while (received < total) {
        final end = (received + chunkSize >= total ? total : received + chunkSize) - 1;
        var attempt = 0;
        while (true) {
          try {
            final request = http.Request('GET', info.url)
              ..headers['Range'] = 'bytes=$received-$end';
            final response =
                await client.send(request).timeout(chunkTimeout);
            if (response.statusCode != 206 && response.statusCode != 200) {
              throw http.ClientException(
                'Unexpected status ${response.statusCode}',
                info.url,
              );
            }
            // A gap between packets longer than the timeout is a stall, not a
            // slow link — turn it into a retry rather than an endless wait.
            await for (final data in response.stream.timeout(chunkTimeout)) {
              received += data.length;
              yield data;
            }
            break; // chunk complete
          } catch (e) {
            if (++attempt >= maxAttempts) rethrow;
            await Future<void>.delayed(Duration(seconds: attempt));
            // Loop retries from the current `received`, resuming the chunk.
          }
        }
      }
    } finally {
      client.close();
    }
  }

  PlaybackSources _cache(String key, PlaybackSources sources) {
    _streamCache[key] = (sources: sources, at: DateTime.now());
    return sources;
  }

  static final _clientChain = <yt.YoutubeApiClient>[
    yt.YoutubeApiClient.androidVr,
    yt.YoutubeApiClient.androidSdkless,
    // ignore: deprecated_member_use
    yt.YoutubeApiClient.android,
    yt.YoutubeApiClient.ios,
    yt.YoutubeApiClient.tv,
  ];

  /// Picks the best stream that carries video *and* audio, or null if this
  /// manifest has none.
  PlaybackSources? _combinedSources(yt.StreamManifest manifest, String? audioUrl) {
    // Adaptive HLS first when it is offered: the player handles the bitrate
    // ladder itself and it survives network changes far better than a fixed
    // progressive URL. YouTube rarely returns it for on-demand video today,
    // but live streams still do.
    final hls = manifest.hls.whereType<yt.HlsMuxedStreamInfo>().toList()
      ..sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));
    if (hls.isNotEmpty) {
      return PlaybackSources(
        url: hls.first.url.toString(),
        qualities: _qualityMap(hls.map((s) => (s.qualityLabel, s.url.toString()))),
        audioOnlyUrl: audioUrl,
        isHls: true,
      );
    }

    final muxed = manifest.muxed.toList()
      ..sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));
    if (muxed.isNotEmpty) {
      return PlaybackSources(
        url: muxed.first.url.toString(),
        qualities: _qualityMap(muxed.map((s) => (s.qualityLabel, s.url.toString()))),
        audioOnlyUrl: audioUrl,
      );
    }
    return null;
  }

  /// Collapses duplicate labels (`720p60` and `720p` both appear) keeping the
  /// first — the list is already sorted best-first.
  Map<String, String> _qualityMap(Iterable<(String, String)> entries) {
    final map = <String, String>{};
    for (final (label, url) in entries) {
      map.putIfAbsent(label, () => url);
    }
    return map;
  }

  // ---------------------------------------------------------------- helpers

  Future<List<VideoBrief>> _safe(Future<List<VideoBrief>> Function() task) async {
    try {
      return await task();
    } catch (e) {
      debugPrint('AI BIT: feed section failed — $e');
      return const [];
    }
  }

  static List<String> _rotate(List<String> source, int offset) {
    if (source.isEmpty) return source;
    final start = offset % source.length;
    return [...source.sublist(start), ...source.sublist(0, start)];
  }

  /// Round-robins the sections so no single channel or topic owns the top of
  /// the feed, dropping duplicates as it goes.
  ///
  /// [skip] drops the first n of each section, so a refresh shows what was
  /// further down rather than the same head of every list.
  static List<VideoBrief> _interleave(
    List<List<VideoBrief>> sections, {
    int skip = 0,
  }) {
    final out = <VideoBrief>[];
    final seen = <String>{};
    // Never skip so far that a short section empties out entirely.
    final shortest = sections
        .where((s) => s.isNotEmpty)
        .fold(1 << 30, (m, s) => s.length < m ? s.length : m);
    final offset = shortest == 1 << 30 ? 0 : skip % shortest;
    if (offset > 0) {
      sections = sections
          .map((s) => s.length > offset ? s.sublist(offset) : s)
          .toList();
    }
    final longest = sections.fold(0, (m, s) => s.length > m ? s.length : m);
    for (var i = 0; i < longest; i++) {
      for (final section in sections) {
        if (i >= section.length) continue;
        final video = section[i];
        if (seen.add(video.id)) out.add(video);
      }
    }
    return out;
  }
}

class StreamResolutionException implements Exception {
  StreamResolutionException(this.videoId, this.cause);

  final String videoId;
  final Object? cause;

  @override
  String toString() =>
      'Could not find a playable stream for $videoId. '
      'YouTube may have changed its player, or the video is private, '
      'age-restricted or region-locked.';
}
