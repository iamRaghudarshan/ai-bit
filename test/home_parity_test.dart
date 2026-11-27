// Pure rules behind the YouTube-parity home feed, plus the one query it adds.
//
// Kept in its own file because several pieces of the app were being changed
// at once when it was written; the rules are the kind that look obviously
// right and are wrong on one shape — a feed of one card, a download whose
// size is not known yet, a preview a tick past its rounded duration.

import 'dart:io';

import 'package:ai_bit/src/data/db.dart';
import 'package:ai_bit/src/data/models.dart';
import 'package:ai_bit/src/ui/widgets/feed_preview.dart';
import 'package:ai_bit/src/ui/widgets/responsive_feed.dart';
import 'package:ai_bit/src/ui/widgets/sheets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

VideoBrief _video(String id, {Duration? duration = const Duration(minutes: 10)}) =>
    VideoBrief(
      id: id,
      title: 'title $id',
      author: 'Author',
      channelId: 'UC-a',
      duration: duration,
    );

DownloadRecord _record(DownloadStatus status, {int total = 0, int got = 0}) =>
    DownloadRecord(
      video: _video('d'),
      filePath: '/x',
      quality: '360p',
      audioOnly: false,
      totalBytes: total,
      receivedBytes: got,
      status: status,
    );

void main() {
  group('watchedFraction (the resume bar)', () {
    test('a plain fraction', () {
      expect(watchedFraction(30000, 120000), closeTo(0.25, 1e-9));
    });
    test('unknown or nonsensical sides draw nothing', () {
      expect(watchedFraction(null, 1000), 0);
      expect(watchedFraction(1000, null), 0);
      expect(watchedFraction(0, 1000), 0);
      expect(watchedFraction(1000, 0), 0);
      expect(watchedFraction(-5, 1000), 0);
    });
    test('a position a tick past the duration clamps to full', () {
      expect(watchedFraction(120500, 120000), 1.0);
    });
  });

  group('insertSlot (the Shorts shelf after the second card)', () {
    test('after two cards when the feed reaches that far', () {
      expect(insertSlot(20, 2, hasInsert: true), 2);
      expect(insertSlot(2, 2, hasInsert: true), 2);
    });
    test('nothing to insert, or too short a feed, is no slot', () {
      expect(insertSlot(20, 2, hasInsert: false), isNull);
      expect(insertSlot(1, 2, hasInsert: true), isNull);
      expect(insertSlot(0, 2, hasInsert: true), isNull);
    });
  });

  group('downloadMenuState (the menu row label)', () {
    test('not downloaded', () {
      final s = downloadMenuState(null, active: false);
      expect(s.kind, DownloadMenuKind.none);
      expect(s.label, 'Download video');
    });
    test('downloaded', () {
      final s =
          downloadMenuState(_record(DownloadStatus.completed), active: false);
      expect(s.kind, DownloadMenuKind.done);
      expect(s.label, 'Downloaded');
    });
    test('running shows a whole percentage, rounded down', () {
      final s = downloadMenuState(
        _record(DownloadStatus.running, total: 1000, got: 429),
        active: true,
      );
      expect(s.kind, DownloadMenuKind.active);
      expect(s.label, 'Downloading 42%');
    });
    test('running with the size not known yet does not claim 0%', () {
      final s = downloadMenuState(_record(DownloadStatus.running), active: true);
      expect(s.label, 'Downloading…');
    });
    test('queued says so', () {
      final s = downloadMenuState(_record(DownloadStatus.queued), active: true);
      expect(s.label, 'Download queued');
    });
    test('a failed record offers a fresh download', () {
      final s = downloadMenuState(_record(DownloadStatus.failed), active: false);
      expect(s.kind, DownloadMenuKind.none);
    });
  });

  group('preview overlay', () {
    test('fraction and countdown', () {
      const total = Duration(minutes: 2);
      expect(previewFraction(const Duration(seconds: 30), total),
          closeTo(0.25, 1e-9));
      expect(previewRemaining(const Duration(seconds: 30), total),
          const Duration(seconds: 90));
    });
    test('unknown length: no bar, no badge', () {
      expect(previewFraction(const Duration(seconds: 3), null), 0);
      expect(previewRemaining(const Duration(seconds: 3), null), isNull);
    });
    test('never a negative countdown', () {
      expect(
        previewRemaining(const Duration(seconds: 121), const Duration(minutes: 2)),
        Duration.zero,
      );
    });
  });

  group('watchProgress query', skip: _sqliteUnavailable(), () {
    late Directory dir;
    late AppDatabase db;

    setUp(() async {
      sqfliteFfiInit();
      dir = await Directory.systemTemp.createTemp('aibit-progress-test');
      db = await AppDatabase.open(
        path: '${dir.path}/p.db',
        factory: databaseFactoryFfi,
      );
    });

    tearDown(() async {
      await db.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('one query returns a fraction per watched id, and only those',
        () async {
      await db.recordWatch(_video('a'), position: const Duration(minutes: 5));
      await db.recordWatch(_video('b')); // opened, no position yet
      await db.recordWatch(
        _video('c', duration: null),
        position: const Duration(minutes: 1),
      ); // no duration: nothing to draw against
      final got = await db.watchProgress(['a', 'b', 'c', 'never-seen']);
      expect(got.keys, ['a']);
      expect(got['a'], closeTo(0.5, 1e-9));
    });

    test('more ids than one chunk still come back', () async {
      await db.recordWatch(_video('z'), position: const Duration(minutes: 1));
      final ids = [for (var i = 0; i < 1200; i++) 'id$i', 'z'];
      final got = await db.watchProgress(ids);
      expect(got.keys, ['z']);
    });

    test('an empty feed asks nothing', () async {
      expect(await db.watchProgress(const []), isEmpty);
    });
  });
}

String? _sqliteUnavailable() {
  try {
    sqfliteFfiInit();
    databaseFactoryFfi.openDatabase(inMemoryDatabasePath).ignore();
    return null;
  } catch (e) {
    return 'sqlite3 is not available on this machine: $e';
  }
}
