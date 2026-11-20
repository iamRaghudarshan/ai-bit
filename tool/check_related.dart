// Does the watch page's "Up next" rail have anything to show?
//
//   dart run tool/check_related.dart [videoId ...]
//
// The rail is filled by WatchPage._loadDetails, which makes two independent
// requests: `videoDetails` (youtube_explode_dart's videos.get, which scrapes
// the watch page) and `related` (our own parser over the youtubei `next`
// endpoint). They used to be chained, details first, so a bot-check page on
// the details scrape emptied a rail whose own endpoint was fine. This runs
// BOTH steps, so a failure names the step.
//
// Deliberately does not touch the player streams endpoint beyond what
// videos.get itself does, and mints nothing.
import 'dart:io';

import 'package:ai_bit/src/data/browse_client.dart';
import 'package:ai_bit/src/data/recommender.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

Future<void> main(List<String> args) async {
  final ids = args.isEmpty
      ? [
          'aqz-KE-bpKQ', // Big Buck Bunny, 10 min
          'dQw4w9WgXcQ', // Rick Astley
          'kJQP7kiw5Fk', // Despacito
        ]
      : args;

  final browse = YoutubeBrowseClient();
  final explode = yt.YoutubeExplode();
  var nextFailures = 0;
  var detailFailures = 0;

  for (final id in ids) {
    stdout.writeln('\n===== $id =====');

    // Step 1: what the page does first, and what gates the rest.
    final sw = Stopwatch()..start();
    try {
      final v = await explode.videos.get(id);
      stdout.writeln('  videoDetails : OK in ${sw.elapsedMilliseconds}ms — '
          '"${v.title}" by ${v.author}');
    } catch (e) {
      detailFailures++;
      final msg = e.toString().replaceAll('\n', ' ');
      stdout.writeln('  videoDetails : FAILED in ${sw.elapsedMilliseconds}ms — '
          '${msg.length > 220 ? msg.substring(0, 220) : msg}');
    }

    // Step 2: the `next` endpoint, independently.
    sw.reset();
    try {
      final rows = await browse.related(id);
      stdout.writeln('  next/related : ${rows.length} rows in '
          '${sw.elapsedMilliseconds}ms');
      if (rows.isEmpty) nextFailures++;
      for (final r in rows.take(5)) {
        final age = parseRelativeAgeSeconds(r.uploadRaw);
        stdout.writeln('     ${r.id}  ${r.duration ?? "?:??"}  '
            'age=${age == null ? "null(${r.uploadRaw})" : "${(age / 86400).toStringAsFixed(0)}d"}  '
            '${r.title}  — ${r.author.isEmpty ? "(no channel)" : r.author}'
            '${r.channelId.isEmpty ? "  [no channelId]" : ""}');
      }
      final noChannel = rows.where((r) => r.channelId.isEmpty).length;
      final noAge = rows.where((r) => parseRelativeAgeSeconds(r.uploadRaw) == null).length;
      if (rows.isNotEmpty) {
        stdout.writeln('     missing channelId: $noChannel/${rows.length}, '
            'unparsed age: $noAge/${rows.length}');
      }
    } catch (e) {
      nextFailures++;
      stdout.writeln('  next/related : FAILED in ${sw.elapsedMilliseconds}ms — $e');
    }
  }

  browse.close();
  explode.close();
  stdout.writeln();
  stdout.writeln('SUMMARY: videoDetails failed $detailFailures/${ids.length}, '
      'next endpoint empty/failed $nextFailures/${ids.length}.');
  if (detailFailures > 0 && nextFailures == 0) {
    stdout.writeln('VERDICT: the `next` endpoint works but videoDetails does '
        'not. The watch page now fetches the two independently, so the rail '
        'survives this; the description and chapters do not.');
  } else if (nextFailures > 0) {
    stdout.writeln('VERDICT: the `next` endpoint itself is not answering; '
        'the rail is empty upstream.');
  } else {
    stdout.writeln('VERDICT: both steps work from here.');
  }
  if (detailFailures + nextFailures > 0) exitCode = 1;
}
