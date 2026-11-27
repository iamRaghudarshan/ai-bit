import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:better_player_plus/better_player_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/chapters.dart';
import '../../core/format.dart';
import '../../core/seek_session.dart';
import '../../core/storyboard.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../data/player_client.dart';
import '../../data/settings.dart';
import '../../player/playback_controller.dart';
import '../player_sheet_controller.dart';
import 'cast_button.dart';
import 'end_screen.dart';
import 'player_settings_sheet.dart';
import 'seek_bar.dart';
import 'sheets.dart';
import 'stats_overlay.dart';

/// On-video controls, replacing better_player's built-in set, laid out after
/// YouTube's Android player as redesigned in October 2025.
///
/// **Everything that happens ON the video lives here** — the controls, the
/// gestures (double-tap seek, hold for 2x, pinch to fill, swipe out of
/// fullscreen), the end screen and the stats panel. They used to sit in the
/// watch page's own stack around the `BetterPlayer` widget, which is only the
/// inline surface: the plugin's fullscreen route builds the player again from
/// `customControlsBuilder` and nothing else, so fullscreen had no double-tap
/// seek, no end screen and no way to swipe out. Built from here they exist in
/// both, from one implementation.
///
/// Gestures, and how they share the surface:
///  * **Tap** toggles the controls. On the outer thirds it waits a moment in
///    case it is the first half of a double tap; in the middle, where a double
///    tap means nothing, it acts at once.
///  * **Double tap** on a side starts a seek session ([SeekSession]): every
///    further tap on that side within 700ms adds another ten seconds.
///  * **Press and hold** plays at 2x until released. Applied straight to the
///    native player and never through `PlaybackController.setSpeed`, which
///    would save it as this channel's speed.
///  * **Fullscreen only:** pinch to fill or fit, swipe down to leave. Inline,
///    a vertical drag belongs to the watch page (down minimises, up enters
///    fullscreen) — registering one here as well would win the gesture arena
///    from the page, since the deeper detector sees the pointer first.
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

class _VideoControlsState extends State<VideoControls>
    with TickerProviderStateMixin {
  // 4s rather than 3: three seconds is not long enough to notice the bar,
  // reach for it and land a finger on it.
  static const _hideAfter = Duration(seconds: 4);

  /// How long a side tap waits to learn whether it is a double tap.
  static const _doubleTapWait = Duration(milliseconds: 260);
  static const _doubleTapSlop = 100.0;

  static const _holdSpeed = 2.0;

  bool _visible = true;
  Timer? _hideTimer;

  bool _scrubbing = false;
  double _scrubFrac = 0;

  Timer? _pendingTap;
  Offset? _pendingTapAt;

  final SeekSession _seek = SeekSession();
  int _seekShownSide = 0;
  String _seekLabel = '';
  Timer? _seekHide;
  late final AnimationController _seekPulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );

  bool _holding = false;
  double? _heldFrom;
  Object? _heldSource;

  double _swipeDy = 0;
  int _gesturePointers = 0;
  bool _pinchApplied = false;
  bool _changedFit = false;

  String? _toast;
  Timer? _toastTimer;

  late final AnimationController _playPause = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  bool _wasPlaying = false;

  String? _storyboardVideo;
  Storyboard? _storyboard;

  /// better_player exports `VideoPlayerValue` but not the controller type that
  /// holds it, so this stays untyped. Only `value` and the listener API are
  /// used.
  dynamic get _video => widget.controller.videoPlayerController;

  bool get _isPlaying => widget.controller.isPlaying() ?? false;

  @override
  void initState() {
    super.initState();
    _video?.addListener(_onValue);
    _wasPlaying = _isPlaying;
    _playPause.value = _wasPlaying ? 1 : 0;
    _restartHideTimer();
    PlayerSheetController.compact.addListener(_onSheetCompact);
  }

  /// The sheet left the expanded state (a drag began, or it docked): the
  /// controls go, so the mini player and the drag show the bare picture, and
  /// reopening the sheet shows the video rather than whatever bar was up.
  void _onSheetCompact() {
    if (!mounted) return;
    if (PlayerSheetController.compact.value) {
      _hideTimer?.cancel();
      // A hold in progress ends here: the controls are about to unmount
      // their detector, and a disposed recogniser that had already won fires
      // neither end nor cancel — the video stayed at 2x with every later
      // hold refused.
      _endHold();
      _pendingTap?.cancel();
      _pendingTap = null;
      if (_visible) _setVisible(false);
    } else {
      // Back open: rebuild so the (hidden) controls are mounted again.
      setState(() {});
    }
  }

  @override
  void dispose() {
    PlayerSheetController.compact.removeListener(_onSheetCompact);
    _hideTimer?.cancel();
    _pendingTap?.cancel();
    _seekHide?.cancel();
    _toastTimer?.cancel();
    _video?.removeListener(_onValue);
    if (_holding) _restoreSpeed();
    // A pinch to fill belongs to the fullscreen it was made in. After the
    // frame, because posting a controller event from inside a dispose would
    // set state on the inline player while the tree is being finalised.
    if (_changedFit) {
      final controller = widget.controller;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => controller.setOverriddenFit(BoxFit.contain),
      );
    }
    _seekPulse.dispose();
    _playPause.dispose();
    super.dispose();
  }

  void _onValue() {
    if (!mounted) return;
    final playing = _isPlaying;
    if (playing != _wasPlaying) {
      _wasPlaying = playing;
      if (playing) {
        _playPause.forward();
        if (_visible) _restartHideTimer();
      } else {
        _playPause.reverse();
        _hideTimer?.cancel();
      }
    }
    if (!_scrubbing) setState(() {});
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    // Never auto-hide while paused: a paused video with hidden controls looks
    // like a frozen app.
    if (!_isPlaying) return;
    _hideTimer = Timer(_hideAfter, () {
      if (mounted && !_scrubbing) _setVisible(false);
    });
  }

  void _setVisible(bool visible) {
    if (_visible == visible) {
      if (visible) _restartHideTimer();
      return;
    }
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

  void _showToast(String text) {
    _toastTimer?.cancel();
    setState(() => _toast = text);
    _toastTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  // ------------------------------------------------------------ gestures

  void _onTapUp(
    Offset at,
    Size size,
    PlaybackController playback,
    bool canSeek,
  ) {
    final now = DateTime.now();
    final side = canSeek ? seekSideFor(at.dx, size.width) : 0;

    // Inside a session every tap on a side is another step, single or not.
    if (_seek.isActive(now)) {
      if (side != 0) _seekTap(side, now, playback);
      return;
    }

    final pending = _pendingTap;
    if (pending != null &&
        pending.isActive &&
        _pendingTapAt != null &&
        (at - _pendingTapAt!).distance < _doubleTapSlop) {
      pending.cancel();
      _pendingTap = null;
      if (side != 0) _seekTap(side, now, playback);
      return;
    }

    if (side == 0) {
      _toggle();
      return;
    }
    _pendingTapAt = at;
    _pendingTap = Timer(_doubleTapWait, () {
      _pendingTap = null;
      if (mounted) _toggle();
    });
  }

  void _seekTap(int side, DateTime now, PlaybackController playback) {
    final value = _video?.value as VideoPlayerValue?;
    final reported = value?.duration ?? Duration.zero;
    final duration = reported > Duration.zero ? reported : playback.duration;
    final target = _seek.tap(
      side,
      now: now,
      position: value?.position ?? Duration.zero,
      duration: duration,
    );
    unawaited(playback.seek(target));
    if (playback.showEndScreen && side < 0) playback.dismissEndScreen();
    _setVisible(false);
    setState(() {
      _seekShownSide = side;
      _seekLabel = _seek.label;
    });
    _seekPulse.forward(from: 0);
    _seekHide?.cancel();
    _seekHide = Timer(_seek.window + const Duration(milliseconds: 150), () {
      if (mounted) setState(() => _seekShownSide = 0);
    });
  }

  void _startHold(bool isLive) {
    final value = _video?.value as VideoPlayerValue?;
    if (value == null || isLive || !_isPlaying || _holding) return;
    _pendingTap?.cancel();
    _pendingTap = null;
    // Not initialised yet: nothing to speed up, so nothing to show.
    if (_video == null || !value.initialized) return;
    _heldFrom = value.speed;
    _heldSource = _video;
    unawaited(_setNativeSpeed(_holdSpeed));
    HapticFeedback.lightImpact();
    _setVisible(false);
    setState(() => _holding = true);
  }

  void _endHold() {
    if (!_holding) return;
    _restoreSpeed();
    if (mounted) setState(() => _holding = false);
  }

  /// Back to the speed that was playing before the hold — and only on the
  /// same source: if the video changed under the finger, the new one has
  /// already been given its own (per-channel) speed by the controller.
  void _restoreSpeed() {
    _holding = false;
    if (!identical(_video, _heldSource)) return;
    unawaited(_setNativeSpeed(_heldFrom ?? 1.0));
  }

  /// The plugin's own setter, which the host's speed memory never hears
  /// about. It throws — asynchronously — when the source has gone, which
  /// only means the next source sets its own speed; logged, not surfaced.
  Future<void> _setNativeSpeed(double speed) async {
    try {
      await widget.controller.setSpeed(speed);
    } catch (e) {
      debugPrint('AI BIT: hold-to-2x speed not applied - $e');
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    _swipeDy = 0;
    _gesturePointers = d.pointerCount;
    _pinchApplied = false;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    _gesturePointers = math.max(_gesturePointers, d.pointerCount);
    if (d.pointerCount >= 2) {
      if (_pinchApplied) return;
      final fill = pinchFill(d.scale);
      if (fill == null) return;
      _pinchApplied = true;
      widget.controller.setOverriddenFit(fill ? BoxFit.cover : BoxFit.contain);
      _changedFit = fill;
      _showToast(fill ? 'Zoomed to fill' : 'Original');
    } else if (_gesturePointers == 1) {
      _swipeDy += d.focalPointDelta.dy;
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_gesturePointers == 1 &&
        swipeExitsFullscreen(_swipeDy, d.velocity.pixelsPerSecond.dy)) {
      widget.controller.exitFullScreen();
    }
    _gesturePointers = 0;
  }

  // ------------------------------------------------------------ scrubbing

  void _scrubStart(double f) {
    _hideTimer?.cancel();
    setState(() {
      _scrubbing = true;
      _scrubFrac = f;
    });
  }

  void _scrubUpdate(double f) => setState(() => _scrubFrac = f);

  void _scrubEnd(double totalMs) {
    if (!_scrubbing) return;
    final target = Duration(milliseconds: (_scrubFrac * totalMs).round());
    widget.controller.seekTo(target);
    setState(() => _scrubbing = false);
    _restartHideTimer();
  }

  Storyboard? _storyboardFor(VideoBrief? video) {
    final id = video?.id;
    if (id == null) return null;
    if (_storyboardVideo != id || _storyboard == null) {
      _storyboardVideo = id;
      _storyboard =
          Storyboard.parse(YoutubePlayerClient.storyboardSpecFor(id));
    }
    return _storyboard;
  }

  // ------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    // Read here, in build proper: `select` is not allowed from the
    // LayoutBuilder callback the top bar is built in.
    final autoplay = context.select<SettingsService, bool>(
      (s) => s.autoplayNext,
    );
    // The clock is the only thing here that moves every second, so it rebuilds
    // on its own rather than dragging the whole watch page along with it.
    return ValueListenableBuilder<Duration>(
      valueListenable: playback.ticker,
      builder: (context, _, _) => _buildControls(context, playback, autoplay),
    );
  }

  /// The controls drawing nothing. That unmounts the hold detector, whose
  /// end and cancel then never fire, so a hold still in force is ended here
  /// (after the frame, since ending it sets state).
  Widget _nothing() {
    if (_holding) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _endHold();
      });
    }
    return const SizedBox.shrink();
  }

  Widget _buildControls(
    BuildContext context,
    PlaybackController playback,
    bool autoplay,
  ) {
    final VideoPlayerValue? value = _video?.value as VideoPlayerValue?;
    final fullscreen = widget.controller.isFullScreen;
    // Nothing over the picture in Picture in Picture. The plugin turns its
    // controls off before entering PiP, but these are custom controls and
    // never read that flag — so the floating window was crowded with a
    // shrunken seek bar, quality, speed and fullscreen buttons that are too
    // small to hit. Android draws its own play/pause and skip over a PiP
    // window, as it does for YouTube.
    if (!widget.controller.controlsEnabled || (value?.isPip ?? false)) {
      return _nothing();
    }
    // Nothing over the picture while the player sheet is docked or being
    // dragged — the mini player is the bare video, as on YouTube.
    if (PlayerSheetController.compact.value && !fullscreen) {
      return _nothing();
    }
    // Shorts draw their own surface; none of this belongs over one.
    if ((playback.current?.isShort ?? false) && !fullscreen) {
      return _nothing();
    }
    // The player reports no duration until the manifest has been read, and on
    // some sources never — which showed a total of 0:00 next to a running
    // position. The controller already knows the length from the feed
    // metadata, so fall back to that rather than displaying a lie.
    final reported = value?.duration ?? Duration.zero;
    final duration = reported > Duration.zero ? reported : playback.duration;
    final position = value?.position ?? Duration.zero;
    final isLive = widget.controller.isLiveStream();
    final buffering = widget.controller.isBuffering() ?? false;

    final totalMs = duration.inMilliseconds.toDouble();
    final playedFrac = totalMs > 0
        ? (position.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;
    var bufferedMs = 0;
    for (final range in value?.buffered ?? const []) {
      bufferedMs = math.max(bufferedMs, range.end.inMilliseconds);
    }
    final bufferedFrac =
        totalMs > 0 ? (bufferedMs / totalMs).clamp(0.0, 1.0) : 0.0;
    // While scrubbing, the clock and chapter follow the finger, not the
    // player — that is the whole point of looking at them mid-drag.
    final shown = _scrubbing
        ? Duration(milliseconds: (_scrubFrac * totalMs).round())
        : position;
    final chapterTitle = playback.chapters.isEmpty
        ? null
        : chapterAt(playback.chapters, shown)?.title;
    final audioOnly = playback.isAudioOnly;
    final canSeek = !isLive && totalMs > 0;

    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        final safe = fullscreen ? MediaQuery.paddingOf(context) : EdgeInsets.zero;
        final barInset = fullscreen ? 16.0 + math.max(safe.left, safe.right) : 0.0;
        final barBottom = fullscreen ? 18.0 + safe.bottom : 0.0;
        final barWidth = size.width - barInset * 2;

        return Stack(
          fit: StackFit.expand,
          children: [
            // Audio only draws its artwork HERE, beneath the controls, not
            // over them. It used to be a layer above the whole player made
            // transparent to touch, so its own pause button was only a
            // picture: the tap fell through to whatever control lay
            // underneath — the Next button — and pausing skipped the video.
            if (audioOnly)
              IgnorePointer(child: _AudioBackdrop(video: playback.current)),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) =>
                  _onTapUp(d.localPosition, size, playback, canSeek),
              onLongPressStart: (_) => _startHold(isLive),
              onLongPressEnd: (_) => _endHold(),
              onLongPressCancel: _endHold,
              onScaleStart: fullscreen ? _onScaleStart : null,
              onScaleUpdate: fullscreen ? _onScaleUpdate : null,
              onScaleEnd: fullscreen ? _onScaleEnd : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Ignore pointers while hidden, otherwise invisible buttons
                  // still swallow taps meant for the gesture layer.
                  IgnorePointer(
                    ignoring: !_visible,
                    child: AnimatedOpacity(
                      opacity: _visible ? 1 : 0,
                      duration: const Duration(milliseconds: 180),
                      // The opacity layer holds the scrim and the buttons
                      // only — the video texture is a sibling beneath it,
                      // never inside it.
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Lighter than it was (black38): the 2025 player
                          // dims the picture just enough to read white
                          // icons over it.
                          const ColoredBox(color: Colors.black26),
                          _buildCentre(playback, buffering),
                          _buildTopBar(
                            context,
                            playback,
                            fullscreen,
                            safe,
                            autoplay,
                          ),
                          Positioned(
                            left: barInset + 12,
                            right: barInset + 6,
                            bottom: barBottom + PlayerSeekBar.thumbLift + 14,
                            child: _buildTimeRow(
                              shown,
                              duration,
                              isLive,
                              chapterTitle,
                              fullscreen,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (!isLive && (_visible || !fullscreen))
                    Positioned(
                      left: barInset,
                      right: barInset,
                      bottom: barBottom,
                      child: PlayerSeekBar(
                        fraction: _scrubbing ? _scrubFrac : playedFrac,
                        bufferedFraction: bufferedFrac,
                        totalMs: totalMs,
                        chapters: playback.chapters,
                        showThumb: _visible,
                        scrubbing: _scrubbing,
                        enabled: _visible && canSeek,
                        onScrubStart: _scrubStart,
                        onScrubUpdate: _scrubUpdate,
                        onScrubEnd: (_) => _scrubEnd(totalMs),
                      ),
                    ),
                  if (_scrubbing)
                    _ScrubPreview(
                      left: barInset,
                      width: barWidth,
                      bottom: barBottom + 30,
                      fraction: _scrubFrac,
                      label: clockLabel(shown),
                      frame: _storyboardFor(playback.current)
                          ?.frameAt(shown, duration),
                      maxHeight: size.height - barBottom - 40,
                    ),
                  if (_seekShownSide != 0)
                    IgnorePointer(
                      child: _SeekRipple(
                        side: _seekShownSide,
                        label: _seekLabel,
                        pulse: _seekPulse,
                      ),
                    ),
                  if (_holding)
                    Positioned(
                      top: 12 + safe.top,
                      left: 0,
                      right: 0,
                      child: const IgnorePointer(
                        child: Center(child: _HoldPill()),
                      ),
                    ),
                  if (_toast != null)
                    IgnorePointer(
                      child: Center(child: _Toast(text: _toast!)),
                    ),
                ],
              ),
            ),
            // Above the gesture layer, not inside it, so a tap on the panel
            // closes it instead of also toggling the controls behind.
            if (playback.showStats)
              Padding(
                padding: EdgeInsets.only(top: 44 + safe.top, left: safe.left),
                child: StatsOverlay(
                  stats: playback.stats,
                  onClose: playback.toggleStats,
                ),
              ),
            // Over everything else: a finished video used to freeze on its
            // last frame with no sign that anything came next.
            if (playback.showEndScreen)
              Positioned.fill(
                child: EndScreen(
                  suggestions: playback.endScreenSuggestions,
                  countdown: playback.autoplayCountdown,
                  onReplay: playback.replay,
                  onCancel: playback.cancelAutoplay,
                  onDismiss: playback.dismissEndScreen,
                  // Through the player, never by opening another watch page:
                  // that stacked a second watch route over this one. The page
                  // already follows whatever the player moves on to.
                  onPlay: (video) {
                    playback.dismissEndScreen();
                    final queue = playback.queue;
                    if (queue.isNotEmpty && queue.first.id == video.id) {
                      unawaited(playback.playNext());
                    } else {
                      unawaited(playback.play(video));
                    }
                  },
                ),
              ),
            // Always on screen in audio mode, whether or not the controls
            // are, and it is the way back: there was no control anywhere on
            // the player to leave audio only. Below the top bar, which now
            // owns the corners.
            if (audioOnly)
              Positioned(
                top: 46 + safe.top,
                left: 8 + safe.left,
                child: _AudioOnlyPill(
                  label: playback.isOfflineAudio
                      ? 'Downloaded audio'
                      : playback.isAudioFallback
                      ? 'Audio only — no video for this one'
                      : playback.audioOnlyFromSettings
                      ? 'Audio only (on in Settings)'
                      : 'Audio only',
                  // A sound-only download streams the picture instead, and a
                  // sound-only answer from YouTube is asked again: neither
                  // used to offer a way back, so the video stayed audio until
                  // it was reopened.
                  onShowVideo: playback.canShowVideo
                      ? playback.showVideoAnyway
                      : () => playback.setAudioOnly(false),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildCentre(PlaybackController playback, bool buffering) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RoundButton(
            size: 30,
            dimmed: !playback.hasPrevious,
            onTap: () => _act(playback.playPrevious),
            child: const Icon(Icons.skip_previous_rounded),
          ),
          const SizedBox(width: 28),
          if (buffering)
            const SizedBox(
              width: 60,
              height: 60,
              child: Padding(
                padding: EdgeInsets.all(10),
                child: CircularProgressIndicator(color: Colors.white),
              ),
            )
          else
            _RoundButton(
              size: 42,
              // Through the PlaybackController so a finished video restarts
              // from the top rather than staying stuck on its last frame.
              onTap: () => _act(playback.togglePlayPause),
              child: AnimatedIcon(
                icon: AnimatedIcons.play_pause,
                progress: _playPause,
              ),
            ),
          const SizedBox(width: 28),
          _RoundButton(
            size: 30,
            dimmed: !playback.hasNext,
            onTap: playback.hasNext ? () => _act(playback.playNext) : null,
            child: const Icon(Icons.skip_next_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeRow(
    Duration shown,
    Duration duration,
    bool isLive,
    String? chapterTitle,
    bool fullscreen,
  ) {
    const style = TextStyle(
      color: Colors.white,
      fontSize: 12,
      fontWeight: FontWeight.w500,
      shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (isLive)
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, color: AppColors.brand, size: 8),
              SizedBox(width: 5),
              Text('LIVE', style: style),
            ],
          )
        else
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: clockLabel(shown)),
                TextSpan(
                  text: ' / ${clockLabel(duration)}',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
            style: style,
          ),
        if (chapterTitle != null && !isLive) ...[
          const Text('  ·  ', style: style),
          Flexible(
            child: Text(
              chapterTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
        const Spacer(),
        _CircleButton(
          icon: fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
          tooltip: fullscreen ? 'Exit fullscreen' : 'Fullscreen',
          onTap: () => _act(widget.controller.toggleFullScreen),
        ),
      ],
    );
  }

  Widget _buildTopBar(
    BuildContext context,
    PlaybackController playback,
    bool fullscreen,
    EdgeInsets safe,
    bool autoplay,
  ) {
    final captionsOn = playback.activeCaptions != null;
    return Positioned(
      top: safe.top,
      left: safe.left,
      right: safe.right,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(2, 2, 4, 0),
        child: Row(
          children: [
            _BarButton(
              icon: Icons.keyboard_arrow_down_rounded,
              size: 30,
              tooltip: fullscreen ? 'Exit fullscreen' : 'Minimise',
              onTap: () {
                if (fullscreen) {
                  widget.controller.exitFullScreen();
                } else {
                  // Collapses the player sheet; the mini player takes over
                  // and playback carries on.
                  PlayerSheetController.instance?.collapse();
                }
              },
            ),
            if (fullscreen && playback.current != null)
              Expanded(
                child: Text(
                  playback.current!.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            else
              const Spacer(),
            _AutoplaySwitch(
              value: autoplay,
              onChanged: (v) => _act(() {
                context.read<SettingsService>().autoplayNext = v;
                _showToast(v ? 'Autoplay is on' : 'Autoplay is off');
              }),
            ),
            // Built only while the controls are up: on iOS this is a native
            // platform view, and fading one in an opacity layer is the kind
            // of composition AVRoutePickerView is least happy with.
            if (CastButton.isSupported && _visible)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: IconTheme(
                  data: IconThemeData(color: Colors.white),
                  child: CastButton(size: 22),
                ),
              ),
            _BarButton(
              icon: captionsOn
                  ? Icons.closed_caption
                  : Icons.closed_caption_off_outlined,
              tooltip: captionsOn ? 'Captions off' : 'Captions',
              onTap: () => _act(() {
                if (captionsOn) {
                  unawaited(playback.setCaptions(null));
                  _showToast('Captions off');
                } else {
                  showCaptionsSheet(context);
                }
              }),
            ),
            _BarButton(
              icon: Icons.settings_outlined,
              tooltip: 'Settings',
              onTap: () => _act(() => showPlayerSettingsSheet(context)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A translucent round button for the centre transport row.
class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.child,
    required this.size,
    this.onTap,
    this.dimmed = false,
  });

  final Widget child;
  final double size;
  final VoidCallback? onTap;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.32),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(size > 36 ? 11 : 9),
          child: IconTheme(
            data: IconThemeData(
              size: size,
              color: dimmed ? Colors.white38 : Colors.white,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// A plain white icon in the top bar, with a finger-sized target.
class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 24,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: size, color: Colors.white),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
    );
  }
}

/// The fullscreen button: a 36dp translucent disc.
class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.32),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }
}

/// YouTube's autoplay switch: a small track with the thumb carrying a play
/// or pause glyph.
class _AutoplaySwitch extends StatelessWidget {
  const _AutoplaySwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: value ? 'Autoplay is on' : 'Autoplay is off',
      child: InkResponse(
        radius: 24,
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
          child: SizedBox(
            width: 36,
            height: 20,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 34,
                  height: 14,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: value ? 0.55 : 0.3),
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
                AnimatedAlign(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  alignment:
                      value ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: value ? Colors.white : const Color(0xFFBDBDBD),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      value ? Icons.play_arrow_rounded : Icons.pause_rounded,
                      size: 14,
                      color: Colors.black,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The floating time — and storyboard frame, where YouTube offers one —
/// above the thumb while scrubbing.
class _ScrubPreview extends StatelessWidget {
  const _ScrubPreview({
    required this.left,
    required this.width,
    required this.bottom,
    required this.fraction,
    required this.label,
    required this.frame,
    required this.maxHeight,
  });

  final double left;
  final double width;
  final double bottom;
  final double fraction;
  final String label;
  final StoryboardFrame? frame;
  final double maxHeight;

  static const _frameW = 160.0;
  static const _frameH = 90.0;

  @override
  Widget build(BuildContext context) {
    final showFrame = frame != null && maxHeight > _frameH + 30;
    final boxW = showFrame ? _frameW : 72.0;
    final x = left + fraction * width - boxW / 2;
    final clamped =
        x.clamp(4.0, math.max(4.0, left + width - boxW - 4)).toDouble();
    return Positioned(
      left: clamped,
      bottom: bottom,
      width: boxW,
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showFrame)
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 1.5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: _StoryboardImage(frame: frame!),
                ),
              ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One frame cut out of a storyboard sprite sheet, shown at 160×90.
///
/// The sheet is laid out at the scale that makes one frame 160×90 and
/// shifted so the wanted frame sits in the clip — cheaper than decoding and
/// cropping, and the same cached image serves every frame on that sheet.
class _StoryboardImage extends StatelessWidget {
  const _StoryboardImage({required this.frame});

  final StoryboardFrame frame;

  @override
  Widget build(BuildContext context) {
    final level = frame.level;
    final scaleX = _ScrubPreview._frameW / level.width;
    final scaleY = _ScrubPreview._frameH / level.height;
    return SizedBox(
      width: _ScrubPreview._frameW,
      height: _ScrubPreview._frameH,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          const Positioned.fill(child: ColoredBox(color: Colors.black)),
          Positioned(
            left: -frame.column * level.width * scaleX,
            top: -frame.row * level.height * scaleY,
            width: level.columns * level.width * scaleX,
            height: level.rows * level.height * scaleY,
            child: CachedNetworkImage(
              imageUrl: frame.url,
              fit: BoxFit.fill,
              fadeInDuration: Duration.zero,
              fadeOutDuration: Duration.zero,
              errorWidget: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}

/// The double-tap seek feedback: an arc over one side holding the running
/// total ("+20"), which pulses on every tap.
class _SeekRipple extends StatelessWidget {
  const _SeekRipple({
    required this.side,
    required this.label,
    required this.pulse,
  });

  final int side;
  final String label;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    final left = side < 0;
    final scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1, end: 1.15), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 1.15, end: 1), weight: 1),
    ]).animate(pulse);
    return Align(
      alignment: left ? Alignment.centerLeft : Alignment.centerRight,
      child: FractionallySizedBox(
        widthFactor: 0.38,
        heightFactor: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.horizontal(
              left: left ? Radius.zero : const Radius.elliptical(220, 400),
              right: left ? const Radius.elliptical(220, 400) : Radius.zero,
            ),
          ),
          child: Center(
            child: ScaleTransition(
              scale: scale,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    left ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "2x ▶▶" at the top while the video is held.
class _HoldPill extends StatelessWidget {
  const _HoldPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '2x',
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          SizedBox(width: 4),
          Icon(Icons.fast_forward_rounded, color: Colors.white, size: 16),
        ],
      ),
    );
  }
}

class _Toast extends StatelessWidget {
  const _Toast({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 13),
      ),
    );
  }
}

/// What audio only shows instead of a picture: the video's thumbnail, blurred
/// across the surface and sharp in the middle. No buttons of its own — the
/// player's controls are drawn over it and do the work.
class _AudioBackdrop extends StatelessWidget {
  const _AudioBackdrop({required this.video});

  final VideoBrief? video;

  @override
  Widget build(BuildContext context) {
    final url = video?.thumbUrl;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        if (url != null) ...[
          // Its own layer and a small source: at sigma 24 a 120-pixel image
          // blurred looks the same as a 720-pixel one for a fraction of the
          // work, and a rebuild of the controls does not repaint it.
          RepaintBoundary(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: CachedNetworkImage(
                memCacheWidth: 120,
                imageUrl: url,
                fit: BoxFit.cover,
              ),
            ),
          ),
          const ColoredBox(color: Colors.black45),
          Center(
            child: FractionallySizedBox(
              heightFactor: 0.62,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: CachedNetworkImage(
                    memCacheWidth: 480,
                    imageUrl: url,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// "Audio only" with a Show video button beside it.
class _AudioOnlyPill extends StatelessWidget {
  const _AudioOnlyPill({required this.label, this.onShowVideo});

  final String label;
  final VoidCallback? onShowVideo;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.headphones, color: Colors.white, size: 15),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
          if (onShowVideo != null)
            InkWell(
              onTap: onShowVideo,
              child: const Padding(
                // A finger-sized target, not a word-sized one.
                padding: EdgeInsets.fromLTRB(10, 8, 12, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.videocam, color: AppColors.brand, size: 16),
                    SizedBox(width: 4),
                    Text(
                      'Show video',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
