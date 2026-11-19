// End-to-end probe of the home feed: what comes out, how old it is, and which
// candidate source put it there.
//
//   dart run tool/check_home_feed.dart
//
// check_feed_recency.dart measures one query at a time. This one assembles a
// whole feed and ranks it, because "the feed is still showing old videos" has
// two completely different causes and they need opposite fixes:
//
//   * the candidate pool is old            -> candidate generation, the queries
//   * the pool is fresh, the ranked top is old -> the ranker's weights
//
// It reports both, so the next person does not have to guess which.
//
// NOTE ON THE DUPLICATION: this mirrors YtRepository.homeFeed's source list
// rather than calling it. yt_repository.dart imports package:flutter for
// debugPrint, and a plain `dart run` cannot compile dart:ui — so importing it
// here fails with a hundred errors inside Flutter's own gesture code. The
// layers underneath it (search_client, browse_client, recommender, models) are
// deliberately Flutter-free and are the real subjects anyway: the sources, the
// windows and rankFeed. Keep this in step with homeFeed when sources change.
import 'dart:io';

import 'package:ai_bit/src/data/browse_client.dart';
import 'package:ai_bit/src/data/models.dart';
import 'package:ai_bit/src/data/recommender.dart';
import 'package:ai_bit/src/data/search_client.dart';

final _now = DateTime.now();

void main(List<String> args) async {
  final search = YoutubeSearchClient();
  final browse = YoutubeBrowseClient();

  // ------------------------------------------------------------- the windows
  //
  // What each upload-date window really returns, by age. _recentTopicSearch
  // rotates month / year / week, and "year" is the one to stare at: the
  // most-viewed video of the last twelve months about a topic can easily be
  // several months old. That is a vast improvement on the six-year-old video
  // it replaced and still is not "recent", which is exactly the shape of a
  // report that the feed now shows things from five months ago.
  stdout.writeln('=== what each window returns, by age ===');
  const probeQueries = ['artificial intelligence', 'cricket', 'technology'];
  for (final (label, window) in const [
    ('week ', YoutubeSearchClient.uploadedThisWeek),
    ('month', YoutubeSearchClient.uploadedThisMonth),
    ('year ', YoutubeSearchClient.uploadedThisYear),
  ]) {
    final ages = <double>[];
    for (final q in probeQueries) {
      final results = await search.search(
        q,
        params: YoutubeSearchClient.buildParams(sortBy: 3, uploadDate: window),
      );
      ages.addAll(results.map(_ageDays).whereType<double>());
    }
    ages.sort();
    stdout.writeln(
      '  $label  n=${ages.length}  '
      'median ${_days(_median(ages))}  '
      'oldest ${_days(ages.isEmpty ? null : ages.last)}  '
      'over 60d: ${ages.where((a) => a > 60).length}/${ages.length}',
    );
  }

  // --------------------------------------------------------- the co-watch source
  //
  // The strongest source by prior (0.9) and the one no window can touch:
  // YouTube's related list is whatever YouTube says, and it is full of older
  // video. If the ranked feed is old, this is the likeliest culprit.
  stdout.writeln('\n=== related lists (the co-watch source), by age ===');
  final seedResults = await search.search(
    'technology review',
    params: YoutubeSearchClient.buildParams(
      sortBy: 3,
      uploadDate: YoutubeSearchClient.uploadedThisWeek,
    ),
  );
  final seeds = seedResults.take(3).map((v) => v.id).toList();
  final relatedAll = <VideoBrief>[];
  for (final s in seeds) {
    final rel = await browse.related(s);
    relatedAll.addAll(rel);
    final ages = rel.map(_ageDays).whereType<double>().toList()..sort();
    stdout.writeln(
      '  seed $s -> ${rel.length} related, median ${_days(_median(ages))}, '
      'over 1y: ${ages.where((a) => a > 365).length}',
    );
  }

  // ------------------------------------------------------------ subscriptions
  //
  // Discovered rather than hardcoded, so the probe does not rot when a channel
  // id changes: a recent-window search returns videos from channels that are
  // certainly still active.
  stdout.writeln('\n=== subscription uploads, by age ===');
  final subs = <String, String>{};
  for (final q in ['technology review', 'cricket highlights', 'ai news']) {
    final results = await search.search(
      q,
      params: YoutubeSearchClient.buildParams(
        sortBy: 3,
        uploadDate: YoutubeSearchClient.uploadedThisMonth,
      ),
    );
    for (final v in results.take(3)) {
      if (v.channelId.isNotEmpty) subs[v.channelId] = v.author;
    }
  }
  final subUploads = <String, List<VideoBrief>>{};
  final subAges = <double>[];
  for (final id in subs.keys.take(8)) {
    final ups = (await browse.channelVideos(id)).take(6).toList();
    subUploads[id] = ups;
    final ages = ups.map(_ageDays).whereType<double>().toList()..sort();
    subAges.addAll(ages);
    stdout.writeln(
      '  ${_pad(subs[id]!, 26)}  ${ups.length} uploads, '
      'newest ${_days(ages.isEmpty ? null : ages.first)}, '
      'median ${_days(_median(ages))}',
    );
  }
  subAges.sort();
  stdout.writeln(
    '  -> median subscription upload age: ${_days(_median(subAges))}',
  );

  // ----------------------------------------------------------- rank it all
  final candidates = <Candidate>[
    for (final id in subUploads.keys)
      for (final v in subUploads[id]!)
        Candidate(video: v, source: CandidateSource.subscription),
    for (final v in relatedAll)
      Candidate(video: v, source: CandidateSource.coWatch),
  ];
  // Topic and interest sources, through the same windows the app uses.
  for (final (i, q) in ['technology', 'cricket', 'ai'].indexed) {
    const windows = [
      YoutubeSearchClient.uploadedThisMonth,
      YoutubeSearchClient.uploadedThisYear,
      YoutubeSearchClient.uploadedThisWeek,
    ];
    final results = await search.search(
      q,
      params: YoutubeSearchClient.buildParams(
        sortBy: 3,
        uploadDate: windows[i % windows.length],
      ),
    );
    candidates.addAll(
      results.map((v) => Candidate(video: v, source: CandidateSource.interest)),
    );
  }

  final poolAges = candidates
      .map((c) => _ageDays(c.video))
      .whereType<double>()
      .toList()
    ..sort();

  final profile = TasteProfile.from(
    history: [
      for (final (i, id) in subs.keys.take(5).indexed)
        WatchSignal(
          videoId: 'seed$i',
          channelId: id,
          title: subs[id]!,
          watchedAt: _now.subtract(Duration(days: i + 1)),
          completion: 0.8,
        ),
    ],
    searches: const [],
    subscribed: subs.keys.toSet(),
    now: _now,
  );

  final features = <String, List<double>>{};
  final feed = rankFeed(
    candidates: candidates,
    profile: profile,
    now: _now,
    limit: 80,
    explore: false, // deterministic, so two runs are comparable
    featuresOut: features,
  );

  stdout.writeln('\n=== the ranked feed ===');
  stdout.writeln('  rank  age     source        title');
  for (final (i, v) in feed.take(25).indexed) {
    final f = features[v.id];
    stdout.writeln(
      '  ${_pad('${i + 1}', 4)}  ${_pad(_days(_ageDays(v)), 7)} '
      '${_pad(f == null ? '?' : _sourceFor(f[0]), 13)} '
      '${_truncate(v.title, 44)}',
    );
  }

  final topAges =
      feed.take(20).map(_ageDays).whereType<double>().toList()..sort();
  stdout.writeln('\n=== verdict ===');
  stdout.writeln('  candidate pool:     n=${poolAges.length}  '
      'median ${_days(_median(poolAges))}  '
      'over 60d ${_pct(poolAges.where((a) => a > 60).length, poolAges.length)}');
  stdout.writeln('  ranked top 20:      median ${_days(_median(topAges))}  '
      'over 60d ${_pct(topAges.where((a) => a > 60).length, topAges.length)}');

  final bySource = <String, int>{};
  for (final v in feed.take(20)) {
    final f = features[v.id];
    bySource.update(f == null ? '?' : _sourceFor(f[0]), (n) => n + 1,
        ifAbsent: () => 1);
  }
  stdout.writeln('  top 20 by source:   $bySource');

  final poolOld = poolAges.where((a) => a > 60).length / poolAges.length;
  final topOld = topAges.isEmpty
      ? 0.0
      : topAges.where((a) => a > 60).length / topAges.length;
  stdout.writeln('');
  if (poolOld > 0.4) {
    stdout.writeln('  DIAGNOSIS: the candidate POOL is old. Fix the queries,');
    stdout.writeln('  not the weights — ranking cannot promote what is absent.');
  } else if (topOld > poolOld + 0.1) {
    stdout.writeln('  DIAGNOSIS: the pool is fresh but ranking prefers old.');
    stdout.writeln('  Fix the weights / the freshness curve.');
  } else {
    stdout.writeln('  DIAGNOSIS: pool and ranked output agree and are fresh.');
  }

  search.close();
  browse.close();
}

/// Reverse-maps a source prior back to its name. featuresOut's first element
/// is CandidateSource.prior, so this needs no instrumentation in the app.
String _sourceFor(double prior) {
  for (final s in CandidateSource.values) {
    if ((s.prior - prior).abs() < 1e-9) return s.name;
  }
  return 'prior=$prior';
}

double? _ageDays(VideoBrief video) {
  final seconds = uploadAgeSeconds(video, _now);
  return seconds == null ? null : seconds / Duration.secondsPerDay;
}

double? _median(List<double> sorted) =>
    sorted.isEmpty ? null : sorted[sorted.length ~/ 2];

String _days(double? days) {
  if (days == null) return '?';
  if (days >= 365) return '${(days / 365).toStringAsFixed(1)}y';
  if (days >= 30) return '${(days / 30).toStringAsFixed(1)}mo';
  return '${days.toStringAsFixed(0)}d';
}

String _pct(int n, int total) =>
    total == 0 ? 'n/a' : '${(100 * n / total).round()}%';

String _pad(String s, int n) =>
    s.length >= n ? s.substring(0, n) : s.padRight(n);

String _truncate(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';
