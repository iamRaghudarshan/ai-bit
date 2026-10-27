// Does the recommender actually produce a feed, and an "up next" list?
//
// WHY THIS EXISTS. "Recommendations are not working" can mean four completely
// different faults, needing completely different fixes:
//
//   1. The candidate sources return nothing — YouTube changed an endpoint, and
//      no amount of ranking can order an empty list.
//   2. Candidates arrive but the profile is EMPTY, so homeFeed falls back to
//      the old unranked round-robin. This one looks like "the feature was
//      never installed", because functionally it was not: a fresh install with
//      no watch history and no chosen interests gets exactly the pre-ranker
//      behaviour.
//   3. The related endpoint returns nothing, so "up next" is empty and
//      autoplay has nothing to advance to.
//   4. Ranking runs, but orders badly.
//
// This prints enough to tell them apart. Run it before changing any scoring.
//
// It talks to the clients directly rather than through YtRepository, because
// that file imports package:flutter for debugPrint and so cannot run under a
// plain `dart run`. Everything below it in the stack is Flutter-free on
// purpose — see the note at the top of recommender.dart.
//
//   dart run tool/check_recommendations.dart [videoId]

import 'dart:io';

import 'package:ai_bit/src/data/browse_client.dart';
import 'package:ai_bit/src/data/interests.dart';
import 'package:ai_bit/src/data/models.dart';
import 'package:ai_bit/src/data/recommender.dart';
import 'package:ai_bit/src/data/search_client.dart';

Future<void> main(List<String> args) async {
  final videoId = args.isNotEmpty ? args.first : 'dQw4w9WgXcQ';
  final search = YoutubeSearchClient();
  final browse = YoutubeBrowseClient();
  final now = DateTime.now();

  try {
    stdout.writeln('=' * 72);
    stdout.writeln('1. CANDIDATE SOURCES');
    stdout.writeln('=' * 72);

    final hits = await _try(
      'search("technology news")',
      () => search.search('technology news',
          params: YoutubeSearchClient.filterByViewCount),
    );
    final related = await _try('related($videoId)', () => browse.related(videoId));

    // Every interest query, so a dead one shows up rather than silently
    // contributing nothing to the feed.
    stdout.writeln('');
    stdout.writeln('  interest queries:');
    var deadQueries = 0;
    for (final q in interestQueries(['tech', 'ai', 'news']).take(6)) {
      final r = await _safe(() => search.search(q,
          params: YoutubeSearchClient.filterByViewCount));
      if (r.isEmpty) deadQueries++;
      stdout.writeln('    ${r.length.toString().padLeft(3)}  "$q"');
    }

    stdout.writeln('');
    stdout.writeln('=' * 72);
    stdout.writeln('2. RANKING — is it engaged, and does it reorder?');
    stdout.writeln('=' * 72);

    const chosen = ['tech', 'ai', 'news'];
    final declared = TasteProfile.from(
      history: const [],
      searches: const [],
      subscribed: const {},
      now: now,
      interestQueries: interestQueries(chosen),
    );
    stdout.writeln('  with interests chosen:');
    stdout.writeln('    profile.isEmpty : ${declared.isEmpty}'
        '   <-- true means ranking is SKIPPED');
    stdout.writeln('    topic tokens    : ${declared.topicWeights.length}');

    const bare = TasteProfile.empty;
    stdout.writeln('  fresh install, nothing chosen:');
    stdout.writeln('    profile.isEmpty : ${bare.isEmpty}');

    var coldRanks = false;
    var warmRanks = false;
    if (hits.isNotEmpty) {
      final candidates = [
        for (final v in hits)
          Candidate(video: v, source: CandidateSource.interest),
      ];
      List<VideoBrief> rank(TasteProfile p) => rankFeed(
            candidates: candidates,
            profile: p,
            now: now,
            explore: false,
          );

      // The important one. homeFeed used to BYPASS ranking whenever the
      // profile was empty, which meant a fresh install got the raw fetch
      // order and the whole recommender might as well not have shipped. The
      // bypass is gone; this confirms that an empty profile still reorders,
      // on freshness, popularity, channel spread and MMR alone.
      final cold = rank(TasteProfile.empty);
      final coldMoved = _firstDifference(hits, cold);
      coldRanks = coldMoved >= 0;
      stdout.writeln('');
      stdout.writeln('  EMPTY profile  : ${cold.length} rows, order changes at '
          '${coldMoved < 0 ? 'nowhere (!)' : coldMoved}');

      final warm = rank(declared);
      final warmMoved = _firstDifference(hits, warm);
      warmRanks = warmMoved >= 0;
      stdout.writeln('  WITH interests : ${warm.length} rows, order changes at '
          '${warmMoved < 0 ? 'nowhere (!)' : warmMoved}');
      stdout.writeln('  and the two differ from each other: '
          '${_firstDifference(cold, warm) >= 0}');
      _preview('  ', warm);
    }

    stdout.writeln('');
    stdout.writeln('=' * 72);
    stdout.writeln('3. UP NEXT for $videoId');
    stdout.writeln('=' * 72);
    if (related.isEmpty) {
      stdout.writeln('  !! related list is EMPTY. Up next cannot work and autoplay has');
      stdout.writeln('     nothing to advance to. Upstream break, not a ranking fault.');
    } else {
      final current = related.first;
      final ranked = rankUpNext(
        current: VideoBrief(
          id: videoId,
          title: 'current video',
          author: current.author,
          channelId: current.channelId,
        ),
        related: related,
        profile: declared,
        now: now,
      );
      stdout.writeln('  raw related: ${related.length}   after ranking: ${ranked.length}');
      _preview('  ', ranked);
    }

    stdout.writeln('');
    stdout.writeln('=' * 72);
    stdout.writeln('VERDICT');
    stdout.writeln('=' * 72);
    stdout.writeln('  search works         : ${hits.isNotEmpty}');
    stdout.writeln('  related works        : ${related.isNotEmpty}');
    stdout.writeln('  dead interest queries: $deadQueries');
    stdout.writeln('  ranking reorders with interests  : $warmRanks');
    stdout.writeln('  ranking reorders on a bare install: $coldRanks'
        '   <-- must be true, or cold start is unranked');
  } finally {
    search.close();
    browse.close();
  }
}

Future<List<VideoBrief>> _try(
  String label,
  Future<List<VideoBrief>> Function() task,
) async {
  try {
    final out = await task();
    stdout.writeln('  $label -> ${out.length} results');
    return out;
  } catch (e) {
    stdout.writeln('  $label -> FAILED: $e');
    return const [];
  }
}

Future<List<VideoBrief>> _safe(
    Future<List<VideoBrief>> Function() task) async {
  try {
    return await task();
  } catch (_) {
    return const [];
  }
}

/// First position where two lists disagree, or -1 when they are identical.
/// Identical means ranking changed nothing, which is itself the finding.
int _firstDifference(List<VideoBrief> a, List<VideoBrief> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i].id != b[i].id) return i;
  }
  return -1;
}

void _preview(String indent, List<VideoBrief> videos) {
  for (final v in videos.take(6)) {
    var author = v.author;
    if (author.length > 20) author = author.substring(0, 20);
    var title = v.title;
    if (title.length > 52) title = '${title.substring(0, 52)}…';
    stdout.writeln('$indent  ${author.padRight(20)}  $title');
  }
}
