import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../player/playback_controller.dart';
import 'sheets.dart';

/// On-video controls, replacing better_player's built-in set.
///
/// Its own controls have no notion of a queue, so there was no way to reach the
/// next or previous video from the video surface — only by scrolling to the
/// transport row or waiting for autoplay. This is the same layout the real app
/// uses: tap to reveal, ⏮ ⏯ ⏭ across the middle, scrubber and fullscreen along
/// the bottom.
class VideoControls extends StatefulWidget {
  const VideoControls({
    super.key,
    required this.controller,
    required this.onVisibilityChanged,
  });

  final BetterPlayerController controller;
  final void Function(bool visible) onVisibilityChanged;

  @override
  State<VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<VideoControls> {
  // 4s rather than 3: three seconds is not long enough to notice the bar,
  // reach for it and land a finger on it.
  static const _hideAfter = Duration(seconds: 4);

  bool _visible = true;
  Timer? _hideTimer;
  bool _scrubbing = false;
  double _scrubTo = 0;

  /// better_player exports `VideoPlayerValue` but not the controller type that
  /// holds it, so this stays untyped. Only `value` and the listener API are
  /// used.
  dynamic get _video => widget.controller.videoPlayerController;

  @override
  void initState() {
    super.initState();
    _video?.addListener(_onValue);
    _restartHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _video?.removeListener(_onValue);
    super.dispose();
  }

  void _onValue() {
    if (mounted && !_scrubbing) setState(() {});
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    // Never auto-hide while paused: a paused video with hidden controls looks
    // like a frozen app.
    if (!(widget.controller.isPlaying() ?? false)) return;
    _hideTimer = Timer(_hideAfter, () {
      if (mounted) _setVisible(false);
    });
  }

  void _setVisible(bool visible) {
    setState(() => _visible = visible);
    widget.onVisibilityChanged(visible);
    if (visible) _restartHideTimer();
  }

  void _toggle() => _setVisible(!_visible);

  /// Any button press keeps the controls up — they should not vanish mid-use.
  void _act(VoidCallback action) {
    action();
    _restartHideTimer();
  }

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    // The clock is the only thing here that moves every second, so it rebuilds
    // on its own rather than dragging the whole watch page along with it.
    return ValueListenableBuilder<Duration>(
      valueListenable: playback.ticker,
      builder: (context, _, _) => _buildControls(context, playback),
    );
  }

  Widget _buildControls(BuildContext context, PlaybackController playback) {
    final VideoPlayerValue? value = _video?.value as VideoPlayerValue?;
    final duration = value?.duration ?? Duration.zero;
    final position = value?.position ?? Duration.zero;
    final isLive = widget.controller.isLiveStream();
    final buffering = widget.controller.isBuffering() ?? false;

    final total = duration.inMilliseconds;
    final progress = total > 0
        ? (position.inMilliseconds / total).clamp(0.0, 1.0)
        : 0.0;

    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggle,
          child: AnimatedOpacity(
            opacity: _visible ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            // Ignore pointers while hidden, otherwise invisible buttons still
            // swallow taps meant for the gesture layer beneath.
            child: IgnorePointer(
              ignoring: !_visible,
              child: ColoredBox(
                color: Colors.black38,
                child: Stack(
                  children: [
                    _buildCentre(playback, buffering),
                    _buildBottomBar(position, duration, isLive),
                    _buildTopBar(),
                  ],
                ),
              ),
            ),
          ),
        ),
        // A hairline of progress once the controls fade, the way the real app
        // does it — otherwise a playing video gives no sign of how far in it is
        // without tapping first.
        if (!_visible && !isLive)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 2.5,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation(AppColors.brand),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCentre(PlaybackController playback, bool buffering) {
    return Center(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _RoundButton(
            icon: Icons.skip_previous,
            size: 30,
            dimmed: !playback.hasPrevious,
            onTap: () => _act(playback.playPrevious),
          ),
          const SizedBox(width: 20),
          if (buffering)
            const SizedBox(
              width: 58,
              height: 58,
              child: Padding(
                padding: EdgeInsets.all(10),
                child: CircularProgressIndicator(color: Colors.white),
              ),
            )
          else
            _RoundButton(
              icon: (widget.controller.isPlaying() ?? false)
                  ? Icons.pause
                  : Icons.play_arrow,
              size: 44,
              onTap: () => _act(() {
                if (widget.controller.isPlaying() ?? false) {
                  widget.controller.pause();
                } else {
                  widget.controller.play();
                }
              }),
            ),
          const SizedBox(width: 20),
          _RoundButton(
            icon: Icons.skip_next,
            size: 30,
            dimmed: !playback.hasNext,
            onTap: playback.hasNext ? () => _act(playback.playNext) : null,
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(Duration position, Duration duration, bool isLive) {
    final total = duration.inMilliseconds.toDouble();
    final current = _scrubbing
        ? _scrubTo
        : position.inMilliseconds.toDouble().clamp(0, total <= 0 ? 1 : total);

    return Positioned(
      left: 4,
      right: 4,
      bottom: 0,
      child: Row(
        children: [
          const SizedBox(width: 8),
          Text(
            isLive ? 'LIVE' : clockLabel(position),
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
          Expanded(
            child: isLive
                // A live edge has nothing meaningful to scrub through.
                ? const SizedBox(height: 24)
                : SizedBox(
                    // A generous strip to aim at. The default slider is a few
                    // pixels tall, which is unusable on a phone while a video
                    // is moving underneath it.
                    height: 44,
                    child: SliderTheme(
                      data: SliderThemeData(
                        trackHeight: _scrubbing ? 5 : 3,
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius: _scrubbing ? 9 : 7,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 22,
                        ),
                        activeTrackColor: AppColors.brand,
                        inactiveTrackColor: Colors.white30,
                        thumbColor: AppColors.brand,
                        overlayColor: AppColors.brand.withValues(alpha: 0.25),
                      ),
                      child: Slider(
                        value: total <= 0 ? 0 : current.toDouble(),
                        max: total <= 0 ? 1 : total,
                        onChangeStart: (v) {
                          _hideTimer?.cancel();
                          setState(() {
                            _scrubbing = true;
                            _scrubTo = v;
                          });
                        },
                        onChanged: (v) => setState(() => _scrubTo = v),
                        onChangeEnd: (v) {
                          widget.controller
                              .seekTo(Duration(milliseconds: v.round()));
                          setState(() => _scrubbing = false);
                          _restartHideTimer();
                        },
                      ),
                    ),
                  ),
          ),
          Text(
            isLive ? '' : clockLabel(duration),
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
          IconButton(
            icon: Icon(
              widget.controller.isFullScreen
                  ? Icons.fullscreen_exit
                  : Icons.fullscreen,
              color: Colors.white,
            ),
            tooltip: 'Fullscreen',
            onPressed: () => _act(widget.controller.toggleFullScreen),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      right: 0,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.hd_outlined, color: Colors.white, size: 20),
            tooltip: 'Quality',
            onPressed: () => _act(() => showQualitySheet(context)),
          ),
          IconButton(
            icon: const Icon(Icons.speed, color: Colors.white, size: 20),
            tooltip: 'Playback speed',
            onPressed: () => _act(() => showSpeedSheet(context)),
          ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.size,
    this.onTap,
    this.dimmed = false,
  });

  final IconData icon;
  final double size;
  final VoidCallback? onTap;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black26,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(
            icon,
            size: size,
            color: dimmed ? Colors.white38 : Colors.white,
          ),
        ),
      ),
    );
  }
}
