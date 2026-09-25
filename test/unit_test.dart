import 'package:ai_bit/src/core/chapters.dart';
import 'package:ai_bit/src/core/format.dart';
import 'package:ai_bit/src/data/app_lock_service.dart';
import 'package:ai_bit/src/data/data_usage_service.dart';
import 'package:ai_bit/src/data/dlna_client.dart';
import 'package:ai_bit/src/data/kids_guard.dart';
import 'package:ai_bit/src/data/models.dart';
import 'package:ai_bit/src/data/recommender.dart';
import 'package:ai_bit/src/data/media_processor.dart';
import 'package:ai_bit/src/data/storage_service.dart';
import 'package:ai_bit/src/data/takeout_import.dart';
import 'package:ai_bit/src/data/yt_repository.dart';
import 'package:ai_bit/src/player/playback_controller.dart';
import 'package:ai_bit/src/core/settings_rules.dart';
import 'package:ai_bit/src/ui/widgets/responsive_feed.dart';
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

  group('PlaybackController.isGenuineFinish', () {
    bool finish(Duration position, Duration duration) =>
        PlaybackController.isGenuineFinish(
          position: position,
          duration: duration,
        );

    test('accepts a video that has run out', () {
      expect(finish(const Duration(minutes: 10), const Duration(minutes: 10)),
          isTrue);
    });

    test('accepts the last few seconds', () {
      // The player reports the end a moment before the position catches up.
      expect(
        finish(const Duration(minutes: 9, seconds: 58),
            const Duration(minutes: 10)),
        isTrue,
      );
    });

    test('rejects an ending reported near the start', () {
      // Changing quality rebuilds the data source, and the outgoing player
      // says it ended. Believing it put the end screen over a video that had
      // just restarted from zero.
      expect(finish(Duration.zero, const Duration(minutes: 10)), isFalse);
      expect(
        finish(const Duration(seconds: 30), const Duration(minutes: 10)),
        isFalse,
      );
    });

    test('rejects an ending reported mid-video', () {
      expect(
        finish(const Duration(minutes: 5), const Duration(minutes: 10)),
        isFalse,
      );
    });

    test('accepts when the duration is unknown', () {
      // Nothing to compare against, and suppressing it would strand the end of
      // a live or unmeasured stream.
      expect(finish(const Duration(minutes: 3), Duration.zero), isTrue);
    });
  });

  group('MediaProcessor', () {
    test('an unavailable processor declines rather than throwing', () async {
      // The contract the download manager relies on: a finished transfer is
      // never lost because post-processing could not run.
      const processor = UnavailableMediaProcessor();
      expect(processor.isSupported, isFalse);
      expect(
        await processor.mux(videoPath: 'v', audioPath: 'a', outputPath: 'o'),
        isFalse,
      );
      expect(
        await processor.toMp3(sourcePath: 's', outputPath: 'o'),
        isFalse,
      );
    });
  });

  group('DownloadTarget', () {
    test('counts both files when a join is needed', () {
      const target = DownloadTarget(
        handle: 'video',
        totalBytes: 100,
        quality: '1080p',
        fileExtension: 'mp4',
        audioOnly: false,
        audioHandle: 'audio',
        audioBytes: 25,
      );
      expect(target.needsMux, isTrue);
      // The progress bar has to know about both, or it stalls at the end of
      // the video file and then jumps when the audio starts.
      expect(target.downloadBytes, 125);
    });

    test('a single-file download needs no join', () {
      const target = DownloadTarget(
        handle: 'muxed',
        totalBytes: 100,
        quality: '360p',
        fileExtension: 'mp4',
        audioOnly: false,
      );
      expect(target.needsMux, isFalse);
      expect(target.downloadBytes, 100);
    });
  });

  group('formatBytes', () {
    test('reports whole bytes without a decimal', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(512), '512 B');
    });

    test('steps up through the units', () {
      expect(formatBytes(1024), '1.00 KB');
      expect(formatBytes(1024 * 1024), '1.00 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.00 GB');
    });

    test('drops precision as the number grows', () {
      // A storage screen reading "1.00 GB" and "512 MB" is easier to scan than
      // one with the same decimals everywhere.
      expect(formatBytes(1024 * 1024 * 15), '15.0 MB');
      expect(formatBytes(1024 * 1024 * 512), '512 MB');
    });

    test('never reports a negative size', () {
      expect(formatBytes(-1), '0 B');
    });
  });

  group('feedColumnsFor', () {
    test('phones get a single column', () {
      expect(feedColumnsFor(320), 1);
      expect(feedColumnsFor(390), 1);
      expect(feedColumnsFor(599), 1);
    });

    test('tablets switch to two columns at the 600dp Material boundary', () {
      // A small tablet held portrait is 600–720dp; the old 640 cutoff left it
      // on the stretched phone list.
      expect(feedColumnsFor(600), 2);
      expect(feedColumnsFor(720), 2);
      expect(feedColumnsFor(999), 2);
    });

    test('wider screens step up to three and four', () {
      expect(feedColumnsFor(1000), 3);
      expect(feedColumnsFor(1399), 3);
      expect(feedColumnsFor(1400), 4);
      expect(feedColumnsFor(1920), 4);
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

  // ------------------------------------------------------------- app lock

  group('AppLockService.hashPin', () {
    test('is a stable lowercase sha256 hex digest', () {
      // Pinned to the published sha256 of "1234", not to whatever the code
      // happens to produce: the hash is written into SharedPreferences, so a
      // change to the algorithm would lock every existing user out of their own
      // app with nothing to notice before shipping.
      expect(
        AppLockService.hashPin('1234'),
        '03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4',
      );
      expect(AppLockService.hashPin('1234'), matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('gives the same PIN the same hash every time', () {
      expect(AppLockService.hashPin('9182'), AppLockService.hashPin('9182'));
    });

    test('gives different PINs different hashes', () {
      expect(
        AppLockService.hashPin('1234'),
        isNot(AppLockService.hashPin('4321')),
      );
      // Same digits with one appended — a length-only difference must separate.
      expect(
        AppLockService.hashPin('1234'),
        isNot(AppLockService.hashPin('12345')),
      );
    });
  });

  group('AppLockService.verify', () {
    test('accepts the PIN that produced the hash', () {
      expect(
        AppLockService.verify('1234', AppLockService.hashPin('1234')),
        isTrue,
      );
    });

    test('rejects a wrong PIN', () {
      final stored = AppLockService.hashPin('1234');
      expect(AppLockService.verify('0000', stored), isFalse);
      expect(AppLockService.verify('4321', stored), isFalse);
      expect(AppLockService.verify('12340', stored), isFalse);
    });

    test('never validates against an empty stored hash', () {
      // The one that matters. An unset PIN is stored as '', and sha256 of the
      // empty string is itself a valid digest — without the guard in verify, a
      // lock armed before a PIN was chosen could be opened by an empty entry.
      expect(AppLockService.verify('', ''), isFalse);
      expect(AppLockService.verify('1234', ''), isFalse);
      expect(AppLockService.verify('0000', ''), isFalse);
    });

    test('rejects a stored hash of the wrong length', () {
      // A truncated or corrupted preference value must fail closed rather than
      // match on a prefix.
      final stored = AppLockService.hashPin('1234');
      expect(AppLockService.verify('1234', stored.substring(0, 32)), isFalse);
      expect(AppLockService.verify('1234', '${stored}ff'), isFalse);
    });

    test('treats an empty PIN as a PIN, not as an unset lock', () {
      // Not a contradiction with the rule above: this is a hash that was
      // deliberately computed from an empty PIN, which the setup flow does not
      // produce. Recorded so the two cases are never conflated.
      expect(AppLockService.verify('', AppLockService.hashPin('')), isTrue);
      expect(AppLockService.verify('1', AppLockService.hashPin('')), isFalse);
    });
  });

  // --------------------------------------------------------- kids allowance

  group('KidsGuard.daysSinceEpoch', () {
    int day(DateTime when) => KidsGuard.daysSinceEpoch(when);

    test('counts whole days from the epoch', () {
      expect(day(DateTime(1970, 1, 1, 12)), 0);
      expect(day(DateTime(1970, 1, 2)), 1);
      expect(day(DateTime(2026, 8, 25, 9, 30)), 20690);
    });

    test('gives every instant on one local calendar day the same index', () {
      // 00:05 and 23:55 bracket a local day as tightly as anything realistic
      // does, and they are exactly the pair a naive UTC conversion splits.
      expect(
        day(DateTime(2026, 3, 14, 0, 5)),
        day(DateTime(2026, 3, 14, 23, 55)),
      );
      expect(day(DateTime(2026, 3, 14)), day(DateTime(2026, 3, 14, 12)));
      expect(
        day(DateTime(2026, 3, 14)),
        day(DateTime(2026, 3, 14, 23, 59, 59, 999)),
      );
    });

    test('increments across local midnight', () {
      expect(
        day(DateTime(2026, 3, 15, 0, 1)) - day(DateTime(2026, 3, 14, 23, 59)),
        1,
      );
      // Month and year rollovers are the same arithmetic, but they are where an
      // off-by-one surfaces as "the allowance never resets".
      expect(day(DateTime(2026, 2, 1)) - day(DateTime(2026, 1, 31)), 1);
      expect(day(DateTime(2027, 1, 1)) - day(DateTime(2026, 12, 31)), 1);
      // 2028 is a leap year: Feb 29 has to sit between Feb 28 and Mar 1.
      expect(day(DateTime(2028, 3, 1)) - day(DateTime(2028, 2, 28)), 2);
    });

    test('does not roll over at local midnight minus the UTC offset', () {
      // The bug the implementation comment describes, written out. Dividing the
      // raw instant by a day would reset a child's allowance at 05:30 in IST
      // and charge every evening to the following day. The naive comparison is
      // guarded on the machine's own offset so the suite still means something
      // on a UTC build agent, where the naive form is accidentally right.
      int naive(DateTime when) =>
          when.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

      final early = DateTime(2026, 3, 14, 0, 5);
      final late = DateTime(2026, 3, 14, 23, 55);
      expect(day(early), day(late), reason: 'the correct answer, always');

      if (early.timeZoneOffset.abs() >= const Duration(minutes: 10)) {
        expect(
          naive(early) == naive(late),
          isFalse,
          reason: 'the naive form splits one local day in two, which is what '
              'daysSinceEpoch exists to avoid',
        );
      }
    });
  });

  // ------------------------------------------------------------- data usage

  group('DataUsageService.estimateStreamBytes', () {
    int bytes(Duration watched, String quality) =>
        DataUsageService.estimateStreamBytes(watched, quality);

    test('is zero for no watched time', () {
      expect(bytes(Duration.zero, '1080p'), 0);
      expect(bytes(Duration.zero, 'Audio'), 0);
      // A negative delta can only be a caller passing a position that went
      // backwards after a seek; it must not credit bytes back.
      expect(bytes(const Duration(seconds: -30), '1080p'), 0);
    });

    test('scales linearly with duration', () {
      final oneMinute = bytes(const Duration(minutes: 1), '720p');
      expect(bytes(const Duration(minutes: 2), '720p'), oneMinute * 2);
      expect(bytes(const Duration(minutes: 10), '720p'), oneMinute * 10);
      // 2.5 Mbps of decimal megabits for sixty seconds, as carriers quote it.
      expect(oneMinute, 18750000);
    });

    test('charges a higher rung more than a lower one', () {
      const watched = Duration(minutes: 5);
      const ladder = [
        '144p',
        '240p',
        '360p',
        '480p',
        '720p',
        '1080p',
        '1440p',
        '2160p',
      ];
      for (var i = 1; i < ladder.length; i++) {
        expect(
          bytes(watched, ladder[i]),
          greaterThan(bytes(watched, ladder[i - 1])),
          reason: '${ladder[i]} must cost more than ${ladder[i - 1]}',
        );
      }
    });

    test('audio costs less than any rung the streaming path can reach', () {
      const watched = Duration(minutes: 5);
      // CLAUDE.md's streaming floor: YouTube now exposes only the 360p combined
      // stream, so 360p is the cheapest thing a *watch* can actually pull. The
      // 144p and 240p entries sit below the audio bitrate in the table, but
      // they are download-only rungs, which is why this starts at 360p.
      for (final rung in ['360p', '480p', '720p', '1080p', '1440p', '2160p']) {
        expect(
          bytes(watched, 'Audio'),
          lessThan(bytes(watched, rung)),
          reason: 'audio must be cheaper than $rung',
        );
      }
      expect(bytes(watched, 'Audio'), greaterThan(0));
    });

    test('prices MP3 as audio, not as a video rung', () {
      const watched = Duration(minutes: 3);
      expect(bytes(watched, 'MP3'), bytes(watched, 'Audio'));
      expect(bytes(watched, 'audio only'), bytes(watched, 'Audio'));
    });

    test('falls back to the Auto guess for an unreadable quality', () {
      const watched = Duration(minutes: 4);
      // Auto is documented as splitting the difference at 720p.
      expect(bytes(watched, 'Auto'), bytes(watched, '720p'));
      expect(bytes(watched, ''), bytes(watched, '720p'));
      expect(bytes(watched, 'best available'), bytes(watched, '720p'));
    });

    test('snaps an off-ladder height to its nearest rung', () {
      const watched = Duration(minutes: 4);
      expect(bytes(watched, '722p'), bytes(watched, '720p'));
      expect(bytes(watched, '1088p'), bytes(watched, '1080p'));
      expect(bytes(watched, '320p'), bytes(watched, '360p'));
      // An exact tie goes to the LOWER rung: the nearest-rung loop compares
      // with a strict <, so the first entry at the winning distance keeps the
      // slot and the table is walked in ascending order. 300 is 60 from both
      // 240 and 360, and 240 is what it costs.
      expect(bytes(watched, '300p'), bytes(watched, '240p'));
    });

    test('reads the height out of a WIDTHxHEIGHT track label', () {
      // Regression test. _mbpsFor used to strip every non-digit, so "1280x720"
      // became the number 1280720 and snapped to the 2160p rung - a 720p HLS
      // track billed at 7x its real cost. The width must not reach the rung
      // lookup at all.
      const watched = Duration(minutes: 4);
      expect(bytes(watched, '1280x720'), bytes(watched, '720p'));
      expect(bytes(watched, '640x360'), bytes(watched, '360p'));
      expect(bytes(watched, '1280x720'), isNot(bytes(watched, '2160p')));
    });

    test('ignores the frame rate in a 60fps quality label', () {
      // The same stripping bug, on the input that actually reaches this code:
      // youtube_explode reports any 60fps stream as "1080p60", which became
      // 108060 and snapped to 2160p - 4x overcharged. activeQuality passes
      // these labels through verbatim, so this is the common case, not an edge.
      const watched = Duration(minutes: 4);
      expect(bytes(watched, '1080p60'), bytes(watched, '1080p'));
      expect(bytes(watched, '720p60'), bytes(watched, '720p'));
      expect(bytes(watched, '1080p60'), isNot(bytes(watched, '2160p')));
    });
  });

  // --------------------------------------------------------------- casting

  group('DlnaClient.escapeXml', () {
    test('escapes the five XML metacharacters', () {
      expect(DlnaClient.escapeXml('a&b'), 'a&amp;b');
      expect(DlnaClient.escapeXml('<tag>'), '&lt;tag&gt;');
      expect(DlnaClient.escapeXml('say "hi"'), 'say &quot;hi&quot;');
      expect(DlnaClient.escapeXml("it's"), 'it&apos;s');
    });

    test('escapes the ampersand first so it is not double-escaped', () {
      // Replacing '<' before '&' would turn "a<b" into "a&amp;lt;b".
      expect(DlnaClient.escapeXml('a<b'), 'a&lt;b');
      // Input that already looks like an entity is escaped again, which is
      // correct: it is text, not markup.
      expect(DlnaClient.escapeXml('&lt;'), '&amp;lt;');
    });

    test('leaves ordinary text alone', () {
      expect(DlnaClient.escapeXml('Living Room TV'), 'Living Room TV');
      expect(DlnaClient.escapeXml(''), '');
    });
  });

  group('DlnaClient.buildSoapEnvelope', () {
    test('names the action and the AVTransport namespace', () {
      final envelope = DlnaClient.buildSoapEnvelope('Play', {
        'InstanceID': '0',
        'Speed': '1',
      });
      expect(envelope, startsWith('<?xml version="1.0" encoding="utf-8"?>'));
      expect(
        envelope,
        contains('xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'),
      );
      expect(envelope, contains('<u:Play xmlns:u="${DlnaClient.avTransport}">'));
      expect(envelope, contains('</u:Play>'));
      expect(envelope, endsWith('</s:Envelope>'));
      expect(
        DlnaClient.avTransport,
        'urn:schemas-upnp-org:service:AVTransport:1',
      );
    });

    test('writes each argument as its own element, in order', () {
      expect(
        DlnaClient.buildSoapEnvelope('Stop', {'InstanceID': '0'}),
        contains('<InstanceID>0</InstanceID>'),
      );

      final ordered = DlnaClient.buildSoapEnvelope('SetAVTransportURI', {
        'InstanceID': '0',
        'CurrentURI': 'http://x/y.mp4',
        'CurrentURIMetaData': '',
      });
      expect(
        ordered.indexOf('<InstanceID>'),
        lessThan(ordered.indexOf('<CurrentURI>')),
      );
      expect(
        ordered.indexOf('<CurrentURI>'),
        lessThan(ordered.indexOf('<CurrentURIMetaData>')),
      );
      // An empty argument still has to be sent: a missing element is a
      // different request as far as the renderer is concerned.
      expect(ordered, contains('<CurrentURIMetaData></CurrentURIMetaData>'));
    });

    test('escapes the ampersands in a stream URL', () {
      // The bug this whole group exists for. A googlevideo URL is nothing but
      // '&' separators; one unescaped makes the envelope invalid XML, and the
      // TV answers 200 and then sits on a black screen — which reads as
      // "casting is broken" rather than "the request was malformed".
      const url =
          'https://r5---sn-x.googlevideo.com/videoplayback?id=abc&itag=18&sig=xy';
      final envelope = DlnaClient.buildSoapEnvelope('SetAVTransportURI', {
        'InstanceID': '0',
        'CurrentURI': url,
      });
      expect(envelope, contains('id=abc&amp;itag=18&amp;sig=xy'));
      expect(envelope, isNot(contains('id=abc&itag')));
      // No bare ampersand may survive anywhere in the body.
      expect(envelope, isNot(matches(RegExp(r'&(?!amp;|lt;|gt;|quot;|apos;)'))));
    });

    test('escapes angle brackets and quotes in a title', () {
      final envelope = DlnaClient.buildSoapEnvelope('SetAVTransportURI', {
        'CurrentURIMetaData': '<dc:title>He said "no" & <left></dc:title>',
      });
      expect(envelope, contains('&lt;dc:title&gt;'));
      expect(envelope, contains('&quot;no&quot;'));
      expect(envelope, contains('&amp; &lt;left&gt;'));
      // The metadata must arrive as text, never as live markup that would
      // reopen the SOAP body.
      expect(envelope, isNot(contains('<dc:title>')));
      expect('<'.allMatches(envelope).length, '>'.allMatches(envelope).length);
    });

    test('emits no argument elements when there are none', () {
      expect(
        DlnaClient.buildSoapEnvelope('Pause', const {}),
        contains('<u:Pause xmlns:u="${DlnaClient.avTransport}"></u:Pause>'),
      );
    });
  });

  // ------------------------------------------------------------ queue order

  group('PlaybackController.shuffledOrder', () {
    List<int> items(int n) => [for (var i = 0; i < n; i++) i];

    test('is deterministic for a given seed', () {
      final source = items(50);
      expect(
        PlaybackController.shuffledOrder(source, 12345),
        PlaybackController.shuffledOrder(source, 12345),
      );
    });

    test('a different seed gives a different order', () {
      // Not asserted per-seed: two seeds can legitimately collide. What must
      // hold is that the seed is used at all.
      final source = items(30);
      final baseline = PlaybackController.shuffledOrder(source, 0);
      final differs = [
        for (var seed = 1; seed <= 20; seed++)
          PlaybackController.shuffledOrder(source, seed),
      ].any((order) => order.join(',') != baseline.join(','));
      expect(differs, isTrue);
    });

    test('is a true permutation - nothing lost, nothing duplicated', () {
      final source = items(200);
      final shuffled = PlaybackController.shuffledOrder(source, 7);
      expect(shuffled.length, source.length);
      expect(shuffled.toSet().length, source.length);
      expect(shuffled.toList()..sort(), source);
    });

    test('keeps duplicates rather than collapsing them', () {
      // The queue can legitimately hold the same video twice; a shuffle that
      // deduplicated would silently shorten it.
      final source = ['a', 'b', 'a', 'c', 'a'];
      final shuffled = PlaybackController.shuffledOrder(source, 3);
      expect(shuffled.length, 5);
      expect(shuffled.where((v) => v == 'a').length, 3);
      expect(shuffled.toList()..sort(), source.toList()..sort());
    });

    test('does not mutate the list it was given', () {
      // shuffleQueue stashes the original list as the way back from a shuffle,
      // so shuffling in place would destroy exactly the thing it saved.
      final source = items(20);
      final before = List<int>.of(source);
      PlaybackController.shuffledOrder(source, 99);
      expect(source, before);
    });

    test('handles an empty and a single-entry queue', () {
      // The Fisher-Yates loop starts at length - 1 and stops above zero, so
      // both of these have to fall straight through rather than index out of
      // range or ask Random for nextInt(0).
      expect(PlaybackController.shuffledOrder(<int>[], 1), isEmpty);
      expect(PlaybackController.shuffledOrder([42], 1), [42]);
      expect(PlaybackController.shuffledOrder([42], 0), [42]);
    });

    test('reaches many distinct orders across seeds', () {
      // A shuffle that ignored part of the seed, or that only ever rotated,
      // would show up here as a handful of distinct results.
      final source = items(8);
      final seen = <String>{};
      for (var seed = 0; seed < 200; seed++) {
        seen.add(PlaybackController.shuffledOrder(source, seed).join(','));
      }
      expect(seen.length, greaterThan(100));
    });
  });

  // ---------------------------------------------------- subscribed feed age

  group('YtRepository.uploadAgeSeconds', () {
    VideoBrief video({DateTime? date, String? raw}) => VideoBrief(
      id: 'abcdefghijk',
      title: 'T',
      author: 'A',
      channelId: 'C',
      uploadDate: date,
      uploadRaw: raw,
    );

    test('prefers a real upload date', () {
      final age = YtRepository.uploadAgeSeconds(
        video(date: DateTime.now().subtract(const Duration(days: 2))),
      );
      expect(age, closeTo(const Duration(days: 2).inSeconds, 5));
    });

    test('clamps a future date to zero', () {
      // Clock skew or a scheduled premiere must not sort *below* everything by
      // going negative; it is simply the newest thing there is.
      final age = YtRepository.uploadAgeSeconds(
        video(date: DateTime.now().add(const Duration(days: 3))),
      );
      expect(age, 0);
    });

    test('parses the relative phrase the browse renderer returns', () {
      int? age(String raw) => YtRepository.uploadAgeSeconds(video(raw: raw));
      expect(age('3 days ago'), const Duration(days: 3).inSeconds);
      expect(age('45 seconds ago'), 45);
      expect(age('2 hours ago'), const Duration(hours: 2).inSeconds);
      expect(age('1 week ago'), const Duration(days: 7).inSeconds);
      // Coarse by design: a month is 30 days and a year is 365.
      expect(age('1 month ago'), 2592000);
      expect(age('1 year ago'), 31536000);
    });

    test('ignores leading text, casing and the plural s', () {
      int? age(String raw) => YtRepository.uploadAgeSeconds(video(raw: raw));
      expect(age('Streamed 3 days ago'), const Duration(days: 3).inSeconds);
      expect(age('1 day ago'), const Duration(days: 1).inSeconds);
      expect(age('PREMIERED 6 MONTHS AGO'), 6 * 2592000);
    });

    test('orders correctly across units', () {
      int? age(String raw) => YtRepository.uploadAgeSeconds(video(raw: raw));
      expect(age('3 hours ago')!, lessThan(age('3 days ago')!));
      expect(age('3 days ago')!, lessThan(age('3 weeks ago')!));
      expect(age('11 months ago')!, lessThan(age('1 year ago')!));
    });

    test('gives up on anything with no unit word', () {
      int? age(String raw) => YtRepository.uploadAgeSeconds(video(raw: raw));
      // uploadRaw is sometimes an ISO timestamp. It carries digits but no unit
      // word, so it must fail to match rather than be read as "2026 seconds".
      expect(age('2026-08-05 15:56:39.000Z'), isNull);
      expect(age('LIVE'), isNull);
      expect(age(''), isNull);
      expect(YtRepository.uploadAgeSeconds(video()), isNull);
    });

    test('reports an unreadable age as null, not zero', () {
      // _newestFirst sinks a null to the bottom of the feed. Returning zero
      // instead would float every odd renderer to the very top, above the
      // uploads the user pulled to refresh for.
      expect(YtRepository.uploadAgeSeconds(video(raw: 'sometime')), isNull);
      expect(
        YtRepository.uploadAgeSeconds(video(date: DateTime.now())),
        isNotNull,
      );
    });
  });

  // Deliberately absent, so the gap is a decision and not an oversight:
  // AppDatabase.deleteHistoryOlderThan's retention cutoff and
  // DataUsageService's day-window subtraction are both "keep-forever guard plus
  // an offset", but neither is reachable without a live SQLite handle
  // (AppDatabase's only constructor is private and takes an open Database), and
  // this suite does no I/O. The shared, testable half of both is
  // KidsGuard.daysSinceEpoch — which DataUsageService explicitly borrows rather
  // than reimplementing — and it is covered above. Nothing was restructured to
  // make the rest reachable.

  group('parsePlaylistCsv', () {
    // The real shape: a header naming the id column, then rows whose second
    // column is a timestamp that must not be mistaken for an id.
    const typical = 'Video ID,Playlist Video Creation Timestamp\n'
        'dQw4w9WgXcQ,2023-01-01T00:00:00+00:00\n'
        'jNQXAC9IVRw,2023-01-02T00:00:00+00:00\n';

    test('reads ids from the column the header names', () {
      expect(parsePlaylistCsv(typical), ['dQw4w9WgXcQ', 'jNQXAC9IVRw']);
    });

    test('keeps the order the file listed', () {
      const csv = 'Video ID,When\nBBBBBBBBBBB,x\nAAAAAAAAAAA,x\n';
      expect(parsePlaylistCsv(csv), ['BBBBBBBBBBB', 'AAAAAAAAAAA']);
    });

    test('drops duplicates', () {
      const csv = 'Video ID,When\ndQw4w9WgXcQ,x\ndQw4w9WgXcQ,y\n';
      expect(parsePlaylistCsv(csv), ['dQw4w9WgXcQ']);
    });

    test('survives CRLF, blank lines and a BOM', () {
      const csv = '\ufeffVideo ID,When\r\n\r\ndQw4w9WgXcQ,x\r\n\r\n';
      expect(parsePlaylistCsv(csv), ['dQw4w9WgXcQ']);
    });

    test('still imports when the header is missing or unfamiliar', () {
      // The fallback scan is the whole reason an export whose layout drifted
      // does not silently import nothing.
      const csv = 'Some Future Column,When\ndQw4w9WgXcQ,2023-01-01\n';
      expect(parsePlaylistCsv(csv), ['dQw4w9WgXcQ']);
    });

    test('does not mistake a timestamp for a video id', () {
      // 11 characters, but not an id - this is the trap the anchored pattern
      // and the header column both exist to avoid.
      const csv = 'Video ID,When\ndQw4w9WgXcQ,2023-01-01T\n';
      expect(parsePlaylistCsv(csv), ['dQw4w9WgXcQ']);
    });

    test('returns nothing for a file with no ids at all', () {
      expect(parsePlaylistCsv('Channel Id,Channel Title\n'), isEmpty);
      expect(parsePlaylistCsv(''), isEmpty);
    });
  });

  group('playlistNameFromFileName', () {
    test('strips the -videos.csv Takeout appends', () {
      expect(playlistNameFromFileName('Road trip-videos.csv'), 'Road trip');
    });

    test('handles a full path and mixed case', () {
      expect(
        playlistNameFromFileName('Takeout/playlists/Chill-VIDEOS.CSV'),
        'Chill',
      );
    });

    test('keeps the stem when the convention does not hold', () {
      // A wrong-looking name beats a refused import.
      expect(playlistNameFromFileName('mystery.csv'), 'mystery');
    });

    test('never returns an empty name', () {
      expect(playlistNameFromFileName('-videos.csv'), 'Imported playlist');
    });
  });

  group('readPlaylistFile', () {
    test('pairs the name with the ids', () {
      final playlist = readPlaylistFile(
        fileName: 'Focus-videos.csv',
        contents: 'Video ID,When\ndQw4w9WgXcQ,x\n',
      );
      expect(playlist, isNotNull);
      expect(playlist!.name, 'Focus');
      expect(playlist.videoIds, ['dQw4w9WgXcQ']);
    });

    test('returns null for a file that holds no videos', () {
      // An export folder contains files that are not playlists; creating an
      // empty local playlist for each would be worse than skipping them.
      expect(
        readPlaylistFile(
          fileName: 'subscriptions.csv',
          contents: 'Channel Id,Channel Url,Channel Title\n',
        ),
        isNull,
      );
    });
  });


  group('parsePlaylistCsv rejects other Takeout files', () {
    test('does not read subscriptions.csv as a playlist', () {
      // Found by running the parser over a REAL export, not by reasoning: the
      // fallback id scan matched channel NAMES, because "CodingPhase" and
      // "Geekyranjit" are eleven characters of the same alphabet a video id
      // uses. The header is the only thing that can tell them apart.
      const csv = 'Channel Id,Channel Url,Channel Title\n'
          'UC-gY8K7vS7WQzmBBxwrStDQ,http://youtube.com/x,CodingPhase\n'
          'UC0HLXWlZV6RV0mkDdpUo73w,http://youtube.com/y,Geekyranjit\n';
      expect(parsePlaylistCsv(csv), isEmpty);
    });

    test('does not read the playlist index as a playlist', () {
      const csv = 'Playlist ID,Playlist Title\nPLabcdefghij,Road trip\n';
      expect(parsePlaylistCsv(csv), isEmpty);
    });
  });

  group('splitCsvLine', () {
    test('keeps a quoted field containing a comma intact', () {
      expect(
        splitCsvLine('UC123,http://x,"Banwasi, English Classes"'),
        ['UC123', 'http://x', 'Banwasi, English Classes'],
      );
    });

    test('unescapes a doubled quote', () {
      expect(splitCsvLine('a,"He said ""hi"""'), ['a', 'He said "hi"']);
    });

    test('leaves an unquoted line alone', () {
      expect(splitCsvLine('a,b,c'), ['a', 'b', 'c']);
    });
  });

  group('parseSubscriptionsCsv', () {
    const real = 'Channel Id,Channel Url,Channel Title\n'
        'UC-gY8K7vS7WQzmBBxwrStDQ,http://www.youtube.com/channel/UC-gY8K7vS7WQzmBBxwrStDQ,Prathap T M\n'
        'UC0HLXWlZV6RV0mkDdpUo73w,http://www.youtube.com/channel/UC0HLXWlZV6RV0mkDdpUo73w,Master Anand\n';

    test('reads the id and title of each channel', () {
      final channels = parseSubscriptionsCsv(real);
      expect(channels.length, 2);
      expect(channels.first.id, 'UC-gY8K7vS7WQzmBBxwrStDQ');
      expect(channels.first.title, 'Prathap T M');
    });

    test('does not mistake the channel URL for the title', () {
      // The URL contains the id and sits between it and the title.
      expect(parseSubscriptionsCsv(real).last.title, 'Master Anand');
    });

    test('drops duplicates and ignores the header', () {
      const csv = 'Channel Id,Channel Url,Channel Title\n'
          'UC-gY8K7vS7WQzmBBxwrStDQ,http://x,One\n'
          'UC-gY8K7vS7WQzmBBxwrStDQ,http://x,One again\n';
      expect(parseSubscriptionsCsv(csv).length, 1);
    });

    test('returns nothing for a file with no channel ids', () {
      expect(parseSubscriptionsCsv('Video ID,When\ndQw4w9WgXcQ,x\n'), isEmpty);
    });
  });

  group('parseHistoryTimestamp', () {
    test('reads the format Takeout actually writes', () {
      // The space before AM is U+202F, a NARROW no-break space - not a plain
      // space. A parser that splits on ' ' silently fails on every row.
      expect(
        parseHistoryTimestamp('Sep 4, 2026, 11:07:12\u202fAM IST'),
        DateTime(2026, 9, 4, 11, 7, 12),
      );
    });

    test('converts PM correctly', () {
      expect(
        parseHistoryTimestamp('Feb 24, 2013, 12:41:28\u202fPM IST'),
        DateTime(2013, 2, 24, 12, 41, 28),
      );
    });

    test('treats 12 AM as midnight', () {
      expect(
        parseHistoryTimestamp('Jan 1, 2020, 12:30:00\u202fAM IST'),
        DateTime(2020, 1, 1, 0, 30, 0),
      );
    });

    test('returns null rather than guessing at nonsense', () {
      expect(parseHistoryTimestamp('sometime last year'), isNull);
    });
  });

  group('parseWatchHistoryHtml', () {
    const entry =
        'Watched\u00a0<a href="https://www.youtube.com/watch?v=s2lye-G90Pg">'
        'A &amp; B title</a><br>'
        '<a href="https://www.youtube.com/channel/UCucUR4lXSo2CRtaTJDddHQg">'
        'Karnataka Auction Properties</a><br>'
        'Sep 4, 2026, 11:07:12\u202fAM IST<br>';

    test('reads the video, title, channel and time from a real entry', () {
      final watches = parseWatchHistoryHtml(entry);
      expect(watches.length, 1);
      expect(watches.first.videoId, 's2lye-G90Pg');
      expect(watches.first.title, 'A & B title');
      expect(watches.first.channelId, 'UCucUR4lXSo2CRtaTJDddHQg');
      expect(watches.first.author, 'Karnataka Auction Properties');
      expect(watches.first.watchedAt, DateTime(2026, 9, 4, 11, 7, 12));
    });

    test('keeps only the first of a rewatched video', () {
      // Takeout writes newest first, so the first occurrence is the latest
      // watch and the rest are older views of the same video.
      expect(parseWatchHistoryHtml(entry + entry).length, 1);
    });

    test('returns nothing for html with no entries', () {
      expect(
        parseWatchHistoryHtml('<html><body>nothing</body></html>'),
        isEmpty,
      );
    });
  });


  group('feedPreviewBlockedReason', () {
    // The five causes are indistinguishable from outside the class, which is
    // how "previews do not work" was first reported. Each is pinned so a
    // future edit cannot make one of them silent again.
    test('nothing to say when previews are simply off', () {
      // The switch already shows off; a reason would be noise.
      expect(
        feedPreviewBlockedReason(
          previewsEnabled: false,
          previewsOnMobile: false,
          dataSaver: false,
          audioOnly: false,
          isMobile: false,
          somethingPlaying: false,
        ),
        isNull,
      );
    });

    test('explains that playback wins', () {
      expect(
        feedPreviewBlockedReason(
          previewsEnabled: true,
          previewsOnMobile: false,
          dataSaver: false,
          audioOnly: false,
          isMobile: false,
          somethingPlaying: true,
        ),
        contains('playing'),
      );
    });

    test('explains Data saver', () {
      expect(
        feedPreviewBlockedReason(
          previewsEnabled: true,
          previewsOnMobile: false,
          dataSaver: true,
          audioOnly: false,
          isMobile: false,
          somethingPlaying: false,
        ),
        contains('Data saver'),
      );
    });

    test('explains mobile data, and names the setting that fixes it', () {
      final reason = feedPreviewBlockedReason(
        previewsEnabled: true,
          previewsOnMobile: false,
          dataSaver: false,
          audioOnly: false,
        isMobile: true,
        somethingPlaying: false,
      );
      expect(reason, contains('mobile data'));
      expect(reason, contains('Previews on mobile data'));
    });

    test('says nothing when previews will actually run', () {
      expect(
        feedPreviewBlockedReason(
          previewsEnabled: true,
          previewsOnMobile: false,
          dataSaver: false,
          audioOnly: false,
          isMobile: false,
          somethingPlaying: false,
        ),
        isNull,
      );
    });

    test('allows mobile data once it is permitted', () {
      expect(
        feedPreviewBlockedReason(
          previewsEnabled: true,
          previewsOnMobile: true,
          dataSaver: false,
          audioOnly: false,
          isMobile: true,
          somethingPlaying: false,
        ),
        isNull,
      );
    });
  });


  group('settings rules', () {
    // Each of these is a setting that silently overrides another. They are
    // pinned individually because the failure mode is not a crash - it is a
    // switch that does nothing, which reads as a bug and was reported as one.
    test('Data saver stops previews, and says so', () {
      expect(
        feedPreviewBlockedReason(
          previewsEnabled: true,
          previewsOnMobile: true,
          dataSaver: true,
          audioOnly: false,
          isMobile: false,
          somethingPlaying: false,
        ),
        contains('Data saver'),
      );
    });

    test('a low battery stops previews only when battery saver is on', () {
      String? reason({required bool saver, required bool low}) =>
          feedPreviewBlockedReason(
            previewsEnabled: true,
            previewsOnMobile: true,
            dataSaver: false,
            audioOnly: false,
            isMobile: false,
            somethingPlaying: false,
            batterySaver: saver,
            batteryLow: low,
          );
      expect(reason(saver: true, low: true), contains('battery'));
      // A low battery alone is not a reason: the user did not ask for it.
      expect(reason(saver: false, low: true), isNull);
      // Nor is the setting alone, while the battery is fine.
      expect(reason(saver: true, low: false), isNull);
    });

    test('the mobile-only savers go quiet once the global one is on', () {
      expect(mobileDataSaverInertReason(dataSaver: true), isNotNull);
      expect(mobileDataSaverInertReason(dataSaver: false), isNull);
      expect(mobileAudioOnlyInertReason(audioOnly: true), isNotNull);
      expect(mobileAudioOnlyInertReason(audioOnly: false), isNull);
    });

    test('the quality picker names whichever setting took it over', () {
      // Telling someone about Data saver when they turned on Audio only sends
      // them to the wrong switch.
      expect(
        qualityInertReason(dataSaver: false, audioOnly: true),
        contains('Audio only'),
      );
      expect(
        qualityInertReason(dataSaver: true, audioOnly: false),
        contains('Data saver'),
      );
      // Audio only wins when both are on: it is the one with no picture at all.
      expect(
        qualityInertReason(dataSaver: true, audioOnly: true),
        contains('Audio only'),
      );
      expect(qualityInertReason(dataSaver: false, audioOnly: false), isNull);
    });

    test('biometrics need a PIN to fall back to', () {
      expect(biometricUnavailableReason(hasPin: false), isNotNull);
      expect(biometricUnavailableReason(hasPin: true), isNull);
    });

    test('a Kids limit without a PIN is worth warning about', () {
      // The limit works; what does not work is stopping the child leaving
      // Kids mode when it runs out, which is the whole point of setting one.
      expect(
        kidsLimitWeakReason(limitMinutes: 30, hasKidsPin: false),
        isNotNull,
      );
      expect(kidsLimitWeakReason(limitMinutes: 30, hasKidsPin: true), isNull);
      // No limit set, nothing to warn about.
      expect(kidsLimitWeakReason(limitMinutes: 0, hasKidsPin: false), isNull);
    });

    test('app lock enabled without a PIN locks nothing', () {
      expect(appLockInertReason(enabled: true, hasPin: false), isNotNull);
      expect(appLockInertReason(enabled: true, hasPin: true), isNull);
      expect(appLockInertReason(enabled: false, hasPin: false), isNull);
    });
  });


  // ---------------------------------------------------------- recommender
  //
  // Every rule below is a judgement about what somebody wants to watch, which
  // is the kind of logic that rots silently: a feed that is quietly slightly
  // worse produces no crash and no bug report. So each term is pinned on its
  // own rather than only through the total, which two terms cancelling each
  // other out would satisfy just as happily.

  group('tokenise', () {
    test('drops stop words and anything under three letters', () {
      expect(tokenise('The best of my cat'), ['cat']);
    });

    test('splits on punctuation and folds case', () {
      expect(
        tokenise('Rust-lang: ASYNC/await, explained!'),
        ['rust', 'lang', 'async', 'await', 'explained'],
      );
    });

    test('keeps numbers that survive the length rule', () {
      expect(
        tokenise('iPhone 16 Pro review 2026'),
        ['iphone', 'pro', 'review', '2026'],
      );
    });

    test('returns nothing for text made entirely of noise', () {
      expect(tokenise('The best of the new official video'), isEmpty);
    });
  });

  group('WatchSignal.fromWatch', () {
    WatchSignal build({required Duration position, Duration? duration}) =>
        WatchSignal.fromWatch(
          videoId: 'v',
          channelId: 'c',
          title: 't',
          watchedAt: DateTime(2026, 1, 1),
          position: position,
          duration: duration,
        );

    test('completion is the watched fraction', () {
      expect(
        build(
          position: const Duration(minutes: 3),
          duration: const Duration(minutes: 4),
        ).completion,
        closeTo(0.75, 1e-9),
      );
    });

    test('a position past the end clamps to one rather than exceeding it', () {
      expect(
        build(
          position: const Duration(minutes: 9),
          duration: const Duration(minutes: 4),
        ).completion,
        1.0,
      );
    });

    test('an unknown duration is neither evidence for nor against', () {
      // Not 0 and not 1: a missing duration is a parsing gap, and either
      // extreme would claim more about the user than the data supports.
      expect(
        build(position: const Duration(minutes: 3)).completion,
        WatchSignal.assumedCompletion,
      );
      expect(
        build(position: const Duration(minutes: 3), duration: Duration.zero)
            .completion,
        WatchSignal.assumedCompletion,
      );
    });
  });

  group('TasteProfile', () {
    final now = DateTime(2026, 6, 1, 12);

    WatchSignal watch(
      String channel, {
      required double completion,
      Duration ago = Duration.zero,
      String title = 'something',
      String? id,
    }) =>
        WatchSignal(
          videoId: id ?? '$channel-$completion-${ago.inMinutes}',
          channelId: channel,
          title: title,
          watchedAt: now.subtract(ago),
          completion: completion,
        );

    test('a channel watched through outweighs one bounced off', () {
      // The single most important property here, and the thing the old feed
      // had no way to express: opening a video used to be the whole signal.
      final profile = TasteProfile.from(
        history: [
          watch('finished', completion: 1.0),
          watch('bounced', completion: 0.05),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
      );
      expect(
        profile.channelAffinity['finished']!,
        greaterThan(profile.channelAffinity['bounced']! * 10),
      );
    });

    test('interest decays, so last night outranks last month', () {
      final profile = TasteProfile.from(
        history: [
          watch('recent', completion: 1.0, ago: const Duration(hours: 12)),
          watch('stale', completion: 1.0, ago: const Duration(days: 60)),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
      );
      expect(
        profile.channelAffinity['recent']!,
        greaterThan(profile.channelAffinity['stale']!),
      );
    });

    test('one half-life is worth half as much', () {
      final profile = TasteProfile.from(
        history: [
          watch('now', completion: 1.0),
          watch('older', completion: 1.0, ago: TasteProfile.interestHalfLife),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
      );
      expect(
        profile.channelAffinity['older']!,
        closeTo(profile.channelAffinity['now']! * 0.5, 1e-6),
      );
    });

    test('a future timestamp is treated as now, not as a prophecy', () {
      // A device clock that has been moved back must not send the weight to
      // infinity through a negative exponent.
      final profile = TasteProfile.from(
        history: [
          watch('ahead', completion: 1.0, ago: const Duration(days: -5)),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
      );
      expect(profile.channelAffinity['ahead'], closeTo(1.0, 1e-9));
    });

    test('titles of abandoned videos do not teach the topic model', () {
      // Learning from what was rejected would pull the feed towards more of
      // exactly the clickbait the user bounced off.
      final profile = TasteProfile.from(
        history: [
          watch('c', completion: 0.02, title: 'shocking pyramid mystery'),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
      );
      expect(profile.topicWeights['pyramid'], isNull);
    });

    test('titles of watched videos do', () {
      final profile = TasteProfile.from(
        history: [
          watch('c', completion: 0.9, title: 'woodworking bench build'),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
      );
      expect(profile.topicWeights['woodworking'], greaterThan(0));
    });

    test('repeating a search counts for more, with diminishing returns', () {
      double weightFor(int hits) => TasteProfile.from(
            history: const [],
            searches: [
              SearchSignal(query: 'kayaking', hits: hits, searchedAt: now),
            ],
            subscribed: const {},
            now: now,
          ).topicWeights['kayaking']!;

      expect(weightFor(10), greaterThan(weightFor(1)));
      // Ten times the searches is nowhere near ten times the interest.
      expect(weightFor(10), lessThan(weightFor(1) * 10));
    });

    test('records when each channel was last watched', () {
      final profile = TasteProfile.from(
        history: [
          watch('c', completion: 1, ago: const Duration(days: 3)),
          watch('c', completion: 1, ago: const Duration(days: 1)),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
      );
      expect(
        profile.lastWatchedOnChannel['c'],
        now.subtract(const Duration(days: 1)),
      );
    });

    test('an empty profile knows it is empty', () {
      expect(TasteProfile.empty.isEmpty, isTrue);
      expect(
        TasteProfile.from(
          history: const [],
          searches: const [],
          subscribed: const {'UC1'},
          now: now,
        ).isEmpty,
        isFalse,
      );
    });
  });

  group('recommender scoring', () {
    final now = DateTime(2026, 6, 1, 12);

    VideoBrief video(
      String id, {
      String channel = 'UC-other',
      String title = 'a woodworking bench build',
      int? views,
      Duration age = const Duration(days: 1),
    }) =>
        VideoBrief(
          id: id,
          title: title,
          author: channel,
          channelId: channel,
          viewCount: views,
          uploadDate: now.subtract(age),
        );

    final profile = TasteProfile.from(
      history: [
        WatchSignal(
          videoId: 'seen',
          channelId: 'UC-loved',
          title: 'woodworking bench build',
          watchedAt: now.subtract(const Duration(hours: 2)),
          completion: 1,
        ),
      ],
      searches: [SearchSignal(query: 'woodworking', hits: 3, searchedAt: now)],
      subscribed: const {'UC-followed'},
      now: now,
    );

    double scoreOf(
      VideoBrief v, {
      CandidateSource source = CandidateSource.search,
      ImpressionCount? impression,
      TasteProfile? against,
    }) {
      final p = against ?? profile;
      final maxAffinity =
          p.channelAffinity.values.fold<double>(0, (a, b) => a > b ? a : b);
      return score(
        candidate: Candidate(video: v, source: source),
        profile: p,
        now: now,
        impression: impression,
        maxAffinity: maxAffinity,
      ).total;
    }

    test('a watched channel outranks a stranger', () {
      expect(
        scoreOf(video('a', channel: 'UC-loved')),
        greaterThan(scoreOf(video('b', channel: 'UC-nobody'))),
      );
    });

    test('subscribing counts even with no watch time behind it', () {
      // A channel followed this morning has nothing in history yet, and a
      // profile that only read watch time would rank it as a stranger.
      expect(
        scoreOf(video('a', channel: 'UC-followed')),
        greaterThan(scoreOf(video('b', channel: 'UC-nobody'))),
      );
    });

    test('a title matching what the user watches outranks one that does not',
        () {
      expect(
        scoreOf(video('a', title: 'woodworking bench build')),
        greaterThan(scoreOf(video('b', title: 'crypto trading signals'))),
      );
    });

    test('a long title is not rewarded for having more chances to match', () {
      // Divided by token count rather than summed, or the feed becomes a
      // title-length contest.
      final short = scoreOf(video('a', title: 'woodworking'));
      final padded = scoreOf(
        video('b', title: 'woodworking alongside unrelated filler nonsense'),
      );
      expect(short, greaterThan(padded));
    });

    test('a fresh upload outranks an old one, all else equal', () {
      expect(
        scoreOf(video('a', age: const Duration(hours: 6))),
        greaterThan(scoreOf(video('b', age: const Duration(days: 400)))),
      );
    });

    test('an unknown upload age scores as the midpoint, not as ancient', () {
      final undated = VideoBrief(
        id: 'u',
        title: 'a woodworking bench build',
        author: 'x',
        channelId: 'x',
      );
      final ancient =
          video('old', channel: 'x', age: const Duration(days: 3000));
      expect(scoreOf(undated), greaterThan(scoreOf(ancient)));
    });

    test('popularity is a tiebreak, never a verdict', () {
      // A viral video from a channel the user ignores must not beat a modest
      // one from the channel they watch. Linear view counts would.
      final viral = video('a', channel: 'UC-nobody', views: 50000000);
      final modest = video('b', channel: 'UC-loved', views: 900);
      expect(scoreOf(modest), greaterThan(scoreOf(viral)));
    });

    test('more views still wins between two otherwise identical videos', () {
      expect(
        scoreOf(video('a', views: 1000000)),
        greaterThan(scoreOf(video('b', views: 100))),
      );
    });

    test('a video already watched sinks below anything unwatched', () {
      final seen = VideoBrief(
        id: 'seen',
        title: 'woodworking bench build',
        author: 'UC-loved',
        channelId: 'UC-loved',
        uploadDate: now,
      );
      expect(
        scoreOf(seen),
        lessThan(scoreOf(video('fresh', channel: 'UC-nobody'))),
      );
    });

    test('being shown and passed over costs something', () {
      final shown = ImpressionCount(
        videoId: 'a',
        shown: 3,
        lastShownAt: now.subtract(const Duration(hours: 1)),
      );
      expect(
        scoreOf(video('a'), impression: shown),
        lessThan(scoreOf(video('a'))),
      );
    });

    test('the impression penalty is capped so nothing is buried forever', () {
      double withShows(int n) => scoreOf(
            video('a'),
            impression: ImpressionCount(
              videoId: 'a',
              shown: n,
              lastShownAt: now.subtract(const Duration(hours: 1)),
            ),
          );
      // Past the cap, more showings change nothing.
      expect(withShows(50), closeTo(withShows(500), 1e-9));
      // And the cap never sinks a video as far as having watched it does.
      final seen = VideoBrief(
        id: 'seen',
        title: 'woodworking bench build',
        author: 'UC-loved',
        channelId: 'UC-loved',
        uploadDate: now,
      );
      expect(withShows(500), greaterThan(scoreOf(seen)));
    });

    test('an old impression is forgotten rather than held against it', () {
      final stale = ImpressionCount(
        videoId: 'a',
        shown: 9,
        lastShownAt: now.subtract(impressionMemory + const Duration(days: 1)),
      );
      expect(
        scoreOf(video('a'), impression: stale),
        closeTo(scoreOf(video('a')), 1e-9),
      );
    });

    test('the source prior orders sources when nothing else separates them',
        () {
      const blank = TasteProfile.empty;
      double bySource(CandidateSource s) =>
          scoreOf(video('a', channel: 'UC-x'), source: s, against: blank);
      expect(
        bySource(CandidateSource.subscription),
        greaterThan(bySource(CandidateSource.coWatch)),
      );
      expect(
        bySource(CandidateSource.coWatch),
        greaterThan(bySource(CandidateSource.watchedChannel)),
      );
      expect(
        bySource(CandidateSource.watchedChannel),
        greaterThan(bySource(CandidateSource.search)),
      );
      expect(
        bySource(CandidateSource.search),
        greaterThan(bySource(CandidateSource.topic)),
      );
    });

    test('uploadAgeSeconds agrees with the repository copy it mirrors', () {
      // Two implementations of one rule; if they drift, the feed and the
      // subscriptions tab start disagreeing about how old a video is.
      const shapes = [
        '3 days ago',
        'Streamed 2 hours ago',
        '1 year ago',
        'nonsense',
      ];
      for (final raw in shapes) {
        final v = VideoBrief(
          id: 'x',
          title: 't',
          author: 'a',
          channelId: 'c',
          uploadRaw: raw,
        );
        expect(uploadAgeSeconds(v, now), YtRepository.uploadAgeSeconds(v));
      }
    });
  });

  group('rankFeed', () {
    final now = DateTime(2026, 6, 1, 12);

    Candidate candidate(
      String id, {
      String channel = 'UC-x',
      CandidateSource source = CandidateSource.search,
      String title = 'a bench build',
    }) =>
        Candidate(
          video: VideoBrief(
            id: id,
            title: title,
            author: channel,
            channelId: channel,
            uploadDate: now.subtract(const Duration(days: 1)),
          ),
          source: source,
        );

    final profile = TasteProfile.from(
      history: [
        WatchSignal(
          videoId: 'old',
          channelId: 'UC-loved',
          title: 'bench build',
          watchedAt: now.subtract(const Duration(hours: 1)),
          completion: 1,
        ),
      ],
      searches: const [],
      subscribed: const {},
      now: now,
    );

    test('returns nothing for no candidates', () {
      expect(
        rankFeed(candidates: const [], profile: profile, now: now),
        isEmpty,
      );
    });

    test('keeps one copy of a video that arrived from several sources', () {
      final out = rankFeed(
        candidates: [
          candidate('dup', source: CandidateSource.topic),
          candidate('dup', source: CandidateSource.subscription),
          candidate('other', channel: 'UC-y'),
        ],
        profile: profile,
        now: now,
      );
      expect(out, hasLength(2));
      expect(out.where((v) => v.id == 'dup'), hasLength(1));
    });

    test('one prolific channel cannot take the whole top of the feed', () {
      // Six videos from the channel the user loves against three from
      // strangers. Without the diversity pass the loved channel sweeps the
      // top six, which is not what anyone means by a recommendation feed.
      final out = rankFeed(
        candidates: [
          for (var i = 0; i < 6; i++) candidate('loved$i', channel: 'UC-loved'),
          for (var i = 0; i < 3; i++) candidate('other$i', channel: 'UC-$i'),
        ],
        profile: profile,
        now: now,
      );
      final topFive = out.take(5).where((v) => v.channelId == 'UC-loved');
      expect(topFive.length, lessThan(5));
    });

    test('the loved channel still leads, it just does not monopolise', () {
      final out = rankFeed(
        candidates: [
          for (var i = 0; i < 3; i++) candidate('loved$i', channel: 'UC-loved'),
          for (var i = 0; i < 3; i++) candidate('other$i', channel: 'UC-$i'),
        ],
        profile: profile,
        now: now,
      );
      expect(out.first.channelId, 'UC-loved');
    });

    test('honours the limit without repeating anything', () {
      final out = rankFeed(
        candidates: [
          for (var i = 0; i < 40; i++) candidate('v$i', channel: 'UC-$i'),
        ],
        profile: profile,
        now: now,
        limit: 7,
      );
      expect(out, hasLength(7));
      expect(out.map((v) => v.id).toSet(), hasLength(7));
    });

    test('a limit past the candidate count returns everything once', () {
      final out = rankFeed(
        candidates: [
          for (var i = 0; i < 5; i++) candidate('v$i', channel: 'UC-$i'),
        ],
        profile: profile,
        now: now,
        limit: 500,
      );
      expect(out, hasLength(5));
    });

    test('is deterministic - the same input gives the same order', () {
      final candidates = [
        for (var i = 0; i < 12; i++) candidate('v$i', channel: 'UC-${i % 4}'),
      ];
      final a = rankFeed(candidates: candidates, profile: profile, now: now);
      final b = rankFeed(candidates: candidates, profile: profile, now: now);
      expect(a.map((v) => v.id), b.map((v) => v.id));
    });
  });

  group('rankUpNext', () {
    final now = DateTime(2026, 6, 1, 12);

    VideoBrief v(
      String id, {
      String channel = 'UC-other',
      String title = 'clip',
    }) =>
        VideoBrief(
          id: id,
          title: title,
          author: channel,
          channelId: channel,
          uploadDate: now.subtract(const Duration(days: 2)),
        );

    final current = v('playing', channel: 'UC-current');

    test('never suggests the video that is playing', () {
      final out = rankUpNext(
        current: current,
        related: [v('playing', channel: 'UC-current'), v('a'), v('b')],
        profile: TasteProfile.empty,
        now: now,
      );
      expect(out.map((x) => x.id), isNot(contains('playing')));
      expect(out, hasLength(2));
    });

    test('returns nothing for an empty related list', () {
      expect(
        rankUpNext(
          current: current,
          related: const [],
          profile: TasteProfile.empty,
          now: now,
        ),
        isEmpty,
      );
    });

    test('keeps the co-watch order when nothing is known about the viewer', () {
      // YouTube's related list is a real recommendation and must not be
      // scrambled for the sake of scrambling it.
      final related = [for (var i = 0; i < 5; i++) v('r$i', channel: 'UC-$i')];
      final out = rankUpNext(
        current: current,
        related: related,
        profile: TasteProfile.empty,
        now: now,
      );
      expect(out.map((x) => x.id).toList(), ['r0', 'r1', 'r2', 'r3', 'r4']);
    });

    test('a channel the viewer watches climbs over YouTube ordering', () {
      final profile = TasteProfile.from(
        history: [
          WatchSignal(
            videoId: 'seen',
            channelId: 'UC-loved',
            title: 'clip',
            watchedAt: now.subtract(const Duration(hours: 1)),
            completion: 1,
          ),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
      );
      final out = rankUpNext(
        current: current,
        related: [
          v('a', channel: 'UC-nobody'),
          v('b', channel: 'UC-nobody2'),
          v('loved', channel: 'UC-loved'),
        ],
        profile: profile,
        now: now,
      );
      expect(out.first.id, 'loved');
    });

    test('autoplay does not walk down the current channel back catalogue', () {
      // Same position in YouTube's list, same everything else - the one from
      // the channel already on screen should lose.
      final out = rankUpNext(
        current: current,
        related: [
          v('same', channel: 'UC-current'),
          v('different', channel: 'UC-elsewhere'),
        ],
        profile: TasteProfile.empty,
        now: now,
      );
      expect(out.first.id, 'different');
    });

    test('something already watched sinks to the bottom', () {
      final profile = TasteProfile.from(
        history: [
          WatchSignal(
            videoId: 'seen',
            channelId: 'UC-other',
            title: 'clip',
            watchedAt: now.subtract(const Duration(days: 1)),
            completion: 1,
          ),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
      );
      final out = rankUpNext(
        current: current,
        related: [v('seen'), v('unseen1'), v('unseen2')],
        profile: profile,
        now: now,
      );
      expect(out.last.id, 'seen');
    });
  });
}
