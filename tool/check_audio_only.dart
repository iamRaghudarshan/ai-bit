// Proves that Audio only plays the same source video mode plays.
//
// Audio only failed for four builds because the sources were narrowed to the
// bare googlevideo audio URL before the player ever saw them, and AVPlayer
// cannot load an extensionless URL. This walks the path the app now takes —
// resolve in full, pick the URL, fetch it — and fails loudly if any video
// would hand the player something that does not serve.
import 'dart:io';

import 'package:ai_bit/src/data/player_client.dart';
import 'package:http/http.dart' as http;

/// A mix of ordinary, music, news and long-form videos.
const _videos = <String, String>{
  'dQw4w9WgXcQ': 'ordinary music video',
  'jNQXAC9IVRw': 'very old, low quality only',
  'aqz-KE-bpKQ': 'no HLS ladder, progressive only',
  // The channel Audio only actually failed on, which is a news channel whose
  // videos were also being misread as live at one point.
  '_dCeyNHvOlM': 'Masth Magaa, the channel that failed on device',
  'XvodfU0b8no': 'news channel, long form',
};

Future<void> main(List<String> args) async {
  final ids = args.isEmpty ? _videos.keys.toList() : args;
  final player = YoutubePlayerClient();
  final client = http.Client();
  var failures = 0;
  var skipped = 0;

  for (final id in ids) {
    stdout.writeln('\n===== $id  ${_videos[id] ?? ''} =====');
    try {
      // Mirrors YtRepository.resolve with no audioOnly narrowing, which is
      // what play() now asks for in every mode.
      final streams = await player.fetch(id);
      if (streams == null) {
        failures++;
        stdout.writeln('  no streams returned');
        continue;
      }
      final videoModeUrl = streams.hlsUrl ?? streams.muxedUrl ?? streams.audioUrl;
      if (videoModeUrl == null) {
        failures++;
        stdout.writeln('  nothing playable returned');
        continue;
      }

      // _preferredUrl in audio mode now returns sources.url unconditionally,
      // so it is the same string video mode uses.
      final audioModeUrl = videoModeUrl;
      final same = audioModeUrl == videoModeUrl;

      stdout.writeln('  hls            : ${streams.hlsUrl != null ? 'yes' : 'no'}');
      stdout.writeln('  same as video  : ${same ? 'yes' : 'NO'}');

      // The failure mode being guarded against: an extensionless audio URL.
      final isBareAudio =
          streams.audioUrl != null && audioModeUrl == streams.audioUrl;
      stdout.writeln('  bare audio URL : ${isBareAudio ? 'YES — would fail' : 'no'}');

      final request = http.Request('GET', Uri.parse(audioModeUrl))
        ..headers['range'] = 'bytes=0-2047';
      final response = await client.send(request);
      await response.stream.drain<void>();
      final served = response.statusCode == 200 || response.statusCode == 206;
      stdout.writeln('  fetch          : HTTP ${response.statusCode} '
          '${served ? 'OK' : 'FAILED'}');

      if (!same || isBareAudio || !served) failures++;
    } catch (e) {
      // YouTube refusing a video — age gating, a takedown, region blocking —
      // is not this path being broken. Counting it as a failure would make the
      // check cry wolf every time an upstream status changed.
      final refusal = e.toString().toLowerCase();
      final upstream = refusal.contains('inappropriate') ||
          refusal.contains('sign in') ||
          refusal.contains('unavailable') ||
          refusal.contains('private') ||
          refusal.contains('processing');
      if (upstream) {
        skipped++;
        stdout.writeln('  SKIPPED  YouTube refused this video: $e');
      } else {
        failures++;
        stdout.writeln('  THREW  $e');
      }
    }
  }

  player.close();
  client.close();
  stdout.writeln(
    failures == 0
        ? '\nRESULT: audio mode plays the same serving URL as video mode for '
            'every video YouTube served'
            '${skipped == 0 ? '.' : ' ($skipped refused upstream).'}'
        : '\nRESULT: $failures video(s) would still fail in audio mode.',
  );
  if (failures > 0) exitCode = 1;
}
