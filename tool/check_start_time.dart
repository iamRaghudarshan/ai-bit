// Where does the time go between tapping a video and the player starting?
//
//   dart run tool/check_start_time.dart [videoId ...]
//
// Reported as "videos sometimes take long to start". resolve() made three
// network round trips before the native player got a URL, all in a row: the
// ios player request, the android player request, and the end-of-file probe
// that decides whether the adaptive tracks are capped. This times each one
// separately, then the two player requests in parallel, so the saving from
// overlapping them is a measured number rather than a guess.
import 'dart:io';

import 'package:ai_bit/src/data/player_client.dart';
import 'package:http/http.dart' as http;

const _videos = ['dQw4w9WgXcQ', 'kJQP7kiw5Fk', '9bZkp7q19f0', 'LaOUkDBDjW8'];

Future<void> main(List<String> args) async {
  final ids = args.isEmpty ? _videos : args;
  final seq = <int>[], par = <int>[], probe = <int>[];
  for (final id in ids) {
    final client = YoutubePlayerClient();
    final sw = Stopwatch()..start();
    final streams = await client.fetch(id, parallel: false);
    final fetchMs = sw.elapsedMilliseconds;

    sw.reset();
    await client.fetch(id, parallel: true);
    final parMs = sw.elapsedMilliseconds;

    var probeMs = -1;
    var probeCode = 0;
    final formats = streams?.adaptiveFormats ?? const [];
    final videos = [for (final f in formats) if (f.isVideo && f.isUsable) f]
      ..sort((a, b) => b.height.compareTo(a.height));
    if (videos.isNotEmpty) {
      final url = videos.first.url;
      final clen = int.tryParse(Uri.parse(url).queryParameters['clen'] ?? '');
      if (clen != null) {
        sw.reset();
        final r = await http.get(Uri.parse(url),
            headers: {'Range': 'bytes=${clen - 2}-${clen - 1}'});
        probeMs = sw.elapsedMilliseconds;
        probeCode = r.statusCode;
      }
    }
    client.close();
    seq.add(fetchMs);
    par.add(parMs);
    if (probeMs >= 0) probe.add(probeMs);
    stdout.writeln('$id  player sequential=${fetchMs}ms  parallel=${parMs}ms  '
        'probe=${probeMs}ms (HTTP $probeCode)  hls=${streams?.hlsUrl != null}');
  }
  int avg(List<int> l) => l.isEmpty ? 0 : l.reduce((a, b) => a + b) ~/ l.length;
  stdout.writeln('\nAVERAGE  sequential=${avg(seq)}ms  parallel=${avg(par)}ms  '
      'probe=${avg(probe)}ms');
  stdout.writeln('before the player started: ${avg(seq) + avg(probe)}ms; '
      'with parallel requests and the probe off the critical path: '
      '${avg(par)}ms');
}
