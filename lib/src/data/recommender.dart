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

/// How often a video has been put in front of the user without being opened,
/// and when that last happened.
class ImpressionCount {
  const ImpressionCount({
    required this.videoId,
    required this.shown,
    required this.lastShownAt,
    double? attention,
  }) : attention = attention ?? shown * 1.0;

  final String videoId;

  /// Raw count of showings, for display and for deciding what is stale.
  final int shown;

  final DateTime lastShownAt;

  /// Sum of [attentionAtRank] over every showing — how much of the user's
  /// notice this video has actually had.
  ///
  /// This is the local stand-in for the **shallow tower** in YouTube's
  /// multitask ranking paper, which trains a small side model on the position
  /// a video was shown at so the main model can have that bias subtracted.
  /// Their reason applies unchanged here: a video shown at the top and skipped
  /// is real evidence of disinterest, while one glimpsed at the bottom of a
  /// scroll is almost none, and treating the two alike teaches the ranker to
  /// bury things for having been listed rather than for having been rejected.
  ///
  /// Theirs is a learned scalar; this is a fixed attention curve. Same intent,
  /// much simpler mechanism, and no training loop to feed it — which is worth
  /// being plain about rather than calling it the same thing.
  final double attention;
}

/// How much notice a card at [rank] in the feed can be assumed to have had.
///
/// A gentle positional decay rather than a cliff: the top card has the user's
/// full attention, and by about the thirtieth they are scrolling. Bounded
/// below at [_minAttention] because an impression the recorder captured did
/// genuinely appear on screen — this discounts it, it never erases it.
double attentionAtRank(int rank) {
  if (rank <= 0) return 1;
  const halfLife = 12.0;
  final decayed = math.pow(0.5, rank / halfLife).toDouble();
  return decayed < _minAttention ? _minAttention : decayed;
}

const _minAttention = 0.15;

/// An explicit "no" from the user.
///
/// YouTube names *Not interested* and *Don't recommend channel* as first-class
/// signals, and they are the strongest satisfaction input available to an app
/// with no likes, no surveys and no account. Everything else here is inferred
/// from behaviour; this is the one place the user gets to state a preference
/// outright, so it is treated as near-absolute rather than as one term among
/// many.
enum DislikeKind {
  /// This video, and — weakly — things that look like it.
  video,

  /// This whole channel. A hard exclusion.
  channel,
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
    required this.channelSatisfaction,
    required this.topicWeights,
    required this.subscribed,
    required this.watchedIds,
    required this.lastWatchedOnChannel,
    this.dislikedChannels = const {},
    this.dislikedVideos = const {},
    this.dislikedTopics = const {},
  });

  /// Channel id to interest, already recency-decayed and completion-weighted.
  /// Not normalised — [_normalise] handles that at scoring time so the raw
  /// numbers stay readable in a test failure.
  ///
  /// This is an **engagement** signal: how much of this channel gets opened
  /// and watched. It says nothing about whether the user was glad.
  final Map<String, double> channelAffinity;

  /// Channel id to how much of its videos typically gets watched, 0..1.
  ///
  /// The **satisfaction** half, and the one thing affinity alone cannot say.
  /// YouTube's multitask ranking paper splits its objectives into engagement
  /// (clicks, watch time) and satisfaction (likes, dismissals, surveys)
  /// precisely because a model trained on engagement alone learns to promote
  /// whatever gets clicked — which is the definition of clickbait.
  ///
  /// With no likes and no surveys to read, mean completion is the honest local
  /// proxy: a channel opened twenty times and abandoned after ten seconds each
  /// time is one the user keeps regretting. Under affinity alone it still
  /// accumulates interest, because twenty small numbers add up. Here it is
  /// separated out and used to hold the score down.
  ///
  /// Shrunk towards [_neutralSatisfaction] for channels with few watches —
  /// see [_shrink]. One abandoned video is not proof of anything.
  final Map<String, double> channelSatisfaction;

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

  /// Channels the user said "don't recommend" about. Excluded outright.
  final Set<String> dislikedChannels;

  /// Videos marked "not interested". Excluded outright.
  final Set<String> dislikedVideos;

  /// Words from the titles of videos marked "not interested", so the dismissal
  /// generalises a little instead of applying to that one video and nothing
  /// else. Weak on purpose — a title word is a blunt instrument, and one
  /// dismissal should not wipe out a topic the user otherwise watches.
  final Map<String, double> dislikedTopics;

  /// An empty profile — a fresh install, or Kids mode, which deliberately
  /// consults no personal signal at all.
  static const empty = TasteProfile(
    channelAffinity: {},
    channelSatisfaction: {},
    topicWeights: {},
    subscribed: {},
    watchedIds: {},
    lastWatchedOnChannel: {},
  );

  bool get isEmpty =>
      channelAffinity.isEmpty && topicWeights.isEmpty && subscribed.isEmpty;

  /// What a channel's satisfaction is assumed to be before there is evidence.
  ///
  /// Deliberately not 1.0: an unknown channel should be neither rewarded nor
  /// punished for being unknown, and starting everyone at "perfect" would make
  /// the satisfaction term a pure penalty that only ever subtracts.
  static const _neutralSatisfaction = 0.55;

  /// Watches needed before a channel's own completion rate is trusted fully.
  ///
  /// Bayesian shrinkage with a fixed prior weight. Without it a channel with
  /// one abandoned video would score as badly as one abandoned fifty times,
  /// and a channel with a single finished video would outrank a proven
  /// favourite — both of which are noise winning over evidence.
  static const _satisfactionPrior = 3.0;

  static double _shrink(double sum, double count) =>
      (sum + _neutralSatisfaction * _satisfactionPrior) /
      (count + _satisfactionPrior);

  /// How much of this channel the user typically watches, 0..1, already
  /// shrunk towards neutral for thin evidence.
  double satisfactionFor(String channelId) =>
      channelSatisfaction[channelId] ?? _neutralSatisfaction;

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
    Set<String> dislikedChannels = const {},
    List<WatchSignal> dislikedVideos = const [],
  }) {
    final affinity = <String, double>{};
    final topics = <String, double>{};
    final watched = <String>{};
    final lastOnChannel = <String, DateTime>{};
    // Running sums for the satisfaction average, kept apart from affinity
    // because they answer a different question: affinity is "how much", this
    // is "how well".
    final completionSum = <String, double>{};
    final completionCount = <String, double>{};

    for (final watch in history) {
      watched.add(watch.videoId);

      final recency = _decay(watch.watchedAt, now, interestHalfLife);
      // Completion IS the weight. A video opened and abandoned after a few
      // seconds is close to no evidence; one watched through is full evidence.
      final weight = watch.completion * recency;

      if (watch.channelId.isNotEmpty) {
        affinity[watch.channelId] = (affinity[watch.channelId] ?? 0) + weight;
        // Recency-weighted so a channel that used to be watched through and
        // is now abandoned reflects the recent truth, not the old one.
        completionSum[watch.channelId] =
            (completionSum[watch.channelId] ?? 0) + watch.completion * recency;
        completionCount[watch.channelId] =
            (completionCount[watch.channelId] ?? 0) + recency;
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

    final satisfaction = <String, double>{
      for (final channel in completionSum.keys)
        channel: _shrink(completionSum[channel]!, completionCount[channel]!),
    };

    for (final search in searches) {
      final recency = _decay(search.searchedAt, now, searchHalfLife);
      // Repeats matter but with diminishing returns — searching something
      // twenty times is not twenty times the interest of searching it once.
      final weight = recency * (1 + math.log(search.hits.clamp(1, 1000)));
      for (final token in tokenise(search.query)) {
        topics[token] = (topics[token] ?? 0) + weight;
      }
    }

    // An explicit dismissal generalises weakly through the title's words, so
    // that saying "not interested" to one reaction video makes the next one
    // slightly less likely rather than only removing that exact id. Weak, and
    // deliberately so: a title word is blunt, and a dismissal should not be
    // able to wipe out a topic the user otherwise watches.
    final dislikedTopics = <String, double>{};
    for (final disliked in dislikedVideos) {
      for (final token in tokenise(disliked.title)) {
        dislikedTopics[token] = (dislikedTopics[token] ?? 0) + 1;
      }
    }

    return TasteProfile(
      channelAffinity: affinity,
      channelSatisfaction: satisfaction,
      topicWeights: topics,
      subscribed: subscribed,
      watchedIds: watched,
      lastWatchedOnChannel: lastOnChannel,
      dislikedChannels: dislikedChannels,
      dislikedVideos: {for (final d in dislikedVideos) d.videoId},
      dislikedTopics: dislikedTopics,
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
/// Two separate predictions, combined — the structure of YouTube's multitask
/// ranking system (Zhao et al., RecSys '19), which splits its objectives into
/// **engagement** (will they click, will they watch) and **satisfaction** (were
/// they glad they did). It exists because a system trained on engagement alone
/// reliably learns to promote whatever gets clicked, and what gets clicked most
/// is clickbait. Their satisfaction signals are likes, dismissals and surveys;
/// none of those exist here, so ours are mean completion per channel and the
/// user's explicit dismissals.
///
/// The breakdown is not debug clutter: every term is a judgement call about
/// what somebody wants to watch, and a test that could only assert on the
/// total would pass just as happily with two terms cancelling each other out.
class ScoredCandidate {
  const ScoredCandidate({
    required this.video,
    required this.source,
    required this.affinity,
    required this.topic,
    required this.freshness,
    required this.popularity,
    required this.context,
    required this.satisfaction,
    required this.impressionPenalty,
    required this.watchedPenalty,
    required this.dislikePenalty,
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

  /// Overlap with whatever is being watched right now, 0..1. Zero on the home
  /// feed, which has no "right now".
  final double context;

  /// Predicted satisfaction, 0..1: how much of this channel usually gets
  /// watched. Applied as a **multiplier** on engagement rather than added to
  /// it — see [total].
  final double satisfaction;

  /// Negative. Grows with how much attention this video has already had in the
  /// feed without being opened.
  final double impressionPenalty;

  /// Negative, and large, when the video is already in watch history.
  final double watchedPenalty;

  /// Negative, from words shared with videos the user dismissed.
  final double dislikePenalty;

  /// The weight of each engagement term.
  ///
  /// Read them as a statement of priorities rather than tuned constants,
  /// because that is what they are — there is no training loop here to fit
  /// them. Who you watch matters most, what it is about is close behind,
  /// whether it is recent matters, and **how popular it is matters least of
  /// all**: popularity is what a feed falls back on when it knows nothing
  /// about you, and this one usually knows something.
  static const weights = (
    source: 1.0,
    affinity: 1.4,
    topic: 1.1,
    freshness: 0.6,
    popularity: 0.25,
    context: 0.9,
  );

  /// How far the long-run topic preference is turned down once there is a
  /// video actually playing.
  ///
  /// Not to zero — what someone usually likes is still a tiebreak — but this
  /// list is no longer about it. See [upNextContextWeight].
  static const ambientTopicUnderContext = 0.4;

  /// Extra weight the current video's subject carries on the "up next"
  /// surface, on top of [weights].
  ///
  /// Large enough that it outweighs any single other term, and that is the
  /// intent rather than an accident of tuning. YouTube is explicit that on
  /// this surface "our system uses the video you're currently watching as the
  /// main signal", and a weight that merely competed with channel affinity
  /// would not be a main signal — someone who usually watches cooking but has
  /// spent the last hour on guitar would keep being handed cooking.
  ///
  /// It applies only here. On the home feed, where YouTube says the system
  /// "primarily relies on your watch history", there is no current video and
  /// this term is zero.
  static const upNextContextWeight = 3.0;

  /// The engagement prediction: how likely this is to be opened and watched.
  double get engagement =>
      source.prior * weights.source +
      affinity * weights.affinity +
      topic * weights.topic +
      freshness * weights.freshness +
      popularity * weights.popularity +
      context * weights.context;

  /// Satisfaction as a bounded multiplier on engagement.
  ///
  /// Multiplicative rather than additive, and that choice is the whole point.
  /// Added, a big enough engagement score simply drowns it and the clickbait
  /// channel still wins — which is the failure being designed against. As a
  /// gate it scales everything: a channel the user opens constantly and
  /// abandons constantly has its engagement discounted in proportion.
  ///
  /// Bounded either side so it stays a gate and never becomes the ranking:
  /// a channel with a perfect record gets a modest lift, and a thoroughly
  /// unsatisfying one is held down without being erased — it may still be
  /// exactly what the user wants today.
  double get satisfactionGate {
    const floor = 0.45;
    const ceiling = 1.25;
    return floor + (ceiling - floor) * satisfaction.clamp(0.0, 1.0);
  }

  double get total =>
      engagement * satisfactionGate +
      impressionPenalty +
      watchedPenalty +
      dislikePenalty;
}

/// Cost of a video having had the user's full attention once without being
/// opened. Scaled by [attentionAtRank] at record time, so a card seen at the
/// bottom of a scroll costs a fraction of this.
///
/// Capped at [_maxImpressionPenalty] so nothing is buried permanently by a few
/// scroll-pasts — the user may simply not have been in the mood.
const _impressionCost = 0.35;
const _maxImpressionPenalty = 1.4;

/// Cost of already having watched a video.
///
/// Large enough to sink it below anything unwatched, but a penalty and not a
/// filter: a feed assembled from thin candidates should degrade to "things you
/// have seen" rather than to an empty screen.
const _watchedCost = 5.0;

/// Cost per word shared with a video the user marked "not interested".
///
/// Small, and capped by [_maxDislikePenalty]. An explicit dismissal removes
/// that video and that channel outright elsewhere; this is only the weak
/// generalisation to things that look like it, and a title word is far too
/// blunt an instrument to be trusted with more than a nudge.
const _dislikeTokenCost = 0.25;
const _maxDislikePenalty = 1.0;

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
  Set<String> contextTokens = const {},
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

  // What is being watched right now, when there is such a thing.
  //
  // YouTube's own description of suggested videos is blunt about this — "our
  // system uses the video you're currently watching as the main signal" — and
  // it is the one input an all-time profile cannot supply. Somebody who
  // usually watches cooking but has spent the last hour on guitar lessons
  // wants another guitar lesson; an aggregate profile will keep insisting
  // otherwise, and the louder its history the more insistent it gets.
  //
  // So context is its OWN term rather than folded into [topic]. Blended in, it
  // could never be worth more than the topic weight and would lose to a strong
  // channel affinity every time — which is the failure this is here to stop.
  var contextMatch = 0.0;
  if (contextTokens.isNotEmpty) {
    if (tokens.isNotEmpty) {
      var shared = 0;
      for (final token in tokens) {
        if (contextTokens.contains(token)) shared++;
      }
      contextMatch = shared / tokens.length;
    }
    // And the long-run topic preference is turned down while something is
    // playing: it is still a tiebreak, but it is not what this list is about.
    topic *= ScoredCandidate.ambientTopicUnderContext;
  }

  var impressionPenalty = 0.0;
  if (impression != null &&
      now.difference(impression.lastShownAt) < impressionMemory) {
    // Attention, not raw count — the shallow-tower idea. A card that was on
    // screen at the top and skipped costs the full amount; one glimpsed at the
    // bottom of a fling costs a fraction. See [ImpressionCount.attention].
    impressionPenalty = -math.min(
      impression.attention * _impressionCost,
      _maxImpressionPenalty,
    );
  }

  var dislikePenalty = 0.0;
  if (profile.dislikedTopics.isNotEmpty && tokens.isNotEmpty) {
    var hits = 0.0;
    for (final token in tokens) {
      hits += profile.dislikedTopics[token] ?? 0;
    }
    if (hits > 0) {
      dislikePenalty =
          -math.min(hits * _dislikeTokenCost, _maxDislikePenalty);
    }
  }

  return ScoredCandidate(
    video: video,
    source: candidate.source,
    affinity: affinity,
    topic: topic,
    freshness: _freshnessScore(video, now),
    popularity: _popularityScore(video),
    context: contextMatch,
    satisfaction: profile.satisfactionFor(video.channelId),
    impressionPenalty: impressionPenalty,
    watchedPenalty:
        profile.watchedIds.contains(video.id) ? -_watchedCost : 0.0,
    dislikePenalty: dislikePenalty,
  );
}

/// How much each additional video from a channel already in the output costs.
///
/// Without it the top of the feed collapses onto whichever channel the profile
/// likes most, which is not what anybody means by a recommendation feed — a
/// point the existing `_newestFirst` comment already makes about the
/// subscriptions tab.
const _channelRepeatCost = 0.55;

/// How much overlap with what has already been picked costs.
///
/// Channel diversity alone is not enough: three different channels all posting
/// about the same phone launch crowd the feed just as effectively as one
/// channel posting three times, and the user experiences that as "it keeps
/// showing me the same thing". This is Maximal Marginal Relevance — pick for
/// relevance *minus* similarity to what is already selected — over title
/// tokens, which are the only description of a video available here.
const _topicRepeatCost = 0.7;

/// Fraction of the feed reserved for videos from channels the profile has
/// never seen.
///
/// Pure exploitation is a trap: a ranker that only ever shows what it is
/// already confident about can never discover that the user has taken up
/// something new, and with no training loop to correct it the feed narrows
/// until it is the same few channels forever. Reserving a slice for novelty is
/// the cheapest defence there is, and it is what lets the feed still surprise.
const _explorationShare = 0.15;

/// How sharply picking favours the best candidate.
///
/// Selection is a softmax sample rather than a strict argmax. Higher scores
/// still win the overwhelming majority of the time — this is not shuffling —
/// but near-ties resolve differently between refreshes, which is both honest
/// about how little separates them and the reason the feed does not look
/// identical every time the app is opened.
const _selectionTemperature = 0.35;

/// Ranks [candidates] into the final feed order.
///
/// Deduplicates by video id, keeping the highest-scoring copy — the same video
/// legitimately arrives from several sources, and the best case for it is the
/// one that should count. Anything the user has explicitly dismissed is
/// dropped outright rather than merely demoted.
///
/// Selection is greedy and sequential rather than a plain sort, because two of
/// the things that decide a position depend on what has already been picked:
/// the channel-repeat cost and the MMR topic overlap. A sort with pre-computed
/// penalties could not express either.
///
/// [seed] makes the exploration reproducible: callers pass something that
/// changes per refresh. [explore] turns off both novelty slots and the softmax
/// sampling, leaving pure exploitation — which is what a test asserting on
/// ranking wants, since it can then state the expected order exactly rather
/// than around a sample.
List<VideoBrief> rankFeed({
  required List<Candidate> candidates,
  required TasteProfile profile,
  required DateTime now,
  Map<String, ImpressionCount> impressions = const {},
  int limit = 120,
  int seed = 0,
  bool explore = true,
}) {
  if (candidates.isEmpty) return const [];

  final maxAffinity = profile.channelAffinity.values.fold<double>(0, math.max);

  // Best score wins a duplicate.
  final best = <String, ScoredCandidate>{};
  for (final candidate in candidates) {
    final video = candidate.video;
    // An explicit "no" is honoured absolutely. Everything else in this file is
    // inference about what somebody probably wants; this is the one place they
    // said it outright, and a ranker that argued with it would be worse than
    // one that never asked.
    if (profile.dislikedVideos.contains(video.id)) continue;
    if (profile.dislikedChannels.contains(video.channelId)) continue;

    final scored = score(
      candidate: candidate,
      profile: profile,
      now: now,
      impression: impressions[video.id],
      maxAffinity: maxAffinity,
    );
    final existing = best[video.id];
    if (existing == null || scored.total > existing.total) {
      best[video.id] = scored;
    }
  }
  if (best.isEmpty) return const [];

  final pool = best.values.toList()
    // Sorted first so the greedy pass starts from a stable order and ties
    // break deterministically rather than on Map iteration order.
    ..sort((a, b) => b.total.compareTo(a.total));

  final tokensOf = <String, Set<String>>{
    for (final scored in pool)
      scored.video.id: tokenise(scored.video.title).toSet(),
  };

  final random = math.Random(seed);
  final out = <VideoBrief>[];
  final perChannel = <String, int>{};
  final pickedTokens = <String, int>{};
  final taken = List<bool>.filled(pool.length, false);
  final wanted = math.min(limit, pool.length);
  // Every nth slot goes to something from a channel the profile has never
  // seen, when there is one to give it to.
  final exploreEvery =
      explore && _explorationShare > 0 ? (1 / _explorationShare).round() : 0;

  double adjusted(int i) {
    final scored = pool[i];
    final channel = scored.video.channelId;
    final seen = channel.isEmpty ? 0 : (perChannel[channel] ?? 0);
    var value = scored.total - seen * _channelRepeatCost;

    // MMR: how much of this title has already been said by something picked.
    final tokens = tokensOf[scored.video.id] ?? const <String>{};
    if (tokens.isNotEmpty && pickedTokens.isNotEmpty) {
      var overlap = 0;
      for (final token in tokens) {
        if (pickedTokens.containsKey(token)) overlap++;
      }
      value -= (overlap / tokens.length) * _topicRepeatCost;
    }
    return value;
  }

  for (var picked = 0; picked < wanted; picked++) {
    final wantNovel =
        exploreEvery > 0 && picked > 0 && picked % exploreEvery == 0;

    var chosenIndex = -1;
    if (wantNovel) {
      // Best candidate from a channel with no history behind it. Still the
      // best one — exploration here means widening what is eligible, not
      // lowering the bar to random.
      var bestValue = double.negativeInfinity;
      for (var i = 0; i < pool.length; i++) {
        if (taken[i]) continue;
        final channel = pool[i].video.channelId;
        if (channel.isEmpty) continue;
        if (profile.channelAffinity.containsKey(channel)) continue;
        if (perChannel.containsKey(channel)) continue;
        final value = adjusted(i);
        if (value > bestValue) {
          bestValue = value;
          chosenIndex = i;
        }
      }
    }

    if (chosenIndex < 0) {
      chosenIndex = _sampleBest(
        pool,
        taken,
        adjusted,
        random,
        deterministic: !explore,
      );
    }
    if (chosenIndex < 0) break;

    taken[chosenIndex] = true;
    final chosen = pool[chosenIndex].video;
    out.add(chosen);
    if (chosen.channelId.isNotEmpty) {
      perChannel[chosen.channelId] = (perChannel[chosen.channelId] ?? 0) + 1;
    }
    for (final token in tokensOf[chosen.id] ?? const <String>{}) {
      pickedTokens[token] = (pickedTokens[token] ?? 0) + 1;
    }
  }

  return out;
}

/// Picks the next index: usually the best remaining candidate, occasionally a
/// close runner-up.
///
/// A softmax (Plackett–Luce) sample over the top few rather than an argmax.
/// Restricted to a short head so this can never reach far down the list and
/// produce something irrelevant — the aim is to break near-ties differently
/// between refreshes, not to gamble with the feed.
int _sampleBest(
  List<ScoredCandidate> pool,
  List<bool> taken,
  double Function(int) adjusted,
  math.Random random, {
  bool deterministic = false,
}) {
  const headSize = 5;
  final head = <({int index, double value})>[];
  for (var i = 0; i < pool.length; i++) {
    if (taken[i]) continue;
    final value = adjusted(i);
    if (head.length < headSize) {
      head.add((index: i, value: value));
      head.sort((a, b) => b.value.compareTo(a.value));
    } else if (value > head.last.value) {
      head[head.length - 1] = (index: i, value: value);
      head.sort((a, b) => b.value.compareTo(a.value));
    }
  }
  if (head.isEmpty) return -1;
  if (head.length == 1 || deterministic) return head.first.index;

  // Exponentials are taken relative to the best score, so the weights are
  // unaffected by the absolute scale and cannot overflow.
  final top = head.first.value;
  var total = 0.0;
  final weights = <double>[];
  for (final entry in head) {
    final w = math.exp((entry.value - top) / _selectionTemperature);
    weights.add(w);
    total += w;
  }

  var roll = random.nextDouble() * total;
  for (var i = 0; i < head.length; i++) {
    roll -= weights[i];
    if (roll <= 0) return head[i].index;
  }
  return head.first.index;
}

/// Orders the "Up next" list for [current].
///
/// YouTube says plainly what drives this surface — "our system uses the video
/// you're currently watching as the main signal" — and that is a different
/// brief from the home feed, which "primarily relies on your watch history".
/// So this function weights three things the home feed does not:
///
///  * **YouTube's own related order**, kept as a strong positional prior. It
///    is built from what everybody else watched after the same video, which is
///    the co-watch signal a single-device app can never compute for itself.
///    Discarding it to re-derive an order from local history alone would throw
///    away the only view of what other people do.
///  * **The current video's own words**, via [score]'s context term, so a
///    session that has drifted into a subject beats an all-time profile that
///    has not noticed yet.
///  * **What has already been played in this session** ([recentlyPlayed]), so
///    autoplay does not circle back to the same few channels. A queue that
///    loops is the specific complaint autoplay attracts.
///
/// Already-watched videos sink, dismissed ones are dropped outright, and the
/// channel of the video currently playing is damped so autoplay stops walking
/// down one uploader's back catalogue.
///
/// [related] must be in YouTube's order; the position in that list is the
/// prior.
List<VideoBrief> rankUpNext({
  required VideoBrief current,
  required List<VideoBrief> related,
  required TasteProfile profile,
  required DateTime now,
  Map<String, ImpressionCount> impressions = const {},
  List<VideoBrief> recentlyPlayed = const [],
}) {
  if (related.isEmpty) return const [];

  final maxAffinity = profile.channelAffinity.values.fold<double>(0, math.max);
  // What this session is actually about, which is not necessarily what the
  // profile says the user likes.
  final contextTokens = tokenise(current.title).toSet();
  final sessionChannels = <String, int>{};
  for (final played in recentlyPlayed) {
    if (played.channelId.isEmpty) continue;
    sessionChannels[played.channelId] =
        (sessionChannels[played.channelId] ?? 0) + 1;
  }
  final sessionIds = {for (final played in recentlyPlayed) played.id};

  final ranked = <({double score, int index, VideoBrief video})>[];

  for (var i = 0; i < related.length; i++) {
    final video = related[i];
    // Never suggest the video that is playing.
    if (video.id == current.id) continue;
    // Nor anything already played in this sitting: it is not "up next", it is
    // the loop the user is trying to get out of.
    if (sessionIds.contains(video.id)) continue;
    // Nor anything explicitly dismissed.
    if (profile.dislikedVideos.contains(video.id)) continue;
    if (profile.dislikedChannels.contains(video.channelId)) continue;

    final scored = score(
      candidate: Candidate(video: video, source: CandidateSource.coWatch),
      profile: profile,
      now: now,
      impression: impressions[video.id],
      maxAffinity: maxAffinity,
      contextTokens: contextTokens,
    );

    // YouTube's ordering, decaying with position. The first entry is worth a
    // full point and the tenth about a third of one, which is enough to keep
    // the list recognisably YouTube's while letting a strong personal match
    // climb over a weak one.
    final positionPrior = 1 / (1 + i * 0.2);

    // Autoplay that marches through one channel is the complaint this damping
    // exists for. The channel is still allowed to win — it just has to win on
    // something other than being the one already on screen, and each further
    // video from a channel this session has already played costs more again.
    final sameChannel =
        video.channelId.isNotEmpty && video.channelId == current.channelId;
    final sessionRepeats = sessionChannels[video.channelId] ?? 0;

    ranked.add((
      score: scored.total +
          scored.context * ScoredCandidate.upNextContextWeight +
          positionPrior -
          (sameChannel ? 0.4 : 0.0) -
          sessionRepeats * 0.25,
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
