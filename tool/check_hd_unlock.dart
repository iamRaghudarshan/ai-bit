// Everything in the HD-unlock chain that can be checked WITHOUT a browser.
//
//   dart run tool/check_hd_unlock.dart [videoId]
//
// The route (lib/src/data/attestation/) has two halves. One half runs only
// in a WebView — YouTube's BotGuard, which mints the proof-of-origin token,
// and yt-dlp's solver for the web client's URL challenges — and can only be
// exercised on a phone, through Settings → "Test HD unlock". The other half
// is plain HTTP, and this probe runs it:
//
//   1. the player build discovery (`iframe_api` → `base.js` → sts);
//   2. the anonymous visitor id;
//   3. a web-client player request carrying a visitor id and a *placeholder*
//      token — because the shape of the answer is decided before the token
//      is checked: the token is verified by googlevideo when bytes are
//      requested, and the player endpoint's reply says whether this client
//      still hands out byte-range URLs at all or has moved to server-side
//      streaming, which no token helps with;
//   4. the solver modules, by hash.
//
// It cannot say "HD works". It can say "the route is dead before minting",
// which is the cheaper thing to learn, and it is worth re-running whenever
// the phone-side test fails: a failure here means the player endpoint moved,
// a failure only there means the attestation did.
import 'dart:convert';
import 'dart:io';

import 'package:ai_bit/src/data/attestation/web_formats.dart';
import 'package:ai_bit/src/data/player_client.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

const _ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

Future<void> main(List<String> args) async {
  final id = args.isEmpty ? 'aqz-KE-bpKQ' : args.first;
  final client = http.Client();
  var failures = 0;

  // 1. player build
  stdout.writeln('--- player build ---');
  String? playerUrl;
  int? sts;
  try {
    final api = await client
        .get(Uri.parse('https://www.youtube.com/iframe_api'),
            headers: {'User-Agent': _ua})
        .timeout(const Duration(seconds: 20));
    playerUrl = playerScriptUrlFromIframeApi(api.body);
    if (playerUrl == null) throw StateError('iframe_api names no build');
    final script = await client
        .get(Uri.parse(playerUrl), headers: {'User-Agent': _ua})
        .timeout(const Duration(seconds: 30));
    sts = signatureTimestampOf(script.body);
    if (sts == null) throw StateError('no sts in base.js');
    stdout.writeln('  $playerUrl');
    stdout.writeln('  ${script.body.length ~/ 1024} KB, sts=$sts');
  } catch (e) {
    failures++;
    stdout.writeln('  FAIL: $e');
  }

  // 2. visitor id
  stdout.writeln('--- visitor id ---');
  String? visitor;
  try {
    final res = await client
        .post(
          Uri.parse(
            'https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false',
          ),
          headers: {
            'Content-Type': 'application/json',
            'Origin': 'https://www.youtube.com',
            'User-Agent': _ua,
          },
          body: jsonEncode({
            'context': {
              'client': {
                'clientName': 'WEB',
                'clientVersion': '2.20250312.04.00',
                'hl': 'en',
                'gl': 'US',
              },
            },
          }),
        )
        .timeout(const Duration(seconds: 20));
    final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
    visitor = (json['responseContext'] as Map?)?['visitorData'] as String?;
    if (visitor == null) throw StateError('HTTP ${res.statusCode}, no visitorData');
    stdout.writeln('  ${visitor.substring(0, 16)}… (${visitor.length} chars)');
  } catch (e) {
    failures++;
    stdout.writeln('  FAIL: $e');
  }

  // 3. web clients with a placeholder token
  if (visitor != null && sts != null) {
    final player = YoutubePlayerClient(client: client);
    var anyAddressable = false;
    for (final profile in YoutubePlayerClient.webClients) {
      stdout.writeln('--- ${profile.name}, visitor id + placeholder token ---');
      try {
        final r = await player.fetchWeb(
          id,
          client: profile,
          visitorData: visitor,
          poToken: 'placeholder',
          signatureTimestamp: sts,
        );
        stdout.writeln('  playabilityStatus: ${r.status} ${r.reason ?? ''}');
        if (!r.isOk) continue;
        var plain = 0, ciphered = 0, bare = 0;
        for (final f in r.rawAdaptiveFormats) {
          if (f is! Map) continue;
          if (f['url'] != null) {
            plain++;
          } else if (f['signatureCipher'] != null || f['cipher'] != null) {
            ciphered++;
          } else {
            bare++;
          }
        }
        final wanted = challengesIn(r.rawAdaptiveFormats);
        stdout.writeln(
          '  hls=${r.hlsUrl != null}  server-abr=${r.serverAbr}  '
          'adaptive=${r.rawAdaptiveFormats.length}: '
          'plain-url=$plain  ciphered=$ciphered  no-url=$bare',
        );
        if (r.hasAddressableFormats) {
          anyAddressable = true;
          stdout.writeln(
            '  challenges to solve: ${wanted.sig.length} sig, '
            '${wanted.n.length} n  -> URLs can be made once solved',
          );
        } else if (r.serverAbr) {
          stdout.writeln(
            '  server-side streaming only: nothing a token could unlock here',
          );
        }
      } catch (e) {
        stdout.writeln('  FAIL: $e');
      }
    }
    if (!anyAddressable) {
      failures++;
      stdout.writeln(
        '\n  No web client hands out byte-range URLs any more. The route is\n'
        '  dead before minting; a token would have nothing to stamp.',
      );
    }
  }

  // 4. solver modules
  stdout.writeln('--- solver modules ---');
  for (final m in const [
    (
      'lib',
      'https://github.com/yt-dlp/ejs/releases/download/0.8.0/yt.solver.lib.min.js',
      'c55987fe697e5b9ee18830163f7af85327e9bb5c3e674b969d38c8d205eaa577'
    ),
    (
      'core',
      'https://github.com/yt-dlp/ejs/releases/download/0.8.0/yt.solver.core.min.js',
      '18da6ce0758b416e7ae645084f4f8801f9f9d59d6c477c05eaa0ff94ebd8cc00'
    ),
  ]) {
    try {
      final res =
          await client.get(Uri.parse(m.$2)).timeout(const Duration(seconds: 30));
      final hash = sha256.convert(res.bodyBytes).toString();
      final ok = res.statusCode == 200 && hash == m.$3;
      if (!ok) failures++;
      stdout.writeln(
        '  ${m.$1}: HTTP ${res.statusCode}, ${res.bodyBytes.length ~/ 1024} KB, '
        'hash ${ok ? 'matches' : 'MISMATCH'}',
      );
    } catch (e) {
      failures++;
      stdout.writeln('  ${m.$1}: FAIL $e');
    }
  }

  client.close();
  stdout.writeln('\n================ RESULT ================');
  if (failures == 0) {
    stdout.writeln(
      'Everything checkable from here checks out. What remains — minting the\n'
      'token and solving the challenges — needs a browser engine: run\n'
      'Settings → "Test HD unlock" on the phone.',
    );
  } else {
    stdout.writeln('$failures problem(s) above. Fix these before building.');
  }
  exit(failures == 0 ? 0 : 1);
}
