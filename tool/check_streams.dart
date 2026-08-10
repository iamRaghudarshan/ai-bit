// Diagnostic for the one part of this app that can break without any code
// change: YouTube's player endpoints.
//
// Run it whenever playback starts failing, to see which API clients still
// return usable streams:
//
//   dart run tool/check_streams.dart [videoIdOrUrl]
//
// It mirrors the client chain and stream-selection rules in
// lib/src/data/yt_repository.dart, so a green result here means the app's
// resolver should succeed too.
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

// Not const: YoutubeApiClient.ios is a `static final`, not a constant.
final _clients = <(String, YoutubeApiClient)>[
  ('ios', YoutubeApiClient.ios),
  ('androidVr', YoutubeApiClient.androidVr),
  ('androidSdkless', YoutubeApiClient.androidSdkless),
  ('tv', YoutubeApiClient.tv),
];

Future<void> main(List<String> args) async {
  final input = args.isEmpty ? 'dQw4w9WgXcQ' : args.first;
  final videoId = VideoId.parseVideoId(input) ?? input;
  final yt = YoutubeExplode();

  stdout.writeln('Checking $videoId\n');

  try {
    final video = await yt.videos.get(videoId);
    stdout.writeln('metadata   OK  "${video.title}" by ${video.author}');
    stdout.writeln('           duration=${video.duration} '
        'views=${video.engagement.viewCount}\n');
  } catch (e) {
    stdout.writeln('metadata   FAIL  $e\n');
  }

  var anyPlayable = false;
  for (final (name, client) in _clients) {
    try {
      final manifest =
          await yt.videos.streamsClient.getManifest(videoId, ytClients: [client]);
      final hls = manifest.hls.whereType<HlsMuxedStreamInfo>().toList();
      final muxed = manifest.muxed.toList();
      final audio = manifest.audioOnly.toList();

      final playable = hls.isNotEmpty || muxed.isNotEmpty || audio.isNotEmpty;
      anyPlayable |= playable;

      stdout.writeln('${name.padRight(15)}${playable ? 'OK  ' : 'EMPTY'}'
          '  hlsMuxed=${hls.length} muxed=${muxed.length} '
          'audioOnly=${audio.length} videoOnly=${manifest.videoOnly.length}');

      final best = <VideoStreamInfo>[...hls, ...muxed]..sort(
          (a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));
      if (best.isNotEmpty) {
        final labels = best.map((s) => s.qualityLabel).toSet().take(8);
        stdout.writeln('${' ' * 15}      qualities: ${labels.join(', ')}');
      }
    } catch (e) {
      stdout.writeln('${name.padRight(15)}FAIL  $e');
    }
  }

  yt.close();

  stdout.writeln();
  if (anyPlayable) {
    stdout.writeln('RESULT: at least one client returned playable streams.');
  } else {
    stdout.writeln(
      'RESULT: no client returned playable streams. Try upgrading '
      'youtube_explode_dart (flutter pub upgrade youtube_explode_dart); '
      'YouTube has probably changed its player again.',
    );
    exitCode = 1;
  }
}

/// Search for something to test with when you do not have an id handy.
// ignore: unused_element
Future<void> sampleSearch() async {
  final yt = YoutubeExplode();
  final results = await yt.search.search('flutter');
  for (final video in results.take(5)) {
    stdout.writeln('${video.id}  ${video.title}');
  }
  yt.close();
}
