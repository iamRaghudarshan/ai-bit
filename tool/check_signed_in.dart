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
// **ANSWERED, 19 November 2026, with a real signed-in session: it does not.**
// Measured per client, three ways each (cookies + SAPISIDHASH, cookies alone,
// nothing):
//
//   * WEB accepts the session — it goes from "The page needs to be reloaded"
//     to OK — but answers with **server-side ABR**: 40 formats and not one
//     URL, plain or ciphered, only a `serverAbrStreamingUrl`. Using that means
//     speaking YouTube's streaming session protocol, not fetching byte ranges.
//   * IOS and ANDROID **ignore the cookies** (identical capped result with and
//     without them) and answer 400 INVALID_ARGUMENT to the auth header.
//   * TVHTML5 — the client yt-dlp uses with cookies — moves from
//     LOGIN_REQUIRED to "The page needs to be reloaded" when signed in, which
//     is the token demand. The account was accepted and the token still asked
//     for.
//   * MWEB and WEB_EMBEDDED_PLAYER refuse in every mode.
//
// So a login screen alone would buy nothing. The account is accepted and the
// proof-of-origin token is then demanded anyway, which is the hypothesis
// above, confirmed. Re-run before revisiting; the answer is YouTube's.
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
  final cookieHeader =
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  // Every client is asked with the session. The WEB client is the one a
  // browser session belongs to, but it has moved to server-side streaming
  // (formats with no URL at all — see `sabr` below), so the question has to
  // be put to the clients that still hand out byte-range URLs as well. That is
  // what yt-dlp does with cookies, and it is the only way to find out which
  // of them accepts a web session.
  final results = <_Result>[];
  for (final profile in _clients) {
    // Three ways of presenting the session, because "400 with the session"
    // can mean the cookies are refused or only the SAPISIDHASH header is.
    for (final mode in _Mode.values) {
      final label = '${profile.$1}, ${mode.name}';
      stdout.writeln('\n--- $label ---');
      try {
        final headers = <String, String>{
          'Content-Type': 'application/json',
          'Origin': 'https://www.youtube.com',
          'User-Agent': profile.$3,
          if (mode != _Mode.anonymous) 'Cookie': cookieHeader,
          if (mode == _Mode.signed) ...{
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
                  'client': {...profile.$2, 'hl': 'en', 'gl': 'US'},
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
        if (ps == null) {
          final err = json['error'];
          stdout.writeln(
            'HTTP ${res.statusCode}: '
            '${err is Map ? '${err['code']} ${err['status']} ${err['message']}' : utf8.decode(res.bodyBytes).substring(0, 300)}',
          );
        }
        final result = _Result(label, status);
        results.add(result);
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
        result
          ..hls = streaming?['hlsManifestUrl'] != null
          ..sabr = streaming?['serverAbrStreamingUrl'] != null
          ..plain = formats.length
          ..ciphered = ciphered;

        stdout.writeln(
          'hls=${result.hls}  adaptive=${raw.length}  '
          'plain-url=${formats.length}  behind signatureCipher=$ciphered  '
          'server-abr=${result.sabr}',
        );
        if (raw.isNotEmpty && formats.isEmpty && ciphered == 0) {
          final first = raw.first;
          stdout.writeln(
            'Formats carry no URL at all (keys: '
            '${first is Map ? first.keys.join(', ') : '?'}).\n'
            'That is server-side ABR: the client is expected to stream through\n'
            'a session protocol, not fetch byte ranges. Nothing to test here.',
          );
          continue;
        }
        if (ciphered > 0 && formats.isEmpty) {
          stdout.writeln(
            'Every track is behind signatureCipher, so the URLs cannot be used\n'
            'without solving the player JS. That is a second project on top of\n'
            'sign-in, and worth knowing now.',
          );
          continue;
        }
        if (result.hls) {
          // The HLS route is never capped, so a client that hands out a
          // ladder when signed in is a full answer by itself.
          final hlsUrl = streaming!['hlsManifestUrl'] as String;
          result.hlsTop = await _hlsTopHeight(client, hlsUrl);
          stdout.writeln('HLS ladder tops out at ${result.hlsTop}p');
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
        result
          ..height = top.height
          ..fullLength = end;
        stdout.writeln(
          '${top.height}p: start=${start ? 'ok' : 'refused'}  '
          'end of file=${end ? 'OK' : 'refused'}  '
          '-> ${end ? 'FULL LENGTH ***' : 'still capped'}',
        );
      } catch (e) {
        stdout.writeln('ERROR: $e');
      }
    }
  }

  client.close();
  stdout.writeln('\n================ SUMMARY ================');
  for (final r in results) {
    stdout.writeln('  ${r.label.padRight(26)} ${r.describe()}');
  }
  final lifts = results
      .where((r) => !r.label.endsWith(_Mode.anonymous.name))
      .where((r) => r.fullLength || (r.hls && (r.hlsTop ?? 0) > 360))
      .toList();
  stdout.writeln('\n================ VERDICT ================');
  if (lifts.isNotEmpty) {
    stdout.writeln(
      'Signing in LIFTS the cap for: ${lifts.map((r) => r.label).join(', ')}.\n'
      'A sign-in feature asking as one of those clients would give HD on\n'
      'this video. Re-run on a few more ids before building it.',
    );
  } else if (results.any((r) => r.sabr && r.plain == 0 && r.ciphered == 0)) {
    stdout.writeln(
      'INCONCLUSIVE. The session was accepted, but every client that accepted\n'
      'it answered with server-side ABR — formats with no URL to test — and\n'
      'every client that still hands out URLs refused the session. HD through\n'
      'sign-in would mean speaking that streaming protocol, which is a far\n'
      'larger job than a login screen. Do not build the login screen alone.',
    );
  } else {
    stdout.writeln(
      'Signing in does NOT lift the cap. The account is not what YouTube is\n'
      'checking — it wants a token attesting which client is asking — so a\n'
      'sign-in feature would cost the safety of a Google account and buy no\n'
      'HD at all. Do not build it on this evidence.',
    );
  }
  exit(lifts.isNotEmpty ? 0 : 1);
}

enum _Mode { signed, cookiesOnly, anonymous }

class _Result {
  _Result(this.label, this.status);
  final String label;
  final String status;
  bool hls = false;
  int? hlsTop;
  bool sabr = false;
  int plain = 0;
  int ciphered = 0;
  int height = 0;
  bool fullLength = false;

  String describe() {
    if (status != 'OK') return status;
    final parts = <String>[
      if (hls) 'hls to ${hlsTop ?? '?'}p',
      if (sabr && plain == 0 && ciphered == 0) 'server-abr only',
      if (ciphered > 0) '$ciphered ciphered',
      if (height > 0) '${height}p ${fullLength ? 'FULL LENGTH ***' : 'capped'}',
    ];
    return parts.isEmpty ? 'OK, nothing testable' : parts.join(', ');
  }
}

/// The clients worth asking with a browser session. The app's own two first,
/// then the ones yt-dlp reaches for when it has cookies.
const _clients = <(String, Map<String, Object>, String)>[
  (
    'WEB',
    {'clientName': 'WEB', 'clientVersion': '2.20250312.04.00'},
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  ),
  (
    'IOS',
    {
      'clientName': 'IOS',
      'clientVersion': '20.10.4',
      'deviceMake': 'Apple',
      'deviceModel': 'iPhone16,2',
      'osName': 'iPhone',
      'osVersion': '18.3.2.22D82',
    },
    'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
  ),
  (
    'ANDROID',
    {
      'clientName': 'ANDROID',
      'clientVersion': '20.10.38',
      'osName': 'Android',
      'osVersion': '11',
      'androidSdkVersion': 30,
    },
    'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
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
    'MWEB',
    {'clientName': 'MWEB', 'clientVersion': '2.20250311.03.00'},
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 '
        '(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',
  ),
  (
    'WEB_EMBEDDED',
    {'clientName': 'WEB_EMBEDDED_PLAYER', 'clientVersion': '1.20250310.01.00'},
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  ),
];

/// Tallest variant in a YouTube-issued HLS master playlist.
Future<int?> _hlsTopHeight(http.Client c, String url) async {
  try {
    final r = await c.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) return null;
    var top = 0;
    for (final m in RegExp(r'RESOLUTION=\d+x(\d+)').allMatches(r.body)) {
      top = top < int.parse(m.group(1)!) ? int.parse(m.group(1)!) : top;
    }
    return top;
  } catch (_) {
    return null;
  }
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
