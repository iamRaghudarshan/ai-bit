import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'models.dart';

/// Exports and restores the device-local library — playlists, subscriptions and
/// watch history — as a single JSON file.
///
/// There is no account and no sync, so this is the only way library data
/// survives a lost phone or a reinstall. The file is portable between installs;
/// restore merges into whatever is already there rather than replacing it.
class BackupService {
  BackupService(this._db);

  final AppDatabase _db;

  static const _formatVersion = 1;

  /// Writes a backup to a temporary file and returns its path, for sharing.
  Future<String> export() async {
    final playlists = await _db.playlists();
    final data = <String, Object?>{
      'app': 'AI BIT',
      'version': _formatVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'subscriptions': [
        for (final c in await _db.subscriptions())
          {'id': c.id, 'title': c.title, 'avatarUrl': c.avatarUrl},
      ],
      'playlists': [
        for (final p in playlists)
          {
            'name': p.name,
            // Watch Later (id 1) is exported by name and merged back into the
            // reserved one on restore, so it is never duplicated.
            'reserved': p.id == LocalPlaylist.watchLaterId,
            'videos': [
              for (final v in await _db.playlistItems(p.id)) _videoMap(v),
            ],
          },
      ],
      'history': [
        for (final h in await _db.history(limit: 2000))
          {
            ..._videoMap(h.video),
            'position_ms': h.position.inMilliseconds,
            'watched_at': h.watchedAt.millisecondsSinceEpoch,
            'is_short': h.video.isShort,
            'is_kids': h.video.isKids,
          },
      ],
    };

    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final file = File('${dir.path}/aibit-backup-$stamp.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    return file.path;
  }

  /// Merges the backup at [path] into the current library. Returns a short
  /// summary of what was added.
  Future<String> restore(String path) async {
    final raw = jsonDecode(await File(path).readAsString());
    if (raw is! Map || raw['app'] != 'AI BIT') {
      throw const FormatException('Not an AI BIT backup file.');
    }

    var subs = 0, lists = 0, videos = 0, watched = 0;

    for (final c in (raw['subscriptions'] as List? ?? const [])) {
      if (c is! Map) continue;
      await _db.subscribe(ChannelInfo(
        id: '${c['id']}',
        title: '${c['title']}',
        avatarUrl: c['avatarUrl'] as String?,
      ));
      subs++;
    }

    for (final p in (raw['playlists'] as List? ?? const [])) {
      if (p is! Map) continue;
      final reserved = p['reserved'] == true;
      final id = reserved
          ? LocalPlaylist.watchLaterId
          : await _db.createPlaylist('${p['name']}');
      if (!reserved) lists++;
      for (final v in (p['videos'] as List? ?? const [])) {
        if (v is! Map) continue;
        await _db.addToPlaylist(id, _videoFromMap(v));
        videos++;
      }
    }

    for (final h in (raw['history'] as List? ?? const [])) {
      if (h is! Map) continue;
      final video = _videoFromMap(h);
      final stamp = h['watched_at'] as int?;
      if (stamp != null) {
        // The backup carries the time each video was ACTUALLY watched, and
        // recordWatch stamps now - restoring through it collapsed a whole
        // history onto today and destroyed the ordering the history screen
        // and the feed both read.
        await _db.importWatch(
          video,
          DateTime.fromMillisecondsSinceEpoch(stamp),
        );
      } else {
        await _db.recordWatch(
          video,
          position: Duration(milliseconds: (h['position_ms'] as int?) ?? 0),
        );
      }
      watched++;
    }

    return '$subs subscriptions, $lists playlists, $videos saved videos, '
        '$watched history entries restored.';
  }

  static Map<String, Object?> _videoMap(VideoBrief v) => {
        'id': v.id,
        'title': v.title,
        'author': v.author,
        'channelId': v.channelId,
        'durationMs': v.duration?.inMilliseconds,
        'viewCount': v.viewCount,
        'uploadRaw': v.uploadRaw,
        'isShort': v.isShort,
        'isKids': v.isKids,
      };

  static VideoBrief _videoFromMap(Map<dynamic, dynamic> m) => VideoBrief(
        id: '${m['id']}',
        title: '${m['title'] ?? ''}',
        author: '${m['author'] ?? ''}',
        channelId: '${m['channelId'] ?? ''}',
        duration: m['durationMs'] == null
            ? null
            : Duration(milliseconds: m['durationMs'] as int),
        viewCount: m['viewCount'] as int?,
        uploadRaw: m['uploadRaw'] as String?,
        isShort: m['isShort'] == true || m['is_short'] == true,
        isKids: m['isKids'] == true || m['is_kids'] == true,
      );
}
