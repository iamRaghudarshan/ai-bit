import 'dart:async';

import 'package:flutter/material.dart';

/// Transparent gesture layer over the video surface.
///
/// Double-tap left or right to seek ∓10s, with a brief ripple. That is the
/// only gesture here.
///
/// Brightness and volume used to be on a vertical drag, one per half of the
/// screen. They are gone: the watch page drags down to minimise the player,
/// and both gestures start the same way, so every downward swipe was a
/// coin toss between dimming the screen and dismissing the video. Losing two
/// shortcuts is worth a drag that behaves the same way every time — the system
/// volume buttons and Control Centre cover both anyway.
class PlayerGestures extends StatefulWidget {
  const PlayerGestures({
    super.key,
    required this.onSeekBy,
    this.enabled = true,
  });

  final void Function(Duration delta) onSeekBy;
  final bool enabled;

  @override
  State<PlayerGestures> createState() => _PlayerGesturesState();
}

class _PlayerGesturesState extends State<PlayerGestures> {
  static const _seekStep = Duration(seconds: 10);

  /// -1 rewind, 1 forward, 0 idle. Drives the ripple.
  int _seekSide = 0;
  Timer? _seekFade;

  @override
  void dispose() {
    _seekFade?.cancel();
    super.dispose();
  }

  void _onDoubleTapDown(TapDownDetails details, BoxConstraints box) {
    final isLeft = details.localPosition.dx < box.maxWidth / 2;
    widget.onSeekBy(isLeft ? -_seekStep : _seekStep);

    setState(() => _seekSide = isLeft ? -1 : 1);
    _seekFade?.cancel();
    _seekFade = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _seekSide = 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        // translucent: this layer is hit-tested across its whole area, and the
        // controls beneath it still receive their own taps.
        //
        // It used to be deferToChild over a transparent ColoredBox, which
        // hit-tests nothing at all — RenderColoredBox only accepts a hit when
        // the colour has alpha, so a fully transparent one is invisible to the
        // gesture system. Double-tap to seek and the volume drag were both
        // dead as a result.
        behavior: HitTestBehavior.translucent,
        onDoubleTapDown: (d) => _onDoubleTapDown(d, box),
        onDoubleTap: () {},
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_seekSide != 0) _SeekRipple(side: _seekSide, step: _seekStep),
          ],
        ),
      ),
    );
  }
}

class _SeekRipple extends StatelessWidget {
  const _SeekRipple({required this.side, required this.step});

  final int side;
  final Duration step;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: side < 0 ? Alignment.centerLeft : Alignment.centerRight,
      child: FractionallySizedBox(
        widthFactor: 0.4,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.28),
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(side < 0 ? 0 : 200),
              right: Radius.circular(side < 0 ? 200 : 0),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                side < 0 ? Icons.fast_rewind : Icons.fast_forward,
                color: Colors.white,
                size: 30,
              ),
              Text(
                '${step.inSeconds} seconds',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
