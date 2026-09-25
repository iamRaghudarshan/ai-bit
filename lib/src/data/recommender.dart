/// Ranks candidate videos the way YouTube's own recommender does, with the
/// signals this app can actually see.
///
/// ## Why this exists
///
/// The home feed used to be assembled and then shown in the order it was
/// assembled: several searches and channel listings round-robined together,
/// with a rotating window so a refresh looked different. Nothing was ever
/// *scored*. A video you would never watch sat above one you would, purely
/// because of which source fetched it, and a video you had already watched
/// could come back at the top. "Up next" was worse — it was YouTube's related
/// list verbatim, with no reference to the user at all.
///
/// ## What it is modelled on
///
/// Covington, Adams & Sargin, *Deep Neural Networks for YouTube
/// Recommendations* (RecSys '16), which is still the public description of the
/// system's shape. Two stages: **candidate generation** pulls a few hundred
/// plausible videos from several sources, and **ranking** scores that much
/// smaller set with far richer features. [YtRepository] does the first stage;
/// this file is the second.
///
/// Four of that paper's specific findings are reproduced here, because each
/// one fixes something the old feed got wrong:
///
///  1. **Rank on expected watch time, not on clicks.** Their ranking network
///     predicts how long a video will be watched, weighting training examples
///     by watch time, precisely because optimising for clicks promotes
///     clickbait. Here there is no network, but the same idea drives
///     [TasteProfile]: a channel's affinity is the sum of *how much of each
///     video was actually watched*, so a video abandoned after ten seconds
///     barely counts while one watched to the end counts fully. The old feed
///     treated both as identical — opening a video was the entire signal.
///
///  2. **"Example age", i.e. freshness is a first-class feature.** They feed
///     the age of the training example in explicitly, because a recommender
///     trained on a window of history otherwise behaves as though that window
///     were the present, and recommends stale video. [_freshnessScore] is the
///     counterpart: uploads are preferred while recent, on a curve that
///     flattens rather than a cliff, so a genuinely good older video still
///     places.
///
///  3. **Previous impressions are a ranking feature.** The paper lists "the
///     number of previous impressions" among the most important features, and
///     the reason is churn: a video shown repeatedly and never clicked should
///     stop being shown. This is what makes pull-to-refresh mean something.
///     The old feed rotated a window modulo the list length, which cycled back
///     around to the same rows; this demotes what has already been put in
///     front of the user and never opened.
///
///  4. **Blend candidates from several sources, then rank them together.**
///     Sources carry a prior ([CandidateSource.prior]) rather than a fixed
///     share of the feed, so a strong search-derived video can outrank a weak
///     subscription upload instead of losing to it on source alone.
///
/// Plus one thing the paper treats as a solved implementation detail and this
/// app needs spelt out: **diversity**. A greedy pass in [rankFeed] penalises
/// each additional video from a channel already represented, so one prolific
/// channel cannot take the top of the feed even when it wins on every other
/// term.
///
/// ## Everything here is pure
///
/// No I/O, no network, no plugins, no clock of its own — [now] is always
/// passed in. That is deliberate and is the same reasoning as
/// `takeout_import.dart`: ranking logic that cannot be tested is ranking logic
/// that rots the next time a term is added beside it, and its failure mode is
/// not a crash but a feed that is quietly slightly worse, which nobody ever
/// files a bug for.
library;

import 'dart:math' as math;

import 'models.dart';

/// Where a candidate came from, and how much that fact alone is worth.
///
/// A prior, not a quota. The old feed gave each source a fixed number of slots
/// and interleaved them, which meant the ordering could never express "this
/// search result is better than that subscription upload".
enum CandidateSource {
  /// An upload from a channel followed on this device. The strongest statement
  /// of intent available without an account — the user pressed Subscribe.
  subscription(1.0),

  /// A video YouTube itself lists as related to something recently watched.
  ///
  /// This is the closest thing to the paper's co-watch signal that an app
  /// without an account can reach: the `next` endpoint's related list is built
  /// from what everybody else watched after the same video. It is the single
  /// most valuable source here and was previously used only on the watch page,
  /// never in the feed.
  coWatch(0.9),

  /// Another upload from a channel behind a recent watch, followed or not.
  watchedChannel(0.7),

  /// A result for something the user recently searched for.
  search(0.55),

  /// Cold-start filler from a broad evergreen topic. Deliberately last: it
  /// knows nothing about the user and exists so a fresh install is not empty.
  topic(0.2);

  const CandidateSource(this.prior);

  /// 0..1, added to the score before the personal terms.
  final double prior;
}

/// One watched video, reduced to what ranking needs.
///
/// [completion] rather than a plain "was watched" flag is the whole point —
/// see finding 1 in the library comment.
class WatchSignal {
  const WatchSignal({
    required this.videoId,
    required this.channelId,
    required this.title,
    required this.watchedAt,
    required this.completion,
  });

  final String videoId;
  final String channelId;
  final String title;
  final DateTime watchedAt;

  /// Fraction of the video watched, 0..1.
  ///
  /// Videos with no known duration land at [assumedCompletion] rather than 0
  /// or 1: an unknown length is a parsing gap, not evidence about the user,
  /// and both extremes would be a stronger claim than the data supports.
  final double completion;

  /// What an unknown duration is worth. Live streams and some browse renderers
  /// carry no duration at all.
  static const assumedCompletion = 0.5;

  /// Builds a signal from the columns history stores.
  static WatchSignal fromWatch({
    required String videoId,
    required String channelId,
    required String title,
    required DateTime watchedAt,
    required Duration position,
    Duration? duration,
  }) {
    final double completion;
    if (duration == null || duration.inMilliseconds <= 0) {
      completion = assumedCompletion;
    } else {
      completion =
          (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    }
    return WatchSignal(
      videoId: videoId,
      channelId: channelId,
      title: title,
      watchedAt: watchedAt,
      completion: completion,
    );
  }
}

/// One remembered search, with how often it was repeated.
class SearchSignal {
  const SearchSignal({
    required this.query,
    required this.hits,
    required this.searchedAt,
  });

  final String query;

  /// Times the query has been repeated. A recurring interest should outrank a
  /// one-off lookup, which is why the `searches` table counts at all.
  final int hits;
  final DateTime searchedAt;
}

/// How many times a video has been put in front of the user without being
/// opened, and when that last happened.
class ImpressionCount {
  const ImpressionCount({
    required this.videoId,
    required this.shown,
    required this.lastShownAt,
  });

  final String videoId;
  final int shown;
  final DateTime lastShownAt;
}

/// What the app believes about the user, derived entirely from local history.
///
/// Rebuilt per feed load rather than cached: it is a few hundred rows of
/// arithmetic, and a stale profile is exactly how the old feed came to show a
/// session's worth of recommendations that predated everything the user had
/// done in it.
class TasteProfile {
  const TasteProfile({
    required this.channelAffinity,
    required this.topicWeights,
    required this.subscribed,
    required this.watchedIds,
    required this.lastWatchedOnChannel,
  });

  /// Channel id to interest, already recency-decayed and completion-weighted.
  /// Not normalised — [_normalise] handles that at scoring time so the raw
  /// numbers stay readable in a test failure.
  final Map<String, double> channelAffinity;

  /// Interest in a word, from search queries and from the titles of videos
  /// that were actually watched through.
  final Map<String, double> topicWeights;

  /// Channels followed on this device.
  final Set<String> subscribed;

  /// Everything in watch history, so the feed can stop re-recommending it.
  final Set<String> watchedIds;

  /// When each channel was last watched, for the paper's "time since last
  /// watch on this channel" feature.
  final Map<String, DateTime> lastWatchedOnChannel;

  /// An empty profile — a fresh install, or Kids mode, which deliberately
  /// consults no personal signal at all.
  static const empty = TasteProfile(
    channelAffinity: {},
    topicWeights: {},
    subscribed: {},
    watchedIds: {},
    lastWatchedOnChannel: {},
  );

  bool get isEmpty =>
      channelAffinity.isEmpty && topicWeights.isEmpty && subscribed.isEmpty;

  /// Interest decays with a half-life of two weeks.
  ///
  /// Long enough that a fortnight-old binge still counts for something, short
  /// enough that what was watched last night dominates. This is the app's
  /// stand-in for the paper's "example age": without it, a profile built over
  /// months behaves as though every month were now, and the feed slowly
  /// becomes a museum of what the user used to like.
  static const interestHalfLife = Duration(days: 14);

  /// Half-life for a search query's weight. Shorter than [interestHalfLife]:
  /// a search is usually a task, and last month's task is finished.
  static const searchHalfLife = Duration(days: 7);

  static double _decay(DateTime at, DateTime now, Duration halfLife) {
    final elapsed = now.difference(at).inSeconds;
    // A timestamp in the future is a clock change, not a prophecy. Treat it as
    // "just now" rather than letting the exponent blow the weight up.
    if (elapsed <= 0) return 1;
    return math.pow(0.5, elapsed / halfLife.inSeconds).toDouble();
  }

  /// Builds the profile.
  ///
  /// [history] should be newest-first but need not be; nothing here depends on
  /// the order, only on the timestamps.
  factory TasteProfile.from({
    required List<WatchSignal> history,
    required List<SearchSignal> searches,
    required Set<String> subscribed,
    required DateTime now,
  }) {
    final affinity = <String, double>{};
    final topics = <String, double>{};
    final watched = <String>{};
    final lastOnChannel = <String, DateTime>{};

    for (final watch in history) {
      watched.add(watch.videoId);

      final recency = _decay(watch.watchedAt, now, interestHalfLife);
      // Completion IS the weight. A video opened and abandoned after a few
      // seconds is close to no evidence; one watched through is full evidence.
      // This is the whole of finding 1 in one line.
      final weight = watch.completion * recency;

      if (watch.channelId.isNotEmpty) {
        affinity[watch.channelId] = (affinity[watch.channelId] ?? 0) + weight;
        final previous = lastOnChannel[watch.channelId];
        if (previous == null || watch.watchedAt.isAfter(previous)) {
          lastOnChannel[watch.channelId] = watch.watchedAt;
        }
      }

      // Title words only count once the video was genuinely watched. Titles of
      // things bounced off immediately are the clickbait the paper warns
      // against learning from, and learning them would pull the feed towards
      // more of exactly what the user rejected.
      if (watch.completion >= 0.3) {
        for (final token in tokenise(watch.title)) {
          topics[token] = (topics[token] ?? 0) + weight * 0.5;
        }
      }
    }

    for (final search in searches) {
      final recency = _decay(search.searchedAt, now, searchHalfLife);
      // Repeats matter but with diminishing returns — searching something
      // twenty times is not twenty times the interest of searching it once.
      final weight = recency * (1 + math.log(search.hits.clamp(1, 1000)));
      for (final token in tokenise(search.query)) {
        topics[token] = (topics[token] ?? 0) + weight;
      }
    }

    return TasteProfile(
      channelAffinity: affinity,
      topicWeights: topics,
      subscribed: subscribed,
      watchedIds: watched,
      lastWatchedOnChannel: lastOnChannel,
    );
  }
}

/// Words too common to say anything about what someone is interested in.
///
/// Short rather than exhaustive. The length filter in [tokenise] already drops
/// most noise; this catches the frequent words long enough to survive it, which
/// otherwise match everything and turn the topic term into a constant.
const _stopWords = {
  'the', 'and', 'for', 'you', 'your', 'with', 'this', 'that', 'from', 'have',
  'how', 'what', 'why', 'when', 'was', 'are', 'not', 'but', 'all', 'can',
  'new', 'get', 'out', 'now', 'top', 'best', 'full', 'video', 'official',
  'watch', 'episode', 'part', 'latest', 'live', 'shorts', 'short', 'free',
  'vs', 'ft', 'feat', 'hd', 'ep',
};

/// Splits text into the words worth matching on.
///
/// Deliberately crude — lowercase, split on anything that is not a letter or
/// digit, drop stop words and anything under three characters. It is not
/// stemming and does not pretend to be: "review" and "reviews" are different
/// tokens here, which costs a little recall and keeps the function something a
/// test can state the expected output of exactly.
List<String> tokenise(String text) {
  final out = <String>[];
  for (final raw in text.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) {
    if (raw.length < 3) continue;
    if (_stopWords.contains(raw)) continue;
    out.add(raw);
  }
  return out;
}

/// A candidate with the source that produced it.
class Candidate {
  const Candidate({required this.video, required this.source});

  final VideoBrief video;
  final CandidateSource source;
}

/// A scored candidate, with the terms kept apart.
///
/// The breakdown is not debug clutter: every term here is a judgement call
/// about what the user wants, and a test that could only assert on the total
/// would pass just as happily with two terms cancelling each other out.
class ScoredCandidate {
  const ScoredCandidate({
    required this.video,
    required this.source,
    required this.affinity,
    required this.topic,
    required this.freshness,
    required this.popularity,
    required this.impressionPenalty,
    required this.watchedPenalty,
  });

  final VideoBrief video;
  final CandidateSource source;

  /// How much this channel has been watched, 0..1 after normalisation.
  final double affinity;

  /// Title overlap with what the user searches for and watches, 0..1.
  final double topic;

  /// Upload recency, 0..1.
  final double freshness;

  /// Log-scaled view count, 0..1. The weakest term by design — see [weights].
  final double popularity;

  /// Negative. Grows with the number of times this video has been shown in the
  /// feed and not opened.
  final double impressionPenalty;

  /// Negative, and large, when the video is already in watch history.
  final double watchedPenalty;

  /// The weight of each term in the final score.
  ///
  /// Read them as a statement of priorities rather than tuned constants,
  /// because that is what they are: who you watch matters most, what it is
  /// about is close behind, whether it is recent matters, and **how popular it
  /// is matters least of all** — popularity is what a feed falls back on when
  /// it knows nothing about you, and this one usually knows something.
  static const weights = (
    source: 1.0,
    affinity: 1.4,
    topic: 1.1,
    freshness: 0.6,
    popularity: 0.25,
  );

  double get total =>
      source.prior * weights.source +
      affinity * weights.affinity +
      topic * weights.topic +
      freshness * weights.freshness +
      popularity * weights.popularity +
      impressionPenalty +
      watchedPenalty;
}

/// Cost of having already shown a video that was not opened, per impression.
///
/// Capped at [_maxImpressionPenalty] so a video cannot be buried permanently
/// by a few scroll-pasts — the user may simply not have been in the mood.
const _impressionCost = 0.35;
const _maxImpressionPenalty = 1.4;

/// Cost of already having watched a video.
///
/// Large enough to sink it below anything unwatched, but a penalty and not a
/// filter: a feed assembled from thin candidates should degrade to "things you
/// have seen" rather than to an empty screen.
const _watchedCost = 5.0;

/// Impressions older than this are forgotten. A video passed over a fortnight
/// ago is worth offering again.
const impressionMemory = Duration(days: 14);

/// Half-life of an upload's freshness, for the "example age" term.
///
/// Ten days: a video posted today clearly beats one from last month, while a
/// year-old video and a two-year-old video are both simply "old" and are left
/// to be separated by the terms that actually describe the user.
const _freshnessHalfLife = Duration(days: 10);

double _freshnessScore(VideoBrief video, DateTime now) {
  final age = uploadAgeSeconds(video, now);
  // Unknown age scores as the midpoint rather than 0. Plenty of browse
  // renderers carry no date, and treating that as "ancient" would quietly
  // demote whole sources for a parsing gap.
  if (age == null) return 0.5;
  return math.pow(0.5, age / _freshnessHalfLife.inSeconds).toDouble();
}

/// Rough age of [video] in seconds, or null when nothing usable was returned.
///
/// A copy of the rule in [YtRepository.uploadAgeSeconds], taking [now] instead
/// of reading the clock so this file stays pure. The two must agree, which a
/// test asserts.
int? uploadAgeSeconds(VideoBrief video, DateTime now) {
  final date = video.uploadDate;
  if (date != null) {
    final seconds = now.difference(date).inSeconds;
    return seconds < 0 ? 0 : seconds;
  }
  final raw = video.uploadRaw;
  if (raw == null || raw.isEmpty) return null;
  final match = RegExp(
    r'(\d+)\s*(second|minute|hour|day|week|month|year)',
  ).firstMatch(raw.toLowerCase());
  if (match == null) return null;
  final count = int.tryParse(match.group(1)!);
  if (count == null) return null;
  const perUnit = {
    'second': 1,
    'minute': 60,
    'hour': 3600,
    'day': 86400,
    'week': 604800,
    'month': 2592000,
    'year': 31536000,
  };
  return count * perUnit[match.group(2)]!;
}

/// Views, log-scaled to 0..1 across the range a real video occupies.
///
/// Linear would make one viral video worth more than every other term
/// combined. A million views is roughly 0.6 here and ten million roughly 0.75,
/// which is the right shape: popularity is a tiebreak, not a verdict.
double _popularityScore(VideoBrief video) {
  final views = video.viewCount ?? 0;
  if (views <= 0) return 0;
  // log10(1e10) = 10 is comfortably past the most-viewed video ever.
  return (math.log(views) / math.ln10 / 10).clamp(0.0, 1.0);
}

/// Scales a raw affinity into 0..1 against the strongest channel in the
/// profile, so one heavy user's numbers and one light user's mean the same
/// thing to the weights.
double _normalise(double value, double max) {
  if (max <= 0) return 0;
  return (value / max).clamp(0.0, 1.0);
}

/// Scores one candidate. Pure; [now] is the only clock.
ScoredCandidate score({
  required Candidate candidate,
  required TasteProfile profile,
  required DateTime now,
  ImpressionCount? impression,
  double maxAffinity = 0,
}) {
  final video = candidate.video;

  var affinity = _normalise(
    profile.channelAffinity[video.channelId] ?? 0,
    maxAffinity,
  );
  // Subscribing is an explicit statement that watch history may not have
  // caught up with — a channel followed this morning has no watch time behind
  // it yet. Floor it rather than add, so a followed channel the user also
  // watches constantly is not counted twice.
  if (profile.subscribed.contains(video.channelId) && affinity < 0.6) {
    affinity = 0.6;
  }

  final tokens = tokenise(video.title);
  var topic = 0.0;
  if (tokens.isNotEmpty && profile.topicWeights.isNotEmpty) {
    final maxTopic = profile.topicWeights.values.fold<double>(0, math.max);
    var sum = 0.0;
    for (final token in tokens) {
      sum += profile.topicWeights[token] ?? 0;
    }
    // Divided by the token count, not left as a sum: otherwise a long title
    // wins by having more chances to match, which is a title-length contest
    // rather than a relevance one.
    topic = _normalise(sum / tokens.length, maxTopic);
  }

  var impressionPenalty = 0.0;
  if (impression != null &&
      now.difference(impression.lastShownAt) < impressionMemory) {
    impressionPenalty =
        -math.min(impression.shown * _impressionCost, _maxImpressionPenalty);
  }

  return ScoredCandidate(
    video: video,
    source: candidate.source,
    affinity: affinity,
    topic: topic,
    freshness: _freshnessScore(video, now),
    popularity: _popularityScore(video),
    impressionPenalty: impressionPenalty,
    watchedPenalty:
        profile.watchedIds.contains(video.id) ? -_watchedCost : 0.0,
  );
}

/// How much each additional video from a channel already in the output costs.
///
/// Applied greedily in [rankFeed]. Without it the top of the feed collapses
/// onto whichever channel the profile likes most, which is not what anybody
/// means by a recommendation feed — a point the existing `_newestFirst` comment
/// already makes about the subscriptions tab.
const _channelRepeatCost = 0.55;

/// Ranks [candidates] into the final feed order.
///
/// Deduplicates by video id, keeping the highest-scoring copy — the same video
/// legitimately arrives from several sources, and the best case for it is the
/// one that should count.
///
/// The selection is greedy rather than a plain sort so that diversity can
/// depend on what has already been emitted: each pick is the best remaining
/// candidate *after* charging [_channelRepeatCost] for every video from its
/// channel already in the output. O(n²) on a few hundred candidates, which is
/// nothing next to the network round trips that produced them, and it is exact
/// — a sort with a pre-computed penalty could not be, because the penalty is
/// not known until the earlier picks are made.
List<VideoBrief> rankFeed({
  required List<Candidate> candidates,
  required TasteProfile profile,
  required DateTime now,
  Map<String, ImpressionCount> impressions = const {},
  int limit = 120,
}) {
  if (candidates.isEmpty) return const [];

  final maxAffinity = profile.channelAffinity.values.fold<double>(0, math.max);

  // Best score wins a duplicate.
  final best = <String, ScoredCandidate>{};
  for (final candidate in candidates) {
    final scored = score(
      candidate: candidate,
      profile: profile,
      now: now,
      impression: impressions[candidate.video.id],
      maxAffinity: maxAffinity,
    );
    final existing = best[candidate.video.id];
    if (existing == null || scored.total > existing.total) {
      best[candidate.video.id] = scored;
    }
  }

  final pool = best.values.toList()
    // Sorted first so the greedy pass starts from a stable order and ties
    // break deterministically rather than on Map iteration order.
    ..sort((a, b) => b.total.compareTo(a.total));

  final out = <VideoBrief>[];
  final perChannel = <String, int>{};
  final taken = List<bool>.filled(pool.length, false);
  final wanted = math.min(limit, pool.length);

  for (var picked = 0; picked < wanted; picked++) {
    var bestIndex = -1;
    var bestScore = double.negativeInfinity;
    for (var i = 0; i < pool.length; i++) {
      if (taken[i]) continue;
      final channel = pool[i].video.channelId;
      final seen = channel.isEmpty ? 0 : (perChannel[channel] ?? 0);
      final adjusted = pool[i].total - seen * _channelRepeatCost;
      if (adjusted > bestScore) {
        bestScore = adjusted;
        bestIndex = i;
      }
    }
    if (bestIndex < 0) break;
    taken[bestIndex] = true;
    final chosen = pool[bestIndex].video;
    out.add(chosen);
    if (chosen.channelId.isNotEmpty) {
      perChannel[chosen.channelId] = (perChannel[chosen.channelId] ?? 0) + 1;
    }
  }

  return out;
}

/// Orders the "Up next" list for [current].
///
/// YouTube's own related list is already a recommendation — it is built from
/// what everyone else watched after the same video, which is the co-watch
/// signal the paper's candidate generator is trained on — so it is kept as a
/// strong prior rather than thrown away and re-derived. What this adds is the
/// single viewer: already-watched videos sink, followed and well-watched
/// channels rise, and the channel of the video *currently playing* is damped
/// so autoplay does not walk down one uploader's back catalogue.
///
/// [related] must be in YouTube's order; the position in that list is the
/// prior.
List<VideoBrief> rankUpNext({
  required VideoBrief current,
  required List<VideoBrief> related,
  required TasteProfile profile,
  required DateTime now,
  Map<String, ImpressionCount> impressions = const {},
}) {
  if (related.isEmpty) return const [];

  final maxAffinity = profile.channelAffinity.values.fold<double>(0, math.max);
  final ranked = <({double score, int index, VideoBrief video})>[];

  for (var i = 0; i < related.length; i++) {
    final video = related[i];
    // Never suggest the video that is playing.
    if (video.id == current.id) continue;

    final scored = score(
      candidate: Candidate(video: video, source: CandidateSource.coWatch),
      profile: profile,
      now: now,
      impression: impressions[video.id],
      maxAffinity: maxAffinity,
    );

    // YouTube's ordering, decaying with position. The first entry is worth a
    // full point and the tenth about a third of one, which is enough to keep
    // the list recognisably YouTube's while letting a strong personal match
    // climb over a weak one.
    final positionPrior = 1 / (1 + i * 0.2);

    // Autoplay that marches through one channel is the complaint this damping
    // exists for. The channel is still allowed to win — it just has to win on
    // something other than being the one already on screen.
    final sameChannel =
        video.channelId.isNotEmpty && video.channelId == current.channelId;

    ranked.add((
      score: scored.total + positionPrior - (sameChannel ? 0.4 : 0.0),
      index: i,
      video: video,
    ));
  }

  // Decorated with the original index because Dart's List.sort is not stable,
  // and without it equal scores would scramble YouTube's ordering for no
  // reason — the same trap `_newestFirst` documents.
  ranked.sort(
    (a, b) => a.score != b.score
        ? b.score.compareTo(a.score)
        : a.index.compareTo(b.index),
  );
  return [for (final r in ranked) r.video];
}
