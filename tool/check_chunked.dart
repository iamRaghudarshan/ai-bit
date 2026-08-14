// Verifies the ranged-chunk download mechanism used by
// YtRepository._rangedDownload against a live googlevideo stream: does YouTube
// honour 8 MB Range requests and does the whole file arrive?
//
//   dart run tool/check_chunked.dart [videoId]
// ignore_for_file: avoid_print
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main(List<String> args) async {
  final id = args.isNotEmpty ? args.first : 'jNQXAC9IVRw';
  final yt = YoutubeExplode();
  try {
    final manifest = await yt.videos.streamsClient.getManifest(
      id,
      ytClients: [YoutubeApiClient.androidVr, YoutubeApiClient.androidSdkless],
    );
    final muxed = manifest.muxed.toList()
      ..sort((a, b) => a.size.totalBytes.compareTo(b.size.totalBytes));
    if (muxed.isEmpty) {
      print('no muxed stream for $id');
      return;
    }
    final info = muxed.last;
    final total = info.size.totalBytes;
    print('stream  ${info.qualityLabel} ${info.container.name}  '
        '${(total / 1024 / 1024).toStringAsFixed(2)} MB  throttled=${info.isThrottled}');

    const chunkSize = 8 * 1024 * 1024;
    const chunkTimeout = Duration(seconds: 25);
    final client = http.Client();
    final sw = Stopwatch()..start();
    var received = 0;
    var chunks = 0;
    while (received < total) {
      final end = (received + chunkSize >= total ? total : received + chunkSize) - 1;
      final request = http.Request('GET', info.url)
        ..headers['Range'] = 'bytes=$received-$end';
      final response = await client.send(request).timeout(chunkTimeout);
      if (response.statusCode != 206 && response.statusCode != 200) {
        print('FAIL  chunk from $received got HTTP ${response.statusCode}');
        client.close();
        return;
      }
      await for (final data in response.stream.timeout(chunkTimeout)) {
        received += data.length;
      }
      chunks++;
      print('  chunk $chunks  → ${(received / 1024 / 1024).toStringAsFixed(2)} MB');
    }
    client.close();
    sw.stop();
    final ok = received == total;
    print('${ok ? 'OK' : 'MISMATCH'}  $received of $total bytes in $chunks chunks, '
        '${sw.elapsed.inMilliseconds / 1000}s '
        '(${(received / 1024 / 1024 / (sw.elapsed.inMilliseconds / 1000)).toStringAsFixed(2)} MB/s)');
    print(ok ? 'RESULT: ranged chunked download works.' : 'RESULT: byte count mismatch.');
  } finally {
    yt.close();
  }
}
