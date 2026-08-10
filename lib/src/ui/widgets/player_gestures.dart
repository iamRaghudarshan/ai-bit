import 'dart:async';

import 'package:flutter/material.dart';
import 'package:screen_brightness/screen_brightness.dart';

/// Transparent gesture layer over the video surface.
///
/// Sits *behind* better_player's own controls in the stack, so a tap that hits
/// a real button is consumed by the button and never reaches here. Only gestures
/// on empty video area get through.
///
///   * double-tap left / right — seek ∓10s, with a brief ripple
///   * vertical drag, left half — screen brightness
///   * vertical drag, right half — player volume
class PlayerGestures extends StatefulWidget {
  const PlayerGestures({
    super.key,
    required this.onSeekBy,
    required this.onVolume,
    required this.currentVolume,
    this.enabled = true,
  });

  final void Function(Duration delta) onSeekBy;
  final void Function(double volume) onVolume;
  final double currentVolume;
  final bool enabled;

  @override
  State<PlayerGestures> createState() => _PlayerGesturesState();
}

class _PlayerGesturesState extends State<PlayerGestures> {
  static const _seekStep = Duration(seconds: 10);

  /// -1 rewind, 1 forward, 0 idle. Drives the ripple.
  int _seekSide = 0;
  Timer? _seekFade;

  /// Non-null while a vertical drag is in progress.
  _Adjust? _adjust;
  double _startValue = 0;
  double _liveValue = 0;

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

  Future<void> _onDragStart(DragStartDetails d, BoxConstraints box) async {
    final isLeft = d.localPosition.dx < box.maxWidth / 2;
    _adjust = isLeft ? _Adjust.brightness : _Adjust.volume;
    if (isLeft) {
      try {
        _startValue = await ScreenBrightness.instance.application;
      } catch (_) {
        _startValue = 0.5;
      }
    } else {
      _startValue = widget.currentVolume;
    }
    _liveValue = _startValue;
    if (mounted) setState(() {});
  }

  Future<void> _onDragUpdate(DragUpdateDetails d, BoxConstraints box) async {
    final adjust = _adjust;
    if (adjust == null) return;
    // Full height of the surface maps to the full 0..1 range; dragging up
    // increases, which is the convention everywhere else.
    final delta = -d.primaryDelta! / box.maxHeight;
    _liveValue = (_liveValue + delta).clamp(0.0, 1.0);

    if (adjust == _Adjust.brightness) {
      try {
        await ScreenBrightness.instance.setApplicationScreenBrightness(_liveValue);
      } catch (_) {
        // Brightness control is unavailable on some devices; ignore rather
        // than interrupt playback with an error.
      }
    } else {
      widget.onVolume(_liveValue);
    }
    if (mounted) setState(() {});
  }

  void _onDragEnd() {
    if (mounted) setState(() => _adjust = null);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        // deferToChild, NOT opaque: better_player's controls sit above this in
        // the stack and must keep receiving their own taps.
        behavior: HitTestBehavior.deferToChild,
        onDoubleTapDown: (d) => _onDoubleTapDown(d, box),
        onDoubleTap: () {},
        onVerticalDragStart: (d) => _onDragStart(d, box),
        onVerticalDragUpdate: (d) => _onDragUpdate(d, box),
        onVerticalDragEnd: (_) => _onDragEnd(),
        onVerticalDragCancel: _onDragEnd,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Something must be hit-testable for the drag to register, but it
            // has to stay invisible and let taps fall through to the controls.
            const ColoredBox(color: Colors.transparent),
            if (_seekSide != 0) _SeekRipple(side: _seekSide, step: _seekStep),
            if (_adjust != null)
              _LevelBadge(adjust: _adjust!, value: _liveValue),
          ],
        ),
      ),
    );
  }
}

enum _Adjust { brightness, volume }

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

class _LevelBadge extends StatelessWidget {
  const _LevelBadge({required this.adjust, required this.value});

  final _Adjust adjust;
  final double value;

  @override
  Widget build(BuildContext context) {
    final isBrightness = adjust == _Adjust.brightness;
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isBrightness
                    ? (value > 0.5 ? Icons.brightness_high : Icons.brightness_low)
                    : (value == 0 ? Icons.volume_off : Icons.volume_up),
                color: Colors.white,
                size: 26,
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: 90,
                child: LinearProgressIndicator(
                  value: value,
                  minHeight: 3,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation(Colors.white),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${(value * 100).round()}%',
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
