// Is the "Up next" list still YouTube's list?
//
//   dart run tool/check_up_next.dart
//
// The watch page re-ranks YouTube's related list for the viewer
// (rankUpNext). Reported as "suggestions below the video are not proper":
// under a Rick Astley song the rail led with a cricket video and office
// cartoons. This fetches the related list for several kinds of video, ranks
// it the way the app does for a viewer with an unrelated watch history (the
// case that goes wrong), and prints both orders side by side with how many of
// YouTube's top five survive in the app's top five and how far rows moved.
//
// Read-only: the next endpoint only, no player requests, nothing minted.
import 'dart:io';

import 'package:ai_bit/src/data/browse_client.dart';
import 'package:ai_bit/src/data/models.dart';
import 'package:ai_bit/src/data/recommender.dart';

Future<void> main() async {
  final now = DateTime.now();
  const seeds = {
    'dQw4w9WgXcQ': 'Rick Astley - Never Gonna Give You Up (music, 2009)',
    'jfKfPfyJRdk': 'lofi hip hop radio (live music)',
    'aqz-KE-bpKQ': 'Big Buck Bunny (animation)',
    'kJQP7kiw5Fk': 'Despacito (music)',
  };

  // A viewer who mostly watches fresh news and cricket — nothing to do with
  // any seed. This is the profile under which unrelated fresh videos jumped
  // the queue on the emulator.
  final profile = TasteProfile.from(
    history: [
      for (var i = 0; i < 12; i++)
        WatchSignal(
          videoId: 'n$i',
          channelId: i.isEven ? 'UCnews' : 'UCcricket',
          title: i.isEven ? 'breaking news today live' : 'cricket highlights india',
          watchedAt: now.subtract(Duration(hours: i * 5)),
          completion: 0.8,
        ),
    ],
    searches: const [],
    subscribed: const {},
    now: now,
  );

  final browse = YoutubeBrowseClient();
  var totalKept = 0;
  var totalDisplacement = 0.0;
  for (final entry in seeds.entries) {
    final related = await browse.related(entry.key);
    final current = VideoBrief(
      id: entry.key,
      title: entry.value,
      author: '',
      channelId: '',
    );
    final ours = rankUpNext(
      current: current,
      related: related,
      profile: profile,
      now: now,
    );
    final youtubeTop = related.take(5).map((v) => v.id).toSet();
    final kept = ours.take(5).where((v) => youtubeTop.contains(v.id)).length;
    final moves = <int>[];
    for (var i = 0; i < ours.length; i++) {
      moves.add((related.indexWhere((v) => v.id == ours[i].id) - i).abs());
    }
    final displacement = moves.isEmpty ? 0.0 : moves.reduce((a, b) => a + b) / moves.length;
    totalKept += kept;
    totalDisplacement += displacement;

    stdout.writeln('\n=== ${entry.value}');
    stdout.writeln('  YouTube top 5 kept in our top 5: $kept/5   mean rows moved: ${displacement.toStringAsFixed(1)}');
    stdout.writeln('  #   YouTube order                                  | ours');
    for (var i = 0; i < 6 && i < related.length; i++) {
      String cut(String s) => s.length > 44 ? '${s.substring(0, 44)}…' : s.padRight(45);
      final o = i < ours.length ? ours[i] : null;
      final from = o == null ? '' : ' (was ${related.indexWhere((v) => v.id == o.id) + 1})';
      stdout.writeln('  ${i + 1}   ${cut(related[i].title)} | ${o == null ? '' : cut(o.title)}$from');
    }
  }
  browse.close();
  final n = seeds.length;
  stdout.writeln('\nSUMMARY: top-5 kept ${(totalKept / n).toStringAsFixed(1)}/5 on average, '
      'mean rows moved ${(totalDisplacement / n).toStringAsFixed(1)}');
}
