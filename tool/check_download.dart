// Verifies that YouTube will actually stream bytes for offline download,
// mirroring the rendition choice in YtRepository.downloadTarget.
//
//   dart run tool/check_download.dart [videoId] [--audio]
//
// Downloads to a temp file, reports throughput, then deletes it.
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

final _clients = <YoutubeApiClient>[
  YoutubeApiClient.androidVr,
  YoutubeApiClient.androidSdkless,
  // ignore: deprecated_member_use
  YoutubeApiClient.android,
  YoutubeApiClient.ios,
];

Future<void> main(List<String> args) async {
  final audioOnly = args.contains('--audio');
  final positional = args.where((a) => !a.startsWith('--')).toList();
  // "Me at the zoo" — 19 seconds, so a full download stays quick.
  final id = VideoId.parseVideoId(positional.isEmpty ? 'jNQXAC9IVRw' : positional.first) ??
      positional.first;

  final yt = YoutubeExplode();
  stdout.writeln('Downloading $id (${audioOnly ? 'audio only' : 'video'})\n');

  StreamInfo? chosen;
  for (final client in _clients) {
    try {
      final manifest =
          await yt.videos.streamsClient.getManifest(id, ytClients: [client]);
      if (audioOnly) {
        if (manifest.audioOnly.isEmpty) continue;
        // Mirrors YtRepository._bestPlayableAudio: AAC-in-MP4 over the
        // higher-bitrate Opus track, because iOS decodes neither WebM nor
        // Opus. Using withHighestBitrate() here made this tool report a WebM
        // download while the app correctly fetched AAC.
        final aac = manifest.audioOnly
            .where(
              (t) =>
                  t.container.name.toLowerCase().contains('mp4') ||
                  t.codec.subtype.toLowerCase().contains('mp4'),
            )
            .toList();
        final pool = aac.isNotEmpty ? aac : manifest.audioOnly.toList();
        chosen = pool.reduce(
          (a, b) => a.bitrate.compareTo(b.bitrate) >= 0 ? a : b,
        );
      } else {
        final muxed = manifest.muxed.toList()
          ..sort((a, b) =>
              b.videoResolution.height.compareTo(a.videoResolution.height));
        if (muxed.isEmpty) continue;
        chosen = muxed.first;
      }
      break;
    } catch (e) {
      stdout.writeln('  client failed: $e');
    }
  }

  if (chosen == null) {
    stdout.writeln('FAIL: no downloadable rendition found.');
    yt.close();
    exitCode = 1;
    return;
  }

  stdout.writeln('rendition  ${chosen.qualityLabel}  '
      '${chosen.container.name}  ${chosen.size.totalMegaBytes.toStringAsFixed(2)} MB');

  final file = File(
    '${Directory.systemTemp.path}/aibit_$id.${chosen.container.name}',
  );
  final sink = file.openWrite();
  final started = DateTime.now();
  var received = 0;

  try {
    await for (final chunk in yt.videos.streamsClient.get(chosen)) {
      sink.add(chunk);
      received += chunk.length;
      stdout.write('\rreceived   ${(received / 1048576).toStringAsFixed(2)} MB');
    }
    await sink.flush();
    await sink.close();

    final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
    final onDisk = await file.length();
    stdout.writeln('\n\nwrote      $onDisk bytes in '
        '${seconds.toStringAsFixed(1)}s '
        '(${(onDisk / 1048576 / seconds).toStringAsFixed(2)} MB/s)');

    if (onDisk != chosen.size.totalBytes) {
      stdout.writeln('WARN: size mismatch, expected ${chosen.size.totalBytes}');
    }
    stdout.writeln(onDisk > 0
        ? 'RESULT: downloads work.'
        : 'RESULT: empty file — downloads are broken.');
    if (onDisk == 0) exitCode = 1;
  } catch (e) {
    await sink.close();
    stdout.writeln('\nFAIL: $e');
    exitCode = 1;
  } finally {
    if (await file.exists()) await file.delete();
    yt.close();
  }
}
