import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'playback_controller.dart';

/// Pops what is playing out of the app, so it survives switching to another
/// one.
///
/// Two different platform features answer that sentence, because the platforms
/// disagree about what an app may draw above another app:
///
/// * **Android** grants a genuine overlay window. `SYSTEM_ALERT_WINDOW` plus a
///   foreground service that holds a view in the `WindowManager` at
///   `TYPE_APPLICATION_OVERLAY`. That is what [start] drives, over the
///   `ai.bit/floating_player` channel; the Kotlin lives in
///   `android/app/src/main/kotlin/com/personal/aibit/ai_bit/`.
///
/// * **iOS has no equivalent, and this is not worth re-attempting.** UIKit
///   offers a third-party app no window level above another app's — the
///   sandbox simply has no such thing, `UIWindowLevel` is per-application, and
///   an app that found a way would be rejected for it. Picture-in-Picture is
///   Apple's deliberate answer to the same need, and this app already
///   implements it natively (`PlaybackController.enterPictureInPicture`). So
///   [isSupported] is false on iOS and [popOut] falls back to PiP rather than
///   pretending there is an overlay to ask for.
///
/// **The Android window shows real video.** There is exactly one native player
/// in this app (CLAUDE.md, "One player for the whole app"), so the overlay does
/// not start a second one — a second decoder would fight the first for audio
/// focus. Instead the overlay owns a `SurfaceView` and the vendored plugin's
/// `BetterPlayerSurfaceBridge` (PATCH 18) points the live ExoPlayer at it,
/// then points it back at Flutter's texture when the window closes.
///
/// The consequence, and it is the intended one: **the in-app video surface goes
/// blank while the overlay is up**, because one decoder has one output. System
/// Picture-in-Picture behaves identically. Audio never stops. To keep that
/// blankness from outliving the overlay, [start] installs a lifecycle observer
/// that takes the window down the moment the app is resumed — returning to the
/// app is exactly when the video has to come back, and the user may well return
/// through the launcher rather than by tapping the bubble.
class FloatingPlayer {
  const FloatingPlayer._();

  static const _channel = MethodChannel('ai.bit/floating_player');

  /// True only where a real overlay window exists. See the class comment for
  /// why iOS is a permanent false rather than a to-do.
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static final StreamController<String> _failures =
      StreamController<String>.broadcast();

  /// Failures that surface *after* [start] has already returned true.
  ///
  /// The overlay is a foreground service started with
  /// `startForegroundService`, which returns before the service has run a line
  /// — so the two failures that actually happen in the field (Android 14
  /// refusing the `mediaPlayback` service type at runtime, and the overlay
  /// permission being revoked between the check and `addView`) have no
  /// `Result` left to fail. They arrive here instead, so that a button that
  /// appears to do nothing can say why.
  static Stream<String> get failures => _failures.stream;

  static bool _handlerInstalled = false;
  static _ResumeWatcher? _resumeWatcher;

  static void _ensureHandler() {
    if (_handlerInstalled || !isSupported) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onFailed') {
        final message = call.arguments is String
            ? call.arguments as String
            : 'The floating player could not be shown.';
        _failures.add(message);
      }
      // Anything else is a native side newer than this file. Ignored rather
      // than thrown back, because an unhandled reply would only produce log
      // noise on a channel whose only job is one-way notification.
      return null;
    });
  }

  /// Whether the user has granted "display over other apps".
  ///
  /// Android will not put this behind a runtime permission dialog: it is a
  /// settings screen the user has to visit, which is what [requestPermission]
  /// opens.
  static Future<bool> hasPermission() =>
      _ask<bool>('hasPermission', fallback: false);

  /// Opens the system's "display over other apps" screen for this app.
  ///
  /// Resolves as soon as the screen is launched, *not* when the user decides —
  /// there is no result to wait for, because the grant happens in another app.
  /// Callers re-check [hasPermission] afterwards rather than trusting this.
  static Future<void> requestPermission() =>
      _ask<bool>('requestPermission', fallback: false);

  /// Shows the window. False when it could not be shown, which in practice
  /// means the overlay permission is not granted or [playing] was false.
  ///
  /// [playing] is not decoration. The service declares
  /// `foregroundServiceType="mediaPlayback"`, and from Android 14 the system
  /// judges that claim at runtime and throws
  /// `InvalidForegroundServiceTypeException` when it does not believe it. Only
  /// the caller knows whether media is actually running, so the answer travels
  /// with the request and the native side refuses without it.
  static Future<bool> start({
    String title = '',
    String subtitle = '',
    required bool playing,
  }) async {
    _ensureHandler();
    final started = await _ask<bool>(
      'start',
      fallback: false,
      arguments: <String, dynamic>{
        'title': title,
        'subtitle': subtitle,
        'playing': playing,
      },
    );
    if (started) _watchForResume();
    return started;
  }

  /// Takes the window down. Safe to call when it is not showing.
  ///
  /// This is also the path that returns the video to the in-app player, so it
  /// is deliberately cheap and safe to call speculatively — `RootShell` does,
  /// on dispose and whenever playback ends.
  static Future<void> stop() async {
    _stopWatchingForResume();
    await _ask<bool>('stop', fallback: false);
  }

  /// Whether the overlay service is currently up.
  static Future<bool> isRunning() => _ask<bool>('isRunning', fallback: false);

  static void _watchForResume() {
    if (_resumeWatcher != null) return;
    final watcher = _ResumeWatcher();
    _resumeWatcher = watcher;
    WidgetsBinding.instance.addObserver(watcher);
  }

  static void _stopWatchingForResume() {
    final watcher = _resumeWatcher;
    if (watcher == null) return;
    _resumeWatcher = null;
    WidgetsBinding.instance.removeObserver(watcher);
  }

  /// One place for the channel call, so every unhappy path is handled the same
  /// way and none of them is silent.
  static Future<T> _ask<T>(
    String method, {
    required T fallback,
    Map<String, dynamic>? arguments,
  }) async {
    // Short-circuited rather than allowed to fail: on iOS and web there is no
    // handler registered at all, so every call would raise
    // MissingPluginException and log noise for a platform that is behaving
    // correctly.
    if (!isSupported) return fallback;
    try {
      final result = await _channel.invokeMethod<T>(method, arguments);
      return result ?? fallback;
    } catch (e) {
      // Logged, not swallowed. A floating player that quietly never appears is
      // indistinguishable from one that is broken, and this codebase has
      // already lost a feature for months to a catch that returned a neutral
      // value in silence.
      debugPrint('AI BIT: floating player "$method" failed - $e');
      return fallback;
    }
  }

  /// The one entry point a UI should call: pops out on Android, falls back to
  /// Picture-in-Picture everywhere else.
  ///
  /// Needs a context under both the app's providers and a Navigator, because
  /// it may put up a dialog explaining the overlay permission.
  static Future<void> popOut(BuildContext context) async {
    final playback = context.read<PlaybackController>();

    if (!isSupported) {
      // iOS (and anything else): PiP is the platform's answer to this, and it
      // is already wired up. See the class comment.
      final messenger = ScaffoldMessenger.of(context);
      final failure = await playback.enterPictureInPicture();
      if (failure != null) {
        messenger.showSnackBar(SnackBar(content: Text(failure)));
      }
      return;
    }

    final video = playback.current;
    if (video == null) return;

    // Captured before the first await: the messenger must not be looked up
    // through a context that may have been popped by then.
    final messenger = ScaffoldMessenger.of(context);

    if (!playback.isPlaying) {
      // Refused here rather than left to fail natively. The overlay runs as a
      // mediaPlayback foreground service, and Android 14 rejects that type at
      // runtime when nothing is playing — so a paused video would start a
      // service the OS immediately kills, which reads to the user as a button
      // that silently does nothing.
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Start playing first — the floating player needs '
              'playback running.'),
        ),
      );
      return;
    }

    if (!await hasPermission()) {
      if (!context.mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Allow floating player'),
          content: const Text(
            'Android needs "Display over other apps" switched on before AI BIT '
            'can float above other apps. It is a settings screen, not a '
            'permission prompt, so it has to be turned on by hand.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
      if (go != true) return;
      await requestPermission();
      // Deliberately stops here. The grant happens in Settings, in another
      // task; there is nothing to wait on and re-checking immediately would
      // always read "not granted". The user comes back and taps again.
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Turn on "Display over other apps", then tap again.'),
        ),
      );
      return;
    }

    // Armed before the call, because the service can fail inside
    // startForeground before start() has even returned.
    _listenForFailure(messenger);

    final started = await start(
      title: video.title,
      subtitle: video.author,
      playing: playback.isPlaying,
    );
    if (!started) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open the floating player.')),
      );
    }
  }

  /// Shows the next late failure, if one arrives soon, then stops listening.
  ///
  /// Bounded on purpose: [failures] is a broadcast stream, and a subscription
  /// left open per tap would leak. Anything that goes wrong later than this is
  /// the user closing the window, not the window failing to open.
  static void _listenForFailure(ScaffoldMessengerState messenger) {
    StreamSubscription<String>? subscription;
    Timer? timer;
    subscription = failures.listen((message) {
      timer?.cancel();
      subscription?.cancel();
      messenger.showSnackBar(SnackBar(content: Text(message)));
    });
    timer = Timer(const Duration(seconds: 5), () => subscription?.cancel());
  }
}

/// Takes the overlay down when the app comes back to the front.
///
/// This is the safety net for the surface handoff. While the overlay holds the
/// video, the in-app surface is blank; if the user returns through the launcher
/// or the recents list instead of tapping the bubble, nothing else would close
/// it and the app would look broken. Returning to the app is precisely when
/// the video has to come home, which is also how system PiP behaves.
class _ResumeWatcher extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // stop() removes this observer, so it does not fire twice.
      FloatingPlayer.stop();
    }
  }
}

/// Button that pops the player out, labelled for whichever mechanism the
/// platform actually has.
///
/// It lives here rather than in a page so that the one place that knows the
/// Android/iOS split also owns how it is offered.
class FloatingPlayerButton extends StatelessWidget {
  const FloatingPlayerButton({super.key, this.size = 22});

  final double size;

  @override
  Widget build(BuildContext context) {
    // The browser preview has neither an overlay window nor a native player to
    // put in one, so the button would be a guaranteed no-op.
    if (kIsWeb) return const SizedBox.shrink();

    return IconButton(
      iconSize: size,
      icon: const Icon(Icons.picture_in_picture_alt_outlined),
      tooltip: FloatingPlayer.isSupported
          ? 'Float over other apps'
          : 'Picture in picture',
      onPressed: () => FloatingPlayer.popOut(context),
    );
  }
}
