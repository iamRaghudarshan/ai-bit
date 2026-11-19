// Can an iPhone play HD? Validates the generated HLS manifest against YouTube.
//
//   dart run tool/check_hls.dart [videoId ...] [--serve] [--ffmpeg=<path>]
//
// This is the iOS counterpart of `check_dash.dart`, and it exists because iOS
// spent a long time stuck on 360p for about seven videos in eight. AVPlayer
// cannot play DASH, but it can play fragmented MP4 over HLS with byte-range
// segments — so the app reads each track's `sidx` box and writes the fragment
// offsets out as an HLS playlist. None of that can be checked by reading the
// code: it is right only if the offsets land exactly on fragment boundaries in
// a file on googlevideo, and one byte out plays nothing.
//
// Four checks per video, in increasing strength:
//
//   1. A ladder is offered at all, and the playlists are structurally valid.
//   2. The fragment durations sum to the video's declared duration. Catches a
//      timescale misread, which otherwise shows up as a seek bar that lies.
//   3. **The arithmetic closes.** Every googlevideo URL carries `clen`, the
//      exact length of the file, so the last fragment must end precisely
//      there: `offset + size == clen`. This is the check worth having — the
//      `sidx` anchor is the one thing that cannot fail loudly, because a wrong
//      anchor still produces byte ranges that are valid HTTP requests for the
//      wrong bytes, and googlevideo answers 206 with content that simply is
//      not a fragment.
//   4. The first and last fragments are really fetched, and really begin with
//      an ISO-BMFF `moof`/`styp` box.
//
// With `--serve` it publishes the playlists on loopback exactly as the app
// does and leaves the URL printed, so a real demuxer can be pointed at it.
// Give `--ffmpeg=<path to ffmpeg>` and it will do that itself and decode
// frames at the top rung, which is the only way to prove from this machine
// that the whole set actually plays.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_bit/src/data/dash_manifest.dart';
import 'package:ai_bit/src/data/hls_manifest.dart';
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
  final serve = args.contains('--serve');
  final ffmpeg = args
      .firstWhere((a) => a.startsWith('--ffmpeg='), orElse: () => '')
      .replaceFirst('--ffmpeg=', '');
  final ids = args.where((a) => !a.startsWith('--')).toList();
  final videos = ids.isEmpty
      ? ['dQw4w9WgXcQ', 'LXb3EKWsInQ', 'aqz-KE-bpKQ', 'jNQXAC9IVRw']
      : ids;

  final client = http.Client();
  var failures = 0;
  var checked = 0;
  GeneratedHls? lastBuilt;

  for (final id in videos) {
    stdout.writeln('\n===== $id =====');
    try {
      final formats = await _formats(client, id);
      if (formats == null) continue;

      final candidates = hlsCandidates(formats);
      if (candidates.isEmpty) {
        stdout.writeln('  FAIL: no AVC+AAC set to build from');
        failures++;
        continue;
      }
      stdout.writeln(
        '  candidates: ${candidates.where((f) => f.isVideo).map((f) => '${f.height}p').join(', ')}'
        ' + audio ${candidates.last.bitrate ~/ 1000}kbps',
      );

      // Every index range in parallel — this is one round trip in the app too.
      final indexes = await Future.wait([
        for (final f in candidates) _index(client, f),
      ]);

      final tracks = <HlsTrack>[];
      var ok = true;
      for (var i = 0; i < candidates.length; i++) {
        final f = candidates[i];
        final label = f.isVideo ? '${f.height}p' : 'audio';
        final index = indexes[i];
        if (index == null) {
          stdout.writeln('  $label: FAIL could not read sidx');
          ok = false;
          continue;
        }

        // 2. Durations must sum to the declared length of the video.
        final totalMs = index.segments
            .fold<int>(0, (a, s) => a + s.durationUs) ~/
            1000;
        final driftMs = (totalMs - f.durationMs).abs();
        final driftOk = driftMs <= 1500;

        // 3. The arithmetic has to close on `clen`.
        final clen = int.tryParse(
          Uri.parse(f.url).queryParameters['clen'] ?? '',
        );
        final last = index.segments.last;
        final end = last.offset + last.size;
        final closes = clen == null || end == clen;

        stdout.writeln(
          '  $label: ${index.segments.length} fragments, '
          'longest ${index.longestSegmentSeconds.toStringAsFixed(1)}s, '
          'duration ${driftOk ? 'matches' : 'DRIFTS ${driftMs}ms'}, '
          '${clen == null ? 'no clen' : closes ? 'ends exactly at clen' : 'ENDS AT $end, clen $clen'}',
        );
        if (!driftOk || !closes) ok = false;
        tracks.add(HlsTrack(f, index));
      }

      final built = buildHls(tracks);
      if (built == null) {
        stdout.writeln('  FAIL: no playlists could be built');
        failures++;
        continue;
      }
      lastBuilt = built;
      stdout.writeln(
        '  ladder: ${built.ladder.join(', ')}  '
        '(${built.media.length} variant playlists)',
      );

      final structure = _validate(built);
      if (structure != null) {
        stdout.writeln('  FAIL: $structure');
        ok = false;
      }

      // 4. Fetch the real first and last fragment of the top rung.
      //
      // The last one is refused for most videos, and that is not a defect in
      // this file: YouTube serves these URLs for only the first ~60 seconds
      // without a proof-of-origin token (measured by
      // `tool/check_stream_limits.dart`). The app detects that and plays the
      // progressive stream instead, so a capped video is reported here rather
      // than failed — what would be a real failure is a *playable* video whose
      // fragments do not fetch.
      final top = tracks.firstWhere((t) => t.format.isVideo);

      // The init segment the playlist points EXT-X-MAP at. Without a valid
      // `moov` every fragment is undecodable, and the codec string has to
      // agree with what is inside it.
      final init = await _range(
        client,
        top.format.url,
        top.format.initStart,
        top.format.initEnd,
      );
      if (init == null) {
        stdout.writeln('  init segment: FAIL could not fetch');
        ok = false;
      } else {
        final verdict = _checkInit(init, top.format);
        stdout.writeln('  init segment: ${init.length} bytes, $verdict');
        if (verdict.startsWith('FAIL')) ok = false;
      }

      final clen = int.tryParse(
        Uri.parse(top.format.url).queryParameters['clen'] ?? '',
      );
      final capped = clen != null &&
          !(await _servesEnd(client, top.format.url, clen));
      if (capped) {
        stdout.writeln(
          '  CAPPED: these tracks serve only the first ~60s, so the app will '
          'use 360p\n          for this video. The playlists above are correct '
          'and will be used\n          the moment a token makes the rest of the '
          'file reachable.',
        );
      }
      for (final pick in [
        ('first', top.index.segments.first),
        if (!capped) ('last', top.index.segments.last),
      ]) {
        final got = await _range(
          client,
          top.format.url,
          pick.$2.offset,
          pick.$2.offset + pick.$2.size - 1,
        );
        if (got == null || got.length != pick.$2.size) {
          stdout.writeln(
            '  ${pick.$1} fragment: FAIL wanted ${pick.$2.size} bytes, '
            'got ${got?.length}',
          );
          ok = false;
          continue;
        }
        final box = got.length >= 8
            ? String.fromCharCodes(got, 4, 8)
            : '????';
        final valid = box == 'moof' || box == 'styp' || box == 'emsg';
        stdout.writeln(
          '  ${pick.$1} fragment: ${got.length} bytes, starts with '
          '`$box`${valid ? '' : ' — NOT A FRAGMENT'}',
        );
        if (!valid) ok = false;
      }

      checked++;
      if (!ok) failures++;
    } catch (e) {
      stdout.writeln('  ERROR: $e');
      failures++;
    }
  }

  stdout.writeln('\n================ SUMMARY ================');
  stdout.writeln('videos validated: $checked   failures: $failures');

  if ((serve || ffmpeg.isNotEmpty) && lastBuilt != null) {
    final server = await _publish(lastBuilt);
    final url = 'http://${server.address.address}:${server.port}/master.m3u8';
    stdout.writeln('serving: $url');
    if (ffmpeg.isNotEmpty) {
      stdout.writeln('\n--- decoding with ffmpeg, 6 seconds of the top rung ---');
      final r = await Process.run(ffmpeg, [
        '-hide_banner',
        '-loglevel', 'warning',
        '-allowed_extensions', 'ALL',
        '-i', url,
        '-map', '0:v:0',
        '-map', '0:a:0',
        '-t', '6',
        '-f', 'null',
        '-',
      ]);
      stdout.writeln(r.stderr.toString().trim().isEmpty
          ? '(no warnings)'
          : r.stderr.toString().trim());
      stdout.writeln(
        r.exitCode == 0
            ? 'DECODED OK — the generated playlist really plays.'
            : 'DECODE FAILED (exit ${r.exitCode})',
      );
      if (r.exitCode != 0) failures++;
      await server.close(force: true);
    } else {
      stdout.writeln('press enter to stop.');
      await stdin.first;
      await server.close(force: true);
    }
  }

  client.close();
  if (failures > 0) {
    stdout.writeln('\nFAIL: $failures video(s) would not play on iOS.');
    exit(1);
  }
  stdout.writeln('\nOK: every video builds a valid iOS ladder.');
}

/// Structural rules AVPlayer would enforce, checked here so a mistake shows up
/// as a line of output rather than as a black screen on a phone.
String? _validate(GeneratedHls built) {
  if (!built.master.startsWith('#EXTM3U')) return 'master lacks #EXTM3U';
  if (!built.master.contains('#EXT-X-VERSION:7')) return 'master is not v7';
  final refs = RegExp(r'^[^#\s].*\.m3u8$', multiLine: true)
      .allMatches(built.master)
      .map((m) => m.group(0)!.trim())
      .toSet();
  final quoted = RegExp(r'URI="([^"]+\.m3u8)"')
      .allMatches(built.master)
      .map((m) => m.group(1)!)
      .toSet();
  for (final name in {...refs, ...quoted}) {
    if (!built.media.containsKey(name)) return 'master references $name';
  }
  for (final entry in built.media.entries) {
    final body = entry.value;
    if (!body.contains('#EXT-X-MAP:')) return '${entry.key} has no init map';
    if (!body.contains('#EXT-X-ENDLIST')) return '${entry.key} has no endlist';
    final infs = RegExp('#EXTINF:').allMatches(body).length;
    final ranges = RegExp('#EXT-X-BYTERANGE:').allMatches(body).length;
    if (infs == 0 || infs != ranges) {
      return '${entry.key} has $infs EXTINF and $ranges byte ranges';
    }
    final target = RegExp(r'#EXT-X-TARGETDURATION:(\d+)').firstMatch(body);
    if (target == null) return '${entry.key} has no target duration';
    final declared = int.parse(target.group(1)!);
    final longest = RegExp(r'#EXTINF:([\d.]+)')
        .allMatches(body)
        .map((m) => double.parse(m.group(1)!))
        .fold<double>(0, (a, b) => b > a ? b : a);
    if (declared < longest) {
      return '${entry.key} target $declared < longest segment $longest';
    }
  }
  return null;
}

/// Publishes the playlists on loopback, the way `hls_server.dart` does.
Future<HttpServer> _publish(GeneratedHls built) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final name = request.uri.pathSegments.isEmpty
        ? ''
        : request.uri.pathSegments.last;
    final body = name == 'master.m3u8' ? built.master : built.media[name];
    if (body == null) {
      request.response.statusCode = HttpStatus.notFound;
    } else {
      request.response.headers
          .set('Content-Type', 'application/vnd.apple.mpegurl');
      request.response.write(body);
    }
    await request.response.close();
  });
  return server;
}

Future<List<AdaptiveFormat>?> _formats(http.Client client, String id) async {
  final res = await client
      .post(
        Uri.parse('https://www.youtube.com/youtubei/v1/player?prettyPrint=false'),
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
    stdout.writeln('  playabilityStatus: $status — skipped');
    return null;
  }
  final streaming = json['streamingData'] as Map<String, dynamic>?;
  stdout.writeln(
    '  hlsManifestUrl: ${streaming?['hlsManifestUrl'] == null ? 'ABSENT (this is the 7-in-8 case)' : 'present'}',
  );
  return [
    for (final f in (streaming?['adaptiveFormats'] as List? ?? const []))
      ?parseAdaptiveFormat(f),
  ];
}

Future<SegmentIndex?> _index(http.Client client, AdaptiveFormat f) async {
  final bytes = await _range(client, f.url, f.indexStart, f.indexEnd);
  if (bytes == null) return null;
  return parseSegmentIndex(bytes, indexStart: f.indexStart);
}

/// Does the init segment really hold a `moov`, and does the codec string the
/// playlist declares match the bitstream inside it?
///
/// A `CODECS` attribute that disagrees with the actual profile and level is a
/// classic reason for a player to refuse a variant outright — and it fails
/// quietly, by simply not selecting that rung. The three hex bytes of an
/// `avc1.PPCCLL` string are AVCProfileIndication, profile_compatibility and
/// AVCLevelIndication, which are bytes 1 to 3 of the `avcC` box, so the two
/// can be compared directly rather than taken on trust.
String _checkInit(Uint8List bytes, AdaptiveFormat format) {
  final boxes = <String>[];
  Uint8List? avcC;

  void walk(int start, int end, int depth) {
    var p = start;
    while (p + 8 <= end) {
      final size = ByteData.sublistView(bytes).getUint32(p);
      final type = String.fromCharCodes(bytes, p + 4, p + 8);
      if (depth == 0) boxes.add(type);
      var boxSize = size;
      var header = 8;
      if (size == 1) {
        if (p + 16 > end) return;
        boxSize = ByteData.sublistView(bytes).getUint64(p + 8);
        header = 16;
      } else if (size == 0) {
        boxSize = end - p;
      }
      if (boxSize < header || p + boxSize > end) return;
      if (type == 'avcC') {
        avcC = Uint8List.sublistView(bytes, p + header, p + boxSize);
      }
      // Only containers are descended into; a sample entry carries its config
      // boxes after a fixed-size header, hence the offsets.
      const containers = {
        'moov', 'trak', 'mdia', 'minf', 'stbl', 'mvex', 'edts',
      };
      if (containers.contains(type)) {
        walk(p + header, p + boxSize, depth + 1);
      } else if (type == 'stsd') {
        walk(p + header + 8, p + boxSize, depth + 1);
      } else if (type == 'avc1' || type == 'avc3') {
        walk(p + header + 78, p + boxSize, depth + 1);
      }
      p += boxSize;
    }
  }

  walk(0, bytes.length, 0);
  if (!boxes.contains('moov')) {
    return 'FAIL no moov box (boxes: ${boxes.join(',')})';
  }
  if (!format.isVideo) return 'moov present (${boxes.join(',')})';

  final config = avcC;
  if (config == null || config.length < 4) {
    return 'moov present, but no avcC to compare the codec string against';
  }
  final actual = config
      .sublist(1, 4)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final declared = format.codecs.split('.').last.toLowerCase();
  return actual == declared
      ? 'moov + avcC, codec string avc1.$actual matches the bitstream'
      : 'FAIL declares avc1.$declared but the bitstream is avc1.$actual';
}

/// Will googlevideo serve the last two bytes of the file? Mirrors
/// `YtRepository._adaptiveTracksPlayThroughout`.
Future<bool> _servesEnd(http.Client client, String url, int clen) async {
  if (clen < 4) return false;
  try {
    final r = await client
        .get(Uri.parse(url), headers: {'Range': 'bytes=${clen - 2}-${clen - 1}'})
        .timeout(const Duration(seconds: 15));
    return r.statusCode == 200 || r.statusCode == 206;
  } catch (_) {
    return false;
  }
}

Future<Uint8List?> _range(
  http.Client client,
  String url,
  int start,
  int end,
) async {
  try {
    final r = await client
        .get(Uri.parse(url), headers: {'Range': 'bytes=$start-$end'})
        .timeout(const Duration(seconds: 25));
    if (r.statusCode != 200 && r.statusCode != 206) {
      stdout.writeln('    (range $start-$end -> HTTP ${r.statusCode})');
      return null;
    }
    return r.bodyBytes;
  } catch (e) {
    stdout.writeln('    (range $start-$end -> $e)');
    return null;
  }
}
