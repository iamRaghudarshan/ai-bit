// Converts a Google Takeout export into ONE AI BIT backup file.
//
//   dart run tool/takeout_to_backup.dart "<path to>/Takeout/YouTube and YouTube Music"
//
// Why this exists rather than importing the export directly on the phone:
//
//  * It is one file to move instead of five, and the app already knows how to
//    read it - Settings > Import & export > Import library.
//  * Takeout stores bare video ids for playlists, so every title, channel and
//    duration is a separate lookup. Doing them here means they happen once, on
//    a machine with a real connection, instead of slowly on a phone every time.
//  * The result is the app's own backup format, so it round-trips: export from
//    the app later and the same importer reads it back.
//
// Reads only the files it names and writes one JSON beside them. Nothing is
// uploaded anywhere.

import 'dart:convert';
import 'dart:io';

import 'package:ai_bit/src/data/models.dart';
import 'package:ai_bit/src/data/takeout_import.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

/// Matches BackupService's history cap, so the file cannot carry rows the app
/// would only trim away on restore.
const _historyCap = 500;

/// Bounded read for the history file: a real export was 28 MB, it is
/// newest-first, and only the most recent entries survive the cap.
const _maxHistoryBytes = 6 * 1024 * 1024;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/takeout_to_backup.dart '
      '"<Takeout>/YouTube and YouTube Music" [output.json]',
    );
    exitCode = 2;
    return;
  }

  final root = Directory(args.first);
  if (!root.existsSync()) {
    stderr.writeln('No such folder: ${root.path}');
    exitCode = 2;
    return;
  }

  // youtube_explode directly rather than YtRepository: the repository
  // imports package:flutter, which a plain `dart run` cannot load.
  final client = yt.YoutubeExplode();
  final subscriptions = <Map<String, Object?>>[];
  final playlists = <Map<String, Object?>>[];
  final history = <Map<String, Object?>>[];

  // ------------------------------------------------------------ subscriptions
  final subsFile = _find(root, 'subscriptions.csv');
  if (subsFile != null) {
    for (final channel in parseSubscriptionsCsv(await subsFile.readAsString())) {
      subscriptions.add({
        'id': channel.id,
        'title': channel.title,
        'avatarUrl': null,
      });
    }
    stdout.writeln('subscriptions: ${subscriptions.length}');
  }

  // ----------------------------------------------------------------- history
  final historyFile = _find(root, 'watch-history.html');
  if (historyFile != null) {
    final handle = await historyFile.open();
    final bytes = await handle.read(_maxHistoryBytes);
    await handle.close();
    // allowMalformed: a bounded read can slice a multi-byte character in half,
    // and one broken glyph must not cost the whole file.
    final html = utf8.decode(bytes, allowMalformed: true);

    for (final watch in parseWatchHistoryHtml(html, limit: _historyCap)) {
      history.add({
        'id': watch.videoId,
        'title': watch.title,
        'author': watch.author,
        'channelId': watch.channelId,
        'durationMs': null,
        'viewCount': null,
        'uploadRaw': null,
        'isShort': false,
        'isKids': false,
        'position_ms': 0,
        'watched_at':
            (watch.watchedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
                .millisecondsSinceEpoch,
      });
    }
    stdout.writeln('history: ${history.length}');
  }

  // --------------------------------------------------------------- playlists
  // The slow part, and the reason this script is worth running: each id needs
  // a lookup. Serial on purpose - a burst to the same endpoint gets throttled,
  // which is the same reason the app's download queue is serial.
  final playlistDir = _findDir(root, 'playlists');
  if (playlistDir != null) {
    for (final entity in playlistDir.listSync()) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.csv')) {
        continue;
      }
      final parsed = readPlaylistFile(
        fileName: entity.path,
        contents: await entity.readAsString(),
      );
      if (parsed == null) continue;

      final videos = <Map<String, Object?>>[];
      var failed = 0;
      for (var i = 0; i < parsed.videoIds.length; i++) {
        final id = parsed.videoIds[i];
        stdout.write(
          '\r${parsed.name}: ${i + 1}/${parsed.videoIds.length}   ',
        );
        try {
          final video = VideoBrief.fromYt(await client.videos.get(id));
          videos.add({
            'id': video.id,
            'title': video.title,
            'author': video.author,
            'channelId': video.channelId,
            'durationMs': video.duration?.inMilliseconds,
            'viewCount': video.viewCount,
            'uploadRaw': video.uploadRaw,
            'isShort': false,
            'isKids': false,
          });
        } catch (_) {
          // Deleted, private or region-locked. Counted, not hidden.
          failed++;
        }
      }
      stdout.writeln(
        '\r${parsed.name}: ${videos.length} videos'
        '${failed > 0 ? ' ($failed unavailable)' : ''}          ',
      );

      playlists.add({
        'name': parsed.name,
        // The app reserves one playlist for Watch Later; flagging it here is
        // what makes restore merge into that one instead of creating a second
        // playlist with the same name.
        'reserved': parsed.name.toLowerCase() == 'watch later',
        'videos': videos,
      });
    }
  }

  client.close();

  final output = args.length > 1
      ? args[1]
      : '${root.path}/aibit-import.json';
  final data = <String, Object?>{
    'app': 'AI BIT',
    'version': 1,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'subscriptions': subscriptions,
    'playlists': playlists,
    'history': history,
  };
  await File(output).writeAsString(
    const JsonEncoder.withIndent('  ').convert(data),
  );

  final videoCount = playlists.fold<int>(
    0,
    (sum, p) => sum + (p['videos']! as List).length,
  );
  stdout.writeln(
    '\nWrote $output\n'
    '  ${subscriptions.length} subscriptions, '
    '${playlists.length} playlists ($videoCount videos), '
    '${history.length} history entries',
  );
}

File? _find(Directory root, String name) {
  final direct = File('${root.path}/$name');
  if (direct.existsSync()) return direct;
  for (final entity in root.listSync()) {
    if (entity is Directory) {
      final nested = File('${entity.path}/$name');
      if (nested.existsSync()) return nested;
    }
  }
  return null;
}

Directory? _findDir(Directory root, String name) {
  final direct = Directory('${root.path}/$name');
  if (direct.existsSync()) return direct;
  // The caller may already have pointed at the folder itself.
  if (root.path.toLowerCase().endsWith(name)) return root;
  return null;
}
