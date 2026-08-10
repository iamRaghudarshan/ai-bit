// End-to-end check of what the app will actually hand the player.
//
//   dart run tool/check_resolve.dart [videoId ...]
//
// Exercises YoutubePlayerClient the way YtRepository.resolve does, then fetches
// the chosen URL to prove it serves. Covers the two cases that broke on device:
// a live stream (no progressive stream exists at all) and an ordinary video
// (where the HLS ladder is the difference between 360p and 2160p).
import 'dart:io';

import 'package:ai_bit/src/data/player_client.dart';
import 'package:http/http.dart' as http;

Future<void> main(List<String> args) async {
  final ids = args.isEmpty
      ? ['jdJoOhqCipA', 'dQw4w9WgXcQ', 'aqz-KE-bpKQ']
      : args;

  final player = YoutubePlayerClient();
  final client = http.Client();
  var failures = 0;

  for (final id in ids) {
    stdout.writeln('\n===== $id =====');
    try {
      final s = await player.fetch(id);
      if (s == null) {
        stdout.writeln('  NOTHING PLAYABLE');
        failures++;
        continue;
      }

      stdout.writeln('  live      : ${s.isLive}');
      stdout.writeln('  hls       : ${s.hlsUrl != null ? 'yes' : 'no'}');
      stdout.writeln('  muxed 360 : ${s.muxedUrl != null ? 'yes' : 'no'}');
      stdout.writeln('  audio     : ${s.audioUrl != null ? 'yes' : 'no'}');

      final chosen = s.hlsUrl ?? s.muxedUrl ?? s.audioUrl;
      if (chosen == null) {
        stdout.writeln('  NO URL CHOSEN');
        failures++;
        continue;
      }

      final res = await client
          .get(Uri.parse(chosen), headers: const {'Range': 'bytes=0-2047'})
          .timeout(const Duration(seconds: 25));
      final ok = res.statusCode == 200 || res.statusCode == 206;
      stdout.writeln('  fetch     : HTTP ${res.statusCode} '
          '${res.bodyBytes.length} bytes  ${ok ? 'OK' : 'BLOCKED'}');
      if (!ok) failures++;

      // For a ladder, list what qualities the player will be able to pick.
      if (s.hlsUrl != null && res.body.contains('RESOLUTION=')) {
        final heights = RegExp(r'RESOLUTION=\d+x(\d+)')
            .allMatches(res.body)
            .map((m) => int.parse(m.group(1)!))
            .toSet()
            .toList()
          ..sort();
        stdout.writeln('  qualities : ${heights.map((h) => '${h}p').join(', ')}');
      }
    } catch (e) {
      stdout.writeln('  FAILED $e');
      failures++;
    }
  }

  player.close();
  client.close();

  stdout.writeln();
  stdout.writeln(failures == 0
      ? 'RESULT: every video resolved to a URL that serves.'
      : 'RESULT: $failures failed.');
  if (failures > 0) exitCode = 1;
}
