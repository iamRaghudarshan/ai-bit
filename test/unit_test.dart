import 'package:ai_bit/src/core/chapters.dart';
import 'package:ai_bit/src/core/format.dart';
import 'package:ai_bit/src/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('compactCount', () {
    test('leaves small numbers alone', () {
      expect(compactCount(0), '0');
      expect(compactCount(999), '999');
    });

    test('abbreviates thousands, millions and billions', () {
      expect(compactCount(1000), '1K');
      expect(compactCount(1500), '1.5K');
      expect(compactCount(12300), '12K');
      expect(compactCount(2400000), '2.4M');
      expect(compactCount(3200000000), '3.2B');
    });

    test('renders nothing for a missing count', () {
      expect(compactCount(null), '');
    });
  });

  group('clockLabel', () {
    test('drops the hour segment for short videos', () {
      expect(clockLabel(const Duration(seconds: 5)), '0:05');
      expect(clockLabel(const Duration(minutes: 12, seconds: 7)), '12:07');
    });

    test('zero-pads minutes once hours are shown', () {
      expect(
        clockLabel(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03',
      );
    });
  });

  group('metaLine', () {
    test('joins only the non-empty parts', () {
      expect(metaLine(['Channel', '', '2 days ago']), 'Channel • 2 days ago');
    });
  });

  group('HistoryEntry.progress', () {
    VideoBrief video(Duration? duration) => VideoBrief(
      id: 'abcdefghijk',
      title: 'T',
      author: 'A',
      channelId: 'C',
      duration: duration,
    );

    test('is the watched fraction', () {
      final entry = HistoryEntry(
        video: video(const Duration(minutes: 10)),
        position: const Duration(minutes: 2, seconds: 30),
        watchedAt: DateTime(2026),
      );
      expect(entry.progress, closeTo(0.25, 1e-9));
    });

    test('is zero when the duration is unknown', () {
      final entry = HistoryEntry(
        video: video(null),
        position: const Duration(minutes: 3),
        watchedAt: DateTime(2026),
      );
      expect(entry.progress, 0);
    });
  });

  group('VideoBrief round trip', () {
    test('survives a SQLite map conversion', () {
      final original = VideoBrief(
        id: 'dQw4w9WgXcQ',
        title: 'Title',
        author: 'Author',
        channelId: 'UC123',
        duration: const Duration(minutes: 3, seconds: 33),
        viewCount: 1234,
        uploadDate: DateTime.utc(2026, 5, 1),
        uploadRaw: '3 months ago',
        isLive: true,
      );
      final restored = VideoBrief.fromMap(original.toMap());

      expect(restored.id, original.id);
      expect(restored.title, original.title);
      expect(restored.duration, original.duration);
      expect(restored.viewCount, original.viewCount);
      expect(restored.uploadDate, original.uploadDate);
      expect(restored.isLive, isTrue);
    });
  });

  group('parseChapters', () {
    test('reads a normal chapter list', () {
      final chapters = parseChapters('''
Some blurb about the video.

0:00 Intro
1:30 The setup
12:05 The payoff
1:02:10 Outro
''');
      expect(chapters.length, 4);
      expect(chapters.first.start, Duration.zero);
      expect(chapters.first.title, 'Intro');
      expect(chapters[2].start, const Duration(minutes: 12, seconds: 5));
      expect(
        chapters.last.start,
        const Duration(hours: 1, minutes: 2, seconds: 10),
      );
    });

    test('ignores a list that does not start at zero', () {
      // YouTube itself refuses these, so accepting them would put a chapter
      // track on a video that has none.
      expect(parseChapters('1:00 A\n2:00 B\n3:00 C'), isEmpty);
    });

    test('ignores fewer than three timestamps', () {
      expect(parseChapters('0:00 Intro\n1:00 End'), isEmpty);
    });

    test('ignores timestamps that go backwards', () {
      // A tracklist for something else, not chapters for this video.
      final chapters = parseChapters('0:00 A\n5:00 B\n2:00 C\n9:00 D');
      expect(chapters.map((c) => c.title).toList(), ['A', 'B', 'D']);
    });

    test('handles bracketed and dash-separated forms', () {
      final chapters = parseChapters(
        '(0:00) - Start\n(0:45) - Middle\n(2:00) - End',
      );
      expect(chapters.length, 3);
      expect(chapters[1].title, 'Middle');
    });

    test('returns nothing for a description with no timestamps', () {
      expect(parseChapters('Just a normal description.'), isEmpty);
    });
  });

  group('chapterAt', () {
    test('finds the chapter covering a position', () {
      final chapters = parseChapters('0:00 A\n1:00 B\n2:00 C');
      expect(chapterAt(chapters, const Duration(seconds: 30))?.title, 'A');
      expect(chapterAt(chapters, const Duration(seconds: 90))?.title, 'B');
      expect(chapterAt(chapters, const Duration(minutes: 5))?.title, 'C');
    });

    test('returns null when there are no chapters', () {
      expect(chapterAt(const [], Duration.zero), isNull);
    });
  });

  group('formatDateTime', () {
    test('renders dd-MM-yyyy with a 12-hour clock', () {
      expect(
        formatDateTime(DateTime(2026, 8, 5, 15, 56)),
        '05-08-2026 03:56 PM',
      );
      expect(
        formatDateTime(DateTime(2026, 12, 25, 9, 5)),
        '25-12-2026 09:05 AM',
      );
    });

    test('renders both midnights as 12, not 00', () {
      expect(formatDateTime(DateTime(2026, 1, 1, 0, 30)), '01-01-2026 12:30 AM');
      expect(formatDateTime(DateTime(2026, 1, 1, 12, 30)), '01-01-2026 12:30 PM');
    });

    test('is empty for a missing date', () {
      expect(formatDateTime(null), '');
    });
  });

  group('timeAgo', () {
    test('passes through a human phrase', () {
      expect(timeAgo(null, raw: '3 days ago'), '3 days ago');
    });

    test('never prints a raw ISO timestamp', () {
      // This is what showed on the watch page as
      // "2026-08-05 15:56:39.000Z" instead of anything readable.
      final result = timeAgo(
        DateTime.now().subtract(const Duration(days: 2)),
        raw: '2026-08-05 15:56:39.000Z',
      );
      expect(result, '2 days ago');
    });
  });
}
