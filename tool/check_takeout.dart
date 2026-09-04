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
}
