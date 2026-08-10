// One-off experiment: which YouTube API clients still return a *combined*
// (muxed or HLS) stream, and at what quality?
//
//   dart run tool/probe_clients.dart [videoId ...]
//
// This matters because a single-URL player cannot recombine separate
// video-only and audio-only tracks, so combined streams decide the ceiling on
// playback quality.
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

final _clients = <(String, YoutubeApiClient)>[
  ('ios', YoutubeApiClient.ios),
  ('safari', YoutubeApiClient.safari),
  ('mweb', YoutubeApiClient.mweb),
  ('androidVr', YoutubeApiClient.androidVr),
  ('androidSdkless', YoutubeApiClient.androidSdkless),
  ('android', YoutubeApiClient.android),
  ('androidMusic', YoutubeApiClient.androidMusic),
  ('mediaConnect', YoutubeApiClient.mediaConnect),
  ('tv', YoutubeApiClient.tv),
];

Future<void> main(List<String> args) async {
  final ids = args.isEmpty
      ? ['dQw4w9WgXcQ', 'jNQXAC9IVRw', 'aqz-KE-bpKQ']
      : args;
  final yt = YoutubeExplode();

  for (final id in ids) {
    stdout.writeln('\n===== $id =====');
    for (final (name, client) in _clients) {
      try {
        final m = await yt.videos.streamsClient
            .getManifest(id, ytClients: [client])
            .timeout(const Duration(seconds: 30));
        final hls = m.hls.whereType<HlsMuxedStreamInfo>().toList();
        final muxed = m.muxed.toList();
        final combined = <VideoStreamInfo>[...hls, ...muxed]
          ..sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));
        final bestVideoOnly = m.videoOnly.isEmpty
            ? '-'
            : (m.videoOnly.toList()
                    ..sort((a, b) =>
                        b.videoResolution.height.compareTo(a.videoResolution.height)))
                .first
                .qualityLabel;

        stdout.writeln(
          '${name.padRight(16)} combined=${combined.isEmpty ? '-' : combined.map((s) => s.qualityLabel).toSet().join('/')}'
          '  (hls=${hls.length} muxed=${muxed.length})'
          '  bestVideoOnly=$bestVideoOnly  audioOnly=${m.audioOnly.length}',
        );
      } catch (e) {
        final msg = e.toString();
        stdout.writeln(
          '${name.padRight(16)} FAIL ${msg.substring(0, msg.length > 90 ? 90 : msg.length)}',
        );
      }
    }
  }

  yt.close();
}
