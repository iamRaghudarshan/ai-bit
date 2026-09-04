import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'db.dart';
import 'models.dart';
import 'takeout_import.dart';
import 'yt_repository.dart';

/// Progress of a running import, so the UI can show something honest while a
/// few hundred videos are fetched one at a time.
class TakeoutProgress {
  const TakeoutProgress({
    required this.playlistName,
    required this.done,
    required this.total,
    this.failed = 0,
  });

  final String playlistName;
  final int done;
  final int total;

  /// Videos whose details could not be fetched - deleted, private, or region
  /// locked. Counted rather than hidden: an import that quietly drops rows
  /// looks like it worked when it did not.
  final int failed;
}

/// What an import ended up doing.
class TakeoutResult {
  const TakeoutResult({
    required this.playlists,
    required this.imported,
    required this.failed,
    this.skippedFiles = 0,
  });

  final int playlists;
  final int imported;
  final int failed;

  /// Files in the selection that held no video ids - subscriptions.csv and the
  /// rest of the export. Reported so a user who picked the whole folder is not
  /// told nothing happened.
  final int skippedFiles;

  bool get isEmpty => playlists == 0 && imported == 0;
}

/// Turns Google Takeout playlist CSVs into local playlists.
///
/// The app has no Google Sign-In on purpose - a real account behind a
/// ToS-violating client is the account that gets actioned - so this is the
/// route that reaches private playlists without ever authenticating.
///
/// The slow part is unavoidable: Takeout gives ids and nothing else, so every
/// title, channel and duration is a separate lookup. They run one at a time
/// rather than in parallel, for the same reason the download queue is serial:
/// a burst of concurrent requests to the same endpoint gets throttled, and a
/// throttled import fails in a way that looks like a bug in the parser.
class TakeoutService {
  TakeoutService({required AppDatabase database, required YtRepository repository})
      : _db = database,
        _repo = repository;

  final AppDatabase _db;
  final YtRepository _repo;

  /// Reads [paths] and creates one local playlist per file that holds videos.
  ///
  /// [onProgress] fires per video so a long import can show a count. A file
  /// that cannot be read is skipped rather than aborting the run: one bad file
  /// in an export should not cost the user the other nine.
  Future<TakeoutResult> importFiles(
    List<String> paths, {
    void Function(TakeoutProgress)? onProgress,
  }) async {
    var playlists = 0;
    var imported = 0;
    var failed = 0;
    var skipped = 0;

    for (final path in paths) {
      String contents;
      try {
        // Latin-1 fallback: Takeout is UTF-8, but a playlist named with an
        // emoji has arrived mis-encoded before, and refusing the whole file
        // over one bad byte loses the entire playlist.
        final bytes = await File(path).readAsBytes();
        try {
          contents = utf8.decode(bytes);
        } on FormatException {
          contents = latin1.decode(bytes);
        }
      } catch (e) {
        debugPrint('AI BIT: could not read $path - $e');
        skipped++;
        continue;
      }

      final parsed = readPlaylistFile(
        fileName: path,
        contents: contents,
      );
      if (parsed == null) {
        skipped++;
        continue;
      }

      // Merge into a playlist of the same name rather than creating a second
      // one. Not hypothetical tidiness: the app seeds a playlist literally
      // called "Watch later" and Takeout exports "Watch later-videos.csv", so
      // a plain create left two playlists of that name with the videos split
      // across them. Found by running tool/check_takeout.dart over a real
      // export, not by reasoning about it.
      final existing = await _db.playlists();
      int? matchId;
      for (final playlist in existing) {
        if (playlist.name.toLowerCase() == parsed.name.toLowerCase()) {
          matchId = playlist.id;
          break;
        }
      }
      final playlistId = matchId ?? await _db.createPlaylist(parsed.name);
      playlists++;

      var done = 0;
      var failedHere = 0;
      for (final videoId in parsed.videoIds) {
        try {
          final details = await _repo.videoDetails(videoId);
          await _db.addToPlaylist(playlistId, VideoBrief.fromYt(details));
          imported++;
        } catch (e) {
          // Deleted, private or region-locked. Counted and logged rather than
          // swallowed, so "40 of 50 imported" can be shown truthfully.
          failedHere++;
          failed++;
          debugPrint('AI BIT: takeout skipped $videoId - $e');
        }
        done++;
        onProgress?.call(
          TakeoutProgress(
            playlistName: parsed.name,
            done: done,
            total: parsed.videoIds.length,
            failed: failedHere,
          ),
        );
      }
    }

    return TakeoutResult(
      playlists: playlists,
      imported: imported,
      failed: failed,
      skippedFiles: skipped,
    );
  }
}
