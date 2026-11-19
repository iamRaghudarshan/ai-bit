// Does the stream URL serve the WHOLE video, or only the first minute?
//
//   dart run tool/check_stream_limits.dart [videoId ...]
//
// This probe exists because of a failure mode none of the others could see.
// `check_streams`, `check_dash` and `check_playback` all answer "can the app
// find a stream", and they do it by fetching the start of a file — the init
// and index ranges live in the first few kilobytes. A URL that serves those
// perfectly and then stops is invisible to all three, and that is exactly what
// YouTube now returns for some clients: the first **60 seconds** of media, and
// HTTP 403 for every byte after it.
//
// The symptom on a phone is not "no videos play". It is worse to diagnose than
// that: the video starts, plays for a minute, and then stalls or dies — which
// reads as a buffering problem, or a bad connection, or a broken build.
//
// So this walks the app's player clients, and for each one binary-searches the
// highest byte offset googlevideo will still serve. A client whose cutoff
// lands at ~60s is **unusable for anything but a short**, no matter how good
// its format list looks. Both the adaptive (HD) track and the progressive 360p
// stream are measured, because they are separately signed URLs and the limit
// does not have to apply to both.
//
// `dur` and `clen` come out of the URL itself, so the cutoff can be reported
// in seconds of playback rather than in bytes, which is the number that
// matters.
import 'dart:convert';
import 'dart:io';

import 'package:ai_bit/src/data/dash_manifest.dart';
import 'package:http/http.dart' as http;

/// Clients worth asking. The first two are what the app ships today; the rest
/// are the candidates to replace them if they turn out to be capped.
const _profiles = <(String, Map<String, Object>, String)>[
  (
    'IOS',
    {
      'clientName': 'IOS',
      'clientVersion': '20.10.4',
      'deviceMake': 'Apple',
      'deviceModel': 'iPhone16,2',
      'osName': 'IOS',
      'osVersion': '18.1.0.22B83',
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
  // The iOS family shares whatever exemption the plain IOS client enjoys, so
  // these are the likeliest places to find a full-length stream — or an HLS
  // ladder, which the plain client now returns for only one video in eight.
  // Measured 19 November 2026: all of them answer LOGIN_REQUIRED, so there is
  // no sibling to switch to. Re-run before concluding that again.
  (
    'IOS_MUSIC',
    {
      'clientName': 'IOS_MUSIC',
      'clientVersion': '7.31.2',
      'deviceMake': 'Apple',
      'deviceModel': 'iPhone16,2',
      'osName': 'iPhone',
      'osVersion': '18.1.0.22B83',
    },
    'com.google.ios.youtubemusic/7.31.2 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X;)',
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
  (
    'VISIONOS',
    {
      'clientName': 'VISIONOS',
      'clientVersion': '0.1',
      'deviceMake': 'Apple',
      'deviceModel': 'RealityDevice14,1',
      'osName': 'visionOS',
      'osVersion': '1.3.21O771',
    },
    'com.google.ios.youtube/0.1 (RealityDevice14,1; U; CPU visionOS 1_3 like Mac OS X;)',
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
      'timeZone': 'UTC',
      'utcOffsetMinutes': 0,
    },
    'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version,gzip(gfe)',
  ),
  // WEB with a Safari user agent, declared *inside* the context as well as in
  // the header. `youtube_explode_dart` calls this one `safari` and notes that
  // it "also provide[s] high quality muxed stream in the HLS manifest" — which
  // would sidestep the cap entirely, since an HLS ladder is already muxed and
  // its segments are addressed by sequence rather than by byte range.
  (
    'WEB_SAFARI',
    {
      'clientName': 'WEB',
      'clientVersion': '2.20250312.04.00',
      'userAgent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)',
      'timeZone': 'UTC',
      'utcOffsetMinutes': 0,
    },
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15',
  ),
];

Future<void> main(List<String> args) async {
  // Long videos on purpose: a 60-second cap cannot be seen on a short one.
  final ids = args.isEmpty ? ['aqz-KE-bpKQ', '08xvwdsVUaQ'] : args;
  final client = http.Client();
  final verdicts = <String, List<String>>{};

  for (final id in ids) {
    stdout.writeln('\n================ $id ================');
    for (final profile in _profiles) {
      final name = profile.$1;
      try {
        final res = await client
            .post(
              Uri.parse(
                'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
              ),
              headers: {
                'Content-Type': 'application/json',
                'Origin': 'https://www.youtube.com',
                'User-Agent': profile.$3,
              },
              body: jsonEncode({
                'context': {
                  'client': {...profile.$2, 'hl': 'en', 'gl': 'US'},
                },
                'videoId': id,
                'contentCheckOk': true,
                'racyCheckOk': true,
              }),
            )
            .timeout(const Duration(seconds: 25));

        final json =
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final status =
            (json['playabilityStatus'] as Map?)?['status']?.toString() ?? '?';
        if (status != 'OK') {
          stdout.writeln('  $name: playabilityStatus $status');
          verdicts.putIfAbsent(name, () => []).add('blocked');
          continue;
        }
        final streaming = json['streamingData'] as Map<String, dynamic>?;
        final adaptive = [
          for (final f in (streaming?['adaptiveFormats'] as List? ?? const []))
            ?parseAdaptiveFormat(f),
        ];
        final progressive = (streaming?['formats'] as List? ?? const [])
            .cast<Map<String, dynamic>>();

        // The tallest AVC rendition — what HD playback would actually use.
        final videos = [
          for (final f in adaptive)
            if (f.isVideo && f.codecFamily == 'avc') f,
        ]..sort((a, b) => b.height.compareTo(a.height));

        final muxedUrl = progressive
            .cast<Map<String, dynamic>?>()
            .firstWhere(
              (f) => f?['url'] is String,
              orElse: () => null,
            )?['url'] as String?;

        stdout.writeln(
          '  $name: hls=${streaming?['hlsManifestUrl'] != null} '
          'adaptive=${adaptive.length} progressive=${progressive.length}',
        );

        final notes = <String>[];
        final hlsUrl = streaming?['hlsManifestUrl'] as String?;
        if (hlsUrl != null) {
          final r = await _hlsReach(client, hlsUrl);
          stdout.writeln('      HLS: $r');
          notes.add('HLS ${r.verdict}');
        }
        if (videos.isNotEmpty) {
          final r = await _cutoff(client, videos.first.url);
          stdout.writeln('      ${videos.first.height}p AVC: $r');
          notes.add('${videos.first.height}p ${r.verdict}');
        }
        if (muxedUrl != null) {
          final r = await _cutoff(client, muxedUrl);
          stdout.writeln('      progressive: $r');
          notes.add('360p ${r.verdict}');
        }
        verdicts.putIfAbsent(name, () => []).add(notes.join(' / '));
      } catch (e) {
        stdout.writeln('  $name: ERROR $e');
        verdicts.putIfAbsent(name, () => []).add('error');
      }
    }
  }

  stdout.writeln('\n================ SUMMARY ================');
  for (final entry in verdicts.entries) {
    stdout.writeln('  ${entry.key.padRight(12)} ${entry.value.join('  |  ')}');
  }
  stdout.writeln(
    '\nA client whose cutoff is ~60s cannot play anything longer than a minute.',
  );
  client.close();
}

class _Cutoff {
  _Cutoff(this.verdict, this.detail);
  final String verdict;
  final String detail;
  @override
  String toString() => '$verdict  $detail';
}

/// Does an HLS ladder reach the END of the video, and how high does it go?
///
/// Byte-range capping cannot apply here — HLS segments are separate URLs
/// addressed by sequence number — but the *last* segment is still the thing to
/// fetch, because that is what a cap would refuse. Both the top variant's
/// resolution and its final segment are reported.
Future<_Cutoff> _hlsReach(http.Client c, String masterUrl) async {
  try {
    final master = await c.get(Uri.parse(masterUrl)).timeout(
          const Duration(seconds: 25),
        );
    if (master.statusCode != 200) {
      return _Cutoff('DEAD', 'master returned ${master.statusCode}');
    }
    // Highest-bandwidth variant: the lines pair up as STREAM-INF then URI.
    final lines = master.body.split('\n').map((l) => l.trim()).toList();
    var bestBandwidth = -1;
    String? bestUri;
    String? bestResolution;
    for (var i = 0; i < lines.length - 1; i++) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF:')) continue;
      final bw = int.tryParse(
            RegExp(r'BANDWIDTH=(\d+)').firstMatch(lines[i])?.group(1) ?? '',
          ) ??
          0;
      if (bw > bestBandwidth) {
        bestBandwidth = bw;
        bestResolution =
            RegExp(r'RESOLUTION=(\S+?)(,|$)').firstMatch(lines[i])?.group(1);
        bestUri = lines[i + 1];
      }
    }
    if (bestUri == null) return _Cutoff('?', 'no variants in master');

    final media = await c.get(Uri.parse(bestUri)).timeout(
          const Duration(seconds: 25),
        );
    if (media.statusCode != 200) {
      return _Cutoff('DEAD', 'variant returned ${media.statusCode}');
    }
    final segments = media.body
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
    if (segments.isEmpty) return _Cutoff('?', 'variant has no segments');

    final last = await c.get(Uri.parse(segments.last)).timeout(
          const Duration(seconds: 30),
        );
    final ok = last.statusCode == 200 || last.statusCode == 206;
    return _Cutoff(
      ok ? 'FULL' : 'CAPPED',
      '${bestResolution ?? '?'} top rung, ${segments.length} segments, '
          'last segment -> ${last.statusCode}'
          '${ok ? ' (${last.bodyBytes.length} bytes)' : ''}',
    );
  } catch (e) {
    return _Cutoff('ERROR', '$e');
  }
}

/// Binary-searches the highest offset that still returns bytes.
Future<_Cutoff> _cutoff(http.Client c, String url) async {
  final uri = Uri.parse(url);
  final clen = int.tryParse(uri.queryParameters['clen'] ?? '');
  final dur = double.tryParse(uri.queryParameters['dur'] ?? '') ?? 0;
  if (clen == null || clen < 2048) return _Cutoff('?', 'no clen in URL');

  if (!await _ok(c, url, 0)) return _Cutoff('DEAD', 'refuses offset 0');
  if (await _ok(c, url, clen - 256)) {
    return _Cutoff('FULL', 'serves all ${_mb(clen)} / ${dur.toInt()}s');
  }

  var lo = 0, hi = clen - 256;
  while (hi - lo > 32768) {
    final mid = lo + (hi - lo) ~/ 2;
    if (await _ok(c, url, mid)) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final seconds = dur > 0 ? dur * lo / clen : 0;
  return _Cutoff(
    'CAPPED@${seconds.toStringAsFixed(0)}s',
    'serves ${_mb(lo)} of ${_mb(clen)} '
        '(${(lo / clen * 100).toStringAsFixed(1)}%, '
        '${seconds.toStringAsFixed(0)}s of ${dur.toInt()}s)',
  );
}

String _mb(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)}MB';

Future<bool> _ok(http.Client c, String url, int offset) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final r = await c
          .get(
            Uri.parse(url),
            headers: {'Range': 'bytes=$offset-${offset + 255}'},
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200 || r.statusCode == 206) return true;
      // 403 is the cap. Anything else may be transient, so it is retried once
      // rather than being read as a boundary.
      if (r.statusCode == 403) return false;
    } catch (_) {
      // fall through to the retry
    }
  }
  return false;
}
