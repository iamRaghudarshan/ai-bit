// Checks that a Google Takeout .zip can be imported directly, without the user
// unzipping it first. Run against the real download:
//
//   dart run tool/check_takeout_zip.dart "<path>/takeout-....zip"
//
// Prints which entries the importer would pick up and what they parse to.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:ai_bit/src/data/takeout_import.dart';

const _maxReadBytes = 6 * 1024 * 1024;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart run tool/check_takeout_zip.dart <takeout.zip>');
    exitCode = 2;
    return;
  }
  final bytes = await File(args.first).readAsBytes();
  stdout.writeln('zip: ${(bytes.length / 1024 / 1024).toStringAsFixed(0)} MB');

  final archive = ZipDecoder().decodeBytes(bytes);
  var playlists = 0, videos = 0, subs = 0, history = 0;

  for (final file in archive.files) {
    if (!file.isFile) continue;
    final lower = file.name.toLowerCase();
    final wanted = lower.endsWith('-videos.csv') ||
        lower.endsWith('subscriptions.csv') ||
        lower.endsWith('watch-history.html');
    if (!wanted) continue;
    if (file.size > _maxReadBytes * 8) {
      stdout.writeln('skip (too big): ${file.name}');
      continue;
    }

    final content = file.readBytes();
    if (content == null) continue;
    final slice = content.length > _maxReadBytes
        ? content.sublist(0, _maxReadBytes)
        : content;
    final text = utf8.decode(slice, allowMalformed: true);

    if (lower.endsWith('watch-history.html')) {
      history = parseWatchHistoryHtml(text, limit: 500).length;
      stdout.writeln('history: $history entries  <- ${file.name}');
    } else if (lower.endsWith('subscriptions.csv')) {
      subs = parseSubscriptionsCsv(text).length;
      stdout.writeln('subscriptions: $subs  <- ${file.name}');
    } else {
      final parsed = readPlaylistFile(fileName: file.name, contents: text);
      if (parsed == null) continue;
      playlists++;
      videos += parsed.length;
      stdout.writeln('playlist "${parsed.name}": ${parsed.length} videos');
    }
  }

  stdout.writeln(
    '\nRESULT: $playlists playlists ($videos videos), '
    '$subs subscriptions, $history history entries',
  );
}
