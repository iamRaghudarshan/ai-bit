// Exercises the persistence layer against a real SQLite engine.
//
// WHY THIS EXISTS. Everything in `unit_test.dart` is pure by design, which
// means the one part of this app that had never been executed anywhere was its
// SQL — neither platform builds on the development machine, so a broken query
// would first run on a user's phone. The day this file was written it found
// two real defects on its first run: a `!= ""` that SQLite only treats as a
// string literal by a documented misfeature, and a delete that removed more
// rows than the query above it had read.
//
// It is deliberately about the queries and the MIGRATIONS rather than about
// business logic — schema v11 means eleven upgrade paths, and the one thing
// that cannot be checked by reading is whether an install from two years ago
// still opens.

import 'dart:io';

import 'package:ai_bit/src/data/db.dart';
import 'package:ai_bit/src/data/models.dart';
import 'package:ai_bit/src/data/recommender.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  // These tests need a real sqlite3 library on the machine running them, which
  // every developer and CI image this project uses has — but if one ever does
  // not, the right outcome is "the database tests did not run", not a red
  // release that blocks a build for a missing system package. Same reasoning
  // as release.yml skipping the iOS job when the Apple secrets are absent: a
  // workflow that is red for something you chose not to do teaches people to
  // ignore it being red.
  final unavailable = _sqliteUnavailable();

  late Directory dir;
  late AppDatabase db;
  var counter = 0;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('aibit-db-test');
    db = await AppDatabase.open(
      path: '${dir.path}/test-${counter++}.db',
      factory: databaseFactoryFfi,
    );
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  VideoBrief video(
    String id, {
    String channel = 'UC-a',
    String title = 'a title',
    Duration duration = const Duration(minutes: 10),
  }) =>
      VideoBrief(
        id: id,
        title: title,
        author: 'Author',
        channelId: channel,
        duration: duration,
      );

  group('schema', skip: unavailable, () {
    test('a fresh install opens and seeds Watch later', () async {
      final playlists = await db.playlists();
      expect(playlists, isNotEmpty);
      expect(playlists.first.id, LocalPlaylist.watchLaterId);
      expect(playlists.first.name, 'Watch later');
    });

    test('every table the app writes to exists', () async {
      // A table missing from onCreate but present in onUpgrade — or the other
      // way round — is the recurring bug this schema has had, and it fails at
      // the first write rather than at open.
      for (final id in ['a', 'b']) {
        await db.recordWatch(video(id));
      }
      await db.recordSearch('a query');
      await db.subscribe(
        const ChannelInfo(id: 'UC-a', title: 'Author'),
      );
      await db.addToPlaylist(LocalPlaylist.watchLaterId, video('a'));
      await db.addDataUsage(
        day: 1,
        channelId: 'UC-a',
        channelTitle: 'Author',
        bytes: 10,
        kind: 'stream',
      );
      await db.addKidsSeconds(1, 30);
      await db.recordImpressions({'a': 1});
      await db.addNotInterested(id: 'b', kind: DislikeKind.video, title: 't');
      await db.recordCoVisits('a', ['b']);
      await db.recordRankingExamples({
        'a': [1, 1, 1, 1, 1, 1, 1],
      });
      // Nothing above threw, which is the assertion.
      expect(await db.historyCount(), 2);
    });
  });

  group('VideoBrief round trip through every table that stores one', skip: unavailable, () {
    test('history, downloads and playlist_items all accept the same map',
        () async {
      // The shared toMap() is why a column added for one table has twice
      // broken the other two. Writing to all three is the cheapest guard.
      final v = video('shared').asShort().asKids();
      await db.recordWatch(v);
      await db.addToPlaylist(LocalPlaylist.watchLaterId, v);
      await db.saveDownload(
        DownloadRecord(
          video: v,
          filePath: '/tmp/x.mp4',
          quality: '360p',
          audioOnly: false,
          totalBytes: 1,
          receivedBytes: 1,
          status: DownloadStatus.completed,
        ),
      );

      final history = await db.history(shorts: true, kids: true);
      expect(history.single.video.id, 'shared');
      expect(history.single.video.isShort, isTrue);
      expect(history.single.video.isKids, isTrue);
      expect((await db.downloads()).single.video.isShort, isTrue);
      expect(
        (await db.playlistItems(LocalPlaylist.watchLaterId)).single.isKids,
        isTrue,
      );
    });
  });

  group('feed impressions', skip: unavailable, () {
    test('counts showings and accumulates attention', () async {
      await db.recordImpressions({'a': 1.0});
      await db.recordImpressions({'a': 0.5});
      final rows = await db.feedImpressions();
      expect(rows['a']!.shown, 2);
      expect(rows['a']!.attention, closeTo(1.5, 1e-9));
    });

    test('a card seen at the bottom is worth less than one at the top',
        () async {
      await db.recordImpressions({'top': attentionAtRank(0)});
      await db.recordImpressions({'bottom': attentionAtRank(40)});
      final rows = await db.feedImpressions();
      expect(rows['bottom']!.attention, lessThan(rows['top']!.attention));
    });

    test('clearing history clears them too', () async {
      await db.recordImpressions({'a': 1});
      await db.clearHistory();
      expect(await db.feedImpressions(), isEmpty);
    });
  });

  group('not interested', skip: unavailable, () {
    test('records, reads back split by kind, and undoes', () async {
      await db.addNotInterested(
        id: 'v1',
        kind: DislikeKind.video,
        title: 'a bad video',
      );
      await db.addNotInterested(id: 'UC-x', kind: DislikeKind.channel);

      var dismissed = await db.notInterested();
      expect(dismissed.channels, {'UC-x'});
      expect(dismissed.videos.single.videoId, 'v1');
      expect(dismissed.videos.single.title, 'a bad video');
      expect(
        await db.isNotInterested(id: 'v1', kind: DislikeKind.video),
        isTrue,
      );

      await db.removeNotInterested(id: 'v1', kind: DislikeKind.video);
      dismissed = await db.notInterested();
      expect(dismissed.videos, isEmpty);
      expect(dismissed.channels, {'UC-x'});
    });

    test('a video and a channel may share an id without colliding', () async {
      // The primary key is (id, kind). It is not inconceivable for an id to
      // appear as both, and a single-column key would silently overwrite.
      await db.addNotInterested(id: 'same', kind: DislikeKind.video);
      await db.addNotInterested(id: 'same', kind: DislikeKind.channel);
      final dismissed = await db.notInterested();
      expect(dismissed.channels, {'same'});
      expect(dismissed.videos, hasLength(1));
    });

    test('it reaches the taste profile', () async {
      await db.addNotInterested(id: 'UC-bad', kind: DislikeKind.channel);
      final profile = await db.tasteProfile();
      expect(profile.dislikedChannels, contains('UC-bad'));
    });
  });

  group('co-visitation graph', skip: unavailable, () {
    test('a related list becomes position-weighted edges', () async {
      await db.recordCoVisits('seed', ['first', 'second', 'third']);
      final scores = await db.coVisitScores(['seed']);
      expect(scores['first'], greaterThan(scores['second']!));
      expect(scores['second'], greaterThan(scores['third']!));
    });

    test('a video never links to itself', () async {
      await db.recordCoVisits('seed', ['seed', 'other']);
      final scores = await db.coVisitScores(['seed']);
      expect(scores.containsKey('seed'), isFalse);
      expect(scores['other'], greaterThan(0));
    });

    test('seeing the same list again strengthens the edge', () async {
      await db.recordCoVisits('seed', ['other']);
      final first = (await db.coVisitScores(['seed']))['other']!;
      await db.recordCoVisits('seed', ['other']);
      final second = (await db.coVisitScores(['seed']))['other']!;
      expect(second, greaterThan(first));
    });

    test('an edge cannot grow without bound', () async {
      for (var i = 0; i < 40; i++) {
        await db.recordCoVisits('seed', ['other']);
      }
      expect((await db.coVisitScores(['seed']))['other'], lessThanOrEqualTo(12));
    });

    test('what the user did themselves outweighs a borrowed edge', () async {
      await db.recordCoVisits('seed', ['listed']);
      await db.recordWatchTransition('seed', 'watched');
      final scores = await db.coVisitScores(['seed']);
      expect(scores['watched'], greaterThan(scores['listed']!));
    });

    test('agreement across several seeds sums', () async {
      await db.recordCoVisits('s1', ['shared']);
      await db.recordCoVisits('s2', ['shared']);
      await db.recordCoVisits('s3', ['lonely']);
      final scores = await db.coVisitScores(['s1', 's2', 's3']);
      expect(scores['shared'], greaterThan(scores['lonely']!));
    });

    test('no seeds means no query rather than a broken one', () async {
      expect(await db.coVisitScores([]), isEmpty);
      expect(await db.coVisitScores(['']), isEmpty);
    });

    test('a transition to itself is ignored', () async {
      await db.recordWatchTransition('a', 'a');
      expect(await db.coVisitScores(['a']), isEmpty);
    });

    test('clearing history clears the graph', () async {
      await db.recordCoVisits('seed', ['other']);
      await db.clearHistory();
      expect(await db.coVisitScores(['seed']), isEmpty);
    });
  });

  group('ranking examples', skip: unavailable, () {
    List<double> features() => [1, 0.5, 0.5, 0.5, 0.5, 0, 0];
    // Zero settle: the window exists so the user has had a chance to act, and
    // a test should not have to wait twenty minutes to assert on the storage.
    const now = Duration.zero;

    test('an unsettled example is left for next time', () async {
      await db.recordRankingExamples({'a': features()});
      expect(await db.takeRankingExamples(), isEmpty);
      expect(await db.takeRankingExamples(settle: now), hasLength(1));
    });

    test('a label only sticks to a video that was actually offered', () async {
      // A video reached from search or a channel page was never a
      // recommendation, so it is not evidence about the ranker's judgement.
      await db.recordRankingExamples({'offered': features()});
      await db.markExampleOpened('never-offered', 1);
      await db.markExampleOpened('offered', 0.8);

      final taken = await db.takeRankingExamples(settle: now);
      expect(taken, hasLength(1));
      expect(taken.single.opened, isTrue);
      expect(taken.single.completion, closeTo(0.8, 1e-9));
      expect(taken.single.features, features());
    });

    test('an unopened example reads back as a negative', () async {
      await db.recordRankingExamples({'a': features()});
      final taken = await db.takeRankingExamples(settle: now);
      expect(taken.single.opened, isFalse);
      expect(taken.single.completion, 0);
    });

    test('re-offering a video does not create a second observation', () async {
      await db.recordRankingExamples({'a': features()});
      await db.recordRankingExamples({
        'a': [9, 9, 9, 9, 9, 9, 9],
      });
      final taken = await db.takeRankingExamples(settle: now);
      expect(taken, hasLength(1));
      // The FIRST offer is the one the user reacted to.
      expect(taken.single.features, features());
    });

    test('a backlog larger than the limit is not thrown away', () async {
      // The defect this pins: the query was capped at `limit` and the delete
      // below it was not, so with more settled rows than the cap the tail was
      // removed without ever being trained on.
      for (var i = 0; i < 12; i++) {
        await db.recordRankingExamples({'v$i': features()});
      }
      expect(await db.takeRankingExamples(limit: 5, settle: now), hasLength(5));
      expect(await db.takeRankingExamples(limit: 5, settle: now), hasLength(5));
      expect(await db.takeRankingExamples(limit: 5, settle: now), hasLength(2));
      expect(await db.takeRankingExamples(settle: now), isEmpty);
    });

    test('training consumes each example exactly once', () async {
      await db.recordRankingExamples({'a': features()});
      expect(await db.takeRankingExamples(settle: now), hasLength(1));
      expect(await db.takeRankingExamples(settle: now), isEmpty);
    });

    test('an unreadable row is skipped rather than trained on as zeros',
        () async {
      // Zeros would teach the model that a video which looked like nothing was
      // rejected, which is worse than learning nothing from it.
      await db.recordRankingExamples({
        'bad': [1, double.nan, 1, 1, 1, 1, 1],
        'good': features(),
      });
      final taken = await db.takeRankingExamples(settle: now);
      expect(taken, hasLength(1));
      expect(taken.single.features, features());
    });

    test('clearing history clears them', () async {
      await db.recordRankingExamples({'a': features()});
      await db.clearHistory();
      expect(await db.takeRankingExamples(settle: now), isEmpty);
    });
  });

  group('endorsement', skip: unavailable, () {
    test('saving to a playlist endorses the channel', () async {
      await db.addToPlaylist(
        LocalPlaylist.watchLaterId,
        video('a', channel: 'UC-saved'),
      );
      expect(await db.endorsedChannels(), contains('UC-saved'));
    });

    test('downloading endorses it too', () async {
      await db.saveDownload(
        DownloadRecord(
          video: video('b', channel: 'UC-downloaded'),
          filePath: '/tmp/b.mp4',
          quality: '360p',
          audioOnly: false,
          totalBytes: 1,
          receivedBytes: 1,
          status: DownloadStatus.completed,
        ),
      );
      expect(await db.endorsedChannels(), contains('UC-downloaded'));
    });

    test('merely watching does not', () async {
      await db.recordWatch(video('c', channel: 'UC-watched'));
      expect(await db.endorsedChannels(), isNot(contains('UC-watched')));
    });

    test('it reaches the taste profile and lifts satisfaction', () async {
      // The channel is watched badly but saved from, so the floor should show.
      await db.recordWatch(
        video('d', channel: 'UC-mixed'),
        position: const Duration(seconds: 30),
      );
      await db.addToPlaylist(
        LocalPlaylist.watchLaterId,
        video('e', channel: 'UC-mixed'),
      );
      final profile = await db.tasteProfile();
      expect(profile.endorsedChannels, contains('UC-mixed'));
      expect(profile.satisfactionFor('UC-mixed'), greaterThan(0.7));
    });
  });

  group('watch signals feed the profile correctly', skip: unavailable, () {
    test('completion comes from position over duration', () async {
      await db.recordWatch(
        video('a', duration: const Duration(minutes: 10)),
        position: const Duration(minutes: 9),
      );
      final signals = await db.watchSignals();
      expect(signals.single.completion, closeTo(0.9, 1e-9));
    });

    test('Kids rows are excluded from the ranking profile', () async {
      // Ranking a child's viewing into the adult's feed is the thing that
      // must not happen, and it is one WHERE clause away from happening.
      await db.recordWatch(video('kid').asKids());
      await db.recordWatch(video('adult'));
      final signals = await db.watchSignals();
      expect(signals.map((s) => s.videoId), ['adult']);
    });

    test('an imported row keeps the time it was really watched', () async {
      final then = DateTime(2020, 5, 4, 12);
      await db.importWatch(video('old'), then);
      final signals = await db.watchSignals();
      expect(signals.single.watchedAt, then);
    });
  });

  group('migrations', skip: unavailable, () {
    test('an install from schema v1 upgrades all the way to current',
        () async {
      // The real risk this schema carries: a table added to onCreate but not
      // to onUpgrade, or the reverse. Reading cannot catch it; opening can.
      final path = '${dir.path}/legacy.db';
      final legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (d, _) async {
            await d.execute('''
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
                position_ms  INTEGER NOT NULL DEFAULT 0,
                watched_at   INTEGER NOT NULL
              )
            ''');
            await d.execute('''
              CREATE TABLE playlists (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                name       TEXT NOT NULL,
                created_at INTEGER NOT NULL
              )
            ''');
            await d.execute('''
              CREATE TABLE playlist_items (
                playlist_id INTEGER NOT NULL
                  REFERENCES playlists(id) ON DELETE CASCADE,
                video_id    TEXT NOT NULL,
                title       TEXT NOT NULL,
                author      TEXT NOT NULL,
                channel_id  TEXT NOT NULL,
                duration_ms INTEGER,
                view_count  INTEGER,
                upload_raw  TEXT,
                upload_date INTEGER,
                is_live     INTEGER NOT NULL DEFAULT 0,
                added_at    INTEGER NOT NULL,
                PRIMARY KEY (playlist_id, video_id)
              )
            ''');
            await d.insert('playlists', {
              'id': LocalPlaylist.watchLaterId,
              'name': 'Watch later',
              'created_at': DateTime.now().millisecondsSinceEpoch,
            });
            await d.insert('history', {
              'video_id': 'ancient',
              'title': 'Watched years ago',
              'author': 'Author',
              'channel_id': 'UC-old',
              'is_live': 0,
              'position_ms': 0,
              'watched_at': DateTime(2021).millisecondsSinceEpoch,
            });
          },
        ),
      );
      await legacy.close();

      final upgraded =
          await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      try {
        // The old row survived.
        expect(await upgraded.historyCount(), 1);
        // And every table added since v1 now works.
        await upgraded.recordImpressions({'x': 1});
        await upgraded.recordCoVisits('x', ['y']);
        await upgraded.addNotInterested(id: 'z', kind: DislikeKind.video);
        await upgraded.addDataUsage(
          day: 1,
          channelId: 'UC-a',
          channelTitle: 'a',
          bytes: 1,
          kind: 'stream',
        );
        await upgraded.addKidsSeconds(1, 1);
        await upgraded.recordRankingExamples({
          'x': [1, 1, 1, 1, 1, 1, 1],
        });
        // v7's bug specifically: downloads and playlist_items gaining the
        // columns VideoBrief.toMap() emits.
        await upgraded.addToPlaylist(
          LocalPlaylist.watchLaterId,
          video('p').asShort(),
        );
        await upgraded.saveDownload(
          DownloadRecord(
            video: video('d').asShort(),
            filePath: '/tmp/d.mp4',
            quality: '360p',
            audioOnly: false,
            totalBytes: 1,
            receivedBytes: 1,
            status: DownloadStatus.completed,
          ),
        );
        expect((await upgraded.downloads()).single.video.isShort, isTrue);
      } finally {
        await upgraded.close();
      }
    });

    test('an install from v9 gains the attention column with its old count',
        () async {
      // Back-filling at full weight is deliberate: it keeps the penalty a row
      // already carried rather than silently forgiving it.
      final path = '${dir.path}/v9.db';
      final legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 9,
          onCreate: (d, _) async {
            await d.execute('''
              CREATE TABLE feed_impressions (
                video_id      TEXT PRIMARY KEY,
                shown         INTEGER NOT NULL DEFAULT 0,
                last_shown_at INTEGER NOT NULL
              )
            ''');
            await d.insert('feed_impressions', {
              'video_id': 'a',
              'shown': 3,
              'last_shown_at': DateTime.now().millisecondsSinceEpoch,
            });
          },
        ),
      );
      await legacy.close();

      final upgraded =
          await AppDatabase.open(path: path, factory: databaseFactoryFfi);
      try {
        final rows = await upgraded.feedImpressions();
        expect(rows['a']!.shown, 3);
        expect(rows['a']!.attention, 3.0);
      } finally {
        await upgraded.close();
      }
    });
  });
}

/// Returns a skip reason when sqlite3 cannot be loaded here, or null when it
/// can. Probed once rather than assumed, because the failure is a native
/// library load and surfaces as an exception from the first open rather than
/// as anything checkable in Dart.
String? _sqliteUnavailable() {
  try {
    databaseFactoryFfi.openDatabase(inMemoryDatabasePath).ignore();
    return null;
  } catch (e) {
    return 'sqlite3 is not available on this machine: $e';
  }
}
