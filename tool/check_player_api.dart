// Asks YouTube's player endpoint directly what it will serve, per client.
//
//   dart run tool/check_player_api.dart [videoId ...]
//
// Two questions this answers that youtube_explode_dart cannot:
//   1. Live streams -- getManifest crashes on them, but the player response
//      carries hlsManifestUrl, which AVPlayer plays natively.
//   2. Whether hlsManifestUrl also exists for ordinary videos. If it does, it
//      is an adaptive ladder above the 360p ceiling that muxed streams impose.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

final _clients = <String, Map<String, dynamic>>{
  'ios': {
    'clientName': 'IOS',
    'clientVersion': '20.10.4',
    'deviceMake': 'Apple',
    'deviceModel': 'iPhone16,2',
    'osName': 'IOS',
    'osVersion': '18.1.0.22B83',
    'hl': 'en',
    'gl': 'US',
  },
  'web': {'clientName': 'WEB', 'clientVersion': '2.20250312.04.00', 'hl': 'en'},
  'mweb': {'clientName': 'MWEB', 'clientVersion': '2.20240726.01.00', 'hl': 'en'},
  'android': {
    'clientName': 'ANDROID',
    'clientVersion': '20.10.38',
    'osName': 'Android',
    'osVersion': '11',
    'hl': 'en',
  },
  'tvhtml5': {
    'clientName': 'TVHTML5',
    'clientVersion': '7.20251105.10.00',
    'hl': 'en',
  },
};

Future<void> main(List<String> args) async {
  // A live stream and an ordinary video, so the two cases can be compared.
  final ids = args.isEmpty ? ['jdJoOhqCipA', 'dQw4w9WgXcQ'] : args;
  final client = http.Client();

  for (final id in ids) {
    stdout.writeln('\n===== $id =====');
    for (final entry in _clients.entries) {
      try {
        final res = await client
            .post(
              Uri.parse(
                'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
              ),
              headers: const {
                'Content-Type': 'application/json',
                'Origin': 'https://www.youtube.com',
              },
              body: jsonEncode({
                'context': {'client': entry.value},
                'videoId': id,
                'contentCheckOk': true,
                'racyCheckOk': true,
              }),
            )
            .timeout(const Duration(seconds: 20));

        if (res.statusCode != 200) {
          stdout.writeln('${entry.key.padRight(9)} HTTP ${res.statusCode}');
          continue;
        }

        final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final status = (j['playabilityStatus'] as Map?)?['status'];
        final sd = j['streamingData'] as Map?;
        final details = j['videoDetails'] as Map?;
        final isLive = details?['isLiveContent'] == true;
        final hls = sd?['hlsManifestUrl'];
        final dash = sd?['dashManifestUrl'];
        final formats = (sd?['formats'] as List?)?.length ?? 0;
        final adaptive = (sd?['adaptiveFormats'] as List?)?.length ?? 0;

        stdout.writeln(
          '${entry.key.padRight(9)} $status  live=$isLive  '
          'formats=$formats adaptive=$adaptive  '
          'hls=${hls == null ? 'no' : 'YES'}  dash=${dash == null ? 'no' : 'yes'}',
        );

        if (hls is String) {
          stdout.writeln('          ${hls.substring(0, hls.length.clamp(0, 90))}...');
        }
        if (status != 'OK') {
          final reason = (j['playabilityStatus'] as Map?)?['reason'];
          if (reason != null) stdout.writeln('          reason: $reason');
        }
      } catch (e) {
        stdout.writeln('${entry.key.padRight(9)} ERROR $e');
      }
    }
  }

  client.close();
}
