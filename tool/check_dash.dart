// Does the generated DASH manifest describe something YouTube will serve?
//
//   dart run tool/check_dash.dart [videoId ...]
//
// This is the diagnostic for "HD is not playing, it is always 360p". YouTube
// has mostly stopped returning `hlsManifestUrl` — about one video in eight
// still gets one — so above 360p the app builds its own DASH manifest out of
// the separate video and audio tracks. Nothing here can be verified by
// reading the code: the manifest is only right if googlevideo honours the byte
// ranges in it, which is a live question.
//
// It checks, per video:
//   1. whether YouTube offered an HLS ladder at all (the old route),
//   2. what ladder the generated manifest offers (the new route),
//   3. that the XML is well-formed, which an unescaped `&` in a stream URL
//      would break, and
//   4. that the init and index byte ranges of the top rendition really return
//      HTTP 206 with the expected number of bytes.
//
// If (4) fails, the manifest is a fiction and playback will fail on device
// with nothing in the Dart logs to say why.
import 'dart:convert';
import 'dart:io';

import 'package:ai_bit/src/data/dash_manifest.dart';
import 'package:http/http.dart' as http;

const _iosContext = {
  'clientName': 'IOS',
  'clientVersion': '20.10.4',
  'deviceMake': 'Apple',
  'deviceModel': 'iPhone16,2',
  'osName': 'IOS',
  'osVersion': '18.1.0.22B83',
  'hl': 'en',
  'gl': 'US',
};
const _iosAgent =
    'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)';

Future<void> main(List<String> args) async {
  final ids = args.isEmpty
      ? ['dQw4w9WgXcQ', 'LXb3EKWsInQ', 'aqz-KE-bpKQ', 'jNQXAC9IVRw']
      : args;
  final client = http.Client();
  var failures = 0;

  for (final id in ids) {
    stdout.writeln('\n===== $id =====');
    try {
      final res = await client
          .post(
            Uri.parse(
              'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
            ),
            headers: const {
              'Content-Type': 'application/json',
              'Origin': 'https://www.youtube.com',
              'User-Agent': _iosAgent,
            },
            body: jsonEncode({
              'context': {'client': _iosContext},
              'videoId': id,
              'contentCheckOk': true,
              'racyCheckOk': true,
            }),
          )
          .timeout(const Duration(seconds: 25));

      final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final status = (json['playabilityStatus'] as Map?)?['status'];
      if (status != 'OK') {
        stdout.writeln('  playabilityStatus: $status  — skipped');
        continue;
      }
      final streaming = json['streamingData'] as Map<String, dynamic>?;
      stdout.writeln(
        '  hlsManifestUrl: ${streaming?['hlsManifestUrl'] == null ? 'ABSENT (needs DASH)' : 'present'}',
      );

      final formats = [
        for (final f in (streaming?['adaptiveFormats'] as List? ?? const []))
          ?parseAdaptiveFormat(f),
      ];
      stdout.writeln('  usable adaptive formats: ${formats.length}');

      final ladder = dashLadder(formats);
      stdout.writeln('  ladder: ${ladder.isEmpty ? 'NONE' : ladder.join(', ')}');

      final manifest = buildDashManifest(formats);
      if (manifest == null) {
        stdout.writeln('  FAIL: no manifest could be built');
        failures++;
        continue;
      }
      stdout.writeln('  manifest: ${manifest.length} bytes');

      // 3. Well-formedness. An unescaped ampersand in a stream URL is the one
      // mistake that silently breaks the whole document, so check for a raw
      // `&` outside an entity rather than trusting the escaper.
      final raw = RegExp(r'&(?!(amp|lt|gt|quot|apos);)').allMatches(manifest);
      if (raw.isNotEmpty) {
        stdout.writeln('  FAIL: ${raw.length} unescaped ampersand(s)');
        failures++;
        continue;
      }
      final opens = RegExp('<Representation ').allMatches(manifest).length;
      final closes = RegExp('</Representation>').allMatches(manifest).length;
      if (opens != closes || opens == 0) {
        stdout.writeln('  FAIL: $opens Representation opens, $closes closes');
        failures++;
        continue;
      }
      stdout.writeln('  XML: $opens representations, ampersands escaped');

      // 4. The ranges have to be real. Take the tallest video rendition the
      // manifest offers and ask googlevideo for exactly the bytes it claims.
      final videos = formats.where((f) => f.isVideo).toList()
        ..sort((a, b) => b.height.compareTo(a.height));
      final audios = formats.where((f) => f.isAudio).toList();
      if (videos.isEmpty || audios.isEmpty) {
        stdout.writeln('  FAIL: manifest built without both media types');
        failures++;
        continue;
      }

      var ok = true;
      for (final f in [videos.first, audios.first]) {
        final kind = f.isVideo ? 'video ${f.height}p' : 'audio';
        for (final range in [
          ('init', f.initStart, f.initEnd),
          ('index', f.indexStart, f.indexEnd),
        ]) {
          final want = range.$3 - range.$2 + 1;
          final r = await client.get(
            Uri.parse(f.url),
            headers: {
              'Range': 'bytes=${range.$2}-${range.$3}',
              'User-Agent': _iosAgent,
            },
          ).timeout(const Duration(seconds: 25));
          final got = r.bodyBytes.length;
          final good = r.statusCode == 206 && got == want;
          if (!good) ok = false;
          stdout.writeln(
            '    $kind ${range.$1}: HTTP ${r.statusCode} '
            '$got/$want bytes ${good ? 'ok' : 'MISMATCH'}',
          );
        }
      }
      if (!ok) failures++;
    } catch (e) {
      stdout.writeln('  ERROR $e');
      failures++;
    }
  }

  client.close();
  stdout.writeln(
    failures == 0
        ? '\nRESULT: every generated manifest describes bytes YouTube served.'
        : '\nRESULT: $failures video(s) failed — do not trust HD playback.',
  );
  if (failures > 0) exitCode = 1;
}
