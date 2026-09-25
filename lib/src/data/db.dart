import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

import 'models.dart';
import 'recommender.dart';

/// Local store for watch history and user playlists.
///
/// Everything lives on-device; there is no account and nothing is uploaded.
class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;

  static const _historyLimit = 500;

  /// Opens the app database.
  ///
  /// [path] and [factory] exist so a test can point this at a temporary file
  /// with the FFI factory, and are never passed by the app itself. Without
  /// them the whole persistence layer — eleven migrations, and the SQL behind
  /// every feature here — could only ever be exercised on a device, which is
  /// to say never, because neither platform builds on this machine. Two real
  /// SQL defects were found the day this hook was added.
  static Future<AppDatabase> open({String? path, DatabaseFactory? factory}) async {
    // Web is a UI-preview target only — the app ships to iOS/Android, where
    // sqflite uses the platform's native SQLite. On web there is no such
    // engine, so swap in the IndexedDB-backed factory to keep the app bootable
    // in a browser.
    if (factory != null) {
      databaseFactory = factory;
    } else if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
    }

    final resolved = path ??
        (kIsWeb ? 'ai_bit.db' : '${await getDatabasesPath()}/ai_bit.db');
    final db = await openDatabase(
      resolved,
      version: 11,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        await _createSchema(db, version);
        await _createDownloads(db);
        await _createSearches(db);
        await _createSubscriptions(db);
        await _createDataUsage(db);
        await _createKidsUsage(db);
        await _createFeedImpressions(db);
        await _createNotInterested(db);
        await _createCoVisit(db);
        await _createRankingExamples(db);
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
          //
          // Added only if absent, and that is not defensiveness. An install old
          // enough to predate the `downloads` table gets it from
          // _createDownloads a few lines above — which is the CURRENT
          // definition and already carries both columns — and the plain ALTER
          // then failed with "duplicate column name", throwing inside
          // onUpgrade, which fails the open. The app would not start at all.
          // Any migration that both creates a table and later alters it has
          // this shape; the guard belongs on all of them.
          for (final table in ['downloads', 'playlist_items']) {
            await _addColumnIfMissing(db, table, 'is_short');
            await _addColumnIfMissing(db, table, 'is_kids');
          }
        }
        if (from < 8) {
          await _createDataUsage(db);
          await _createKidsUsage(db);
        }
        if (from < 9) await _createFeedImpressions(db);
        if (from < 10) {
          await _createNotInterested(db);
          // Impressions gained a positional weight: how much of the user's
          // attention a showing actually had. Existing rows are back-filled at
          // full weight, which is the old behaviour and errs towards keeping
          // the penalty they already carried rather than silently forgiving it.
          await _addColumnIfMissing(
            db,
            'feed_impressions',
            'attention',
            type: 'REAL',
          );
          await db.execute(
            'UPDATE feed_impressions SET attention = shown WHERE attention = 0',
          );
        }
        if (from < 11) {
          await _createCoVisit(db);
          await _createRankingExamples(db);
        }
      },
    );
    return AppDatabase._(db);
  }

  /// Closes the underlying database. Only a test needs this — the app's one
  /// instance lives as long as the process.
  Future<void> close() => _db.close();

  /// Adds [column] to [table] unless it is already there.
  ///
  /// Guards the one shape of migration bug this schema keeps producing: a
  /// table that is CREATEd by a later-version helper during an upgrade from an
  /// early version, and then ALTERed by a step that assumes the old layout.
  /// The ALTER throws "duplicate column name" inside onUpgrade, which fails
  /// the open — so the symptom is not a missing feature, it is an app that
  /// will not start, for exactly the users with the oldest data.
  static Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column, {
    String type = 'INTEGER',
    String defaultValue = '0',
  }) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    final present = columns.any((c) => c['name'] == column);
    if (present) return;
    await db.execute(
      'ALTER TABLE $table ADD COLUMN $column $type NOT NULL '
      'DEFAULT $defaultValue',
    );
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

  /// How many times a video has been shown in the feed without being opened.
  ///
  /// This is a ranking feature, not analytics: the YouTube recommender paper
  /// lists the number of previous impressions among its most important
  /// features, because a video offered repeatedly and never clicked should
  /// stop being offered. See `recommender.dart`.
  ///
  /// One row per video, counting up, rather than a row per showing — the
  /// ranker only ever asks "how many times, and how long ago", and a log would
  /// grow without bound for an answer it never needs.
  static Future<void> _createFeedImpressions(Database db) async {
    await db.execute('''
      CREATE TABLE feed_impressions (
        video_id      TEXT PRIMARY KEY,
        shown         INTEGER NOT NULL DEFAULT 0,
        attention     REAL NOT NULL DEFAULT 0,
        last_shown_at INTEGER NOT NULL
      )
    ''');
  }


  /// Which videos are watched near which others — a local item-to-item graph.
  ///
  /// This is the nearest thing an account-less app has to collaborative
  /// filtering. Every related list YouTube returns is a *sample* of what
  /// millions of people watched next, because that is how YouTube builds them;
  /// accumulating those samples turns a series of one-off lookups into
  /// something queryable, and something that transfers — a video found by a
  /// plain topic search still gets credit for being co-visited with three
  /// things watched last night.
  ///
  /// Edges are directed and weighted. Kept small by [_coVisitLimit]: an
  /// unbounded graph on a phone is a slow query and a growing file, and the
  /// long tail of weak edges changes no ranking.
  static Future<void> _createCoVisit(Database db) async {
    await db.execute('''
      CREATE TABLE covisit (
        from_id    TEXT NOT NULL,
        to_id      TEXT NOT NULL,
        weight     REAL NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (from_id, to_id)
      )
    ''');
    await db.execute('CREATE INDEX idx_covisit_from ON covisit (from_id)');
  }

  /// What the ranker offered and what the user did about it.
  ///
  /// The training set for `RankerWeights`. One row per card that was actually
  /// on screen, holding the feature vector it was scored on — captured then
  /// rather than recomputed later, because by the next feed load the profile
  /// has moved and the numbers would describe a different world.
  ///
  /// Rows are consumed by training and deleted, so this never becomes a log.
  static Future<void> _createRankingExamples(Database db) async {
    await db.execute('''
      CREATE TABLE ranking_examples (
        video_id   TEXT PRIMARY KEY,
        features   TEXT NOT NULL,
        opened     INTEGER NOT NULL DEFAULT 0,
        completion REAL NOT NULL DEFAULT 0,
        shown_at   INTEGER NOT NULL
      )
    ''');
  }

  /// Videos and channels the user has explicitly said no to.
  ///
  /// YouTube names *Not interested* and *Don't recommend channel* as first-class
  /// recommendation signals, and for an app with no likes, no surveys and no
  /// account this is the only one the user states outright rather than having
  /// inferred from their behaviour. It is therefore treated as near-absolute:
  /// see `recommender.dart`, where a match is dropped from the candidate pool
  /// rather than merely demoted.
  ///
  /// The title is kept for a dismissed video so the dismissal can generalise
  /// weakly through its words. A channel row needs none.
  static Future<void> _createNotInterested(Database db) async {
    await db.execute('''
      CREATE TABLE not_interested (
        id         TEXT NOT NULL,
        kind       TEXT NOT NULL,
        title      TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        PRIMARY KEY (id, kind)
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

  /// Inserts a watched row with the time it was ACTUALLY watched.
  ///
  /// [recordWatch] stamps `DateTime.now()`, which is right when the user just
  /// watched something and wrong for an import: a Takeout export carries the
  /// real timestamps, and collapsing years of history onto today would destroy
  /// the ordering the history screen and the feed both read.
  ///
  /// Does not trim - an import calls [trimHistory] once at the end rather than
  /// after every row.
  Future<void> importWatch(VideoBrief video, DateTime watchedAt) => _db.insert(
    'history',
    {
      ...video.toMap(),
      'position_ms': 0,
      'watched_at': watchedAt.millisecondsSinceEpoch,
    },
    // Ignore, not replace: anything already in history was watched in the app
    // and knows its own resume position, which an import must not clobber.
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );

  /// Trims history to its cap. Public so a bulk import can call it once.
  Future<void> trimHistory() => _trimHistory();

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

  // ------------------------------------------------------ recommendations

  /// Watch history reduced to what the ranker needs, newest first.
  ///
  /// Carries the position and duration so `WatchSignal` can work out how much
  /// of each video was actually watched. That ratio is the whole point — it is
  /// what lets a channel watched to the end outweigh one bounced off after ten
  /// seconds, which is the difference between ranking on watch time and
  /// ranking on clicks.
  ///
  /// Kids-mode rows are excluded: that mode curates from a fixed topic list
  /// and consults no personal signal, so letting it feed the ordinary profile
  /// would push nursery rhymes into an adult's recommendations.
  Future<List<WatchSignal>> watchSignals({int limit = 300}) async {
    final rows = await _db.query(
      'history',
      columns: [
        'video_id',
        'channel_id',
        'title',
        'position_ms',
        'duration_ms',
        'watched_at',
      ],
      where: 'is_kids = 0',
      orderBy: 'watched_at DESC',
      limit: limit,
    );
    return [
      for (final r in rows)
        WatchSignal.fromWatch(
          videoId: r['video_id']! as String,
          channelId: (r['channel_id'] as String?) ?? '',
          title: (r['title'] as String?) ?? '',
          watchedAt: DateTime.fromMillisecondsSinceEpoch(
            r['watched_at']! as int,
          ),
          position: Duration(milliseconds: r['position_ms'] as int? ?? 0),
          duration: r['duration_ms'] == null
              ? null
              : Duration(milliseconds: r['duration_ms']! as int),
        ),
    ];
  }

  /// Remembered searches with their repeat count and timestamp.
  ///
  /// Distinct from [recentSearches], which returns bare strings for the feed's
  /// candidate queries. The ranker needs the weights too.
  Future<List<SearchSignal>> searchSignals({int limit = 30}) async {
    final rows = await _db.query(
      'searches',
      orderBy: 'searched_at DESC',
      limit: limit,
    );
    return [
      for (final r in rows)
        SearchSignal(
          query: r['query']! as String,
          hits: r['hits'] as int? ?? 1,
          searchedAt: DateTime.fromMillisecondsSinceEpoch(
            r['searched_at']! as int,
          ),
        ),
    ];
  }

  // ------------------------------------------------- co-visitation graph

  /// Most edges kept. Beyond this the weakest are pruned.
  static const _coVisitLimit = 4000;

  /// Records that [related] are the videos YouTube lists alongside [videoId].
  ///
  /// Position-weighted: the first entry in a related list is a much stronger
  /// statement than the twentieth, in the same way and for the same reason
  /// that the first result of a search is.
  Future<void> recordCoVisits(String videoId, List<String> related) async {
    if (videoId.isEmpty || related.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = _db.batch();
    for (var i = 0; i < related.length && i < 20; i++) {
      final other = related[i];
      if (other.isEmpty || other == videoId) continue;
      final weight = 1 / (1 + i * 0.25);
      batch.rawInsert('''
        INSERT INTO covisit (from_id, to_id, weight, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(from_id, to_id) DO UPDATE SET
          weight = MIN(covisit.weight + excluded.weight, 12.0),
          updated_at = excluded.updated_at
      ''', [videoId, other, weight, now]);
    }
    await batch.commit(noResult: true);
  }

  /// Records that the user went from [fromId] to [toId] themselves.
  ///
  /// Weighted far above a related-list edge, and deliberately so: a related
  /// list is what YouTube believes about everybody, while this is what this
  /// person actually did. It is also the only edge in the graph that is not
  /// borrowed.
  Future<void> recordWatchTransition(String fromId, String toId) async {
    if (fromId.isEmpty || toId.isEmpty || fromId == toId) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.rawInsert('''
      INSERT INTO covisit (from_id, to_id, weight, updated_at)
      VALUES (?, ?, 4.0, ?)
      ON CONFLICT(from_id, to_id) DO UPDATE SET
        weight = MIN(covisit.weight + 4.0, 12.0),
        updated_at = excluded.updated_at
    ''', [fromId, toId, now]);
  }

  /// Co-visitation strength for everything reachable from [seeds], summed.
  ///
  /// [seeds] are recently watched video ids. A candidate strongly linked to
  /// several of them scores higher than one linked to a single seed, which is
  /// the point: agreement across the recent past is a better signal than one
  /// strong edge from one video.
  Future<Map<String, double>> coVisitScores(List<String> seeds) async {
    final ids = seeds.where((s) => s.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return const {};
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await _db.rawQuery(
      'SELECT to_id, SUM(weight) AS total FROM covisit '
      'WHERE from_id IN ($placeholders) GROUP BY to_id '
      'ORDER BY total DESC LIMIT 400',
      ids,
    );
    return {
      for (final r in rows)
        r['to_id']! as String: (r['total'] as num?)?.toDouble() ?? 0,
    };
  }

  /// Keeps the graph bounded. Called after writes rather than on a schedule,
  /// so there is no separate job that can be forgotten.
  Future<void> pruneCoVisits() async {
    final count = Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COUNT(*) FROM covisit'),
        ) ??
        0;
    if (count <= _coVisitLimit) return;
    await _db.rawDelete('''
      DELETE FROM covisit WHERE rowid NOT IN (
        SELECT rowid FROM covisit ORDER BY weight DESC, updated_at DESC LIMIT ?
      )
    ''', [_coVisitLimit]);
  }

  // ------------------------------------------------------- ranker training

  /// Examples older than this are dropped untrained. A month-old reaction to a
  /// feed nobody remembers is not worth fitting to.
  static const _exampleMemory = Duration(days: 30);

  /// Notes that a card was offered, with the features it was scored on.
  ///
  /// Ignored if the video already has a row: the first offer is the one the
  /// user reacted to, and re-offering it later does not create a second
  /// independent observation.
  Future<void> recordRankingExamples(Map<String, List<double>> features) async {
    if (features.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = _db.batch();
    for (final entry in features.entries) {
      if (entry.key.isEmpty) continue;
      batch.insert(
        'ranking_examples',
        {
          'video_id': entry.key,
          'features': entry.value.join(','),
          'opened': 0,
          'completion': 0.0,
          'shown_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Marks an offered video as opened, and how much of it was watched.
  ///
  /// Only updates a row that already exists — a video reached from search or a
  /// channel page was never a recommendation, so it is not evidence about the
  /// ranker's judgement and must not be trained on as though it were.
  Future<void> markExampleOpened(String videoId, double completion) =>
      _db.update(
        'ranking_examples',
        {'opened': 1, 'completion': completion.clamp(0.0, 1.0)},
        where: 'video_id = ?',
        whereArgs: [videoId],
      );

  /// Reads the untrained examples and removes them, so each is learnt from
  /// exactly once.
  ///
  /// Read-then-delete rather than a trained flag: the alternative is a table
  /// that grows for ever holding rows nothing will ever look at again.
  /// [settle] is how long an example is left alone before it is trained on.
  ///
  /// An offer is only evidence once the user has had the chance to act on it,
  /// so rows from the feed still on screen are left for next time. Twenty
  /// minutes is generous — a session is usually shorter — and it is a
  /// parameter rather than a constant so a test can ask for the rows without
  /// waiting for the clock.
  Future<List<RankingExample>> takeRankingExamples({
    int limit = 500,
    Duration settle = const Duration(minutes: 20),
  }) async {
    final cutoff =
        DateTime.now().subtract(_exampleMemory).millisecondsSinceEpoch;
    await _db.delete(
      'ranking_examples',
      where: 'shown_at < ?',
      whereArgs: [cutoff],
    );

    final settled = DateTime.now().subtract(settle).millisecondsSinceEpoch;
    final rows = await _db.query(
      'ranking_examples',
      where: 'shown_at < ?',
      whereArgs: [settled],
      orderBy: 'shown_at ASC',
      limit: limit,
    );
    if (rows.isEmpty) return const [];
    // Exactly the rows read, so a backlog larger than [limit] is trained on
    // over several passes instead of having its tail deleted unseen. Deleting
    // by the same `shown_at` predicate the query used looks equivalent and is
    // not: the query is capped and the delete was not.
    final consumed = [for (final r in rows) r['video_id']! as String];

    final out = <RankingExample>[];
    for (final r in rows) {
      final raw = (r['features'] as String?) ?? '';
      final features = <double>[];
      for (final part in raw.split(',')) {
        final value = double.tryParse(part);
        // A row we cannot read is skipped rather than fed in as zeros, which
        // would train the model on a video that looked like nothing.
        if (value == null || !value.isFinite) {
          features.clear();
          break;
        }
        features.add(value);
      }
      if (features.isEmpty) continue;
      out.add(
        RankingExample(
          features: features,
          opened: (r['opened'] as int? ?? 0) == 1,
          completion: (r['completion'] as num?)?.toDouble() ?? 0,
        ),
      );
    }

    await _db.delete(
      'ranking_examples',
      where: 'video_id IN (${List.filled(consumed.length, '?').join(',')})',
      whereArgs: consumed,
    );
    return out;
  }

  Future<void> clearRankerLearning() async {
    await _db.delete('ranking_examples');
    await _db.delete('covisit');
  }

  /// Builds the ranking profile from everything this device knows.
  ///
  /// Lives here rather than in each screen so Home and the watch page rank
  /// against exactly the same view of the user — two screens deriving "what
  /// this person likes" from different queries is how a feed and its own
  /// Up-next list come to disagree about the same channel.
  ///
  /// Cheap: three indexed reads and a few hundred multiplications. It is
  /// rebuilt per load rather than cached because a profile that does not
  /// include what was watched five minutes ago is the stale-recommendations
  /// bug the Home screen already had once.
  Future<TasteProfile> tasteProfile({
    DateTime? now,
    List<String> coVisitSeeds = const [],
  }) async {
    final history = await watchSignals();
    final searches = await searchSignals();
    final subs = await subscriptions();
    final dismissed = await notInterested();
    // Seeds default to the most recent watches, which is what the home feed
    // wants; the watch page passes the video being watched instead.
    final seeds = coVisitSeeds.isNotEmpty
        ? coVisitSeeds
        : [for (final w in history.take(8)) w.videoId];
    final coVisit = await coVisitScores(seeds);
    return TasteProfile.from(
      history: history,
      searches: searches,
      subscribed: {for (final c in subs) c.id},
      now: now ?? DateTime.now(),
      dislikedChannels: dismissed.channels,
      dislikedVideos: dismissed.videos,
      coVisit: coVisit,
      endorsedChannels: await endorsedChannels(),
    );
  }

  /// Channels the user saved a video from, or downloaded one from.
  ///
  /// The local stand-in for YouTube's like and share signals, and arguably a
  /// stronger one: saving something for later or spending storage on it is not
  /// the reflex a tap on a thumb is.
  Future<Set<String>> endorsedChannels() async {
    // Single quotes. In SQL a double-quoted token is an IDENTIFIER, and this
    // only behaved because SQLite falls back to treating one as a string when
    // no such column exists — a documented misfeature, not a guarantee, and
    // one that silently changes meaning the day a column is named oddly.
    final rows = await _db.rawQuery(
      "SELECT DISTINCT channel_id FROM playlist_items "
      "WHERE channel_id != '' "
      "UNION "
      "SELECT DISTINCT channel_id FROM downloads WHERE channel_id != ''",
    );
    return {for (final r in rows) r['channel_id']! as String};
  }

  /// Counts one showing for each entry of [seen], mapping video id to how much
  /// of the user's attention that showing had — see
  /// [attentionAtRank] and the shallow-tower note on [ImpressionCount].
  ///
  /// Called when a card is actually on screen, never when a feed is merely
  /// fetched: a video the user never laid eyes on has not been offered to
  /// them, and counting it would demote it for nothing.
  ///
  /// Batched into a single transaction because a feed is a hundred rows and a
  /// hundred separate writes on the UI isolate is visible as a stutter.
  Future<void> recordImpressions(Map<String, double> seen) async {
    if (seen.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = _db.batch();
    for (final entry in seen.entries) {
      if (entry.key.isEmpty) continue;
      batch.rawInsert('''
        INSERT INTO feed_impressions (video_id, shown, attention, last_shown_at)
        VALUES (?, 1, ?, ?)
        ON CONFLICT(video_id) DO UPDATE SET
          shown = shown + 1,
          attention = attention + excluded.attention,
          last_shown_at = excluded.last_shown_at
      ''', [entry.key, entry.value, now]);
    }
    await batch.commit(noResult: true);
  }

  /// Impression counts for the ranker, keyed by video id.
  ///
  /// Rows older than [ImpressionCount] cares about are deleted here rather
  /// than on a schedule: this runs once per feed load, the table is small, and
  /// a video passed over a fortnight ago deserves another chance anyway. Doing
  /// it as part of the read means there is no separate cleanup that can be
  /// forgotten.
  Future<Map<String, ImpressionCount>> feedImpressions() async {
    final cutoff = DateTime.now()
        .subtract(impressionMemory)
        .millisecondsSinceEpoch;
    await _db.delete(
      'feed_impressions',
      where: 'last_shown_at < ?',
      whereArgs: [cutoff],
    );
    final rows = await _db.query('feed_impressions');
    return {
      for (final r in rows)
        r['video_id']! as String: ImpressionCount(
          videoId: r['video_id']! as String,
          shown: r['shown'] as int? ?? 0,
          attention: (r['attention'] as num?)?.toDouble(),
          lastShownAt: DateTime.fromMillisecondsSinceEpoch(
            r['last_shown_at']! as int,
          ),
        ),
    };
  }

  /// Records an explicit dismissal.
  ///
  /// [title] is only meaningful for a video, where its words let the dismissal
  /// generalise a little; a channel dismissal needs nothing but the id.
  Future<void> addNotInterested({
    required String id,
    required DislikeKind kind,
    String title = '',
  }) async {
    if (id.isEmpty) return;
    await _db.insert(
      'not_interested',
      {
        'id': id,
        'kind': kind.name,
        'title': title,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Undoes one dismissal, for the snackbar's Undo.
  ///
  /// Worth having rather than making the user live with a mis-tap: a dismissal
  /// is deliberately near-absolute in the ranker, so an accidental one would
  /// otherwise silently remove a channel from the feed for good with no way
  /// back short of the settings screen.
  Future<void> removeNotInterested({
    required String id,
    required DislikeKind kind,
  }) =>
      _db.delete(
        'not_interested',
        where: 'id = ? AND kind = ?',
        whereArgs: [id, kind.name],
      );

  Future<bool> isNotInterested({
    required String id,
    required DislikeKind kind,
  }) async {
    final rows = await _db.query(
      'not_interested',
      columns: ['id'],
      where: 'id = ? AND kind = ?',
      whereArgs: [id, kind.name],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> clearNotInterested() => _db.delete('not_interested');

  /// Everything dismissed, split by kind, for [tasteProfile].
  Future<({Set<String> channels, List<WatchSignal> videos})>
      notInterested() async {
    final rows = await _db.query('not_interested');
    final channels = <String>{};
    final videos = <WatchSignal>[];
    for (final r in rows) {
      final id = r['id']! as String;
      if (r['kind'] == DislikeKind.channel.name) {
        channels.add(id);
      } else {
        // Reused as the carrier for "an id and a title" rather than inventing
        // a second shape for the same two fields; the ranker only reads those.
        videos.add(
          WatchSignal(
            videoId: id,
            channelId: '',
            title: (r['title'] as String?) ?? '',
            watchedAt: DateTime.fromMillisecondsSinceEpoch(
              r['created_at']! as int,
            ),
            completion: 0,
          ),
        );
      }
    }
    return (channels: channels, videos: videos);
  }

  Future<void> clearFeedImpressions() => _db.delete('feed_impressions');

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

  /// Clearing watch history also clears the feed impressions it is ranked
  /// against. They are the same kind of record - "what this device has seen" -
  /// and leaving them behind would keep demoting videos on the strength of a
  /// history the user has just asked to be rid of.
  Future<void> clearHistory() async {
    await _db.delete('history');
    await _db.delete('feed_impressions');
    // The co-visitation graph and the untrained examples are both derived from
    // history. Keeping them would let a cleared history go on shaping the feed
    // through the back door, which is not what "clear watch history" promises.
    await clearRankerLearning();
  }

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
