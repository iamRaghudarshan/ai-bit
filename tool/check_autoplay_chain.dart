// Does autoplay stay on the subject of what was playing?
//
//   dart run tool/check_autoplay_chain.dart [videoId]
//
// Reported: "while the screen is off the next video is fully different from
// the one playing". Autoplay used to take each next video from the FIRST
// video's suggestions, so the chain drifted. It now takes each next video from
// the suggestions of the one that just finished — this walks that chain the
// way PlaybackController.playNext does (rankUpNext over the next endpoint's
// related list, skipping anything already played this sitting) and prints
// each hop, so "is each video related to the one before it" is visible.
import 'dart:io';

import 'package:ai_bit/src/data/browse_client.dart';
import 'package:ai_bit/src/data/models.dart';
import 'package:ai_bit/src/data/recommender.dart';

Future<void> main(List<String> args) async {
  final browse = YoutubeBrowseClient();
  final now = DateTime.now();
  var current = VideoBrief(
    id: args.isEmpty ? 'dQw4w9WgXcQ' : args.first,
    title: '(start)',
    author: '',
    channelId: '',
  );
  final played = <VideoBrief>[current];
  stdout.writeln('start: ${current.id}');
  for (var hop = 1; hop <= 6; hop++) {
    final related = await browse.related(current.id);
    final ranked = rankUpNext(
      current: current,
      related: related,
      profile: TasteProfile.empty,
      now: now,
      recentlyPlayed: played,
    );
    if (ranked.isEmpty) {
      stdout.writeln('  hop $hop: no suggestions');
      break;
    }
    current = ranked.first;
    played.add(current);
    stdout.writeln('  hop $hop: ${current.title}  — ${current.author}');
  }
  browse.close();
}
