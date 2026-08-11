// What the quality picker will actually be able to offer.
//
// It showed only "Auto" on every video: HLS videos because the sheet snapshot
// was taken before the manifest parsed, and progressive videos because the
// resolver reported no renditions at all. This covers the second half — the
// first is a UI listener and cannot be checked from here.
import 'dart:io';

import 'package:ai_bit/src/data/player_client.dart';

Future<void> main(List<String> args) async {
  final ids = args.isEmpty
      ? ['dQw4w9WgXcQ', '_dCeyNHvOlM', 'aqz-KE-bpKQ', 'jNQXAC9IVRw']
      : args;
  final player = YoutubePlayerClient();
  var empty = 0;

  for (final id in ids) {
    final streams = await player.fetch(id);
    if (streams == null) {
      stdout.writeln('$id  no streams');
      empty++;
      continue;
    }
    final hls = streams.hlsUrl != null;
    final muxed = streams.muxedQualities.keys.toList();
    stdout.writeln(
      '$id  ${hls ? 'HLS ladder (picker reads tracks)' : 'progressive'}'
      '  muxed=${muxed.isEmpty ? 'none' : muxed.join(', ')}',
    );
    // A progressive video with no reported rendition is the broken case.
    if (!hls && muxed.isEmpty) empty++;
  }

  player.close();
  stdout.writeln(
    empty == 0
        ? '\nRESULT: every video can offer at least one named quality.'
        : '\nRESULT: $empty video(s) would still show only Auto.',
  );
  if (empty > 0) exitCode = 1;
}
