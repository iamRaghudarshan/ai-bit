import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import 'models.dart';

/// Local store for watch history and user playlists.
///
/// Everything lives on-device; there is no account and nothing is uploaded.
class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;

  static const _historyLimit = 500;

  static Future<AppDatabase> open() async {
    // Web is a UI-preview target only — the app ships to iOS/Android, where
    // sqflite uses the platform's native SQLite. On web there is no such
    // engine, so swap in the IndexedDB-backed factory to keep the app bootable
    // in a browser.
    if (kIsWeb) databaseFactory = databaseFactoryFfiWeb;

    final path = kIsWeb ? 'ai_bit.db' : '${await getDatabasesPath()}/ai_bit.db';
    final db = await openDatabase(
      path,
      version: 8,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await _createSchema(db, version);
        await _createDownloads(db);
        await _createSearches(db);
        await _createSubscriptions(db);
        await _createDataUsage(db);
        await _createKidsUsage(db);
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) await _createDownloads(db);
        if (from < 3) await _createSearches(db);
        if (from < 4) await _createSubscriptions(db);
        if (from < 5) {
          await db.execute(
            'ALTER TABLE history ADD COLUMN is_short INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (from < 6) {
          await db.execute(
            'ALTER TABLE history ADD COLUMN is_kids INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (from < 7) {
          // downloads and playlist_items both persist a video via
          // VideoBrief.toMap(), which emits is_short/is_kids once those columns
          // were added for history — but these two tables never gained them, so
          // every saveDownload / addToPlaylist threw "no column named is_short"
          // and the download or save failed outright. Add the columns here so
          // the shared insert matches the schema again.
          for (final table in ['downloads', 'playlist_items']) {
            await db.execute(
              'ALTER TABLE $table ADD COLUMN is_short INTEGER NOT NULL DEFAULT 0',
            );
            await db.execute(
              'ALTER TABLE $table ADD COLUMN is_kids INTEGER NOT NULL DEFAULT 0',
            );
          }
        }
        if (from < 8) {
          await _createDataUsage(db);
          await _createKidsUsage(db);
        }
      },
    );
    return AppDatabase._(db);
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE history (
        video_id     TEXT PRIMARY KEY,
        title        TEXT NOT NULL,
        author       TEXT NOT NULL,
        channel_id   TEXT NOT NULL,
        duration_ms  INTEGER,
        view_count   INTEGER,
        upload_raw   TEXT,
        upload_date  INTEGER,
        is_live      INTEGER NOT NULL DEFAULT 0,
        is_short     INTEGER NOT NULL DEFAULT 0,
        is_kids      INTEGER NOT NULL DEFAULT 0,
        position_ms  INTEGER NOT NULL DEFAULT 0,
        watched_at   INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_history_watched ON history (watched_at DESC)',
    );

    await db.execute('''
      CREATE TABLE playlists (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        name       TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE playlist_items (
        playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
        video_id    TEXT NOT NULL,
        title       TEXT NOT NULL,
        author      TEXT NOT NULL,
        channel_id  TEXT NOT NULL,
        duration_ms INTEGER,
        view_count  INTEGER,
        upload_raw  TEXT,
        upload_date INTEGER,
        is_live     INTEGER NOT NULL DEFAULT 0,
        is_short    INTEGER NOT NULL DEFAULT 0,
        is_kids     INTEGER NOT NULL DEFAULT 0,
        added_at    INTEGER NOT NULL,
        PRIMARY KEY (playlist_id, video_id)
      )
    ''');

    // Watch Later is seeded so it always exists at LocalPlaylist.watchLaterId.
    await db.insert('playlists', {
      'id': LocalPlaylist.watchLaterId,
      'name': 'Watch later',
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  static Future<void> _createDownloads(Database db) async {
    await db.execute('''
      CREATE TABLE downloads (
        video_id       TEXT PRIMARY KEY,
        title          TEXT NOT NULL,
        author         TEXT NOT NULL,
        channel_id     TEXT NOT NULL,
        duration_ms    INTEGER,
        view_count     INTEGER,
        upload_raw     TEXT,
        upload_date    INTEGER,
        is_live        INTEGER NOT NULL DEFAULT 0,
        is_short       INTEGER NOT NULL DEFAULT 0,
        is_kids        INTEGER NOT NULL DEFAULT 0,
        file_path      TEXT NOT NULL,
        quality        TEXT,
        audio_only     INTEGER NOT NULL DEFAULT 0,
        total_bytes    INTEGER NOT NULL DEFAULT 0,
        received_bytes INTEGER NOT NULL DEFAULT 0,
        status         TEXT NOT NULL,
        error          TEXT,
        created_at     INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _createSearches(Database db) async {
    await db.execute('''
      CREATE TABLE searches (
        query      TEXT PRIMARY KEY,
        hits       INTEGER NOT NULL DEFAULT 1,
        searched_at INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _createSubscriptions(Database db) async {
    await db.execute('''
      CREATE TABLE subscriptions (
        channel_id   TEXT PRIMARY KEY,
        title        TEXT NOT NULL,
        avatar_url   TEXT,
        subscribed_at INTEGER NOT NULL
      )
    ''');
  }

  /// Bytes spent per channel per day, split by whether they were streamed or
  /// downloaded. Keyed by all three so a day's usage accumulates into one row
  /// instead of growing a row per playback — see [addDataUsage].
  ///
  /// `day` is days since the epoch, not a timestamp: the screen only ever asks
  /// "since when", and a whole-day bucket keeps the table tiny.
  static Future<void> _createDataUsage(Database db) async {
    await db.execute('''
      CREATE TABLE data_usage (
        day           INTEGER NOT NULL,
        channel_id    TEXT NOT NULL,
        channel_title TEXT NOT NULL,
        bytes         INTEGER NOT NULL DEFAULT 0,
        kind          TEXT NOT NULL,
        PRIMARY KEY (day, channel_id, kind)
      )
    ''');
  }

  /// Seconds watched per day in Kids mode, for the daily-limit guard. One row
  /// per day so yesterday's total never leaks into today's allowance.
  static Future<void> _createKidsUsage(Database db) async {
    await db.execute('''
      CREATE TABLE kids_usage (
        day     INTEGER PRIMARY KEY,
        seconds INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  // ---------------------------------------------------------- subscriptions

  /// Local only. Without a Google account there is nothing to sync to, so
  /// "subscribed" means "followed on this device" — it drives the
  /// Subscriptions feed and nothing leaves the phone.
  Future<void> subscribe(ChannelInfo channel) => _db.insert(
    'subscriptions',
    {
      'channel_id': channel.id,
      'title': channel.title,
      'avatar_url': channel.avatarUrl,
      'subscribed_at': DateTime.now().millisecondsSinceEpoch,
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<void> unsubscribe(String channelId) =>
      _db.delete('subscriptions', where: 'channel_id = ?', whereArgs: [channelId]);

  Future<bool> isSubscribed(String channelId) async {
    final rows = await _db.query(
      'subscriptions',
      columns: ['channel_id'],
      where: 'channel_id = ?',
      whereArgs: [channelId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<List<ChannelInfo>> subscriptions() async {
    final rows = await _db.query('subscriptions', orderBy: 'title COLLATE NOCASE');
    return rows
        .map(
          (r) => ChannelInfo(
            id: r['channel_id']! as String,
            title: r['title']! as String,
            avatarUrl: r['avatar_url'] as String?,
          ),
        )
        .toList();
  }

  // --------------------------------------------------------- search history

  /// Records a search so the home feed can recommend from it. Repeating a
  /// query bumps its count, which is what makes a recurring interest outrank a
  /// one-off lookup.
  Future<void> recordSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.length < 2) return;
    await _db.rawInsert('''
      INSERT INTO searches (query, hits, searched_at) VALUES (?, 1, ?)
      ON CONFLICT(query) DO UPDATE SET
        hits = hits + 1,
        searched_at = excluded.searched_at
    ''', [trimmed, DateTime.now().millisecondsSinceEpoch]);

    // Keep it small; the feed only ever reads the top handful.
    await _db.rawDelete('''
      DELETE FROM searches WHERE query NOT IN (
        SELECT query FROM searches ORDER BY searched_at DESC LIMIT 50
      )
    ''');
  }

  /// Removes one remembered search.
  Future<void> deleteSearch(String query) =>
      _db.delete('searches', where: 'query = ?', whereArgs: [query]);

  /// Recent searches, newest first, for the search screen's own list.
  ///
  /// Separate from [recentSearches], which orders by hit count because the
  /// feed wants your strongest interests. A history list wants the most
  /// recent thing you typed at the top.
  Future<List<String>> searchHistory({int limit = 15}) async {
    final rows = await _db.query(
      'searches',
      columns: ['query'],
      orderBy: 'searched_at DESC',
      limit: limit,
    );
    return rows.map((r) => r['query']! as String).toList();
  }

  /// Recent searches, most-repeated first, for feeding recommendations.
  Future<List<String>> recentSearches({int limit = 5}) async {
    final rows = await _db.query(
      'searches',
      columns: ['query'],
      orderBy: 'hits DESC, searched_at DESC',
      limit: limit,
    );
    return rows.map((r) => r['query']! as String).toList();
  }

  Future<void> clearSearchHistory() => _db.delete('searches');

  // -------------------------------------------------------------- downloads

  Future<void> saveDownload(DownloadRecord record) => _db.insert(
    'downloads',
    record.toMap(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  /// Progress-only write, called frequently during a transfer.
  Future<void> updateDownloadProgress(
    String videoId, {
    required int receivedBytes,
    int? totalBytes,
  }) => _db.update(
    'downloads',
    {'received_bytes': receivedBytes, 'total_bytes': ?totalBytes},
    where: 'video_id = ?',
    whereArgs: [videoId],
  );

  Future<void> updateDownloadStatus(
    String videoId,
    DownloadStatus status, {
    String? error,
  }) => _db.update(
    'downloads',
    {'status': status.name, 'error': error},
    where: 'video_id = ?',
    whereArgs: [videoId],
  );

  Future<List<DownloadRecord>> downloads() async {
    final rows = await _db.query('downloads', orderBy: 'created_at DESC');
    return rows.map(DownloadRecord.fromMap).toList();
  }

  Future<DownloadRecord?> download(String videoId) async {
    final rows = await _db.query(
      'downloads',
      where: 'video_id = ?',
      whereArgs: [videoId],
      limit: 1,
    );
    return rows.isEmpty ? null : DownloadRecord.fromMap(rows.first);
  }

  /// Local file for a *finished* download, or null. This is what lets the
  /// player prefer offline media over the network.
  Future<String?> completedDownloadPath(String videoId) async {
    final rows = await _db.query(
      'downloads',
      columns: ['file_path'],
      where: 'video_id = ? AND status = ?',
      whereArgs: [videoId, DownloadStatus.completed.name],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['file_path'] as String?;
  }

  Future<void> deleteDownload(String videoId) =>
      _db.delete('downloads', where: 'video_id = ?', whereArgs: [videoId]);

  // ---------------------------------------------------------------- history

  /// Upserts the history row, preserving the stored position when the caller
  /// does not supply one (opening a video should not reset the resume point).
  Future<void> recordWatch(VideoBrief video, {Duration? position}) async {
    final existing = await _db.query(
      'history',
      columns: ['position_ms'],
      where: 'video_id = ?',
      whereArgs: [video.id],
      limit: 1,
    );
    final keptPosition = existing.isEmpty
        ? 0
        : (existing.first['position_ms'] as int? ?? 0);

    await _db.insert('history', {
      ...video.toMap(),
      'position_ms': position?.inMilliseconds ?? keptPosition,
      'watched_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    await _trimHistory();
  }

  /// Cheap position-only write, called every few seconds while playing.
  Future<void> savePosition(String videoId, Duration position) async {
    await _db.update(
      'history',
      {'position_ms': position.inMilliseconds},
      where: 'video_id = ?',
      whereArgs: [videoId],
    );
  }

  Future<Duration?> resumePosition(String videoId) async {
    final rows = await _db.query(
      'history',
      columns: ['position_ms', 'duration_ms'],
      where: 'video_id = ?',
      whereArgs: [videoId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final ms = rows.first['position_ms'] as int? ?? 0;
    final total = rows.first['duration_ms'] as int?;
    // Ignore a resume point in the first 10s or the last 15s — restarting or
    // re-finishing a video is what the user actually wants there.
    if (ms < 10000) return null;
    if (total != null && ms > total - 15000) return null;
    return Duration(milliseconds: ms);
  }

  /// Partly-watched regular videos, newest first, for a "Continue watching"
  /// shelf. Excludes Shorts, Kids-mode items, and anything effectively
  /// finished (past 92% or with under ten seconds played).
  Future<List<HistoryEntry>> continueWatching({int limit = 15}) async {
    final rows = await _db.query(
      'history',
      where: 'is_short = 0 AND is_kids = 0 AND position_ms > 10000 '
          'AND (duration_ms IS NULL OR position_ms < duration_ms * 0.92)',
      orderBy: 'watched_at DESC',
      limit: limit,
    );
    return rows.map(_historyEntry).toList();
  }

  /// Watch history, filterable so Videos, Shorts and Kids can be shown apart.
  /// Each of [shorts] and [kids] is null (don't care), true or false.
  Future<List<HistoryEntry>> history({
    int limit = 200,
    bool? shorts,
    bool? kids,
  }) async {
    final clauses = <String>[];
    final args = <Object>[];
    if (shorts != null) {
      clauses.add('is_short = ?');
      args.add(shorts ? 1 : 0);
    }
    if (kids != null) {
      clauses.add('is_kids = ?');
      args.add(kids ? 1 : 0);
    }
    final rows = await _db.query(
      'history',
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'watched_at DESC',
      limit: limit,
    );
    return rows.map(_historyEntry).toList();
  }

  /// Watch history matching [query] in either the title or the channel name,
  /// newest first. An empty query is the unfiltered list.
  ///
  /// [shorts] and [kids] filter exactly as they do in [history] — null is
  /// "don't care". They belong in SQL rather than in a caller's `where` over
  /// the result, because [limit] is spent *before* any Dart-side split: one
  /// unfiltered query capped at 200 can come back all regular videos and
  /// leave the Kids tab empty while matching Kids rows sit further down.
  ///
  /// SQLite's LIKE folds case for ASCII only, which is what the history search
  /// box needs and all it promises; an accented or Cyrillic title matches only
  /// when the case already agrees.
  Future<List<HistoryEntry>> searchWatchHistory(
    String query, {
    int limit = 200,
    bool? shorts,
    bool? kids,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return history(limit: limit, shorts: shorts, kids: kids);
    }
    final pattern = '%${_escapeLike(trimmed)}%';
    // The two LIKEs are bracketed: left bare, their OR would swallow the
    // is_short / is_kids term and every tab would show every match.
    final clauses = <String>[
      "(title LIKE ? ESCAPE '\\' OR author LIKE ? ESCAPE '\\')",
    ];
    final args = <Object>[pattern, pattern];
    if (shorts != null) {
      clauses.add('is_short = ?');
      args.add(shorts ? 1 : 0);
    }
    if (kids != null) {
      clauses.add('is_kids = ?');
      args.add(kids ? 1 : 0);
    }
    final rows = await _db.query(
      'history',
      where: clauses.join(' AND '),
      whereArgs: args,
      orderBy: 'watched_at DESC',
      limit: limit,
    );
    return rows.map(_historyEntry).toList();
  }

  /// Neutralises the wildcards in a user-typed LIKE term, so searching for
  /// "10_things" does not silently match "10 things".
  static String _escapeLike(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');

  static HistoryEntry _historyEntry(Map<String, Object?> row) => HistoryEntry(
    video: VideoBrief.fromMap(row),
    position: Duration(milliseconds: row['position_ms'] as int? ?? 0),
    watchedAt: DateTime.fromMillisecondsSinceEpoch(row['watched_at']! as int),
  );

  /// Every video id that appears in history, for marking watched rows in a
  /// feed. Ids only — a feed can hold hundreds of rows to check, and building
  /// a VideoBrief for all of history to answer that would be wasteful.
  Future<Set<String>> watchedVideoIds() async {
    final rows = await _db.query('history', columns: ['video_id']);
    return rows.map((r) => r['video_id']! as String).toSet();
  }

  /// Drops history older than [days], returning how many rows went. Anything
  /// <= 0 means "keep forever" and must not delete a thing.
  Future<int> deleteHistoryOlderThan(int days) async {
    if (days <= 0) return 0;
    final cutoff = DateTime.now()
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    return _db.delete('history', where: 'watched_at < ?', whereArgs: [cutoff]);
  }

  Future<void> deleteHistoryEntry(String videoId) =>
      _db.delete('history', where: 'video_id = ?', whereArgs: [videoId]);

  Future<void> clearHistory() => _db.delete('history');

  /// Where the database file lives, so its size can be reported in settings.
  Future<String> get path async =>
      kIsWeb ? 'ai_bit.db' : '${await getDatabasesPath()}/ai_bit.db';

  /// Number of watched videos, used to show what clearing history would drop.
  Future<int> historyCount() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS n FROM history');
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<void> _trimHistory() async {
    await _db.rawDelete('''
      DELETE FROM history WHERE video_id NOT IN (
        SELECT video_id FROM history ORDER BY watched_at DESC LIMIT ?
      )
    ''', [_historyLimit]);
  }

  // -------------------------------------------------------------- playlists

  Future<List<LocalPlaylist>> playlists() async {
    final rows = await _db.rawQuery('''
      SELECT p.id, p.name, p.created_at,
             COUNT(i.video_id) AS item_count,
             (SELECT video_id FROM playlist_items
               WHERE playlist_id = p.id ORDER BY added_at DESC LIMIT 1) AS cover
      FROM playlists p
      LEFT JOIN playlist_items i ON i.playlist_id = p.id
      GROUP BY p.id
      ORDER BY (p.id = ${LocalPlaylist.watchLaterId}) DESC, p.created_at DESC
    ''');
    return rows
        .map(
          (r) => LocalPlaylist(
            id: r['id']! as int,
            name: r['name']! as String,
            itemCount: r['item_count'] as int? ?? 0,
            coverVideoId: r['cover'] as String?,
          ),
        )
        .toList();
  }

  Future<int> createPlaylist(String name) => _db.insert('playlists', {
    'name': name,
    'created_at': DateTime.now().millisecondsSinceEpoch,
  });

  Future<void> renamePlaylist(int id, String name) => _db.update(
    'playlists',
    {'name': name},
    where: 'id = ?',
    whereArgs: [id],
  );

  Future<void> deletePlaylist(int id) async {
    if (id == LocalPlaylist.watchLaterId) return; // not removable
    await _db.delete('playlists', where: 'id = ?', whereArgs: [id]);
  }

  /// Empties every playlist and removes all but the reserved Watch Later,
  /// which is left in place (but empty) so the seed invariant holds.
  Future<void> clearPlaylists() async {
    await _db.delete('playlist_items');
    await _db.delete(
      'playlists',
      where: 'id != ?',
      whereArgs: [LocalPlaylist.watchLaterId],
    );
  }

  /// Removes every followed channel.
  Future<void> clearSubscriptions() => _db.delete('subscriptions');

  Future<void> addToPlaylist(int playlistId, VideoBrief video) =>
      _db.insert('playlist_items', {
        ...video.toMap(),
        'playlist_id': playlistId,
        'added_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> removeFromPlaylist(int playlistId, String videoId) =>
      _db.delete(
        'playlist_items',
        where: 'playlist_id = ? AND video_id = ?',
        whereArgs: [playlistId, videoId],
      );

  Future<List<VideoBrief>> playlistItems(int playlistId) async {
    final rows = await _db.query(
      'playlist_items',
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
      orderBy: 'added_at DESC',
    );
    return rows.map(VideoBrief.fromMap).toList();
  }

  /// Playlist ids that already contain [videoId] — drives the checkmarks in
  /// the "Save to…" sheet.
  Future<Set<int>> playlistsContaining(String videoId) async {
    final rows = await _db.query(
      'playlist_items',
      columns: ['playlist_id'],
      where: 'video_id = ?',
      whereArgs: [videoId],
    );
    return rows.map((r) => r['playlist_id']! as int).toSet();
  }

  // ------------------------------------------------------------- data usage

  /// Adds [bytes] to the running total for this day / channel / kind.
  ///
  /// Upserts rather than inserts: a single video reports usage many times as
  /// it streams, and one row per report would turn the table into a log
  /// nobody reads. Zero-byte reports are dropped so a video that was opened
  /// but never fetched does not create an empty channel row.
  Future<void> addDataUsage({
    required int day,
    required String channelId,
    required String channelTitle,
    required int bytes,
    required String kind,
  }) async {
    if (bytes <= 0 || channelId.isEmpty) return;
    await _db.rawInsert('''
      INSERT INTO data_usage (day, channel_id, channel_title, bytes, kind)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(day, channel_id, kind) DO UPDATE SET
        bytes = data_usage.bytes + excluded.bytes,
        channel_title = excluded.channel_title
    ''', [day, channelId, channelTitle, bytes, kind]);
  }

  /// Usage since [sinceDay] (days since epoch), heaviest first. A channel that
  /// was both streamed and downloaded returns one row per kind, because the
  /// two costs are worth telling apart.
  Future<List<DataUsageRow>> dataUsageByChannel({required int sinceDay}) async {
    final rows = await _db.rawQuery('''
      SELECT channel_id,
             MAX(channel_title) AS channel_title,
             kind,
             SUM(bytes) AS bytes
      FROM data_usage
      WHERE day >= ?
      GROUP BY channel_id, kind
      ORDER BY bytes DESC
    ''', [sinceDay]);
    return rows
        .map(
          (r) => DataUsageRow(
            channelId: r['channel_id']! as String,
            channelTitle: r['channel_title'] as String? ?? '',
            bytes: r['bytes'] as int? ?? 0,
            kind: r['kind']! as String,
          ),
        )
        .toList();
  }

  /// Total bytes since [sinceDay], optionally for one [kind] only.
  Future<int> dataUsageTotal({required int sinceDay, String? kind}) async {
    final rows = await _db.rawQuery(
      'SELECT SUM(bytes) AS n FROM data_usage WHERE day >= ?'
      '${kind == null ? '' : ' AND kind = ?'}',
      [sinceDay, ?kind],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Forgets every recorded byte, for the storage screen's reset.
  Future<void> clearDataUsage() => _db.delete('data_usage');

  // ------------------------------------------------------------- kids usage

  Future<int> kidsSecondsOn(int day) async {
    final rows = await _db.query(
      'kids_usage',
      columns: ['seconds'],
      where: 'day = ?',
      whereArgs: [day],
      limit: 1,
    );
    return rows.isEmpty ? 0 : (rows.first['seconds'] as int? ?? 0);
  }

  /// Accumulates watched seconds for [day]. Upserted for the same reason as
  /// [addDataUsage]: it is called on a ticker while a video plays.
  Future<void> addKidsSeconds(int day, int seconds) async {
    if (seconds <= 0) return;
    await _db.rawInsert('''
      INSERT INTO kids_usage (day, seconds) VALUES (?, ?)
      ON CONFLICT(day) DO UPDATE SET
        seconds = kids_usage.seconds + excluded.seconds
    ''', [day, seconds]);
  }

  // ------------------------------------------------------------------ feed

  /// Seeds for the personalised home feed: the most recently watched videos
  /// and the channels behind them.
  Future<({List<String> videoIds, List<String> channelIds})> feedSeeds({
    int limit = 6,
  }) async {
    final rows = await _db.query(
      'history',
      columns: ['video_id', 'channel_id'],
      orderBy: 'watched_at DESC',
      limit: limit,
    );
    final videoIds = <String>[];
    final channelIds = <String>{};
    for (final r in rows) {
      videoIds.add(r['video_id']! as String);
      final cid = r['channel_id'] as String? ?? '';
      if (cid.isNotEmpty) channelIds.add(cid);
    }
    return (videoIds: videoIds, channelIds: channelIds.toList());
  }
}

/// One channel's data cost over a period, as returned by
/// [AppDatabase.dataUsageByChannel]. [kind] is 'stream' or 'download'.
class DataUsageRow {
  const DataUsageRow({
    required this.channelId,
    required this.channelTitle,
    required this.bytes,
    required this.kind,
  });

  final String channelId;
  final String channelTitle;
  final int bytes;
  final String kind;
}
