// Runs the REAL app on a real emulator or simulator and prints what it finds.
//
// This exists because neither platform can be built or run on the development
// machine, so every native and playback question has historically been reasoned
// from source - and three consecutive guesses at why iOS Picture in Picture
// did nothing were all wrong. CI is the only place the app actually executes,
// so this is the probe: it plays a video for real and reports stream
// resolution, buffer health and the exact reason PiP was refused.
//
// It is deliberately tolerant. A diagnostic that fails the job on the first
// missing widget tells you nothing; this one catches, prints, and keeps going,
// because the OUTPUT is the deliverable, not a pass/fail.
//
// Known limitation, stated so nobody misreads a clean run: the iOS Simulator
// does not implement Picture in Picture at all -
// AVPictureInPictureController.isPictureInPictureSupported() is false there -
// so an iOS run can only prove the app reaches the PiP call and reports
// sensibly. Confirming PiP itself needs a real iPhone. The Android emulator
// does support PiP and is a genuine test.

import 'package:ai_bit/main.dart' as app;
import 'package:ai_bit/src/data/yt_repository.dart';
import 'package:ai_bit/src/data/settings.dart';
import 'package:ai_bit/src/player/playback_controller.dart';
import 'package:ai_bit/src/ui/widgets/feed_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

/// Prefixed so the interesting lines can be grepped out of a noisy CI log.
void report(String line) => debugPrint('AIBIT-DIAG | $line');

/// Pumps for [total], in slices, so timers and network callbacks run.
///
/// `pumpAndSettle` is useless here: a playing video never settles, and a
/// spinner keeps the frame pipeline busy forever.
Future<void> pumpFor(WidgetTester tester, Duration total) async {
  final deadline = DateTime.now().add(total);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// Pumps until [condition] holds or [timeout] expires. Returns whether it held.
Future<bool> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await tester.pump(const Duration(milliseconds: 250));
  }
  return condition();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('plays a video and reports stream, buffer and PiP', (
    tester,
  ) async {
    report('=== AI BIT device diagnostics ===');
    report('preview mode (web only): ${YtRepository.isPreview}');

    app.main();
    // The app opens the database and loads settings before the first frame.
    await pumpFor(tester, const Duration(seconds: 8));

    // ---------------------------------------------------------- stream layer
    // Checked directly rather than through the UI: if extraction is broken,
    // every later failure is a consequence and the UI would only show an empty
    // feed. This is tool/check_streams.dart, run on the device instead.
    final context = tester.element(find.byType(Navigator).first);
    final repo = context.read<YtRepository>();

    try {
      // "Me at the zoo" - the oldest video on YouTube, and the least likely to
      // be removed, region-locked or turned into a premiere.
      final sources = await repo.resolve('jNQXAC9IVRw');
      report('resolve ok: url=${sources.url.isNotEmpty}, hls=${sources.isHls}');
      report('resolve videoUnavailable=${sources.videoUnavailable}');
      report('resolve qualities=${sources.qualities.keys.toList()}');
    } catch (e) {
      report('resolve FAILED: $e');
      report('-> extraction is broken; playback problems downstream are a '
          'consequence, not a separate bug');
    }

    // ------------------------------------------------------------- the feed
    final feedLoaded = await pumpUntil(
      tester,
      () => find.byType(Card).evaluate().isNotEmpty ||
          find.textContaining('views').evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    report('feed loaded: $feedLoaded');

    // ---------------------------------------------------------- play a video
    final playback = context.read<PlaybackController>();
    try {
      final rows = find.textContaining('views');
      if (rows.evaluate().isNotEmpty) {
        await tester.tap(rows.first, warnIfMissed: false);
        await pumpFor(tester, const Duration(seconds: 3));
      } else {
        report('no feed row to tap; the rest is skipped');
        return;
      }
    } catch (e) {
      report('opening a video FAILED: $e');
      return;
    }

    final started = await pumpUntil(
      tester,
      () => playback.player != null && playback.current != null,
      timeout: const Duration(seconds: 60),
    );
    report('player created: $started, video=${playback.current?.id}');

    // Let it actually buffer and play before measuring anything.
    await pumpFor(tester, const Duration(seconds: 20));

    report('isPlaying=${playback.isPlaying}');
    report('position=${playback.position}');
    for (final entry in playback.stats.entries) {
      report('stat ${entry.key}: ${entry.value}');
    }

    // Sampled over time: one buffer reading says nothing, but a buffer that
    // never grows while the position advances is a starving stream, and one
    // that is healthy while playback stutters is a rendering problem. That is
    // the split no amount of source reading can settle.
    for (var i = 0; i < 5; i++) {
      await pumpFor(tester, const Duration(seconds: 4));
      final stats = playback.stats;
      report(
        'sample $i: pos=${playback.position.inSeconds}s '
        'buffer=${stats['Buffer health'] ?? stats['Buffer'] ?? '?'} '
        'res=${stats['Resolution'] ?? '?'} '
        'playing=${playback.isPlaying}',
      );
    }

    // ---------------------------------------------------------- feed preview
    // "Previews do not work" has five possible causes and no way to tell them
    // apart from the outside, so ask the coordinator directly and then make it
    // actually try one.
    try {
      final previews = FeedPreviewCoordinator(
        repository: repo,
        settings: context.read<SettingsService>(),
        playback: playback,
      );
      report('preview blockedReason: ${previews.blockedReason ?? 'ALLOWED'}');

      final subject = playback.current;
      if (subject != null) {
        previews.onCardVisibility(subject, 1);
        // Longer than the dwell plus a resolve.
        await pumpFor(tester, const Duration(seconds: 12));
        report('preview activeId: ${previews.activeId ?? 'NONE'}');
        report('preview player: ${previews.player != null}');
      }
      previews.dispose();
    } catch (e) {
      report('preview check THREW: $e');
    }

    // -------------------------------------------------------------- the PiP
    // The whole point. enterPictureInPicture returns null on success or the
    // reason it was refused, so this prints the answer three blind fixes could
    // not establish.
    try {
      final failure = await playback.enterPictureInPicture();
      report('PiP result: ${failure ?? 'STARTED (no failure reported)'}');
    } catch (e) {
      report('PiP THREW: $e');
    }
    await pumpFor(tester, const Duration(seconds: 3));

    report('=== end diagnostics ===');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
