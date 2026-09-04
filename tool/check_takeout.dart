// Parses a real Google Takeout playlists folder and reports what it found.
//
// The parser in takeout_import.dart is guessing at an undocumented format that
// has changed between exports, so unit tests can only pin the shapes we have
// thought of. This runs it against an actual export - the only thing that
// proves the guess matches reality.
//
//   dart run tool/check_takeout.dart "<path to>/Takeout/YouTube and YouTube Music/playlists"
//
// Prints per file: the playlist name it would create and how many ids it read.
// Reads nothing but the files named, and sends nothing anywhere.

import 'dart:convert';
import 'dart:io';

import 'package:ai_bit/src/data/takeout_import.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/check_takeout.dart <playlists folder or csv file>',
    );
    exitCode = 2;
    return;
  }

  final target = args.first;
  final files = <File>[];

  if (FileSystemEntity.isDirectorySync(target)) {
    for (final entity in Directory(target).listSync()) {
      if (entity is File && entity.path.toLowerCase().endsWith('.csv')) {
        files.add(entity);
      }
    }
  } else {
    files.add(File(target));
  }

  if (files.isEmpty) {
    stdout.writeln('No CSV files found in $target');
    return;
  }

  files.sort((a, b) => a.path.compareTo(b.path));

  var playlists = 0;
  var videos = 0;

  for (final file in files) {
    final name = file.path.split(RegExp(r'[/\\]')).last;
    final parsed = readPlaylistFile(
      fileName: file.path,
      contents: await file.readAsString(),
    );

    if (parsed == null) {
      // Expected for playlists.csv and the rest of the export - it lists
      // playlist metadata, not videos.
      stdout.writeln('skip   $name  (no video ids)');
      continue;
    }

    playlists++;
    videos += parsed.length;
    stdout.writeln(
      'ok     $name\n'
      '       -> playlist "${parsed.name}", ${parsed.length} videos\n'
      '       first: ${parsed.videoIds.take(3).join(', ')}'
      '${parsed.length > 3 ? ' ...' : ''}',
    );
  }

  stdout.writeln(
    '\nRESULT: $playlists playlists, $videos videos would be imported.',
  );

  await _checkSubscriptions(target);
  await _checkHistory(target);
}

/// subscriptions/subscriptions.csv, if it sits near the target.
Future<void> _checkSubscriptions(String target) async {
  final file = _find(target, 'subscriptions.csv');
  if (file == null) return;
  final channels = parseSubscriptionsCsv(await file.readAsString());
  stdout.writeln('\nsubscriptions.csv: ${channels.length} channels');
  for (final channel in channels.take(3)) {
    stdout.writeln('  ${channel.id}  ${channel.title}');
  }
}

/// history/watch-history.html, read only as far as it needs to be.
Future<void> _checkHistory(String target) async {
  final file = _find(target, 'watch-history.html');
  if (file == null) return;

  // Newest first, so a bounded prefix holds the recent entries. Reading all
  // 28 MB of a real export to keep a few hundred rows is waste, and on a phone
  // it is memory that need not be spent.
  final handle = await file.open();
  final bytes = await handle.read(4 * 1024 * 1024);
  await handle.close();
  final html = utf8.decode(bytes, allowMalformed: true);

  final watches = parseWatchHistoryHtml(html, limit: 500);
  final undated = watches.where((w) => w.watchedAt == null).length;
  stdout.writeln(
    '\nwatch-history.html: ${watches.length} entries from the first 4MB'
    '${undated > 0 ? ', $undated with an unreadable timestamp' : ''}',
  );
  for (final watch in watches.take(3)) {
    stdout.writeln('  ${watch.videoId} | ${watch.watchedAt} | ${watch.author}');
  }
}

/// Looks for a file near the target: in it, its parent, or one level of nested
/// folders - so pointing the script at the playlists folder still finds the rest.
File? _find(String target, String name) {
  final base = FileSystemEntity.isDirectorySync(target)
      ? Directory(target)
      : File(target).parent;
  for (final dir in [base, base.parent]) {
    if (!dir.existsSync()) continue;
    final direct = File('${dir.path}/$name');
    if (direct.existsSync()) return direct;
    for (final entity in dir.listSync()) {
      if (entity is Directory) {
        final nested = File('${entity.path}/$name');
        if (nested.existsSync()) return nested;
      }
    }
  }
  return null;
}
