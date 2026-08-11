// Which channel tabs actually return content, and under which renderer.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const _tabs = {
  'Videos': 'EgZ2aWRlb3PyBgQKAjoA',
  'Shorts': 'EgZzaG9ydHPyBgUKA5oBAA%3D%3D',
  'Live': 'EgdzdHJlYW1z8gYECgJ6AA%3D%3D',
  'Playlists': 'EglwbGF5bGlzdHPyBgQKAkIA',
  'About': 'EgVhYm91dPIGBAoCEgA%3D',
};

Future<void> main(List<String> args) async {
  final channelId = args.isEmpty ? 'UCq-Fj5jknLsUf-MWSy4_brA' : args.first;
  final client = http.Client();

  for (final entry in _tabs.entries) {
    final params = Uri.decodeComponent(entry.value);
    final response = await client.post(
      Uri.parse('https://www.youtube.com/youtubei/v1/browse?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        'context': {
          'client': {'clientName': 'WEB', 'clientVersion': '2.20240101.00.00'},
        },
        'browseId': channelId,
        'params': params,
      }),
    );
    if (response.statusCode != 200) {
      stdout.writeln('${entry.key.padRight(10)} HTTP ${response.statusCode}');
      continue;
    }
    final body = response.body;
    int count(String key) => RegExp('"$key"').allMatches(body).length;
    stdout.writeln(
      '${entry.key.padRight(10)} ${(body.length / 1024).round()}KB  '
      'lockup=${count('lockupViewModel')} '
      'shortsLockup=${count('shortsLockupViewModel')} '
      'video=${count('videoRenderer')} '
      'about=${count('aboutChannelViewModel')}',
    );
  }
  client.close();
}
