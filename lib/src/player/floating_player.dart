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
/// The bubble is a control, not a second video surface: there is exactly one
/// native player and it is attached to the Flutter view (see CLAUDE.md, "One
/// player for the whole app"), so its pixels cannot also be rendered into an
/// overlay window. What the bubble gives you is audio that keeps playing, the
/// title of what is playing, and one tap back into the app.
class FloatingPlayer {
  const FloatingPlayer._();

  static const _channel = MethodChannel('ai.bit/floating_player');

  /// True only where a real overlay window exists. See the class comment for
  /// why iOS is a permanent false rather than a to-do.
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

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

  /// Shows the bubble. False when it could not be shown, which in practice
  /// means the overlay permission is not granted.
  static Future<bool> start({String title = '', String subtitle = ''}) =>
      _ask<bool>(
        'start',
        fallback: false,
        arguments: <String, dynamic>{'title': title, 'subtitle': subtitle},
      );

  /// Takes the bubble down. Safe to call when it is not showing.
  static Future<void> stop() => _ask<bool>('stop', fallback: false);

  /// Whether the overlay service is currently up.
  static Future<bool> isRunning() =>
      _ask<bool>('isRunning', fallback: false);

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
      await playback.enterPictureInPicture();
      return;
    }

    final video = playback.current;
    if (video == null) return;

    // Captured before the first await: the messenger must not be looked up
    // through a context that may have been popped by then.
    final messenger = ScaffoldMessenger.of(context);

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

    final started = await start(title: video.title, subtitle: video.author);
    if (!started) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open the floating player.')),
      );
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
