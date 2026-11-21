// How fast does googlevideo actually serve the stream the player is handed?
//
//   dart run tool/check_stream_speed.dart [videoId ...]
//
// Start-up on the emulator was dominated by the player fetching the first
// second of the progressive 360p file, not by resolving it. This times the
// first byte and the first 1 MB of that exact URL, the way ExoPlayer opens it
// (an open-ended range), so a throttled URL shows up as a number.
import 'dart:io';

import 'package:ai_bit/src/data/player_client.dart';
import 'package:http/http.dart' as http;

const _videos = ['dQw4w9WgXcQ', 'kJQP7kiw5Fk', '9bZkp7q19f0', 'LaOUkDBDjW8'];

Future<void> main(List<String> args) async {
  for (final id in args.isEmpty ? _videos : args) {
    final client = YoutubePlayerClient();
    final streams = await client.fetch(id);
    client.close();
    final url = streams?.muxedUrl;
    if (url == null) {
      stdout.writeln('$id  no progressive stream');
      continue;
    }
    final http2 = http.Client();
    final sw = Stopwatch()..start();
    final req = http.Request('GET', Uri.parse(url))
      ..headers['Range'] = 'bytes=0-';
    final resp = await http2.send(req);
    final firstByte = sw.elapsedMilliseconds;
    var got = 0;
    await for (final chunk in resp.stream) {
      got += chunk.length;
      if (got >= 1024 * 1024) break;
    }
    final ms = sw.elapsedMilliseconds;
    http2.close();
    final kbps = (got / 1024) / (ms / 1000);
    final host = Uri.parse(url).host;
    stdout.writeln('$id  HTTP ${resp.statusCode}  first byte ${firstByte}ms  '
        '1MB in ${ms}ms (${kbps.toStringAsFixed(0)} KB/s)  '
        'n=${Uri.parse(url).queryParameters.containsKey('n')}  $host');
  }
}
