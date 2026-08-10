// Exercises the app's own search implementation against live YouTube, and
// shows what the youtube_explode_dart parser does with the same query.
//
//   dart run tool/check_search.dart [query ...]
//
// The package's search is broken (NoSuchMethodError on `getT`), which is why
// lib/src/data/search_client.dart exists. This proves the replacement works and
// keeps the comparison visible if the package is ever fixed.
import 'dart:io';

import 'package:ai_bit/src/data/search_client.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main(List<String> args) async {
  final queries = args.isEmpty
      ? ['kannada', 'flutter tutorial', 'news today', 'lofi']
      : args;

  final mine = YoutubeSearchClient();
  final yt = YoutubeExplode();
  var failures = 0;

  for (final q in queries) {
    stdout.writeln('\n===== "$q" =====');

    try {
      final r = await mine.search(q);
      stdout.writeln('ours:    ${r.length} results');
      for (final v in r.take(3)) {
        stdout.writeln('   ${v.id}  ${v.duration}  '
            '${v.viewCount ?? '-'} views  ${v.author}');
        stdout.writeln('        ${v.title}');
      }
      if (r.isEmpty) failures++;
    } catch (e) {
      stdout.writeln('ours:    FAILED $e');
      failures++;
    }

    try {
      final r = await yt.search.search(q);
      stdout.writeln('package: ${r.length} results');
    } catch (e) {
      stdout.writeln('package: FAILED ${e.toString().split('\n').first}');
    }

    try {
      final s = await mine.search(q, params: YoutubeSearchClient.filterByViewCount);
      stdout.writeln('ours(by views): ${s.length} results');
    } catch (e) {
      stdout.writeln('ours(by views): FAILED $e');
      failures++;
    }
  }

  mine.close();
  yt.close();

  stdout.writeln();
  stdout.writeln(failures == 0
      ? 'RESULT: search works for every query.'
      : 'RESULT: $failures query variants failed.');
  if (failures > 0) exitCode = 1;
}
