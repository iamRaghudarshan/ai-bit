// Can we read a channel's header and its playlists?
//
//   dart run tool/check_browse.dart [channelId ...]
//
// youtube_explode_dart lists a channel's uploads but not its playlists, so the
// browse endpoint is queried directly. YouTube is mid-migration from
// gridPlaylistRenderer to lockupViewModel, so this proves which shape actually
// comes back before any UI is built on it.
import 'dart:io';

import 'package:ai_bit/src/data/browse_client.dart';

Future<void> main(List<String> args) async {
  final ids = args.isEmpty
      ? [
          'UCuAXFkgsw1L7xaCfnd5JJOw', // Rick Astley
          'UCq-Fj5jknLsUf-MWSy4_brA', // T-Series
          'UCXuqSBlHAE6Xw-yeJA0Tunw', // Linus Tech Tips
        ]
      : args;

  final browse = YoutubeBrowseClient();
  var failures = 0;

  for (final id in ids) {
    stdout.writeln('\n===== $id =====');

    try {
      final c = await browse.channel(id);
      stdout.writeln('  title  : ${c.title.isEmpty ? "(EMPTY)" : c.title}');
      stdout.writeln('  subs   : ${c.subscriberLabel ?? "-"}');
      stdout.writeln('  avatar : ${c.avatarUrl != null ? "yes" : "NO"}');
      if (c.title.isEmpty) failures++;
    } catch (e) {
      stdout.writeln('  channel FAILED: $e');
      failures++;
    }

    try {
      final playlists = await browse.channelPlaylists(id);
      stdout.writeln('  playlists: ${playlists.length}');
      for (final p in playlists.take(4)) {
        stdout.writeln('     ${p.id}  ${p.videoCount ?? "?"} videos  '
            '${p.title.isEmpty ? "(NO TITLE)" : p.title}');
      }
      if (playlists.isEmpty) failures++;
    } catch (e) {
      stdout.writeln('  playlists FAILED: $e');
      failures++;
    }
  }

  browse.close();
  stdout.writeln();
  stdout.writeln(failures == 0
      ? 'RESULT: channel headers and playlists both readable.'
      : 'RESULT: $failures checks failed.');
  if (failures > 0) exitCode = 1;
}
