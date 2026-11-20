import 'dart:convert';
import 'dart:typed_data';

import 'package:ai_bit/src/core/captions.dart';
import 'package:ai_bit/src/core/chapters.dart';
import 'package:better_player_plus/better_player_plus.dart' show BetterPlayerAsmsAudioTrack;
import 'package:ai_bit/src/core/format.dart';
import 'package:ai_bit/src/core/incoming_links.dart';
import 'package:ai_bit/src/data/attestation/web_formats.dart';
import 'package:ai_bit/src/data/app_lock_service.dart';
import 'package:ai_bit/src/data/data_usage_service.dart';
import 'package:ai_bit/src/data/dlna_client.dart';
import 'package:ai_bit/src/data/kids_guard.dart';
import 'package:ai_bit/src/data/custom_feeds.dart';
import 'package:ai_bit/src/data/interests.dart';
import 'package:ai_bit/src/data/models.dart';
import 'package:ai_bit/src/data/player_client.dart';
import 'package:ai_bit/src/data/recommender.dart';
import 'package:ai_bit/src/data/search_client.dart';
import 'package:ai_bit/src/data/media_processor.dart';
import 'package:ai_bit/src/data/storage_service.dart';
import 'package:ai_bit/src/data/takeout_import.dart';
import 'package:ai_bit/src/data/yt_repository.dart';
import 'package:ai_bit/src/player/playback_controller.dart';
import 'package:ai_bit/src/core/settings_rules.dart';
import 'package:ai_bit/src/ui/widgets/responsive_feed.dart';
import 'package:ai_bit/src/data/dash_manifest.dart';
import 'package:ai_bit/src/data/hls_manifest.dart';
import 'package:ai_bit/src/data/browse_client.dart';
import 'package:ai_bit/src/ui/widgets/now_playing_overlay.dart';
import 'package:flutter/widgets.dart';
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

  group('related rows in the older compactVideoRenderer shape', () {
    // YouTube serves this shape to some networks instead of lockupViewModel;
    // read only the newer one, the Up next rail was empty on a phone.
    test('reads id, title, channel, views, age and length', () {
      final row = YoutubeBrowseClient.compactRendererRow({
        'videoId': 'abcdefghijk',
        'title': {'simpleText': 'A related video'},
        'longBylineText': {
          'runs': [
            {
              'text': 'Some Channel',
              'navigationEndpoint': {
                'browseEndpoint': {'browseId': 'UC1234567890'},
              },
            },
          ],
        },
        'viewCountText': {'simpleText': '1,234,567 views'},
        'publishedTimeText': {'simpleText': '3 days ago'},
        'lengthText': {'simpleText': '1:02:03'},
      });
      expect(row, isNotNull);
      expect(row!.id, 'abcdefghijk');
      expect(row.title, 'A related video');
      expect(row.author, 'Some Channel');
      expect(row.channelId, 'UC1234567890');
      expect(row.viewCount, 1234567);
      expect(row.uploadRaw, '3 days ago');
      expect(row.duration, const Duration(hours: 1, minutes: 2, seconds: 3));
    });

    test('title from runs, and a row with no title is skipped', () {
      expect(
        YoutubeBrowseClient.compactRendererRow({
          'videoId': 'x1',
          'title': {
            'runs': [
              {'text': 'Part '},
              {'text': 'two'},
            ],
          },
        })!.title,
        'Part two',
      );
      expect(YoutubeBrowseClient.compactRendererRow({'videoId': 'x2'}), isNull);
    });
  });

  group('localised ages and counts', () {
    // Every string below is one YouTube actually sent (tool/check_age_locales
    // .dart). With the language set to anything but English, ages and view
    // counts all came back null or wrong, silently switching off the ranker's
    // freshness and popularity terms.
    const day = 86400;
    const ages = {
      '6 दिन पहले': 6 * day, // Hindi
      '19 घंटे पहले': 19 * 3600,
      '1 वर्ष पहले': 365 * day,
      '2 সপ্তাহ আগে': 14 * day, // Bengali
      '4 মাস আগে': 120 * day,
      '8 రోజుల క్రితం': 8 * day, // Telugu
      '16 సం. క్రితం': 16 * 365 * day,
      '1 वर्षापूर्वी': 365 * day, // Marathi
      '19 तासांपूर्वी': 19 * 3600,
      '8 நாட்களுக்கு முன்': 8 * day, // Tamil
      '1 ஆண்டிற்கு முன்': 365 * day,
      'ஸ்ட்ரீம் செய்யப்பட்டது: 12 ம. முன்': 12 * 3600,
      '17 કલાક પહેલાં': 17 * 3600, // Gujarati
      '1 ದಿನದ ಹಿಂದೆ': day, // Kannada
      '19 മണിക്കൂർ മുമ്പ്': 19 * 3600, // Malayalam
      '4 ਮਹੀਨੇ ਪਹਿਲਾਂ': 120 * day, // Punjabi
      '5 ماہ قبل': 150 * day, // Urdu
      'سلسلہ بندی کا وقت 1 دن پہلے': day,
    };
    for (final entry in ages.entries) {
      test('reads "${entry.key}"', () {
        expect(parseRelativeAgeSeconds(entry.key), entry.value);
      });
    }

    test('a title is not an age', () {
      expect(parseRelativeAgeSeconds('Best Soft Rock Oldies 90s'), isNull);
    });

    test('compact counts in lakh, crore and arab', () {
      expect(parseCompactCount('6 लाख'), 600000);
      expect(parseCompactCount('2.1 क॰'), 21000000);
      expect(parseCompactCount('1.1 अ॰'), 1100000000);
      expect(parseCompactCount('50 লা'), 5000000);
      expect(parseCompactCount('141 কো'), 1410000000);
      expect(parseCompactCount('138 కోట్లు'), 1380000000);
      expect(parseCompactCount('2.3 अब्ज'), 2300000000);
      expect(parseCompactCount('74 ਹਜ਼ਾਰ'), 74000);
      expect(parseCompactCount('55 لاکھ'), 5500000);
      expect(parseCompactCount('29,184'), 29184);
      expect(parseCompactCount('733K views'), 733000);
      expect(parseCompactCount('1.2M'), 1200000);
    });
  });

  group('normaliseYoutubeVtt', () {
    const youtube = 'WEBVTT\n'
        'Kind: captions\n'
        'Language: en\n'
        '\n'
        '00:00:01.000 --> 00:00:03.500 align:start position:0%\n'
        "We're no strangers\n"
        '\n'
        '00:00:03.500 --> 00:00:05.000 align:start position:0%\n'
        '<00:00:03.600><c> to</c><00:00:04.000><c> love</c>\n';

    test('drops the header block the player parser threw on', () {
      final out = normaliseYoutubeVtt(youtube);
      expect(out, startsWith('WEBVTT\n\n00:00:01.000 --> 00:00:03.500\n'));
      expect(out, isNot(contains('Kind:')));
    });

    test('strips cue settings after the end time', () {
      expect(normaliseYoutubeVtt(youtube), isNot(contains('align:')));
    });

    test('strips inline timing and style tags', () {
      final out = normaliseYoutubeVtt(youtube);
      expect(out, contains('00:00:03.500 --> 00:00:05.000\nto love'));
      expect(out, isNot(contains('<')));
    });

    test('drops a cue that only repeats the one before it', () {
      final out = normaliseYoutubeVtt(
        'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhello\n\n'
        '00:00:02.000 --> 00:00:03.000\nhello\n\n'
        '00:00:03.000 --> 00:00:04.000\nworld\n',
      );
      expect('-->'.allMatches(out).length, 2);
    });

    test('CRLF files and empty cues are handled', () {
      final out = normaliseYoutubeVtt(
        'WEBVTT\r\n\r\n00:00:01.000 --> 00:00:02.000\r\n\r\n'
        '00:00:02.000 --> 00:00:03.000\r\nok\r\n',
      );
      expect('-->'.allMatches(out).length, 1);
      expect(out, contains('ok'));
    });
  });

  group('PlaybackController.distinctAudioTracks', () {
    BetterPlayerAsmsAudioTrack track(int id, String? label, [String? lang]) =>
        BetterPlayerAsmsAudioTrack(id: id, label: label, language: lang);

    test('one audio listed per bitrate group is one track, not two', () {
      // Seen on an emulator: a video with no dubs offered an "Audio track"
      // picker with two rows both reading "Default".
      final out = PlaybackController.distinctAudioTracks(
        [track(0, 'Default'), track(1, 'Default')],
      );
      expect(out, hasLength(1));
    });

    test('real dubs survive, in order', () {
      final out = PlaybackController.distinctAudioTracks([
        track(0, 'English original'),
        track(1, 'Hindi'),
        track(2, 'English original'),
        track(3, null, 'es'),
      ]);
      expect(out.map((t) => t.id), [0, 1, 3]);
    });
  });

  group('PlaybackController.upgradeWorthwhile', () {
    bool worth(Duration position, Duration duration) =>
        PlaybackController.upgradeWorthwhile(
          position: position,
          duration: duration,
        );

    test('switches to HD with most of the video still to play', () {
      expect(worth(const Duration(seconds: 12), const Duration(minutes: 10)),
          isTrue);
    });

    test('leaves the last half-minute alone', () {
      // An upgrade landing here rebuilt the player, cancelled the autoplay
      // countdown, and swallowed the real finish as teardown noise: the video
      // sat on its last frame with no end screen and no next video.
      expect(
        worth(const Duration(minutes: 9, seconds: 45), const Duration(minutes: 10)),
        isFalse,
      );
      expect(worth(const Duration(minutes: 10), const Duration(minutes: 10)),
          isFalse);
    });

    test('exactly thirty seconds left still upgrades', () {
      expect(
        worth(const Duration(minutes: 9, seconds: 30), const Duration(minutes: 10)),
        isTrue,
      );
    });

    test('an unknown duration does not block the upgrade', () {
      expect(worth(const Duration(minutes: 5), Duration.zero), isTrue);
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

    test('reads the ABBREVIATED form the related lists use', () {
      // The bug this group exists to prevent recurring. YouTube's `next`
      // endpoint — the related list, which is the recommender's strongest
      // candidate source — writes ages as "17y ago", not "17 years ago". The
      // spelled-out pattern finds nothing in that, returns null, and the
      // ranker reads null as "age unknown" and scores it at the generous
      // midpoint. Every co-watch candidate was therefore treated as possibly
      // new, and seventeen-year-old videos outranked two-month-old ones.
      int? age(String raw) => YtRepository.uploadAgeSeconds(video(raw: raw));
      expect(age('17y ago'), 17 * 31536000);
      expect(age('5d ago'), const Duration(days: 5).inSeconds);
      expect(age('2w ago'), const Duration(days: 14).inSeconds);
      expect(age('4h ago'), const Duration(hours: 4).inSeconds);
      expect(age('45s ago'), 45);
    });

    test('abbreviated months are months, not minutes', () {
      // `mo` must be tested before `m`, or "9mo ago" is read as nine minutes —
      // which would make an old video the freshest thing in the feed, the
      // exact opposite of the bug being fixed.
      int? age(String raw) => YtRepository.uploadAgeSeconds(video(raw: raw));
      expect(age('9mo ago'), 9 * 2592000);
      expect(age('30m ago'), const Duration(minutes: 30).inSeconds);
      expect(age('9mo ago')!, greaterThan(age('30m ago')!));
    });

    test('abbreviated and spelled-out forms agree', () {
      int? age(String raw) => YtRepository.uploadAgeSeconds(video(raw: raw));
      expect(age('3d ago'), age('3 days ago'));
      expect(age('1y ago'), age('1 year ago'));
      expect(age('6mo ago'), age('6 months ago'));
    });

    test('gives up on anything with no unit word', () {
      int? age(String raw) => YtRepository.uploadAgeSeconds(video(raw: raw));
      // uploadRaw is sometimes an ISO timestamp. It carries digits but no unit
      // word, so it must fail to match rather than be read as "2026 seconds".
      // This is why the abbreviated form requires a following "ago": a bare
      // digit-then-letter rule would read "2026-08-05 15:56:39" as an age.
      expect(age('2026-08-05 15:56:39.000Z'), isNull);
      expect(age('2026-11-19T05:52:11Z'), isNull);
      expect(age('LIVE'), isNull);
      expect(age('1,204 views'), isNull);
      expect(age('17y'), isNull, reason: 'no "ago", so not a relative age');
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

    // --- the "recommendations are from six years back" group ---
    //
    // Three separate causes, each with its own test, because fixing one and
    // declaring victory is what happened the first time. The feed was full of
    // years-old video, and none of these on its own explains it.

    test('months old and years old are not the same thing', () {
      // The fast decay saturates: with a ten-day half-life alone, anything
      // past about two months scored zero on freshness, so a three-month-old
      // video and a six-year-old one were *tied* on the only term that knows
      // about age. Everything beyond the saturation point was a flat plain,
      // and the tiebreak then fell to accumulated views — which the older
      // video wins simply by having been around longer.
      final months = scoreOf(video('a', age: const Duration(days: 90)));
      final years = scoreOf(video('b', age: const Duration(days: 2190)));
      expect(months, greaterThan(years));
      // And the gap is worth something, not a rounding error.
      expect(months - years, greaterThan(0.1));
    });

    test('views are counted per day, so an old blockbuster does not win', () {
      // The heart of it. A view count only ever grows, so it measures age as
      // much as appeal. Totalled, the six-year-old video with fifty million
      // views beat the three-day-old one with two hundred thousand on
      // popularity *as well as* on the saturated freshness term — it won on
      // every term that could separate them. Rated, it is 23k views/day
      // against 67k, and the fresh one wins.
      final oldHit = video(
        'old',
        views: 50000000,
        age: const Duration(days: 2190),
      );
      final newHit = video(
        'new',
        views: 200000,
        age: const Duration(days: 3),
      );
      expect(scoreOf(newHit), greaterThan(scoreOf(oldHit)));
    });

    test('a video posted an hour ago is not credited with a daily rate', () {
      // Age is floored at a day before dividing, or a video an hour old would
      // have its views multiplied by twenty-four and lead the feed on a
      // handful of them.
      final hourOld = video('a', views: 1000, age: const Duration(hours: 1));
      final dayOld = video('b', views: 1000, age: const Duration(days: 1));
      // Same rate, so the only difference left is the freshness term — which
      // the newer one should win, but not by the 24x popularity would give it.
      expect(scoreOf(hourOld) - scoreOf(dayOld), lessThan(0.2));
      expect(scoreOf(hourOld), greaterThan(scoreOf(dayOld)));
    });

    test('an undated video is not crowned by having no age to divide by', () {
      // An unknown age is a parsing gap, not a claim about the video. Dividing
      // by a nominal month keeps every undated row on one scale; dividing by
      // nothing, or treating the age as zero, would have made undated rows the
      // most "popular" thing in the pool.
      final undated = VideoBrief(
        id: 'u',
        title: 'a woodworking bench build',
        author: 'x',
        channelId: 'x',
        viewCount: 1000000,
      );
      final fresh = video(
        'f',
        channel: 'x',
        views: 1000000,
        age: const Duration(days: 1),
      );
      expect(scoreOf(fresh), greaterThan(scoreOf(undated)));
    });

    test('a channel the user loves still beats a stranger posted today', () {
      // The limit on all of the above, and the reason freshness stays below
      // affinity and topic. "Prefer recent" must not become "prefer whatever
      // was posted most recently", or the feed stops being personal.
      final loved = video(
        'a',
        channel: 'UC-loved',
        age: const Duration(days: 20),
      );
      final strangerToday = video(
        'b',
        channel: 'UC-nobody',
        title: 'crypto trading signals',
        age: Duration.zero,
      );
      expect(scoreOf(loved), greaterThan(scoreOf(strangerToday)));
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

    test('one source cannot take the whole top of the feed', () {
      // Eight uploads from eight followed, well-watched channels against
      // eight co-watch rows from strangers. Subscription prior plus affinity
      // put every upload above every stranger, so the feed opened with a
      // block of subscriptions and the co-watch rows — the discovery source
      // — started at row nine. Measured live as 17 of the top 20. YouTube's
      // home is a mixture, and the cap keeps it one.
      final followed = {for (var i = 0; i < 8; i++) 'UC-sub$i'};
      final mixed = TasteProfile.from(
        history: [
          for (final channel in followed)
            WatchSignal(
              videoId: 'seen-$channel',
              channelId: channel,
              title: 'bench build',
              watchedAt: now.subtract(const Duration(days: 1)),
              completion: 0.9,
            ),
        ],
        searches: const [],
        subscribed: followed,
        now: now,
      );
      final out = rankFeed(
        candidates: [
          for (var i = 0; i < 8; i++)
            candidate(
              'sub$i',
              channel: 'UC-sub$i',
              source: CandidateSource.subscription,
              title: 'upload number $i',
            ),
          for (var i = 0; i < 8; i++)
            candidate(
              'cw$i',
              channel: 'UC-stranger$i',
              source: CandidateSource.coWatch,
              title: 'something else entirely $i',
            ),
        ],
        profile: mixed,
        now: now,
        explore: false,
      );
      expect(out, hasLength(16));
      // The single best row is still first, whatever its source.
      expect(out.first.id, startsWith('sub'));
      final topEight = out.take(8).toList();
      final subsInTop = topEight.where((v) => v.id.startsWith('sub')).length;
      expect(subsInTop, lessThanOrEqualTo(5));
      expect(subsInTop, greaterThanOrEqualTo(3));
      // And the cap yields rather than truncating: once the co-watch rows run
      // out, the remaining subscriptions still appear.
      expect(out.where((v) => v.id.startsWith('sub')), hasLength(8));
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

    test('a channel the viewer watches climbs a place over YouTube ordering', () {
      // A nudge, measured in places of YouTube's list — not a licence to
      // jump the queue from anywhere (see the test after this group's end).
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
          v('loved', channel: 'UC-loved'),
          v('b', channel: 'UC-nobody2'),
        ],
        profile: profile,
        now: now,
      );
      expect(out.first.id, 'loved');
    });

    test('a loved channel cannot leap from the bottom of the list', () {
      // Under a 2009 music video, profile terms used to lift the 18th related
      // video to the top. YouTube's order is the backbone now.
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
        subscribed: const {'UC-loved'},
        now: now,
      );
      final out = rankUpNext(
        current: current,
        related: [
          for (var i = 0; i < 6; i++) v('r$i', channel: 'UC-$i'),
          v('loved', channel: 'UC-loved'),
        ],
        profile: profile,
        now: now,
      );
      expect(out.take(3).map((x) => x.id), ['r0', 'r1', 'r2']);
    });

    test('autoplay does not walk down the current channel back catalogue', () {
      // Adjacent in YouTube's list, the one from the channel already on screen
      // — which this sitting has therefore already played, as the app always
      // reports — yields to the other. Only an adjacent swap: a nudge.
      final out = rankUpNext(
        current: current,
        related: [
          v('same', channel: 'UC-current'),
          v('different', channel: 'UC-elsewhere'),
        ],
        profile: TasteProfile.empty,
        now: now,
        recentlyPlayed: [current],
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

  // ------------------------------------------- recommender, second pass
  //
  // Engagement/satisfaction splitting, position-bias discounting, explicit
  // dismissals, topic diversity and exploration. Each is a separate judgement
  // about what somebody wants, so each is pinned separately.

  group('satisfaction', () {
    final now = DateTime(2026, 6, 1, 12);

    // The clickbait case, constructed so ENGAGEMENT IS EQUAL and only
    // satisfaction differs. 'bait' is opened nine times and abandoned after a
    // tenth of each; 'good' is opened once and nearly finished. Affinity is
    // completion x recency summed, so both come to 0.9 - which is exactly the
    // trap: under engagement alone these two channels are indistinguishable.
    final profile = TasteProfile.from(
      history: [
        WatchSignal(
          videoId: 'g1',
          channelId: 'good',
          title: 'alpha beta gamma',
          watchedAt: now,
          completion: 0.9,
        ),
        for (var i = 0; i < 9; i++)
          WatchSignal(
            videoId: 'b$i',
            channelId: 'bait',
            title: 'alpha beta gamma',
            watchedAt: now,
            completion: 0.1,
          ),
      ],
      searches: const [],
      subscribed: const {},
      now: now,
    );

    test('the two channels really are equal on engagement', () {
      // If this ever stops holding, the test below stops testing satisfaction
      // and starts testing affinity without saying so.
      expect(
        profile.channelAffinity['good']!,
        closeTo(profile.channelAffinity['bait']!, 1e-9),
      );
    });

    test('a channel that is opened and abandoned scores worse than one that '
        'is watched through', () {
      expect(
        profile.satisfactionFor('bait'),
        lessThan(profile.satisfactionFor('good')),
      );
    });

    VideoBrief candidateFrom(String channel) => VideoBrief(
          id: 'c-$channel',
          title: 'delta epsilon zeta',
          author: channel,
          channelId: channel,
          uploadDate: now.subtract(const Duration(days: 1)),
        );

    double scoreOf(String channel) {
      final maxAffinity = profile.channelAffinity.values
          .fold<double>(0, (a, b) => a > b ? a : b);
      return score(
        candidate: Candidate(
          video: candidateFrom(channel),
          source: CandidateSource.search,
        ),
        profile: profile,
        now: now,
        maxAffinity: maxAffinity,
      ).total;
    }

    test('so the clickbait channel is ranked below the satisfying one', () {
      // The whole point of splitting the objectives. Engagement alone cannot
      // tell these apart; the feed can.
      expect(scoreOf('bait'), lessThan(scoreOf('good')));
    });

    test('the gap between them is material, not a rounding error', () {
      // The two are indistinguishable to an engagement-only ranker, so this
      // whole gap is the satisfaction gate doing its job.
      expect(scoreOf('good') - scoreOf('bait'), greaterThan(0.3));
    });

    test('an unknown channel is neither rewarded nor punished for being new',
        () {
      // It sits at the neutral prior. Punished, nothing new could ever
      // surface; rewarded, the profile would be pointless.
      final unknown = TasteProfile.empty.satisfactionFor('stranger');
      expect(unknown, greaterThan(profile.satisfactionFor('bait')));
      expect(unknown, lessThan(profile.satisfactionFor('good')));
    });

    test('but a much-watched channel still out-ranks a stranger, gate or not',
        () {
      // Worth pinning because it is a deliberate limit, not an oversight.
      // Repeated abandonment demotes a channel; it does not banish it, because
      // opening something nine times is still engagement and the app cannot
      // know the user was not simply sampling. Banishing is what the explicit
      // "not interested" control is for, and that one IS absolute.
      expect(scoreOf('bait'), greaterThan(scoreOf('stranger')));
    });

    test('one abandoned video does not condemn a channel', () {
      // Shrinkage towards neutral. Without it, noise beats evidence: a channel
      // with a single bad sample would rank below one abandoned fifty times.
      final thin = TasteProfile.from(
        history: [
          WatchSignal(
            videoId: 'x',
            channelId: 'newish',
            title: 't',
            watchedAt: now,
            completion: 0.05,
          ),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
      );
      expect(
        thin.satisfactionFor('newish'),
        greaterThan(profile.satisfactionFor('bait')),
      );
    });

    test('satisfaction gates engagement rather than being added to it', () {
      // Multiplicative, and bounded either side, so a big engagement score
      // cannot simply drown it and a bad channel is held down without being
      // erased.
      const bad = ScoredCandidate(
        video: VideoBrief(id: 'a', title: 't', author: 'a', channelId: 'a'),
        source: CandidateSource.search,
        affinity: 1,
        topic: 1,
        freshness: 1,
        popularity: 1,
        context: 0,
        coVisit: 0,
        satisfaction: 0,
        impressionPenalty: 0,
        watchedPenalty: 0,
        dislikePenalty: 0,
      );
      const good = ScoredCandidate(
        video: VideoBrief(id: 'b', title: 't', author: 'b', channelId: 'b'),
        source: CandidateSource.search,
        affinity: 1,
        topic: 1,
        freshness: 1,
        popularity: 1,
        context: 0,
        coVisit: 0,
        satisfaction: 1,
        impressionPenalty: 0,
        watchedPenalty: 0,
        dislikePenalty: 0,
      );
      expect(bad.engagement, closeTo(good.engagement, 1e-9));
      expect(bad.total, lessThan(good.total));
      // Held down, not erased.
      expect(bad.total, greaterThan(0));
      expect(bad.satisfactionGate, greaterThan(0.0));
      expect(good.satisfactionGate, lessThan(2.0));
    });
  });

  group('attentionAtRank', () {
    test('the top card has the full attention of the viewer', () {
      expect(attentionAtRank(0), 1.0);
    });

    test('attention falls off down the feed', () {
      expect(attentionAtRank(5), lessThan(attentionAtRank(0)));
      expect(attentionAtRank(30), lessThan(attentionAtRank(5)));
    });

    test('it never reaches zero', () {
      // A card the recorder captured genuinely appeared. This discounts the
      // evidence; it must never erase it.
      expect(attentionAtRank(5000), greaterThan(0));
    });

    test('a skip at the top costs more than a skip near the bottom', () {
      final now = DateTime(2026, 6, 1);
      const video = VideoBrief(
        id: 'v',
        title: 'some ordinary title here',
        author: 'a',
        channelId: 'c',
      );
      double penaltyAt(int rank) => score(
            candidate:
                const Candidate(video: video, source: CandidateSource.search),
            profile: TasteProfile.empty,
            now: now,
            impression: ImpressionCount(
              videoId: 'v',
              shown: 1,
              attention: attentionAtRank(rank),
              lastShownAt: now,
            ),
          ).impressionPenalty;

      expect(penaltyAt(0), lessThan(penaltyAt(40)));
      expect(penaltyAt(40), lessThan(0));
    });
  });

  group('explicit dismissals', () {
    final now = DateTime(2026, 6, 1, 12);

    VideoBrief v(String id, {String channel = 'UC-x', String title = 'a clip'}) =>
        VideoBrief(
          id: id,
          title: title,
          author: channel,
          channelId: channel,
          uploadDate: now.subtract(const Duration(days: 1)),
        );

    TasteProfile profileWith({
      Set<String> channels = const {},
      List<WatchSignal> videos = const [],
    }) =>
        TasteProfile.from(
          history: const [],
          searches: const [],
          subscribed: const {},
          now: now,
          dislikedChannels: channels,
          dislikedVideos: videos,
        );

    test('a dismissed video is dropped from the feed, not merely demoted', () {
      final out = rankFeed(
        candidates: [
          Candidate(video: v('gone'), source: CandidateSource.search),
          Candidate(
            video: v('kept', channel: 'UC-y'),
            source: CandidateSource.search,
          ),
        ],
        profile: profileWith(
          videos: [
            WatchSignal(
              videoId: 'gone',
              channelId: '',
              title: 'a clip',
              watchedAt: now,
              completion: 0,
            ),
          ],
        ),
        now: now,
      );
      expect(out.map((x) => x.id), ['kept']);
    });

    test('a dismissed channel is dropped entirely', () {
      final out = rankFeed(
        candidates: [
          Candidate(video: v('a', channel: 'UC-bad'), source: CandidateSource.search),
          Candidate(video: v('b', channel: 'UC-bad'), source: CandidateSource.search),
          Candidate(video: v('c', channel: 'UC-ok'), source: CandidateSource.search),
        ],
        profile: profileWith(channels: const {'UC-bad'}),
        now: now,
      );
      expect(out.map((x) => x.id), ['c']);
    });

    test('an empty feed is an honest outcome when everything was dismissed', () {
      final out = rankFeed(
        candidates: [
          Candidate(video: v('a', channel: 'UC-bad'), source: CandidateSource.search),
        ],
        profile: profileWith(channels: const {'UC-bad'}),
        now: now,
      );
      expect(out, isEmpty);
    });

    test('a dismissal generalises weakly through the title', () {
      final profile = profileWith(
        videos: [
          WatchSignal(
            videoId: 'dismissed',
            channelId: '',
            title: 'shocking pyramid mystery',
            watchedAt: now,
            completion: 0,
          ),
        ],
      );
      double scoreOf(VideoBrief video) => score(
            candidate: Candidate(video: video, source: CandidateSource.search),
            profile: profile,
            now: now,
          ).total;

      expect(
        scoreOf(v('similar', channel: 'UC-z', title: 'pyramid mystery tour')),
        lessThan(scoreOf(v('unrelated', channel: 'UC-z', title: 'bench build'))),
      );
    });

    test('the generalisation is capped so one dismissal cannot kill a topic', () {
      final profile = profileWith(
        videos: [
          for (var i = 0; i < 40; i++)
            WatchSignal(
              videoId: 'd$i',
              channelId: '',
              title: 'pyramid',
              watchedAt: now,
              completion: 0,
            ),
        ],
      );
      final penalty = score(
        candidate: Candidate(
          video: v('x', title: 'pyramid'),
          source: CandidateSource.search,
        ),
        profile: profile,
        now: now,
      ).dislikePenalty;
      expect(penalty, greaterThan(-2.0));
      expect(penalty, lessThan(0));
    });

    test('a dismissed video never turns up as the next video either', () {
      final out = rankUpNext(
        current: v('playing', channel: 'UC-now'),
        related: [v('gone'), v('kept', channel: 'UC-y')],
        profile: profileWith(
          videos: [
            WatchSignal(
              videoId: 'gone',
              channelId: '',
              title: 'a clip',
              watchedAt: now,
              completion: 0,
            ),
          ],
        ),
        now: now,
      );
      expect(out.map((x) => x.id), ['kept']);
    });
  });

  group('topic diversity', () {
    final now = DateTime(2026, 6, 1, 12);

    Candidate c(String id, String channel, String title) => Candidate(
          video: VideoBrief(
            id: id,
            title: title,
            author: channel,
            channelId: channel,
            uploadDate: now.subtract(const Duration(days: 1)),
          ),
          source: CandidateSource.search,
        );

    test('four channels saying the same thing do not take the whole top', () {
      // Channel diversity alone would allow this: four DIFFERENT channels all
      // covering one phone launch. The user experiences that as the feed
      // repeating itself.
      final out = rankFeed(
        candidates: [
          c('p1', 'UC-1', 'iphone launch hands on impressions'),
          c('p2', 'UC-2', 'iphone launch hands on impressions'),
          c('p3', 'UC-3', 'iphone launch hands on impressions'),
          c('p4', 'UC-4', 'iphone launch hands on impressions'),
          c('w1', 'UC-5', 'woodworking bench dovetail joinery'),
        ],
        profile: TasteProfile.empty,
        now: now,
        explore: false,
      );
      // The odd one out must not be last: MMR should lift it once the first
      // phone video has been picked.
      expect(out.last.id, isNot('w1'));
      expect(out.indexWhere((v) => v.id == 'w1'), lessThan(4));
    });

    test('identical topics are still all returned, just spread out', () {
      final out = rankFeed(
        candidates: [
          c('p1', 'UC-1', 'iphone launch'),
          c('p2', 'UC-2', 'iphone launch'),
          c('w1', 'UC-3', 'bench joinery'),
        ],
        profile: TasteProfile.empty,
        now: now,
        explore: false,
      );
      expect(out, hasLength(3));
    });
  });

  group('exploration', () {
    final now = DateTime(2026, 6, 1, 12);

    Candidate c(String id, String channel) => Candidate(
          video: VideoBrief(
            id: id,
            title: 'clip $id about things',
            author: channel,
            channelId: channel,
            uploadDate: now.subtract(const Duration(days: 1)),
          ),
          source: CandidateSource.search,
        );

    final profile = TasteProfile.from(
      history: [
        WatchSignal(
          videoId: 'seen',
          channelId: 'UC-known',
          title: 'clip about things',
          watchedAt: now.subtract(const Duration(hours: 1)),
          completion: 1,
        ),
      ],
      searches: const [],
      subscribed: const {},
      now: now,
    );

    final candidates = [
      for (var i = 0; i < 12; i++) c('known$i', 'UC-known'),
      for (var i = 0; i < 12; i++) c('new$i', 'UC-new-$i'),
    ];

    test('a channel the profile has never seen still reaches the feed', () {
      // Without reserved novelty slots a confident ranker never discovers a
      // new interest, and with no training loop to correct it the feed narrows
      // until it is the same channels for ever.
      final out = rankFeed(
        candidates: candidates,
        profile: profile,
        now: now,
        limit: 12,
      );
      expect(out.where((v) => v.channelId.startsWith('UC-new')), isNotEmpty);
    });

    test('the same seed gives the same feed', () {
      List<String> run(int seed) => rankFeed(
            candidates: candidates,
            profile: profile,
            now: now,
            seed: seed,
          ).map((v) => v.id).toList();
      expect(run(7), run(7));
    });

    test('a different seed moves the feed around', () {
      // This is what makes pull-to-refresh worth doing. It is a resample of
      // near-ties, not a shuffle - the assertion is only that something moved.
      List<String> run(int seed) => rankFeed(
            candidates: candidates,
            profile: profile,
            now: now,
            seed: seed,
          ).map((v) => v.id).toList();
      final orders = {for (var seed = 0; seed < 8; seed++) run(seed).join(',')};
      expect(orders.length, greaterThan(1));
    });

    test('turning exploration off is deterministic without a seed', () {
      List<String> run() => rankFeed(
            candidates: candidates,
            profile: profile,
            now: now,
            explore: false,
          ).map((v) => v.id).toList();
      expect(run(), run());
    });

    test('exploration never promotes something the user dismissed', () {
      final out = rankFeed(
        candidates: candidates,
        profile: TasteProfile.from(
          history: const [],
          searches: const [],
          subscribed: const {},
          now: now,
          dislikedChannels: {for (var i = 0; i < 12; i++) 'UC-new-$i'},
        ),
        now: now,
      );
      expect(out.where((v) => v.channelId.startsWith('UC-new')), isEmpty);
    });
  });

  group('session context in up next', () {
    final now = DateTime(2026, 6, 1, 12);

    VideoBrief v(String id, {String channel = 'UC-other', String title = 'clip'}) =>
        VideoBrief(
          id: id,
          title: title,
          author: channel,
          channelId: channel,
          uploadDate: now.subtract(const Duration(days: 2)),
        );

    test('what is playing now beats what the profile says overall', () {
      // YouTube is explicit that the current video is the main signal for this
      // surface. Someone who usually watches cooking but has spent the last
      // hour on guitar wants another guitar video.
      final profile = TasteProfile.from(
        history: [
          WatchSignal(
            videoId: 'old',
            channelId: 'UC-cooking',
            title: 'risotto carbonara pasta recipe',
            watchedAt: now.subtract(const Duration(days: 1)),
            completion: 1,
          ),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
      );
      final out = rankUpNext(
        current: v(
          'playing',
          channel: 'UC-guitar',
          title: 'guitar fingerpicking lesson',
        ),
        // YouTube ranked the guitar drill first for a guitar lesson; a heavy
        // cooking history must not pull the cooking video over it. This is the
        // shape of the reported failure — a cricket video under a music video.
        related: [
          v('guitar', channel: 'UC-lessons', title: 'guitar fingerpicking drill'),
          v('cooking', channel: 'UC-cooking', title: 'risotto carbonara pasta'),
        ],
        profile: profile,
        now: now,
      );
      expect(out.first.id, 'guitar');
    });

    test('a video already played this sitting is not offered again', () {
      final out = rankUpNext(
        current: v('playing', channel: 'UC-now'),
        related: [v('seen-today'), v('fresh', channel: 'UC-y')],
        profile: TasteProfile.empty,
        now: now,
        recentlyPlayed: [v('seen-today')],
      );
      expect(out.map((x) => x.id), ['fresh']);
    });

    test('a channel played repeatedly this sitting is damped', () {
      final out = rankUpNext(
        current: v('playing', channel: 'UC-now'),
        related: [
          v('again', channel: 'UC-binged'),
          v('different', channel: 'UC-else'),
        ],
        profile: TasteProfile.empty,
        now: now,
        recentlyPlayed: [
          v('p1', channel: 'UC-binged'),
          v('p2', channel: 'UC-binged'),
          v('p3', channel: 'UC-binged'),
        ],
      );
      expect(out.first.id, 'different');
    });

    test('an empty session changes nothing', () {
      final related = [for (var i = 0; i < 4; i++) v('r$i', channel: 'UC-$i')];
      expect(
        rankUpNext(
          current: v('playing', channel: 'UC-now'),
          related: related,
          profile: TasteProfile.empty,
          now: now,
        ).map((x) => x.id),
        rankUpNext(
          current: v('playing', channel: 'UC-now'),
          related: related,
          profile: TasteProfile.empty,
          now: now,
          recentlyPlayed: const [],
        ).map((x) => x.id),
      );
    });
  });

  // ------------------------------------------- the ranker's learning loop
  //
  // A single-user linear model fed a handful of examples will cheerfully
  // conclude something absurd, so the guards matter more than the fit: these
  // pin that it learns in the right direction AND that it cannot run away.

  group('RankerWeights.predict', () {
    test('is a probability', () {
      final p = RankerWeights.prior.predict([1, 1, 1, 1, 1, 1, 1]);
      expect(p, greaterThan(0));
      expect(p, lessThan(1));
    });

    test('a stronger feature vector predicts a higher chance', () {
      final weak = RankerWeights.prior.predict([0, 0, 0, 0, 0, 0, 0]);
      final strong = RankerWeights.prior.predict([1, 1, 1, 1, 1, 1, 1]);
      expect(strong, greaterThan(weak));
    });

    test('an absurd input saturates instead of overflowing', () {
      // exp() of a large number is infinity, and an infinite score would sort
      // unpredictably rather than loudly.
      final p = RankerWeights.prior.predict([1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9]);
      expect(p.isFinite, isTrue);
      expect(p, lessThanOrEqualTo(1.0));
    });

    test('a short feature vector does not throw', () {
      // Old rows written before a feature was added must degrade, not crash.
      expect(RankerWeights.prior.predict([1, 1]).isFinite, isTrue);
    });
  });

  group('RankerWeights.trainedOn', () {
    List<double> only(int index) =>
        [for (var i = 0; i < 7; i++) i == index ? 1.0 : 0.0];

    test('no examples changes nothing', () {
      final after = RankerWeights.prior.trainedOn(const []);
      expect(after.affinity, RankerWeights.prior.affinity);
      expect(after.bias, RankerWeights.prior.bias);
    });

    test('a feature present when videos get opened gains weight', () {
      final after = RankerWeights.prior.trainedOn([
        for (var i = 0; i < 30; i++)
          RankingExample(features: only(1), opened: true, completion: 1),
      ]);
      expect(after.affinity, greaterThan(RankerWeights.prior.affinity));
    });

    test('a feature present when videos get ignored loses weight', () {
      final after = RankerWeights.prior.trainedOn([
        for (var i = 0; i < 30; i++)
          RankingExample(features: only(4), opened: false, completion: 0),
      ]);
      expect(after.popularity, lessThan(RankerWeights.prior.popularity));
    });

    test('a video watched through teaches more than one bounced off', () {
      // Watch time as the positive weight - the objective from the 2016 paper,
      // and the reason a recommender does not end up optimising for clickbait.
      double gain(double completion) =>
          RankerWeights.prior.trainedOn([
            RankingExample(
              features: only(1),
              opened: true,
              completion: completion,
            ),
          ]).affinity -
          RankerWeights.prior.affinity;

      expect(gain(1.0), greaterThan(gain(0.05)));
    });

    test('a feature that was not present is left alone', () {
      final after = RankerWeights.prior.trainedOn([
        for (var i = 0; i < 20; i++)
          RankingExample(features: only(1), opened: true, completion: 1),
      ]);
      expect(after.freshness, closeTo(RankerWeights.prior.freshness, 1e-9));
    });

    test('weights are clamped, so one strange run cannot take over', () {
      final after = RankerWeights.prior.trainedOn([
        for (var i = 0; i < 5000; i++)
          RankingExample(
            features: List.filled(7, 1),
            opened: true,
            completion: 1,
          ),
      ]);
      for (final w in [
        after.source,
        after.affinity,
        after.topic,
        after.freshness,
        after.popularity,
        after.context,
        after.coVisit,
      ]) {
        expect(w, lessThanOrEqualTo(3.0));
        expect(w, greaterThanOrEqualTo(-0.5));
      }
      expect(after.bias.abs(), lessThanOrEqualTo(6.0));
    });

    test('training never produces a weight that is not a number', () {
      final after = RankerWeights.prior.trainedOn([
        for (var i = 0; i < 200; i++)
          RankingExample(
            features: List.filled(7, i.isEven ? 1.0 : 0.0),
            opened: i % 3 == 0,
            completion: i / 200,
          ),
      ]);
      for (final w in after.toMap().values) {
        expect(w.isFinite, isTrue, reason: 'weight went non-finite');
      }
    });
  });

  group('RankerWeights.blend', () {
    final learned = RankerWeights.prior.trainedOn([
      for (var i = 0; i < 200; i++)
        RankingExample(
          features: [0, 1, 0, 0, 0, 0, 0],
          opened: true,
          completion: 1,
        ),
    ]);

    test('nothing learned is used before there is enough evidence', () {
      // A model fitted to four data points is worse than an honest guess.
      final blended =
          RankerWeights.blend(learned, RankerWeights.minExamplesToApply - 1);
      expect(blended.affinity, RankerWeights.prior.affinity);
    });

    test('learning starts to count once there is', () {
      final blended =
          RankerWeights.blend(learned, RankerWeights.examplesForFullTrust);
      expect(blended.affinity, isNot(RankerWeights.prior.affinity));
    });

    test('the priors always keep at least half the decision', () {
      final blended = RankerWeights.blend(learned, 1000000);
      final gap = (blended.affinity - RankerWeights.prior.affinity).abs();
      final full = (learned.affinity - RankerWeights.prior.affinity).abs();
      expect(gap, lessThanOrEqualTo(full * RankerWeights.maxLearnedShare + 1e-9));
    });

    test('trust grows with evidence rather than switching on', () {
      double share(int seen) =>
          (RankerWeights.blend(learned, seen).affinity -
                  RankerWeights.prior.affinity)
              .abs();
      expect(share(300), greaterThan(share(100)));
      expect(share(100), greaterThan(share(50)));
    });
  });

  group('RankerWeights round trip', () {
    test('survives being stored and read back', () {
      final original = RankerWeights.prior.trainedOn([
        const RankingExample(
          features: [1, 1, 1, 1, 1, 1, 1],
          opened: true,
          completion: 0.7,
        ),
      ]);
      final restored = RankerWeights.fromMap(original.toMap());
      expect(restored.toMap(), original.toMap());
    });

    test('a missing field falls back to the prior, never to zero', () {
      // Zeros would rank every video equally, which looks exactly like the
      // feature being broken rather than like a corrupted preference.
      final restored = RankerWeights.fromMap(const {'affinity': 2.0});
      expect(restored.affinity, 2.0);
      expect(restored.topic, RankerWeights.prior.topic);
      expect(restored.popularity, RankerWeights.prior.popularity);
    });

    test('a corrupted field falls back too', () {
      final restored = RankerWeights.fromMap(const {
        'affinity': 'not a number',
        'topic': double.nan,
        'freshness': double.infinity,
      });
      expect(restored.affinity, RankerWeights.prior.affinity);
      expect(restored.topic, RankerWeights.prior.topic);
      expect(restored.freshness, RankerWeights.prior.freshness);
    });
  });

  group('learned weights change the ranking', () {
    final now = DateTime(2026, 6, 1, 12);

    Candidate c(String id, String channel, {int views = 1000}) => Candidate(
          video: VideoBrief(
            id: id,
            title: 'a clip about $id',
            author: channel,
            channelId: channel,
            viewCount: views,
            uploadDate: now.subtract(const Duration(days: 1)),
          ),
          source: CandidateSource.search,
        );

    test('a feed ranked with different weights can come out differently', () {
      // The whole point of the loop: if the weights could not move the order,
      // learning them would be theatre.
      final candidates = [
        c('popular', 'UC-a', views: 5000000),
        c('obscure', 'UC-b', views: 50),
      ];
      const popularityHeavy = RankerWeights(
        source: 0.1,
        affinity: 0.1,
        topic: 0.1,
        freshness: 0.1,
        popularity: 3.0,
        context: 0.1,
        coVisit: 0.1,
        bias: 0,
      );
      final byPopularity = rankFeed(
        candidates: candidates,
        profile: TasteProfile.empty,
        now: now,
        explore: false,
        weights: popularityHeavy,
      );
      expect(byPopularity.first.id, 'popular');
    });

    test('the feature vector matches what the weights expect', () {
      // Two lists that must stay the same length and order, in different
      // files. If they drift, the model silently trains on the wrong columns -
      // which would not crash and would not show up anywhere else.
      final features = <String, List<double>>{};
      rankFeed(
        candidates: [c('a', 'UC-a')],
        profile: TasteProfile.empty,
        now: now,
        explore: false,
        featuresOut: features,
      );
      expect(features['a'], hasLength(7));
      expect(
        RankerWeights.prior.toMap().length,
        features['a']!.length + 1, // + the intercept
      );
    });
  });

  group('co-visitation', () {
    final now = DateTime(2026, 6, 1, 12);

    VideoBrief v(String id, {String channel = 'UC-x'}) => VideoBrief(
          id: id,
          title: 'a clip about $id',
          author: channel,
          channelId: channel,
          uploadDate: now.subtract(const Duration(days: 1)),
        );

    test('a strongly co-visited video outranks an identical one', () {
      final profile = TasteProfile.from(
        history: const [],
        searches: const [],
        subscribed: const {},
        now: now,
        coVisit: const {'linked': 10, 'unlinked': 0},
      );
      double scoreOf(String id) => score(
            candidate:
                Candidate(video: v(id), source: CandidateSource.search),
            profile: profile,
            now: now,
          ).total;
      expect(scoreOf('linked'), greaterThan(scoreOf('unlinked')));
    });

    test('scores are normalised, so a heavy user and a light one agree', () {
      final light = TasteProfile.from(
        history: const [],
        searches: const [],
        subscribed: const {},
        now: now,
        coVisit: const {'a': 1, 'b': 0.5},
      );
      final heavy = TasteProfile.from(
        history: const [],
        searches: const [],
        subscribed: const {},
        now: now,
        coVisit: const {'a': 1000, 'b': 500},
      );
      expect(light.coVisit['a'], heavy.coVisit['a']);
      expect(light.coVisit['b'], heavy.coVisit['b']);
    });

    test('an empty graph contributes nothing rather than dividing by zero', () {
      final profile = TasteProfile.from(
        history: const [],
        searches: const [],
        subscribed: const {},
        now: now,
        coVisit: const {},
      );
      expect(profile.coVisit, isEmpty);
      expect(
        score(
          candidate:
              Candidate(video: v('a'), source: CandidateSource.search),
          profile: profile,
          now: now,
        ).coVisit,
        0,
      );
    });
  });

  group('endorsement and bail-out signals', () {
    final now = DateTime(2026, 6, 1, 12);

    test('saving or downloading from a channel lifts its satisfaction', () {
      // The local stand-in for a like: not a reflex the way a thumb tap is.
      final profile = TasteProfile.from(
        history: [
          WatchSignal(
            videoId: 'a',
            channelId: 'UC-saved',
            title: 't',
            watchedAt: now,
            completion: 0.2,
          ),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
        endorsedChannels: const {'UC-saved'},
      );
      final plain = TasteProfile.from(
        history: [
          WatchSignal(
            videoId: 'a',
            channelId: 'UC-saved',
            title: 't',
            watchedAt: now,
            completion: 0.2,
          ),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
      );
      expect(
        profile.satisfactionFor('UC-saved'),
        greaterThan(plain.satisfactionFor('UC-saved')),
      );
    });

    test('an endorsement is a floor, not a bonus stacked on a good record', () {
      final profile = TasteProfile.from(
        history: [
          WatchSignal(
            videoId: 'a',
            channelId: 'UC-loved',
            title: 't',
            watchedAt: now,
            completion: 1,
          ),
          WatchSignal(
            videoId: 'b',
            channelId: 'UC-loved',
            title: 't',
            watchedAt: now,
            completion: 1,
          ),
          WatchSignal(
            videoId: 'c',
            channelId: 'UC-loved',
            title: 't',
            watchedAt: now,
            completion: 1,
          ),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
        endorsedChannels: const {'UC-loved'},
      );
      expect(profile.satisfactionFor('UC-loved'), lessThanOrEqualTo(1.0));
    });

    test('opening something and leaving at once is a rejection, not a watch',
        () {
      // A four-second visit is the user saying the title lied. Counted as a
      // small positive - which is what a plain completion weighting does - it
      // is exactly how clickbait accumulates.
      final bailed = WatchSignal(
        videoId: 'x',
        channelId: 'c',
        title: 't',
        watchedAt: now,
        completion: 0.02,
      );
      expect(bailed.bailedOut, isTrue);
    });

    test('a bail-out adds nothing to the channel it came from', () {
      final profile = TasteProfile.from(
        history: [
          for (var i = 0; i < 10; i++)
            WatchSignal(
              videoId: 'b$i',
              channelId: 'UC-bait',
              title: 't',
              watchedAt: now,
              completion: 0.02,
            ),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
      );
      expect(profile.channelAffinity['UC-bait'] ?? 0, 0);
    });

    test('a normal short view still counts for something', () {
      // The threshold must not swallow ordinary partial viewing - somebody who
      // watches a fifth of a long video is still interested.
      final profile = TasteProfile.from(
        history: [
          WatchSignal(
            videoId: 'a',
            channelId: 'UC-ok',
            title: 't',
            watchedAt: now,
            completion: 0.2,
          ),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
      );
      expect(profile.channelAffinity['UC-ok'], greaterThan(0));
    });
  });

  // ------------------------------------------------- declared interests
  //
  // The one case inference cannot help with: a fresh install has no behaviour
  // to infer from. These pin that a declared interest behaves like a strong
  // prior rather than an override - it has to lead a feed that knows nothing,
  // and get out of the way once real behaviour disagrees with it.

  group('interest catalogue', () {
    test('every id is unique', () {
      // A duplicate id silently makes one entry unselectable.
      final ids = interestCatalogue.map((i) => i.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('every interest carries search terms', () {
      for (final interest in interestCatalogue) {
        expect(interest.queries, isNotEmpty, reason: interest.id);
        expect(interest.label, isNotEmpty, reason: interest.id);
      }
    });

    test('every query survives tokenising into something usable', () {
      // The queries are seeded into the topic model, so one made entirely of
      // stop words would contribute nothing and look like a dead interest.
      for (final interest in interestCatalogue) {
        for (final query in interest.queries) {
          expect(tokenise(query), isNotEmpty, reason: '${interest.id}: $query');
        }
      }
    });

    test('a known id resolves and an unknown one is null, not a throw', () {
      expect(interestById('tech')?.label, 'Technology');
      // The normal outcome after a catalogue edit, not an error.
      expect(interestById('no-such-interest'), isNull);
    });
  });

  group('interestQueries', () {
    test('expands the chosen ids', () {
      final queries = interestQueries(['ai']);
      expect(queries, isNotEmpty);
      expect(queries.join(' '), contains('ai'));
    });

    test('nothing chosen means nothing, not everything', () {
      expect(interestQueries(const []), isEmpty);
    });

    test('an unknown id is ignored rather than throwing', () {
      expect(interestQueries(['tech', 'was-removed']),
          interestQueries(['tech']));
    });

    test('order follows the catalogue, not the order they were tapped', () {
      // Tap order is an artefact of which chip was nearest; a feed whose
      // composition depended on it would change for no visible reason.
      expect(interestQueries(['news', 'tech']), interestQueries(['tech', 'news']));
    });

    test('duplicates across interests appear once', () {
      final queries = interestQueries(interestCatalogue.map((i) => i.id));
      expect(queries.toSet(), hasLength(queries.length));
    });
  });

  group('declared interests in the profile', () {
    final now = DateTime(2026, 6, 1, 12);

    VideoBrief video(String id, String title) => VideoBrief(
          id: id,
          title: title,
          author: 'Someone',
          channelId: 'UC-$id',
          uploadDate: now.subtract(const Duration(days: 1)),
        );

    double scoreOf(TasteProfile profile, VideoBrief v) => score(
          candidate: Candidate(video: v, source: CandidateSource.topic),
          profile: profile,
          now: now,
        ).total;

    test('a fresh install with interests is no longer an empty profile', () {
      // Which matters beyond tidiness: an empty profile makes homeFeed fall
      // back to the unranked round-robin.
      final profile = TasteProfile.from(
        history: const [],
        searches: const [],
        subscribed: const {},
        now: now,
        interestQueries: interestQueries(['ai']),
      );
      expect(profile.isEmpty, isFalse);
      expect(profile.topicWeights, isNotEmpty);
    });

    test('a matching video outranks an unrelated one from day one', () {
      final profile = TasteProfile.from(
        history: const [],
        searches: const [],
        subscribed: const {},
        now: now,
        interestQueries: interestQueries(['ai']),
      );
      expect(
        scoreOf(profile, video('a', 'machine learning tutorial for beginners')),
        greaterThan(scoreOf(profile, video('b', 'street food market tour'))),
      );
    });

    test('choosing nothing leaves the profile exactly as it was', () {
      final withNone = TasteProfile.from(
        history: const [],
        searches: const [],
        subscribed: const {},
        now: now,
        interestQueries: const [],
      );
      expect(withNone.topicWeights, isEmpty);
      expect(withNone.isEmpty, isTrue);
    });

    test('it seeds the same weights searching would, not a separate override',
        () {
      // The design: a declared interest behaves as though the user had already
      // searched for it, so real behaviour is weighed alongside rather than
      // behind it.
      final declared = TasteProfile.from(
        history: const [],
        searches: const [],
        subscribed: const {},
        now: now,
        interestQueries: const ['machine learning tutorial'],
      );
      for (final token in tokenise('machine learning tutorial')) {
        expect(declared.topicWeights[token], greaterThan(0));
      }
    });

    test('watching something else for long enough outweighs the declaration',
        () {
      // An interest is a strong prior, not a permanent verdict. Somebody who
      // ticked AI and then spent a month on cooking should get cooking.
      final profile = TasteProfile.from(
        history: [
          for (var i = 0; i < 30; i++)
            WatchSignal(
              videoId: 'w$i',
              channelId: 'UC-food',
              title: 'street food market tour',
              watchedAt: now.subtract(Duration(hours: i)),
              completion: 1,
            ),
        ],
        searches: const [],
        subscribed: const {},
        now: now,
        interestQueries: interestQueries(['ai']),
      );
      expect(
        scoreOf(profile, video('food', 'street food market tour')),
        greaterThan(
          scoreOf(profile, video('ai', 'machine learning tutorial')),
        ),
      );
    });
  });

  group('language and region', () {
    test('every catalogue offers a device-default option first', () {
      // Both default to empty, so the app is useful before anyone opens the
      // screen - which is the point of a default rather than a required
      // choice.
      expect(languageCatalogue.first.code, '');
      expect(regionCatalogue.first.code, '');
    });

    test('codes are unique', () {
      expect(
        languageCatalogue.map((l) => l.code).toSet(),
        hasLength(languageCatalogue.length),
      );
      expect(
        regionCatalogue.map((r) => r.code).toSet(),
        hasLength(regionCatalogue.length),
      );
    });

    test('labels resolve, and an unlisted code shows itself', () {
      expect(languageLabel('hi'), contains('Hindi'));
      expect(regionLabel('IN'), 'India');
      expect(languageLabel(''), languageCatalogue.first.label);
      // A device locale this app does not list is entirely normal, and
      // showing "pl" is more honest than showing "Match my device".
      expect(languageLabel('pl'), 'pl');
      expect(regionLabel('PL'), 'PL');
    });

    test('resolveCode prefers the choice, then the device, then the fallback',
        () {
      expect(resolveCode('hi', 'en', 'en'), 'hi');
      expect(resolveCode('', 'ta', 'en'), 'ta');
      expect(resolveCode('', '', 'en'), 'en');
    });

    test('whitespace does not pass for a choice', () {
      expect(resolveCode('   ', 'ta', 'en'), 'ta');
      expect(resolveCode('  ', '  ', 'US'), 'US');
    });
  });

  group('withLanguages', () {
    test('passes queries through when no language is chosen', () {
      expect(withLanguages(['ai tools'], const []), ['ai tools']);
    });

    test('English adds no suffix', () {
      // Its searchWord is empty, so asking for English changes nothing.
      expect(withLanguages(['ai tools'], ['en']), ['ai tools']);
    });

    test('a language adds a suffixed variant and keeps the original', () {
      expect(
        withLanguages(['ai tools'], ['hi']),
        ['ai tools', 'ai tools hindi'],
      );
    });

    test('languages are interleaved per query, not concatenated', () {
      // Candidate generation only takes the first few queries, so grouping all
      // of one language first would mean the second never appeared at all -
      // which looks exactly like the setting being ignored.
      expect(
        withLanguages(['a', 'b'], ['hi', 'ta']),
        ['a', 'a hindi', 'a tamil', 'b', 'b hindi', 'b tamil'],
      );
    });

    test('an unknown language code is ignored', () {
      expect(withLanguages(['ai'], ['zz']), ['ai']);
    });

    test('duplicate codes do not duplicate queries', () {
      expect(withLanguages(['ai'], ['hi', 'hi']), ['ai', 'ai hindi']);
    });

    test('no queries means no output, whatever the languages', () {
      expect(withLanguages(const [], ['hi']), isEmpty);
    });

    test('every feed language has a usable search word except English', () {
      for (final l in feedLanguageCatalogue) {
        if (l.code == 'en') {
          expect(l.searchWord, isEmpty);
        } else {
          expect(l.searchWord, isNotEmpty, reason: l.code);
        }
      }
    });

    test('feed language codes are unique', () {
      expect(
        feedLanguageCatalogue.map((l) => l.code).toSet(),
        hasLength(feedLanguageCatalogue.length),
      );
    });

    test('feedLanguageByCode finds a known one and nulls an unknown', () {
      expect(feedLanguageByCode('ta')?.searchWord, 'tamil');
      expect(feedLanguageByCode('zz'), isNull);
    });
  });

  group('CustomFeed.queries', () {
    CustomFeed feed(String query) => CustomFeed(name: 'f', query: query);

    test('commas separate distinct searches', () {
      expect(feed('ai tools, homelab').queries, ['ai tools', 'homelab']);
    });

    test('spaces do NOT — a phrase is one search', () {
      // "machine learning tutorial" split into three words would return
      // nothing like what was asked for.
      expect(feed('machine learning tutorial').queries,
          ['machine learning tutorial']);
    });

    test('newlines and semicolons separate too', () {
      expect(feed('a\nbb;ccc').queries, ['bb', 'ccc']);
    });

    test('whitespace and empty fragments are dropped', () {
      expect(feed('  proxmox , , truenas  ').queries, ['proxmox', 'truenas']);
    });

    test('a single character is not a search term', () {
      expect(feed('x').queries, isEmpty);
      expect(feed('x, proxmox').queries, ['proxmox']);
    });

    test('isUsable needs both a name and a term', () {
      expect(const CustomFeed(name: 'Homelab', query: 'proxmox').isUsable,
          isTrue);
      expect(const CustomFeed(name: '', query: 'proxmox').isUsable, isFalse);
      expect(const CustomFeed(name: 'Homelab', query: ' ').isUsable, isFalse);
      expect(const CustomFeed(name: '  ', query: 'proxmox').isUsable, isFalse);
    });
  });

  group('custom feed storage', () {
    test('round-trips', () {
      const feeds = [
        CustomFeed(name: 'Homelab', query: 'proxmox, truenas'),
        CustomFeed(name: 'AI', query: 'llm news'),
      ];
      final back = decodeCustomFeeds(encodeCustomFeeds(feeds));
      expect(back.map((f) => f.name).toList(), ['Homelab', 'AI']);
      expect(back.first.query, 'proxmox, truenas');
    });

    test('a name containing a comma survives', () {
      // The reason this is JSON and not a joined string: users type
      // separators, and a delimited format would split the name in half.
      const feeds = [CustomFeed(name: 'Cars, bikes', query: 'car review')];
      expect(decodeCustomFeeds(encodeCustomFeeds(feeds)).single.name,
          'Cars, bikes');
    });

    test('empty storage decodes to nothing', () {
      expect(decodeCustomFeeds(''), isEmpty);
      expect(decodeCustomFeeds('   '), isEmpty);
    });

    test('corrupt storage costs the feeds, not the Home screen', () {
      // A half-written preference is what a crash mid-write leaves behind.
      expect(decodeCustomFeeds('{not json'), isEmpty);
      expect(decodeCustomFeeds('"a string"'), isEmpty);
      expect(decodeCustomFeeds('[1, 2, 3]'), isEmpty);
    });

    test('unusable entries are skipped, usable ones kept', () {
      final out = decodeCustomFeeds(
        '[{"name":"","query":"x"},{"name":"Good","query":"proxmox"},'
        '{"name":"NoQuery","query":""}]',
      );
      expect(out.map((f) => f.name).toList(), ['Good']);
    });

    test('duplicate names are dropped — the name is the identity', () {
      final out = decodeCustomFeeds(
        '[{"name":"AI","query":"one"},{"name":"ai","query":"two"}]',
      );
      expect(out, hasLength(1));
      expect(out.single.query, 'one');
    });
  });

  // ------------------------------------------- combining the player clients
  //
  // Why these exist: adding adaptive tracks to `hasVideo` — which the DASH
  // work had to do — silently broke iOS. The clients return different things,
  // the old code kept one response and discarded the others, and the response
  // it started keeping was the one with no stream an iPhone can play. Android
  // was fine throughout, so nothing here caught it and it shipped.
  //
  // Each test below is one of the ways that merge can go wrong.

  group('PlayerStreams.merge', () {
    AdaptiveFormat fmt(int itag, {bool videoTrack = true}) => AdaptiveFormat(
          itag: itag,
          url: 'https://r1.googlevideo.com/v?itag=$itag',
          mimeType: videoTrack ? 'video/mp4' : 'audio/mp4',
          codecs: videoTrack ? 'avc1.640028' : 'mp4a.40.2',
          bitrate: 1000,
          durationMs: 60000,
          initStart: 0,
          initEnd: 700,
          indexStart: 701,
          indexEnd: 2000,
          height: videoTrack ? 1080 : 0,
        );

    test('a muxed stream survives an adaptive-only response seen first', () {
      // THE REGRESSION, exactly. The ios client returns adaptive tracks and no
      // progressive stream; the android client returns the 360p progressive.
      // Keeping only the first left iOS — which cannot play DASH — with
      // nothing, and every such video showed "could not find a playable
      // stream".
      final iosLike = PlayerStreams(
        adaptiveFormats: [fmt(137), fmt(140, videoTrack: false)],
      );
      final androidLike = PlayerStreams(
        muxedUrl: 'https://r1.googlevideo.com/v?itag=18',
        muxedQualities: const {'360p': 'https://r1.googlevideo.com/v?itag=18'},
        adaptiveFormats: [fmt(137), fmt(140, videoTrack: false)],
      );

      final merged = PlayerStreams.merge([iosLike, androidLike]);
      expect(merged.muxedUrl, isNotNull,
          reason: 'iOS has nothing to play without this');
      expect(merged.muxedQualities, isNotEmpty);
      expect(merged.hasAdaptiveVideo, isTrue,
          reason: 'Android must keep its DASH ladder');
    });

    test('an HLS ladder is kept wherever it came from', () {
      final plain = PlayerStreams(adaptiveFormats: [fmt(137)]);
      final withHls = PlayerStreams(hlsUrl: 'https://m.googlevideo.com/x.m3u8');
      expect(PlayerStreams.merge([plain, withHls]).hlsUrl, isNotNull);
    });

    test('the muxed URL and its quality map come from the same response', () {
      // Pairing one client's chosen URL with another's label map would offer a
      // picker whose entries point at a different client's streams.
      final a = PlayerStreams(
        muxedUrl: 'https://a.example/v',
        muxedQualities: const {'360p': 'https://a.example/v'},
      );
      final b = PlayerStreams(
        muxedUrl: 'https://b.example/v',
        muxedQualities: const {'720p': 'https://b.example/v'},
      );
      final merged = PlayerStreams.merge([a, b]);
      expect(merged.muxedQualities.values, contains(merged.muxedUrl));
    });

    test('adaptive formats are taken whole, never spliced together', () {
      // A DASH manifest must describe one coherent set of tracks. Concatenating
      // two clients' views produces duplicate itags and tracks that disagree
      // about duration.
      final thin = PlayerStreams(adaptiveFormats: [fmt(137)]);
      final rich = PlayerStreams(
        adaptiveFormats: [fmt(137), fmt(248), fmt(140, videoTrack: false)],
      );
      final merged = PlayerStreams.merge([thin, rich]);
      expect(merged.adaptiveFormats.length, 3);
      expect(
        merged.adaptiveFormats.map((f) => f.itag).toSet().length,
        3,
        reason: 'no duplicate itags, so nothing was concatenated',
      );
    });

    test('a single response is returned unchanged', () {
      final only = PlayerStreams(muxedUrl: 'https://a.example/v');
      expect(PlayerStreams.merge([only]), same(only));
    });

    test('live is true if any client says so', () {
      expect(
        PlayerStreams.merge([
          PlayerStreams(),
          PlayerStreams(hlsUrl: 'https://m.googlevideo.com/x.m3u8', isLive: true),
        ]).isLive,
        isTrue,
      );
    });
  });

  // ------------------------------------------------------------------ DASH
  //
  // How HD plays at all. YouTube returns `hlsManifestUrl` for about one video
  // in eight now, and for the rest the only renditions above 360p are the
  // separate video-only and audio-only tracks. These tests pin the manifest
  // that puts them back together — see lib/src/data/dash_manifest.dart.

  group('parseAdaptiveFormat', () {
    Map<String, Object?> video({
      Object? url = 'https://r1.googlevideo.com/v?a=1&b=2',
      Object? mimeType = 'video/mp4; codecs="avc1.640028"',
      Object? height = 1080,
      Object? initEnd = 752,
      Object? indexStart = 753,
      Object? indexEnd = 1528,
      Object? duration = '313780',
    }) => {
      'itag': 299,
      'url': url,
      'mimeType': mimeType,
      'bitrate': 5889664,
      'width': 1920,
      'height': height,
      'fps': 60,
      'initRange': {'start': '0', 'end': '$initEnd'},
      'indexRange': {'start': '$indexStart', 'end': '$indexEnd'},
      'approxDurationMs': duration,
    };

    test('splits the codec out of the mime type', () {
      final f = parseAdaptiveFormat(video())!;
      expect(f.mimeType, 'video/mp4');
      expect(f.codecs, 'avc1.640028');
      expect(f.codecFamily, 'avc');
    });

    test('reads ranges that arrive as strings', () {
      // initRange.start is "0" and height is 1080 in the same response: every
      // number here has to be read, not cast.
      final f = parseAdaptiveFormat(video())!;
      expect(f.initStart, 0);
      expect(f.initEnd, 752);
      expect(f.indexStart, 753);
      expect(f.indexEnd, 1528);
      expect(f.height, 1080);
      expect(f.durationMs, 313780);
    });

    test('a format behind signatureCipher is dropped', () {
      // No plain URL means deciphering, which needs the player JS. Emitting it
      // would put a Representation in the manifest that cannot be fetched.
      expect(parseAdaptiveFormat(video(url: null)), isNull);
    });

    test('a format with no index range is dropped', () {
      // DASH SegmentBase has nothing to point at without one.
      expect(parseAdaptiveFormat(video(indexStart: 0, indexEnd: 0)), isNull);
    });

    test('a format with no duration is dropped', () {
      expect(parseAdaptiveFormat(video(duration: null)), isNull);
    });

    test('codec families are recognised', () {
      String family(String codecs) => parseAdaptiveFormat(
        video(mimeType: 'video/mp4; codecs="$codecs"'),
      )!.codecFamily;
      expect(family('avc1.640028'), 'avc');
      expect(family('vp9'), 'vp9');
      expect(family('vp09.00.50.08'), 'vp9');
      expect(family('av01.0.12M.08'), 'av1');
    });

    test('junk is not a format', () {
      expect(parseAdaptiveFormat(null), isNull);
      expect(parseAdaptiveFormat('nonsense'), isNull);
      expect(parseAdaptiveFormat(<String, Object?>{}), isNull);
    });
  });

  group('buildDashManifest', () {
    AdaptiveFormat vid(
      int height, {
      String codecs = 'avc1.640028',
      String url = 'https://r1.googlevideo.com/v?a=1&b=2',
    }) => AdaptiveFormat(
      itag: height,
      url: url,
      mimeType: 'video/mp4',
      codecs: codecs,
      bitrate: height * 3000,
      durationMs: 60000,
      initStart: 0,
      initEnd: 700,
      indexStart: 701,
      indexEnd: 1500,
      width: height * 16 ~/ 9,
      height: height,
      fps: 30,
    );

    AdaptiveFormat aud({
      String codecs = 'mp4a.40.2',
      String mimeType = 'audio/mp4',
      int bitrate = 128000,
      int durationMs = 60100,
    }) => AdaptiveFormat(
      itag: 140,
      url: 'https://r1.googlevideo.com/a?x=1&y=2',
      mimeType: mimeType,
      codecs: codecs,
      bitrate: bitrate,
      durationMs: durationMs,
      initStart: 0,
      initEnd: 731,
      indexStart: 732,
      indexEnd: 1147,
      audioSampleRate: 44100,
      audioChannels: 2,
    );

    test('every ampersand in a stream URL is escaped', () {
      // The single most important line in the file. A googlevideo URL is a
      // query string of twenty-odd parameters joined by `&`; one raw `&` makes
      // the document malformed and the video does not play at all, which looks
      // nothing like an escaping bug from the outside.
      final xml = buildDashManifest([vid(720), aud()])!;
      expect(xml, contains('a=1&amp;b=2'));
      expect(RegExp(r'&(?!(amp|lt|gt|quot|apos);)').hasMatch(xml), isFalse);
    });

    test('emits the byte ranges the player will ask for', () {
      final xml = buildDashManifest([vid(720), aud()])!;
      expect(xml, contains('indexRange="701-1500"'));
      expect(xml, contains('<Initialization range="0-700"/>'));
      expect(xml, contains('indexRangeExact="true"'));
    });

    test('declares the LONGER of the two durations', () {
      // Video and audio differ by milliseconds on almost every video, and
      // declaring the shorter one clips the end off.
      final xml = buildDashManifest([vid(720), aud(durationMs: 60100)])!;
      expect(xml, contains('PT60.100S'));
    });

    test('nothing without both a video and an audio track', () {
      // A manifest with no audio plays silent, which is worse than the 360p
      // stream it would have replaced. The caller falls back on null.
      expect(buildDashManifest([vid(720)]), isNull);
      expect(buildDashManifest([aud()]), isNull);
      expect(buildDashManifest(const []), isNull);
    });

    test('AV1 is excluded, so 4K comes from VP9 instead', () {
      // AV1 is the codec most likely to fall to a software decoder on a
      // mid-range phone, where 4K does not decode in real time — ExoPlayer
      // would happily pick it and playback would stutter rather than look
      // better. Same "playable beats bigger" rule as HD downloads.
      final ladder = dashLadder([
        vid(2160, codecs: 'av01.0.12M.08'),
        vid(1440, codecs: 'vp9'),
        vid(1080),
        aud(),
      ]);
      expect(ladder, ['1440p', '1080p']);
      final xml = buildDashManifest([
        vid(2160, codecs: 'av01.0.12M.08'),
        vid(1080),
        aud(),
      ])!;
      expect(xml, isNot(contains('av01')));
      expect(xml, contains('avc1'));
    });

    test('codec families get separate AdaptationSets', () {
      // A set is the unit ExoPlayer adapts within, and it can only switch
      // between renditions one decoder handles. Mixing AVC and VP9 in one set
      // makes a stream that claims to be switchable and is not.
      final xml = buildDashManifest([
        vid(1080),
        vid(720, codecs: 'vp9'),
        aud(),
      ])!;
      final videoSets =
          RegExp('contentType="video"').allMatches(xml).length;
      expect(videoSets, 2);
    });

    test('AAC wins over Opus, and Opus is used when it is all there is', () {
      final withBoth = buildDashManifest([
        vid(720),
        aud(),
        aud(codecs: 'opus', mimeType: 'audio/webm'),
      ])!;
      expect(withBoth, contains('mp4a.40.2'));
      expect(withBoth, isNot(contains('opus')));

      final opusOnly = buildDashManifest([
        vid(720),
        aud(codecs: 'opus', mimeType: 'audio/webm'),
      ])!;
      expect(opusOnly, contains('opus'));
    });

    test('every audio rung of the chosen codec is kept', () {
      // So ExoPlayer can drop the audio bitrate on a weak connection instead
      // of stalling the video.
      final xml = buildDashManifest([
        vid(720),
        aud(bitrate: 48000),
        aud(bitrate: 128000),
      ])!;
      expect(RegExp('bandwidth="48000"').hasMatch(xml), isTrue);
      expect(RegExp('bandwidth="128000"').hasMatch(xml), isTrue);
    });

    test('ladder is highest first and deduplicated', () {
      expect(
        dashLadder([vid(1080), vid(1080, codecs: 'vp9'), vid(360), vid(720)]),
        ['1080p', '720p', '360p'],
      );
    });
  });

  // ------------------------------------------------- the now-playing bar
  //
  // Where the persistent mini player is allowed to paint. The bar used to live
  // in the tab shell, so it vanished the moment anything was pushed over it —
  // a channel, a playlist, search, settings — while the audio kept playing.

  group('RouteStackObserver', () {
    final shell = _FakeRoute(null);
    Route<dynamic> route(String? name) => _FakeRoute(name);

    test('nothing to paint over on a root tab', () {
      // The shell draws its own bar, above the navigation bar rather than over
      // it, so a second one here would double it up.
      final o = RouteStackObserver();
      o.didPush(shell, null);
      expect(o.wantsNowPlayingBar, isFalse);
    });

    test('appears once a route is pushed, and goes again on pop', () {
      final o = RouteStackObserver();
      o.didPush(shell, null);
      final channel = route('channel');
      o.didPush(channel, shell);
      expect(o.wantsNowPlayingBar, isTrue);
      o.didPop(channel, shell);
      expect(o.wantsNowPlayingBar, isFalse);
    });

    test('never over the watch page', () {
      final o = RouteStackObserver();
      o.didPush(shell, null);
      o.didPush(route(RouteStackObserver.watchRouteName), shell);
      expect(o.wantsNowPlayingBar, isFalse);
    });

    test('never over fullscreen, which sits ABOVE the watch page', () {
      // The condition is "the watch page is nowhere in the stack", not "is not
      // on top": the player pushes its own fullscreen route over the watch
      // page, and a mini player floating over a fullscreen video is absurd.
      final o = RouteStackObserver();
      o.didPush(shell, null);
      final watch = route(RouteStackObserver.watchRouteName);
      o.didPush(watch, shell);
      o.didPush(route(null), watch);
      expect(o.wantsNowPlayingBar, isFalse);
    });

    test('comes back after the watch page is dismissed over a channel', () {
      final o = RouteStackObserver();
      o.didPush(shell, null);
      final channel = route('channel');
      o.didPush(channel, shell);
      final watch = route(RouteStackObserver.watchRouteName);
      o.didPush(watch, channel);
      expect(o.wantsNowPlayingBar, isFalse);
      o.didPop(watch, channel);
      expect(o.wantsNowPlayingBar, isTrue);
    });

    test('routes popped out of order do not strand the stack', () {
      // popUntil, or a dialog dismissed behind a page transition, can pop in
      // an order the pushes did not predict. Removing the wrong entry would
      // leave the stack permanently out of step, which shows up as a bar that
      // never comes back.
      final o = RouteStackObserver();
      o.didPush(shell, null);
      final a = route('a');
      final b = route('b');
      o.didPush(a, shell);
      o.didPush(b, a);
      o.didPop(a, shell);
      o.didPop(b, shell);
      expect(o.wantsNowPlayingBar, isFalse);
    });

    test('a menu or dialog is drawn over the bar, not under it', () {
      // The bar covered the last rows of every bottom sheet opened from a
      // tab — "Not interested" could not be reached. A sheet over a pushed
      // page hides the bar while it is open, and the bar comes back after.
      final o = RouteStackObserver();
      o.didPush(shell, null);
      final sheetOverTab = _FakePopup();
      o.didPush(sheetOverTab, shell);
      expect(o.wantsNowPlayingBar, isFalse);
      o.didPop(sheetOverTab, shell);
      final channel = route('channel');
      o.didPush(channel, shell);
      expect(o.wantsNowPlayingBar, isTrue);
      final sheetOverPage = _FakePopup();
      o.didPush(sheetOverPage, channel);
      expect(o.wantsNowPlayingBar, isFalse);
      o.didPop(sheetOverPage, channel);
      expect(o.wantsNowPlayingBar, isTrue);
    });

    test('a replacement keeps the depth', () {
      final o = RouteStackObserver();
      o.didPush(shell, null);
      final a = route('a');
      o.didPush(a, shell);
      o.didReplace(newRoute: route('b'), oldRoute: a);
      expect(o.wantsNowPlayingBar, isTrue);
    });

    test('notifies only when the answer changes', () {
      // didPush and didPop fire on every navigation and most of them do not
      // alter whether the bar belongs on screen.
      final o = RouteStackObserver();
      var notifications = 0;
      o.addListener(() => notifications++);
      o.didPush(shell, null);
      final a = route('a');
      o.didPush(a, shell);
      expect(notifications, 1);
      final b = route('b');
      o.didPush(b, a);
      expect(notifications, 1, reason: 'still on a pushed route');
      o.didPop(b, a);
      o.didPop(a, shell);
      expect(notifications, 2);
    });
  });

  // --------------------------------------------------- search filter encoding

  group('search params', () {
    /// Decodes the base64 `sp` message back into bytes, so the assertions can
    /// talk about which protobuf fields were actually sent.
    List<int> bytes(String sp) => base64.decode(sp);

    test('a window and a sort order travel together', () {
      // The feed asks for "the most-viewed thing about this in the last
      // month", which is two fields in one message. Pre-baked filter strings
      // each encoded one field and nothing else, so sending one replaced the
      // rest — which is how choosing "This week" on the search screen used to
      // drop the videos-only filter. The same trap applies here: a window that
      // quietly discarded the sort order would return relevance-ranked results
      // and nobody would notice.
      final sp = YoutubeSearchClient.buildParams(
        sortBy: 3,
        uploadDate: YoutubeSearchClient.uploadedThisMonth,
      );
      final message = bytes(sp);
      // Field 1 (sort), varint 3.
      expect(message[0], 0x08);
      expect(message[1], 3);
      // Field 2, a nested message holding the upload-date filter as field 1
      // and the type filter as field 2.
      expect(message[2], 0x12);
      final nested = message.sublist(4);
      expect(nested, containsAllInOrder([0x08, 4]));
      // Videos only is still in there — the thing that used to get lost.
      expect(nested, containsAllInOrder([0x10, 1]));
    });

    test('the window values are the ones YouTube uses', () {
      // Field numbers on someone else's wire format, so they are worth
      // writing down rather than trusting to memory the next time a window is
      // added.
      expect(YoutubeSearchClient.uploadedThisWeek, 3);
      expect(YoutubeSearchClient.uploadedThisMonth, 4);
      expect(YoutubeSearchClient.uploadedThisYear, 5);
    });

    test('no window asked for means no window sent', () {
      // "Any time" is the search screen's default and must stay absent rather
      // than being encoded as a value.
      final nested = bytes(YoutubeSearchClient.buildParams()).sublist(2);
      expect(nested, containsAllInOrder([0x10, 1]));
      expect(nested.contains(0x08), isFalse);
    });
  });

  // ------------------------------------------- channel playlist video counts

  group('videoCountFromBadge', () {
    test('the ordinary case', () {
      expect(videoCountFromBadge('9 videos'), 9);
    });

    test('singular, so the pattern cannot require the s', () {
      expect(videoCountFromBadge('1 video'), 1);
    });

    test('grouped, with either separator', () {
      // A German response says "1.204 Videos". Treating `.` as a decimal point
      // would read that as one video.
      expect(videoCountFromBadge('1,204 videos'), 1204);
      expect(videoCountFromBadge('1.204 Videos'), 1204);
    });

    test('"Playlist" is not a count', () {
      // It is what the sibling metadata row says, which is why the word
      // "video" has to be matched instead of taking the first run of digits.
      expect(videoCountFromBadge('Playlist'), isNull);
      expect(videoCountFromBadge('View full playlist'), isNull);
      expect(videoCountFromBadge(''), isNull);
    });

    test('a bare number is not a count either', () {
      expect(videoCountFromBadge('12'), isNull);
    });
  });

  // ------------------------------------------------------- generated HLS
  // How an iPhone plays anything above 360p. AVPlayer cannot play the DASH
  // manifest Android gets, but it has played fragmented MP4 over HLS with
  // byte-range segments since iOS 10 — and YouTube's adaptive tracks already
  // have that shape, with a `sidx` box listing every fragment. These tests pin
  // the parser and the playlists; see lib/src/data/hls_manifest.dart.

  // The HD-unlock route: the web client's formats arrive with their URLs
  // behind the player's signature and `n` challenges, and need the
  // proof-of-origin token stamped on. The challenges themselves are solved in
  // a WebView and cannot run here; everything around them is pure and these
  // tests pin it. See lib/src/data/attestation/web_formats.dart.
  // A link tapped in another app or shared into this one. See
  // lib/src/core/incoming_links.dart for why Android gets this and iOS does
  // not; the extraction is pure and these pin the shapes that arrive.
  group('youtubeReferenceIn', () {
    test('a tapped link arrives as itself', () {
      expect(
        youtubeReferenceIn('https://youtu.be/dQw4w9WgXcQ?si=abc'),
        'https://youtu.be/dQw4w9WgXcQ?si=abc',
      );
      expect(
        youtubeReferenceIn('https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLx'),
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLx',
      );
    });

    test('shared text is a sentence around a link', () {
      expect(
        youtubeReferenceIn('Watch this! https://youtu.be/dQw4w9WgXcQ amazing'),
        'https://youtu.be/dQw4w9WgXcQ',
      );
      // Trailing punctuation belongs to the sentence, not the URL.
      expect(
        youtubeReferenceIn('see https://m.youtube.com/shorts/dQw4w9WgXcQ.'),
        'https://m.youtube.com/shorts/dQw4w9WgXcQ',
      );
    });

    test("the YouTube app's own scheme carries a bare id", () {
      expect(youtubeReferenceIn('vnd.youtube:dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
      expect(youtubeReferenceIn('vnd.youtube://dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
    });

    test('anything else is not a reference', () {
      expect(youtubeReferenceIn('hello there'), isNull);
      expect(youtubeReferenceIn('https://example.com/watch?v=dQw4w9WgXcQ'), isNull);
      expect(youtubeReferenceIn('   '), isNull);
    });

    test('and the result is something parseVideoId understands', () {
      for (final text in [
        'Watch https://youtu.be/dQw4w9WgXcQ now',
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'https://www.youtube.com/shorts/dQw4w9WgXcQ',
        'vnd.youtube:dQw4w9WgXcQ',
      ]) {
        expect(
          YtRepository.parseVideoId(youtubeReferenceIn(text)!),
          'dQw4w9WgXcQ',
          reason: text,
        );
      }
    });
  });

  group('web formats', () {
    const base = 'https://rr1.googlevideo.com/videoplayback?expire=1&n=abc&clen=100';

    test('challengesIn collects the scrambled signature and the n value once', () {
      final formats = [
        {'itag': 137, 'signatureCipher': 's=SCRAMBLED&sp=sig&url=${Uri.encodeQueryComponent(base)}'},
        {'itag': 140, 'signatureCipher': 's=SCRAMBLED&sp=sig&url=${Uri.encodeQueryComponent(base)}'},
        {'itag': 18, 'url': base},
        'not a map',
      ];
      final wanted = challengesIn(formats);
      expect(wanted.sig, ['SCRAMBLED']);
      // Shared by every format of a response: one challenge, not three.
      expect(wanted.n, ['abc']);
    });

    test('resolveFormat appends the signature under sp, swaps n, stamps pot', () {
      final raw = {
        'itag': 137,
        'mimeType': 'video/mp4; codecs="avc1.64002a"',
        'signatureCipher': 's=SCRAMBLED&sp=sig&url=${Uri.encodeQueryComponent(base)}',
      };
      final out = resolveFormat(
        raw,
        solvedN: {'abc': 'xyz'},
        solvedSig: {'SCRAMBLED': 'UNSCRAMBLED'},
        poToken: 'TOKEN',
      )!;
      final url = out['url'] as String;
      expect(url, startsWith('https://rr1.googlevideo.com/videoplayback?expire=1'));
      expect(Uri.parse(url).queryParameters['sig'], 'UNSCRAMBLED');
      expect(Uri.parse(url).queryParameters['n'], 'xyz');
      expect(Uri.parse(url).queryParameters['pot'], 'TOKEN');
      // Untouched parameters are untouched: they are signed as written.
      expect(url, contains('clen=100'));
      expect(out.containsKey('signatureCipher'), isFalse);
      expect(out['itag'], 137);
    });

    test('resolveFormat uses a plain url when there is no cipher', () {
      final out = resolveFormat(
        {'itag': 18, 'url': base},
        solvedN: {'abc': 'xyz'},
        solvedSig: const {},
        poToken: 'T',
      )!;
      expect(Uri.parse(out['url'] as String).queryParameters['n'], 'xyz');
      expect(Uri.parse(out['url'] as String).queryParameters['pot'], 'T');
    });

    test('resolveFormat refuses a format whose challenge went unsolved', () {
      // A URL with the wrong n plays at a crawl and one with no signature
      // answers 403, and either shows up as "HD is broken" later. Null now.
      expect(
        resolveFormat(
          {'itag': 18, 'url': base},
          solvedN: {'abc': null},
          solvedSig: const {},
          poToken: 'T',
        ),
        isNull,
      );
      expect(
        resolveFormat(
          {'signatureCipher': 's=S&sp=sig&url=${Uri.encodeQueryComponent(base)}'},
          solvedN: {'abc': 'x'},
          solvedSig: const {},
          poToken: 'T',
        ),
        isNull,
      );
      expect(resolveFormat({'itag': 1}, solvedN: const {}, solvedSig: const {}, poToken: 'T'), isNull);
    });

    test('withPoToken replaces an existing token rather than adding a second', () {
      final once = withPoToken(base, 'ONE');
      final twice = withPoToken(once, 'TWO');
      expect('pot='.allMatches(twice).length, 1);
      expect(Uri.parse(twice).queryParameters['pot'], 'TWO');
      // And the value is encoded so a websafe-base64 token survives.
      expect(withPoToken('https://x/y', 'a=b&c'), 'https://x/y?pot=a%3Db%26c');
    });

    test('playerScriptUrlFromIframeApi reads the escaped build hash', () {
      const body = r'var scriptUrl = "https:\/\/www.youtube.com\/s\/player\/0f8a1b2c\/www-widgetapi.vflset\/www-widgetapi.js";';
      expect(
        playerScriptUrlFromIframeApi(body),
        'https://www.youtube.com/s/player/0f8a1b2c/player_ias.vflset/en_US/base.js',
      );
      expect(playerScriptUrlFromIframeApi('nothing here'), isNull);
    });

    test('signatureTimestampOf reads either spelling', () {
      expect(signatureTimestampOf('x,signatureTimestamp:20315,y'), 20315);
      expect(signatureTimestampOf('x,sts:20315,y'), 20315);
      expect(signatureTimestampOf('sts:1'), isNull);
    });
  });

  group('parseSegmentIndex', () {
    /// Builds a real `sidx` box. Hand-assembled rather than captured from a
    /// response, so each field's width and position is stated explicitly —
    /// which is the whole risk in this parser.
    Uint8List sidx({
      int version = 0,
      int timescale = 1000,
      int firstOffset = 0,
      List<(int size, int duration)> entries = const [
        (1000, 5000),
        (2000, 5000),
        (1500, 2500),
      ],
      String type = 'sidx',
      bool hierarchical = false,
      int leadingBoxBytes = 0,
    }) {
      final body = BytesBuilder();
      void u32(int v) => body.add([
        (v >> 24) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 8) & 0xFF,
        v & 0xFF,
      ]);
      void u16(int v) => body.add([(v >> 8) & 0xFF, v & 0xFF]);

      body.addByte(version);
      body.add([0, 0, 0]); // flags
      u32(1); // reference_ID
      u32(timescale);
      if (version == 0) {
        u32(0); // earliest_presentation_time
        u32(firstOffset);
      } else {
        u32(0);
        u32(0); // 64-bit earliest_presentation_time
        u32(0);
        u32(firstOffset); // 64-bit first_offset
      }
      u16(0); // reserved
      u16(entries.length);
      for (final e in entries) {
        // reference_type in the top bit, then 31 bits of size.
        u32(hierarchical ? (e.$1 | 0x80000000) : e.$1);
        u32(e.$2);
        u32(0x90000000); // starts_with_SAP = 1, SAP_type = 1
      }

      final payload = body.toBytes();
      final out = BytesBuilder();
      // An unrelated box in front, to prove the scan does not assume the
      // index starts at byte zero — real responses sometimes lead with `ssix`.
      if (leadingBoxBytes > 0) {
        final size = leadingBoxBytes;
        out.add([
          (size >> 24) & 0xFF,
          (size >> 16) & 0xFF,
          (size >> 8) & 0xFF,
          size & 0xFF,
        ]);
        out.add('ssix'.codeUnits);
        out.add(List.filled(size - 8, 0));
      }
      final total = payload.length + 8;
      out.add([
        (total >> 24) & 0xFF,
        (total >> 16) & 0xFF,
        (total >> 8) & 0xFF,
        total & 0xFF,
      ]);
      out.add(type.codeUnits);
      out.add(payload);
      return out.toBytes();
    }

    test('fragment offsets are cumulative from the end of the box', () {
      // The anchor is the whole game. `sidx` offsets are relative to the first
      // byte AFTER the box, so the first fragment starts at
      // indexStart + boxLength + first_offset. Getting this wrong does not
      // fail loudly — it produces byte ranges that are valid requests for the
      // wrong bytes, and the only symptom is a video that will not start.
      final bytes = sidx();
      final index = parseSegmentIndex(bytes, indexStart: 701)!;
      expect(index.segments.length, 3);
      final base = 701 + bytes.length;
      expect(index.segments[0].offset, base);
      expect(index.segments[0].size, 1000);
      expect(index.segments[1].offset, base + 1000);
      expect(index.segments[2].offset, base + 3000);
    });

    test('first_offset shifts the whole run', () {
      final bytes = sidx(firstOffset: 64);
      final index = parseSegmentIndex(bytes, indexStart: 0)!;
      expect(index.segments.first.offset, bytes.length + 64);
    });

    test('durations are converted out of the timescale', () {
      // A misread timescale is the bug that shows up as a seek bar that lies
      // rather than as a video that fails, so it gets its own test.
      final index = parseSegmentIndex(sidx(timescale: 90000), indexStart: 0)!;
      // 5000 ticks at 90kHz is 55.5ms, not 5s.
      expect(index.segments.first.durationUs, 55555);
      final normal = parseSegmentIndex(sidx(timescale: 1000), indexStart: 0)!;
      expect(normal.segments.first.durationSeconds, 5.0);
      expect(normal.longestSegmentSeconds, 5.0);
    });

    test('a 64-bit sidx is read with the wider fields', () {
      final index = parseSegmentIndex(sidx(version: 1), indexStart: 0)!;
      expect(index.segments.length, 3);
      expect(index.segments[1].size, 2000);
    });

    test('a box in front of the sidx is skipped', () {
      final bytes = sidx(leadingBoxBytes: 24);
      final index = parseSegmentIndex(bytes, indexStart: 10)!;
      // The anchor is still the end of the sidx box, which is the end of the
      // whole buffer here — not the end of the leading box.
      expect(index.segments.first.offset, 10 + bytes.length);
    });

    test('a hierarchical index is declined rather than half-read', () {
      // An entry pointing at another `sidx` would need a further fetch per
      // level. Returning the sizes as though they were media would produce a
      // playlist of plausible nonsense.
      expect(parseSegmentIndex(sidx(hierarchical: true), indexStart: 0), isNull);
    });

    test('no sidx, truncated bytes and junk all return null', () {
      expect(parseSegmentIndex(sidx(type: 'moof'), indexStart: 0), isNull);
      expect(parseSegmentIndex(Uint8List(0), indexStart: 0), isNull);
      expect(parseSegmentIndex(Uint8List.fromList([0, 0, 1]), indexStart: 0),
          isNull);
      final truncated = sidx().sublist(0, 20);
      expect(parseSegmentIndex(truncated, indexStart: 0), isNull);
      expect(
        parseSegmentIndex(sidx(entries: const []), indexStart: 0),
        isNull,
        reason: 'a sidx claiming zero fragments describes nothing playable',
      );
    });

    test('a zero timescale cannot be divided by', () {
      expect(parseSegmentIndex(sidx(timescale: 0), indexStart: 0), isNull);
    });
  });

  group('buildHls', () {
    AdaptiveFormat vid(int height, {String codecs = 'avc1.640028', int itag = 0}) =>
        AdaptiveFormat(
          itag: itag == 0 ? height : itag,
          url: 'https://r1.googlevideo.com/v?a=1&b=2&itag=$height',
          mimeType: 'video/mp4',
          codecs: codecs,
          bitrate: height * 3000,
          durationMs: 60000,
          initStart: 0,
          initEnd: 700,
          indexStart: 701,
          indexEnd: 1500,
          width: height * 16 ~/ 9,
          height: height,
          fps: 30,
        );

    AdaptiveFormat aud({
      String codecs = 'mp4a.40.2',
      String mimeType = 'audio/mp4',
      int bitrate = 128000,
      String? trackId,
      bool isDefault = false,
    }) => AdaptiveFormat(
      itag: 140,
      url: 'https://r1.googlevideo.com/a?x=1&y=2',
      mimeType: mimeType,
      codecs: codecs,
      bitrate: bitrate,
      durationMs: 60100,
      initStart: 0,
      initEnd: 731,
      indexStart: 732,
      indexEnd: 1147,
      audioSampleRate: 44100,
      audioChannels: 2,
      audioTrackId: trackId,
      audioIsDefault: isDefault,
    );

    SegmentIndex index([int count = 3]) => SegmentIndex([
      for (var i = 0; i < count; i++)
        MediaSegment(offset: 2000 + i * 1000, size: 1000, durationUs: 5000000),
    ]);

    test('AVC and AAC only — VP9 and Opus are unplayable, not just lesser', () {
      // The difference from the DASH manifest, and the reason this is a
      // separate file. ExoPlayer decodes VP9 in hardware on essentially every
      // Android device; AVPlayer decodes it nowhere. A VP9 variant in an iOS
      // playlist is not a lower rung, it is a broken one.
      final candidates = hlsCandidates([
        vid(2160, codecs: 'vp09.00.51.08'),
        vid(1440, codecs: 'av01.0.12M.08'),
        vid(1080),
        aud(codecs: 'opus', mimeType: 'audio/webm'),
        aud(),
      ]);
      expect(
        candidates.where((f) => f.isVideo).map((f) => f.height),
        [1080],
      );
      expect(candidates.last.codecs, 'mp4a.40.2');
    });

    test('one rendition per height, the highest bitrate of each', () {
      final tall = vid(1080, itag: 137);
      final tallerBitrate = AdaptiveFormat(
        itag: 299,
        url: tall.url,
        mimeType: tall.mimeType,
        codecs: tall.codecs,
        bitrate: tall.bitrate * 2,
        durationMs: tall.durationMs,
        initStart: 0,
        initEnd: 700,
        indexStart: 701,
        indexEnd: 1500,
        width: tall.width,
        height: 1080,
        fps: 60,
      );
      final picked = hlsCandidates([tall, tallerBitrate, vid(720), aud()]);
      final thousandEighty =
          picked.where((f) => f.isVideo && f.height == 1080).toList();
      expect(thousandEighty, hasLength(1));
      expect(thousandEighty.single.itag, 299);
    });

    test('candidates lead with the tallest rung and end with the audio', () {
      final picked = hlsCandidates([vid(360), vid(1080), vid(720), aud()]);
      expect(picked.where((f) => f.isVideo).map((f) => f.height),
          [1080, 720, 360]);
      expect(picked.last.isAudio, isTrue);
    });

    test('no audio or no video yields nothing at all', () {
      // Same judgement as buildDashManifest: a silent 1080p stream is worse
      // than the 360p one it would have replaced, so the caller falls back.
      expect(hlsCandidates([vid(1080)]), isEmpty);
      expect(hlsCandidates([aud()]), isEmpty);
      expect(buildHls([HlsTrack(vid(1080), index())]), isNull);
      expect(buildHls([HlsTrack(aud(), index())]), isNull);
      expect(buildHls(const []), isNull);
    });

    test('a rendition whose index could not be read is left out', () {
      final built = buildHls([
        HlsTrack(vid(1080), SegmentIndex(const [])),
        HlsTrack(vid(720), index()),
        HlsTrack(aud(), index()),
      ])!;
      expect(built.ladder, ['720p']);
      expect(built.master, isNot(contains('1920x1080')));
    });

    test('the master declares v7, an audio group and every variant', () {
      final built = buildHls([
        HlsTrack(vid(1080), index()),
        HlsTrack(vid(720), index()),
        HlsTrack(aud(), index()),
      ])!;
      expect(built.master, startsWith('#EXTM3U'));
      // Version 7 is what EXT-X-MAP with a BYTERANGE requires.
      expect(built.master, contains('#EXT-X-VERSION:7'));
      expect(built.master, contains('TYPE=AUDIO'));
      expect(built.master, contains('URI="a.m3u8"'));
      expect(built.master, contains('RESOLUTION=1920x1080'));
      expect(built.master, contains('AUDIO="aud"'));
      expect(built.ladder, ['1080p', '720p']);
      // Every playlist the master names has to exist, or AVPlayer fails on a
      // variant switch rather than at load time.
      for (final name in RegExp(r'[\w.]+\.m3u8').allMatches(built.master)) {
        expect(built.media.keys, contains(name.group(0)));
      }
      expect(built.media.keys, hasLength(3));
    });

    test('a variant bandwidth covers its audio as well as its video', () {
      // Understating this is how an adaptive player talks itself into a rung
      // the connection cannot carry.
      final built = buildHls([
        HlsTrack(vid(1080), index()),
        HlsTrack(aud(bitrate: 128000), index()),
      ])!;
      expect(built.master, contains('BANDWIDTH=${1080 * 3000 + 128000}'));
    });

    test('segments carry explicit offsets and the init map', () {
      final built = buildHls([
        HlsTrack(vid(720), index()),
        HlsTrack(aud(), index()),
      ])!;
      final playlist = built.media['v720.m3u8']!;
      expect(playlist, contains('#EXT-X-PLAYLIST-TYPE:VOD'));
      expect(playlist, contains('#EXT-X-ENDLIST'));
      // The moov box, without which the fragments cannot be decoded.
      expect(playlist, contains('#EXT-X-MAP:URI="'));
      expect(playlist, contains('BYTERANGE="701@0"'));
      // Explicit `length@offset` on every segment rather than the shorthand
      // that continues from the previous one: contiguous fragments make the
      // shorthand correct, but then one wrong length slides the whole rest of
      // the playlist instead of breaking a single segment.
      expect(playlist, contains('#EXT-X-BYTERANGE:1000@2000'));
      expect(playlist, contains('#EXT-X-BYTERANGE:1000@3000'));
      expect(playlist, contains('#EXT-X-BYTERANGE:1000@4000'));
      expect(RegExp('#EXTINF:').allMatches(playlist).length, 3);
    });

    test('the target duration is never below the longest segment', () {
      // A target duration below the real maximum is a spec violation AVPlayer
      // is entitled to reject the whole playlist over, so it rounds up.
      final built = buildHls([
        HlsTrack(
          vid(720),
          SegmentIndex(const [
            MediaSegment(offset: 0, size: 10, durationUs: 7400000),
          ]),
        ),
        HlsTrack(aud(), index()),
      ])!;
      expect(built.media['v720.m3u8']!, contains('#EXT-X-TARGETDURATION:8'));
    });

    test('stream URLs are written raw — m3u8 is not XML', () {
      // The mirror image of the DASH manifest's most important rule. There,
      // an unescaped `&` makes the document malformed; here, escaping one
      // would corrupt the URL.
      final built = buildHls([
        HlsTrack(vid(720), index()),
        HlsTrack(aud(), index()),
      ])!;
      expect(built.media['v720.m3u8']!, contains('a=1&b=2'));
      expect(built.media['v720.m3u8']!, isNot(contains('&amp;')));
    });

    test('variant files are keyed by itag, so two rungs cannot collide', () {
      final built = buildHls([
        HlsTrack(vid(1080, itag: 137), index()),
        HlsTrack(vid(1080, itag: 299), index()),
        HlsTrack(aud(), index()),
      ])!;
      expect(built.media.keys, contains('v137.m3u8'));
      expect(built.media.keys, contains('v299.m3u8'));
    });

    test('the default dub wins over a louder alternate', () {
      final picked = hlsCandidates([
        vid(720),
        aud(bitrate: 256000, trackId: 'es.4'),
        aud(bitrate: 128000, trackId: 'en.4', isDefault: true),
      ]);
      expect(picked.last.audioTrackId, 'en.4');
    });
  });
}

/// A stand-in for a pushed route, so the observer can be exercised without a
/// widget tree. It only ever reads `settings.name`.
/// Carries the name through `Route`'s own constructor rather than overriding
/// the `settings` getter, which is the narrower thing to depend on: the getter
/// has been reworked more than once upstream and this file is analysed against
/// whatever stable Flutter CI has today, which is usually newer than the local
/// SDK.
class _FakeRoute extends Route<void> {
  _FakeRoute(String? name) : super(settings: RouteSettings(name: name));
}

/// A bottom sheet or dialog, as far as the route observer is concerned.
class _FakePopup extends PopupRoute<void> {
  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => null;
  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Widget buildPage(BuildContext context, Animation<double> a, Animation<double> b) =>
      const SizedBox();
}
