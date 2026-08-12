// What the download picker can list: the HD heights that exist as separate
// tracks, the combined 360p, and audio — each with an honest size.
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main(List<String> args) async {
  final ids = args.isEmpty
      ? ['dQw4w9WgXcQ', '_dCeyNHvOlM', 'aqz-KE-bpKQ']
      : args;
  final yt = YoutubeExplode();

  for (final id in ids) {
    stdout.writeln('\n===== $id =====');
    try {
      final m = await yt.videos.streamsClient.getManifest(id);
      final audio = m.audioOnly.isEmpty
          ? null
          : m.audioOnly.withHighestBitrate().size.totalBytes;

      final heights = m.videoOnly
          .where((v) => v.container.name == 'mp4')
          .map((v) => v.videoResolution.height)
          .where((h) => h > 360)
          .toSet()
          .toList()
        ..sort((a, b) => b.compareTo(a));
      for (final h in heights) {
        final v = m.videoOnly
            .where((x) => x.videoResolution.height == h)
            .first;
        final mb = ((v.size.totalBytes + (audio ?? 0)) / 1048576).toStringAsFixed(1);
        stdout.writeln('  ${h}p'.padRight(10) + '$mb MB  (HD, joined)');
      }
      if (m.muxed.isNotEmpty) {
        final mx = m.muxed.withHighestBitrate();
        stdout.writeln('  ${mx.qualityLabel}'.padRight(10) +
            '${(mx.size.totalBytes / 1048576).toStringAsFixed(1)} MB  (combined)');
      }
      if (audio != null) {
        stdout.writeln('  audio'.padRight(10) +
            '${(audio / 1048576).toStringAsFixed(1)} MB');
      }
    } catch (e) {
      stdout.writeln('  ${e.toString().split('\n').first}');
    }
  }
  yt.close();
}
