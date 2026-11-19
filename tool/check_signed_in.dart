// Does being SIGNED IN lift YouTube's 60-second cap on HD streams?
//
//   dart run tool/check_signed_in.dart <path to cookies.txt> [videoId]
//
// This is the question that decides whether a sign-in feature is worth
// building, and it has to be answered before the feature rather than after.
// `check_stream_limits.dart` establishes that an anonymous client gets a
// byte-range HD track for only the first ~60 seconds, and
// `check_visitor_clients.dart` establishes that no alternate client and no
// anonymous `visitorData` changes that. Signing in is one of the two routes
// left. Nobody has measured whether it works.
//
// **It may well not.** The cap is enforced by a proof-of-origin token, and a
// token is about attesting *which client* is asking, not *who* is asking — so
// an authenticated request from an unofficial client could be refused exactly
// as an anonymous one is. That is the hypothesis under test. A day of building
// a login flow is the wrong way to find out.
//
// ## Giving it a session, safely
//
// Export cookies for youtube.com from a browser you are signed into, in the
// usual Netscape `cookies.txt` format (any "export cookies" extension writes
// it; it is the same format yt-dlp's `--cookies` takes). Then pass the file's
// path.
//
// The file stays on this machine. This probe reads it, sends the cookies to
// youtube.com — which is where they came from — and sends them nowhere else.
// It never prints a cookie value: the summary names which cookies were found
// and nothing more, so the output is safe to paste into a chat or an issue.
// Treat the file itself as a password, because that is what it is: delete it
// when you are done, and never commit it.
import 'dart:convert';
import 'dart:io';

import 'package:ai_bit/src/data/dash_manifest.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stdout.writeln(
      'usage: dart run tool/check_signed_in.dart <cookies.txt> [videoId]\n'
      '\n'
      'Export youtube.com cookies from a signed-in browser in Netscape\n'
      'format. The file is read locally and never printed.',
    );
    exit(2);
  }
  final file = File(args.first);
  if (!file.existsSync()) {
    stdout.writeln('No such file: ${args.first}');
    exit(2);
  }
  // A long video, so a 60-second cap is unmistakable.
  final id = args.length > 1 ? args[1] : 'aqz-KE-bpKQ';

  final cookies = _readCookies(file);
  if (cookies.isEmpty) {
    stdout.writeln(
      'No cookies for youtube.com in that file. Make sure the export was\n'
      'taken while signed in, and in Netscape/cookies.txt format.',
    );
    exit(2);
  }
  // Names only. Never the values.
  stdout.writeln('cookies loaded: ${cookies.length} '
      '(${cookies.keys.where(_interesting).join(', ')})');

  final sapisid = cookies['SAPISID'] ??
      cookies['__Secure-3PAPISID'] ??
      cookies['__Secure-1PAPISID'];
  if (sapisid == null) {
    stdout.writeln(
      'FAIL: no SAPISID cookie, so the request cannot be authenticated.\n'
      '      That cookie only exists for a signed-in session.',
    );
    exit(1);
  }
  final signedIn = cookies.containsKey('LOGIN_INFO') ||
      cookies.containsKey('__Secure-3PSID');
  stdout.writeln(
    'session looks ${signedIn ? 'SIGNED IN' : 'anonymous — check the export'}',
  );

  final client = http.Client();
  var hdWorks = false;

  // The WEB client, because that is the one a browser session belongs to.
  // Asking as IOS with web cookies is a mismatch YouTube can see.
  for (final attempt in [
    ('WEB, authenticated', true),
    ('WEB, same request unauthenticated', false),
  ]) {
    stdout.writeln('\n--- ${attempt.$1} ---');
    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Origin': 'https://www.youtube.com',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
        if (attempt.$2) ...{
          'Cookie': cookies.entries
              .map((e) => '${e.key}=${e.value}')
              .join('; '),
          'Authorization': _sapisidHash(sapisid),
          'X-Goog-AuthUser': '0',
          'X-Origin': 'https://www.youtube.com',
        },
      };
      final res = await client
          .post(
            Uri.parse(
              'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
            ),
            headers: headers,
            body: jsonEncode({
              'context': {
                'client': {
                  'clientName': 'WEB',
                  'clientVersion': '2.20250312.04.00',
                  'hl': 'en',
                  'gl': 'US',
                  if (cookies['__Secure-YEC'] != null) 'visitorData': '',
                },
              },
              'videoId': id,
              'contentCheckOk': true,
              'racyCheckOk': true,
            }),
          )
          .timeout(const Duration(seconds: 30));

      final json =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final ps = json['playabilityStatus'] as Map?;
      final status = ps?['status']?.toString() ?? '?';
      stdout.writeln('playabilityStatus: $status  ${ps?['reason'] ?? ''}');
      if (status != 'OK') continue;

      final streaming = json['streamingData'] as Map<String, dynamic>?;
      final raw = (streaming?['adaptiveFormats'] as List? ?? const []);
      final ciphered =
          raw.where((f) => f is Map && f['signatureCipher'] != null).length;
      final formats = [for (final f in raw) ?parseAdaptiveFormat(f)];
      final videos = [
        for (final f in formats)
          if (f.isVideo && f.codecFamily == 'avc') f,
      ]..sort((a, b) => b.height.compareTo(a.height));

      stdout.writeln(
        'hls=${streaming?['hlsManifestUrl'] != null}  '
        'adaptive=${raw.length}  plain-url=${formats.length}  '
        'behind signatureCipher=$ciphered',
      );
      if (ciphered > 0 && formats.isEmpty) {
        stdout.writeln(
          'Every track is behind signatureCipher, so the URLs cannot be used\n'
          'without solving the player JS. That is a second project on top of\n'
          'sign-in, and worth knowing now.',
        );
        continue;
      }
      if (videos.isEmpty) {
        stdout.writeln('no plain AVC track to test the cap with');
        continue;
      }

      final top = videos.first;
      final clen =
          int.tryParse(Uri.parse(top.url).queryParameters['clen'] ?? '');
      if (clen == null || clen < 4) {
        stdout.writeln('${top.height}p track has no clen to test against');
        continue;
      }
      final start = await _serves(client, top.url, 0);
      final end = await _serves(client, top.url, clen - 2);
      stdout.writeln(
        '${top.height}p: start=${start ? 'ok' : 'refused'}  '
        'end of file=${end ? 'OK' : 'refused'}  '
        '-> ${end ? 'FULL LENGTH ***' : 'still capped'}',
      );
      if (end && attempt.$2) hdWorks = true;
    } catch (e) {
      stdout.writeln('ERROR: $e');
    }
  }

  client.close();
  stdout.writeln('\n================ VERDICT ================');
  if (hdWorks) {
    stdout.writeln(
      'Signing in LIFTS the cap: an authenticated request served the last\n'
      'byte of a 1080p track. A sign-in feature would give HD on every\n'
      'video, and is worth building.',
    );
  } else {
    stdout.writeln(
      'Signing in does NOT lift the cap. The account is not what YouTube is\n'
      'checking — it wants a token attesting which client is asking — so a\n'
      'sign-in feature would cost the safety of a Google account and buy no\n'
      'HD at all. Do not build it on this evidence.',
    );
  }
  exit(hdWorks ? 0 : 1);
}

/// Cookie names worth naming in the output. Values are never printed.
bool _interesting(String name) =>
    name == 'SAPISID' ||
    name == 'LOGIN_INFO' ||
    name == 'SID' ||
    name.startsWith('__Secure-');

/// Netscape `cookies.txt`: tab-separated, `#` comments, youtube domains only.
Map<String, String> _readCookies(File file) {
  final out = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trim();
    // "#HttpOnly_" is a real prefix on an otherwise ordinary row, so it is
    // stripped rather than treated as a comment.
    final body = trimmed.startsWith('#HttpOnly_')
        ? trimmed.substring('#HttpOnly_'.length)
        : trimmed;
    if (body.isEmpty || body.startsWith('#')) continue;
    final parts = body.split('\t');
    if (parts.length < 7) continue;
    if (!parts[0].contains('youtube.com')) continue;
    out[parts[5]] = parts[6];
  }
  return out;
}

/// `Authorization: SAPISIDHASH <ts>_<sha1(ts SAPISID origin)>`.
///
/// This is how a browser authenticates an innertube call: the cookie is not
/// sent as a bearer token, it is hashed together with a timestamp and the
/// origin. Reimplemented here rather than taken from a package so there is
/// nothing to audit but these four lines.
String _sapisidHash(String sapisid) {
  const origin = 'https://www.youtube.com';
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final digest = sha1.convert(utf8.encode('$ts $sapisid $origin'));
  return 'SAPISIDHASH ${ts}_$digest';
}

Future<bool> _serves(http.Client c, String url, int offset) async {
  try {
    final r = await c
        .get(Uri.parse(url), headers: {'Range': 'bytes=$offset-${offset + 1}'})
        .timeout(const Duration(seconds: 20));
    return r.statusCode == 200 || r.statusCode == 206;
  } catch (_) {
    return false;
  }
}
