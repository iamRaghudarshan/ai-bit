// Does any alternate client return UNCAPPED HD once a visitorData is sent?
//
//   dart run tool/check_visitor_clients.dart [videoId]
//
// This is the open question on HD, and the last one that can be answered
// without either signing in or minting a proof-of-origin token.
//
// `check_stream_limits.dart` establishes that the IOS and ANDROID clients
// serve a byte-range HD track for only the first ~60 seconds, and that every
// other client answers LOGIN_REQUIRED. But those requests carried no
// `visitorData` at all. visitorData is an anonymous session identifier that
// youtube.com puts in its own page config for any logged-out visitor — there
// is no challenge to solve and no account involved in getting one — and
// several clients refuse a request simply for lacking it. ANDROID_VR is the
// interesting case: it is the client yt-dlp falls back to precisely because it
// has not required a token.
//
// Each client is tried twice, without and with the id, so the variable is
// isolated. For any that answers OK, the top plain AVC track's last two bytes
// are requested: `FULL LENGTH ***` there would mean HD is reachable, and the
// app's existing `_adaptiveTracksPlayThroughout` check would start choosing it
// with no further code change. `ciphered` counts formats behind
// `signatureCipher`, which need the player JS solved before their URLs can be
// used at all — a client offering only those is a bigger job than it looks.
import 'dart:convert';
import 'dart:io';

import 'package:ai_bit/src/data/dash_manifest.dart';
import 'package:http/http.dart' as http;

const _clients = <(String, Map<String, Object>, String)>[
  (
    'ANDROID_VR',
    {
      'clientName': 'ANDROID_VR',
      'clientVersion': '1.60.19',
      'deviceMake': 'Oculus',
      'deviceModel': 'Quest 3',
      'osName': 'Android',
      'osVersion': '12L',
      'androidSdkVersion': 32,
    },
    'com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
  ),
  (
    'ANDROID_VR_OLD',
    {
      'clientName': 'ANDROID_VR',
      'clientVersion': '1.56.21',
      'deviceMake': 'Oculus',
      'deviceModel': 'Quest 3',
      'osName': 'Android',
      'osVersion': '12',
      'androidSdkVersion': 32,
    },
    'com.google.android.apps.youtube.vr.oculus/1.56.21 (Linux; U; Android 12; GB) gzip',
  ),
  (
    'TVHTML5',
    {
      'clientName': 'TVHTML5',
      'clientVersion': '7.20251105.10.00',
      'userAgent': 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version,gzip(gfe)',
      'originalUrl': 'https://www.youtube.com/tv',
      'theme': 'CLASSIC',
      'platform': 'DESKTOP',
      'clientFormFactor': 'UNKNOWN_FORM_FACTOR',
      'deviceMake': '',
      'deviceModel': '',
    },
    'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version,gzip(gfe)',
  ),
  (
    'WEB_SAFARI',
    {
      'clientName': 'WEB',
      'clientVersion': '2.20250312.04.00',
      'userAgent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)',
    },
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15',
  ),
  (
    'MWEB',
    {
      'clientName': 'MWEB',
      'clientVersion': '2.20250312.04.00',
    },
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
  ),
  (
    'IOS_UNPLUGGED',
    {
      'clientName': 'IOS_UNPLUGGED',
      'clientVersion': '8.33.0',
      'deviceMake': 'Apple',
      'deviceModel': 'iPhone16,2',
      'osName': 'iPhone',
      'osVersion': '18.1.0.22B83',
    },
    'com.google.ios.youtubeunplugged/8.33.0 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X;)',
  ),
];

Future<void> main(List<String> args) async {
  final id = args.isEmpty ? 'aqz-KE-bpKQ' : args.first;
  final client = http.Client();

  // Where a visitorData can come from without solving anything.
  final visitor = await _visitorData(client);
  stdout.writeln('visitorData: ${visitor == null ? 'COULD NOT GET ONE' : '${visitor.substring(0, 24)}… (${visitor.length} chars)'}');
  if (visitor == null) {
    client.close();
    return;
  }

  for (final profile in _clients) {
    for (final withVisitor in [false, true]) {
      final label = '${profile.$1}${withVisitor ? ' +visitor' : ''}';
      try {
        final context = <String, Object>{
          ...profile.$2,
          'hl': 'en',
          'gl': 'US',
          if (withVisitor) 'visitorData': visitor,
        };
        final res = await client
            .post(
              Uri.parse(
                'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
              ),
              headers: {
                'Content-Type': 'application/json',
                'Origin': 'https://www.youtube.com',
                'User-Agent': profile.$3,
                if (withVisitor) 'X-Goog-Visitor-Id': visitor,
              },
              body: jsonEncode({
                'context': {'client': context},
                'videoId': id,
                'contentCheckOk': true,
                'racyCheckOk': true,
              }),
            )
            .timeout(const Duration(seconds: 25));
        final json =
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final ps = json['playabilityStatus'] as Map?;
        final status = ps?['status']?.toString() ?? '?';
        if (status != 'OK') {
          stdout.writeln('  ${label.padRight(26)} $status  ${ps?['reason'] ?? ''}');
          continue;
        }
        final streaming = json['streamingData'] as Map<String, dynamic>?;
        final hls = streaming?['hlsManifestUrl'] as String?;
        final formats = [
          for (final f in (streaming?['adaptiveFormats'] as List? ?? const []))
            ?parseAdaptiveFormat(f),
        ];
        final ciphered = (streaming?['adaptiveFormats'] as List? ?? const [])
            .where((f) => f is Map && f['signatureCipher'] != null)
            .length;
        final videos = [
          for (final f in formats)
            if (f.isVideo && f.codecFamily == 'avc') f,
        ]..sort((a, b) => b.height.compareTo(a.height));

        stdout.write(
          '  ${label.padRight(26)} OK  hls=${hls != null}  '
          'usable=${formats.length} ciphered=$ciphered  ',
        );
        if (videos.isEmpty) {
          stdout.writeln('no plain AVC track to test');
          continue;
        }
        final top = videos.first;
        final clen =
            int.tryParse(Uri.parse(top.url).queryParameters['clen'] ?? '');
        if (clen == null) {
          stdout.writeln('${top.height}p but no clen');
          continue;
        }
        final end = await _ok(client, top.url, clen - 2);
        stdout.writeln(
          '${top.height}p -> ${end ? 'FULL LENGTH ***' : 'capped'}',
        );
      } catch (e) {
        stdout.writeln('  ${label.padRight(26)} ERROR $e');
      }
    }
  }
  client.close();
}

/// Fetches an anonymous visitorData. No challenge, no token: it is the id
/// youtube.com puts in its own page config for a logged-out visitor.
Future<String?> _visitorData(http.Client client) async {
  try {
    final res = await client
        .get(
          Uri.parse('https://www.youtube.com/'),
          headers: const {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
            'Accept-Language': 'en-US,en;q=0.9',
          },
        )
        .timeout(const Duration(seconds: 25));
    final match =
        RegExp(r'"visitorData":"([^"]+)"').firstMatch(res.body);
    if (match != null) return jsonDecode('"${match.group(1)!}"') as String;
  } catch (e) {
    stdout.writeln('homepage failed: $e');
  }
  return null;
}

Future<bool> _ok(http.Client c, String url, int offset) async {
  try {
    final r = await c
        .get(Uri.parse(url), headers: {'Range': 'bytes=$offset-${offset + 1}'})
        .timeout(const Duration(seconds: 20));
    return r.statusCode == 200 || r.statusCode == 206;
  } catch (_) {
    return false;
  }
}
