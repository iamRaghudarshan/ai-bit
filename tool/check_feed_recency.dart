// Diagnostic for the home feed's candidate generation: is what the app fetches
// actually recent?
//
//   dart run tool/check_feed_recency.dart [query ...]
//
// This exists because of a report that read "recommendations are coming 6 year
// back". The ranker had a freshness term all along, so the obvious reading was
// that the weighting was wrong — but ranking can only ever order what candidate
// generation found, and candidate generation was asking YouTube for the
// most-viewed videos of all time about each topic. For most topics that is
// something from years ago, so there was nothing recent in the pool to rank.
//
// What this checks, in one pass per query:
//
//   1. The old query (sort by view count, any time) — and how old its results
//      actually are. This is the evidence of the bug, not an assumption.
//   2. The new query (sort by view count, uploaded within a window). YouTube's
//      `sp` parameter is a hand-written protobuf here, and the two filters live
//      in different fields of a nested message. A malformed combination does
//      not error — it returns an EMPTY page, which in the app would look like
//      the feed quietly losing its topic sources. That is the failure this is
//      really guarding against, and it cannot be established by reading code.
//   3. That the window was honoured, by reading the ages back.
import 'dart:io';

import 'package:ai_bit/src/data/models.dart';
import 'package:ai_bit/src/data/search_client.dart';

const _defaultQueries = [
  'artificial intelligence',
  'cricket',
  'flutter tutorial',
  'music',
  'self-hosting homelab tutorials', // deliberately narrow: tests the widening
];

void main(List<String> args) async {
  final queries = args.isEmpty ? _defaultQueries : args;
  final client = YoutubeSearchClient();

  var oldWindowTotalAgeDays = 0.0;
  var oldWindowCounted = 0;
  var newWindowTotalAgeDays = 0.0;
  var newWindowCounted = 0;
  var emptyWindows = 0;

  for (final query in queries) {
    stdout.writeln('\n=== $query');

    final allTime = await _run(
      client,
      query,
      YoutubeSearchClient.filterByViewCount,
      'all time, by views (the old query)',
    );
    oldWindowTotalAgeDays += allTime.totalAgeDays;
    oldWindowCounted += allTime.dated;

    final windowed = await _run(
      client,
      query,
      YoutubeSearchClient.buildParams(
        sortBy: 3,
        uploadDate: YoutubeSearchClient.uploadedThisMonth,
      ),
      'this month, by views (the new query)',
    );
    newWindowTotalAgeDays += windowed.totalAgeDays;
    newWindowCounted += windowed.dated;
    if (windowed.count == 0) {
      emptyWindows++;
      stdout.writeln('    -> EMPTY: the app widens to the year for this one');
      final wider = await _run(
        client,
        query,
        YoutubeSearchClient.buildParams(
          sortBy: 3,
          uploadDate: YoutubeSearchClient.uploadedThisYear,
        ),
        'this year, by views (the widening)',
      );
      if (wider.count == 0) {
        stdout.writeln('    -> STILL EMPTY: falls back to all time');
      }
    }
  }

  client.close();

  stdout.writeln('\n--- summary');
  final oldMean =
      oldWindowCounted == 0 ? null : oldWindowTotalAgeDays / oldWindowCounted;
  final newMean =
      newWindowCounted == 0 ? null : newWindowTotalAgeDays / newWindowCounted;
  stdout.writeln(
    'mean age, old query:  ${_days(oldMean)}  ($oldWindowCounted dated results)',
  );
  stdout.writeln(
    'mean age, new query:  ${_days(newMean)}  ($newWindowCounted dated results)',
  );
  stdout.writeln('queries with an empty one-month window: $emptyWindows'
      '/${queries.length}');

  if (newWindowCounted == 0) {
    stdout.writeln(
      '\nFAIL: the windowed query returned nothing anywhere. The combined sp '
      'parameter is likely malformed — the feed would lose its topic sources.',
    );
    exit(1);
  }
  if (oldMean != null && newMean != null && newMean >= oldMean) {
    stdout.writeln(
      '\nFAIL: the windowed query is not returning fresher results than the '
      'unwindowed one. The uploadDate field is being ignored.',
    );
    exit(1);
  }
  stdout.writeln('\nRESULT: windowing works and the candidate pool is fresh.');
}

class _Run {
  _Run(this.count, this.dated, this.totalAgeDays);
  final int count;
  final int dated;
  final double totalAgeDays;
}

Future<_Run> _run(
  YoutubeSearchClient client,
  String query,
  String params,
  String label,
) async {
  List<VideoBrief> results;
  try {
    results = await client.search(query, params: params);
  } catch (e) {
    stdout.writeln('  $label: ERROR $e');
    return _Run(0, 0, 0);
  }

  var dated = 0;
  var totalAgeDays = 0.0;
  for (final v in results) {
    final age = _ageDays(v);
    if (age != null) {
      dated++;
      totalAgeDays += age;
    }
  }
  final mean = dated == 0 ? null : totalAgeDays / dated;
  stdout.writeln(
    '  $label: ${results.length} results, mean age ${_days(mean)}',
  );
  for (final v in results.take(3)) {
    final raw = v.uploadRaw ?? '(no date)';
    stdout.writeln('      $raw  ${_truncate(v.title, 54)}');
  }
  return _Run(results.length, dated, totalAgeDays);
}

/// The app's own age rule, so this measures what the ranker will see rather
/// than something adjacent to it.
double? _ageDays(VideoBrief video) {
  final date = video.uploadDate;
  if (date != null) {
    return DateTime.now().difference(date).inSeconds / Duration.secondsPerDay;
  }
  final raw = video.uploadRaw;
  if (raw == null || raw.isEmpty) return null;
  final match = RegExp(
    r'(\d+)\s*(second|minute|hour|day|week|month|year)',
  ).firstMatch(raw.toLowerCase());
  if (match == null) return null;
  final count = int.tryParse(match.group(1)!);
  if (count == null) return null;
  const perUnitDays = {
    'second': 1 / 86400,
    'minute': 1 / 1440,
    'hour': 1 / 24,
    'day': 1.0,
    'week': 7.0,
    'month': 30.0,
    'year': 365.0,
  };
  return count * perUnitDays[match.group(2)]!;
}

String _days(double? days) {
  if (days == null) return 'unknown';
  if (days >= 365) return '${(days / 365).toStringAsFixed(1)} years';
  if (days >= 30) return '${(days / 30).toStringAsFixed(1)} months';
  return '${days.toStringAsFixed(1)} days';
}

String _truncate(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';
