// Does the resolved stream URL actually serve bytes to a player?
//
//   dart run tool/check_playback.dart [videoId ...]
//
// Extraction working does not mean playback works. YouTube hands out a URL and
// then decides, at fetch time, whether to honour it — a stream obtained through
// an Android client can 403 when the player requests it with a different
// User-Agent. This fetches the first kilobyte the way a player would, with and
// without a matching UA, and reports the status codes.
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

final _clients = <(String, YoutubeApiClient)>[
  ('androidVr', YoutubeApiClient.androidVr),
  ('androidSdkless', YoutubeApiClient.androidSdkless),
  ('ios', YoutubeApiClient.ios),
];

// What each client claims to be. A stream issued to one of these is often only
// served back to the same identity.
const _agents = <String, String>{
  'androidVr':
      'com.google.android.youtube/1.56.21 (Linux; U; Android 12; Quest 3) gzip',
  'androidSdkless':
      'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
  'ios':
      'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
  // What AVPlayer on an iPhone actually sends if we set nothing.
  'AVPlayer (no header set)': 'AppleCoreMedia/1.0.0.22C161 (iPhone; U; CPU OS 18_1 like Mac OS X; en_us)',
};

Future<void> main(List<String> args) async {
  final ids = args.isEmpty ? ['dQw4w9WgXcQ'] : args;
  final yt = YoutubeExplode();
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 20);

  for (final input in ids) {
    final id = VideoId.parseVideoId(input) ?? input;
    stdout.writeln('\n===== $id =====');

    for (final (clientName, client) in _clients) {
      Uri? url;
      String label = '';
      try {
        final m = await yt.videos.streamsClient
            .getManifest(id, ytClients: [client]);
        final muxed = m.muxed.toList()
          ..sort((a, b) =>
              b.videoResolution.height.compareTo(a.videoResolution.height));
        if (muxed.isEmpty) {
          stdout.writeln('$clientName: no muxed stream');
          continue;
        }
        url = muxed.first.url;
        label = muxed.first.qualityLabel;
      } catch (e) {
        stdout.writeln('$clientName: manifest failed — $e');
        continue;
      }

      stdout.writeln('$clientName ($label):');
      for (final entry in _agents.entries) {
        try {
          final req = await http.getUrl(url);
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
          req.headers.set(HttpHeaders.userAgentHeader, entry.value);
          final res = await req.close();
          final body = await res.fold<int>(0, (n, chunk) => n + chunk.length);
          final verdict = (res.statusCode == 200 || res.statusCode == 206)
              ? 'OK'
              : 'BLOCKED';
          stdout.writeln('    ${entry.key.padRight(26)} '
              'HTTP ${res.statusCode}  $body bytes  $verdict');
        } catch (e) {
          stdout.writeln('    ${entry.key.padRight(26)} ERROR $e');
        }
      }
    }
  }

  http.close(force: true);
  yt.close();
  stdout.writeln('\nIf a row says 403/BLOCKED, the player must send that '
      "client's User-Agent for the stream to be served.");
}
