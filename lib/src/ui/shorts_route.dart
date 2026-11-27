import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import 'shorts_page.dart';
import 'widgets/now_playing_overlay.dart';

/// The vertical Shorts player as a pushed, full-screen route.
///
/// Opened from anywhere that shows Shorts outside the Shorts tab — the Home
/// shelf, search results, a channel's Shorts, a saved list — so a Short tapped
/// there plays the way it does on YouTube (full-bleed, swipe to the next one)
/// instead of in the long-form watch page.
///
/// It runs the same [ShortsPage] the tab does, started from [shorts] at
/// `startIndex`, and carries on into the ranked Shorts feed once the given
/// list runs out. Leaving the route stops the Short rather than pausing it, so
/// a Short never lingers in the mini player.
class ShortsRoute {
  ShortsRoute._();

  /// Pushes the player over the current route. Every entry is tagged
  /// [VideoBrief.asShort] so history files it under Shorts.
  static Future<void> open(
    BuildContext context,
    List<VideoBrief> shorts, {
    int startIndex = 0,
  }) {
    if (shorts.isEmpty) return Future.value();
    final list = [for (final s in shorts) s.isShort ? s : s.asShort()];
    final start = startIndex.clamp(0, list.length - 1);
    return Navigator.of(context).push(
      PageRouteBuilder<void>(
        // Named so the now-playing overlay knows not to paint its bar over a
        // screen that is itself the player. See RouteStackObserver.
        settings: const RouteSettings(
          name: RouteStackObserver.shortsRouteName,
        ),
        opaque: true,
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, _, _) => _ShortsRouteBody(shorts: list, start: start),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
      ),
    );
  }
}

class _ShortsRouteBody extends StatelessWidget {
  const _ShortsRouteBody({required this.shorts, required this.start});

  final List<VideoBrief> shorts;
  final int start;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            ShortsPage(initial: shorts, startIndex: start),
            SafeArea(
              child: Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: IconButton(
                    tooltip: 'Back',
                    icon: const Icon(
                      Icons.arrow_back,
                      color: Colors.white,
                      shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
                    ),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
