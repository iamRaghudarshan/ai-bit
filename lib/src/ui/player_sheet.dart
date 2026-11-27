import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:better_player_plus/better_player_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/seek_session.dart' show swipeEntersFullscreen;
import '../core/theme.dart';
import '../data/models.dart';
import '../player/floating_player.dart';
import '../player/playback_controller.dart';
import 'player_sheet_controller.dart';
import 'watch_page.dart';
import 'widgets/mini_player.dart';

/// The one continuous player: the watch page and the mini player are two ends
/// of this one sheet, as in YouTube's Android app.
///
/// Expanded (1.0) it fills the screen — video under the status bar, the watch
/// page below. Dragged down it follows the finger 1:1 while the LIVE video
/// shrinks towards the left of a bar docked just above the navigation bar;
/// the page fades out over the first 40% of the drag and the bar's title and
/// buttons fade in over the last 25%. Released, a fling decides the
/// direction, otherwise the nearer end wins, on a spring.
///
/// **The video widget is mounted exactly once, at one place in this tree, at
/// all times** — `BetterPlayer(key: playback.playerKey)` is a GlobalKey, and
/// two mounted copies crash. Between expanded and mini it is only scaled and
/// moved by transforms around it, never rebuilt elsewhere, so the picture in
/// the mini player is the real one. It is not mounted while the Shorts player
/// presents the source ([PlaybackController.onShortsSurface]); that is the
/// condition the Shorts page mounts its own copy under, so the two are
/// mutually exclusive.
///
/// Nothing here rebuilds per frame of a drag: the page, the video and the bar
/// are built once per real change and handed to one [AnimatedBuilder] that
/// only positions them. No `Opacity` below 1 is ever applied over the video
/// texture — the page and the bar fade with [FadeTransition]s on their own
/// subtrees, and the video stays opaque.
class PlayerSheet extends StatefulWidget {
  const PlayerSheet({
    super.key,
    required this.controller,
    required this.bottomInset,
    required this.hidden,
  });

  /// Height of the docked mini player, and of the video inside it.
  static const miniHeight = 64.0;

  final PlayerSheetController controller;

  /// Height of the navigation bar the mini player docks above.
  final double bottomInset;

  /// True on the Shorts tab and under the full-screen Shorts player, where
  /// the sheet draws nothing.
  final bool hidden;

  @override
  State<PlayerSheet> createState() => _PlayerSheetState();
}

class _PlayerSheetState extends State<PlayerSheet>
    with SingleTickerProviderStateMixin {
  late final PlaybackController _playback;
  String? _lastCurrent;
  bool _hadVideo = false;

  /// The mini player's swipe-to-dismiss offset.
  final ValueNotifier<Offset> _dismiss = ValueNotifier(Offset.zero);
  late final AnimationController _dismissAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  Offset _dismissFrom = Offset.zero;
  Offset _dismissTo = Offset.zero;
  VoidCallback? _afterDismiss;

  /// Which way the current drag on the mini player is going.
  _MiniDrag? _miniDrag;

  /// True while a pull-down on the page's list is moving the sheet.
  bool _bodyDragging = false;

  late final Animation<double> _bodyFade = CurvedAnimation(
    parent: widget.controller.animation,
    curve: const Interval(0.6, 1.0),
  );
  late final Animation<double> _miniFade = Tween<double>(begin: 1, end: 0)
      .animate(
        CurvedAnimation(
          parent: widget.controller.animation,
          curve: const Interval(0.0, 0.25),
        ),
      );

  // Children built once per real change, so the AnimatedBuilder that moves
  // them never rebuilds their subtrees.
  String? _builtFor;
  Widget? _body;
  Widget? _video;
  Widget? _mini;

  @override
  void initState() {
    super.initState();
    _playback = context.read<PlaybackController>()..addListener(_onPlayback);
    _lastCurrent = _playback.current?.id;
    _hadVideo = _playback.current != null;
    _dismissAnim.addListener(() {
      _dismiss.value = Offset.lerp(
        _dismissFrom,
        _dismissTo,
        Curves.easeOutCubic.transform(_dismissAnim.value),
      )!;
    });
  }

  @override
  void dispose() {
    _playback.removeListener(_onPlayback);
    _playback.setMinimised(false);
    _dismissAnim.dispose();
    _dismiss.dispose();
    // The bubble is a handle back to something that is playing. Once the
    // player layer is gone there is nothing for it to be a handle to.
    FloatingPlayer.stop();
    super.dispose();
  }

  void _onPlayback() {
    final current = _playback.current;
    if (current?.id != _lastCurrent) {
      _lastCurrent = current?.id;
      widget.controller.playerMoved(current?.id);
      // A new video rebuilds the page under a held pull-down, and a list
      // disposed mid-drag sends no ScrollEnd — which was the only thing that
      // settled the sheet, so it sat half-collapsed and untouchable.
      if (_bodyDragging) {
        _bodyDragging = false;
        widget.controller.endDrag(0);
      }
    }
    if (current == null && _hadVideo) {
      _hadVideo = false;
      // Playback stopped, so the floating bubble is now a dead button
      // sitting above every other app. Deferred off the notification, since
      // it is a platform call.
      WidgetsBinding.instance.addPostFrameCallback((_) => FloatingPlayer.stop());
      // Nothing to show: the next video rises from the bottom again.
      if (widget.controller.requested == null) widget.controller.reset();
      _dismiss.value = Offset.zero;
    } else if (current != null) {
      _hadVideo = true;
    }
  }

  /// The X, and the end of a dismiss swipe.
  void _close() {
    widget.controller.reset();
    unawaited(_playback.stop());
    _dismiss.value = Offset.zero;
  }

  // ------------------------------------------------------- mini gestures

  void _miniVerticalUpdate(DragUpdateDetails d) {
    _miniDrag ??= d.delta.dy < 0 ? _MiniDrag.expand : _MiniDrag.dismissDown;
    if (_miniDrag == _MiniDrag.expand) {
      widget.controller.dragBy(d.delta.dy);
    } else {
      _dismiss.value = Offset(0, math.max(0, _dismiss.value.dy + d.delta.dy));
    }
  }

  void _miniVerticalEnd(DragEndDetails d) {
    final drag = _miniDrag;
    _miniDrag = null;
    final velocity = d.velocity.pixelsPerSecond.dy;
    if (drag == _MiniDrag.expand) {
      widget.controller.endDrag(velocity);
    } else if (drag == _MiniDrag.dismissDown) {
      // Started down, taken back to rest, then flung up: the finger's last
      // word was "up", which on the mini player means open — never close.
      if (velocity < 0 && _dismiss.value.dy == 0) {
        widget.controller.endDrag(velocity);
        return;
      }
      _endDismiss(
        Offset(0, _dismiss.value.dy),
        velocity: velocity,
        extent: PlayerSheet.miniHeight * 1.25,
        away: Offset(0, PlayerSheet.miniHeight + widget.bottomInset),
        bothWays: false,
      );
    }
  }

  void _miniHorizontalUpdate(DragUpdateDetails d) {
    _dismiss.value = Offset(_dismiss.value.dx + d.delta.dx, 0);
  }

  void _miniHorizontalEnd(DragEndDetails d, double width) {
    final dx = _dismiss.value.dx;
    _endDismiss(
      Offset(dx, 0),
      velocity: d.velocity.pixelsPerSecond.dx,
      extent: width,
      away: Offset(
        (dx == 0 ? d.velocity.pixelsPerSecond.dx : dx).sign * width,
        0,
      ),
    );
  }

  void _endDismiss(
    Offset offset, {
    required double velocity,
    required double extent,
    required Offset away,
    bool bothWays = true,
  }) {
    final along = offset.dx != 0 ? offset.dx : offset.dy;
    final dismissed = miniDismisses(
      offset: along,
      extent: extent,
      velocity: velocity,
      bothWays: bothWays,
    );
    _dismissFrom = _dismiss.value;
    _dismissTo = dismissed ? away : Offset.zero;
    _afterDismiss = dismissed ? _close : null;
    _dismissAnim.forward(from: 0).then((_) {
      final after = _afterDismiss;
      _afterDismiss = null;
      after?.call();
    });
  }

  // ------------------------------------------------------- body gestures

  /// Pulling the page down from its top minimises, as dragging the video does.
  bool _onBodyScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    final sheet = widget.controller;
    if (n is OverscrollNotification &&
        n.dragDetails != null &&
        n.overscroll < 0 &&
        (sheet.isExpanded || _bodyDragging)) {
      _bodyDragging = true;
      sheet.dragBy(-n.overscroll);
    } else if (n is ScrollEndNotification && _bodyDragging) {
      _bodyDragging = false;
      sheet.endDrag(n.dragDetails?.velocity.pixelsPerSecond.dy ?? 0);
    } else if (n is ScrollUpdateNotification && _bodyDragging) {
      // The finger reversed without lifting, so the list scrolls instead of
      // overscrolling. The sheet follows it back up rather than hanging
      // where the pull left it, and is settled once it is back open.
      final delta = n.scrollDelta ?? 0;
      if (n.dragDetails != null) {
        if (delta > 0) sheet.dragBy(-delta);
        if (sheet.animation.value >= 1) {
          _bodyDragging = false;
          sheet.endDrag(0);
        }
      } else {
        // Released into a fling: its ScrollEnd comes only when the fling
        // stops, and the sheet must not wait part-collapsed until then.
        _bodyDragging = false;
        sheet.endDrag(0);
      }
    }
    return false;
  }

  void _enterFullscreen(VideoBrief video) {
    final player = _playback.player;
    if (player == null || player.isFullScreen) return;
    if (_playback.current?.id != video.id) return;
    player.enterFullScreen();
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final current = context.select<PlaybackController, VideoBrief?>(
      (p) => p.current,
    );
    final onShorts = context.select<PlaybackController, bool>(
      (p) => p.onShortsSurface,
    );
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final sheet = widget.controller;
        final video = sheet.requested ?? (onShorts ? null : current);
        final shown = video != null && !widget.hidden;
        // The screen is kept awake only while the watch page is expanded (or
        // fullscreen), as YouTube does; the docked mini player lets it sleep.
        _playback.setMinimised(shown && !sheet.isExpanded);
        if (!shown) return const SizedBox.shrink();
        _prepareChildren(video);
        return LayoutBuilder(
          builder: (context, box) => _layout(context, box.biggest),
        );
      },
    );
  }

  void _prepareChildren(VideoBrief video) {
    if (_builtFor == video.id && _body != null) return;
    _builtFor = video.id;
    final sheet = widget.controller;
    _body = RepaintBoundary(
      child: FadeTransition(
        opacity: _bodyFade,
        child: Material(
          type: MaterialType.transparency,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onBodyScroll,
            child: WatchPage(key: ValueKey(video.id), video: video),
          ),
        ),
      ),
    );
    _video = _DragToMinimise(
      onUpdate: sheet.dragBy,
      onEnd: sheet.endDrag,
      onSwipeUp: () => _enterFullscreen(video),
      child: ValueListenableBuilder<bool>(
        valueListenable: PlayerSheetController.compact,
        // Nothing on the picture is pressable until the sheet has settled
        // open: in the mini player a tap means "open", not "show controls".
        builder: (context, compact, child) =>
            IgnorePointer(ignoring: compact, child: child),
        child: _PlayerSurface(video: video),
      ),
    );
    _mini = Material(
      type: MaterialType.transparency,
      child: FadeTransition(
        opacity: _miniFade,
        child: MiniPlayerBar(video: video, onClose: _close),
      ),
    );
  }

  Widget _layout(BuildContext context, Size size) {
    final sheet = widget.controller;
    final theme = Theme.of(context);
    final width = size.width;
    final height = size.height;
    final safeTop = MediaQuery.paddingOf(context).top;
    // 16:9 at full width — except on a phone held sideways outside
    // fullscreen, where a full-width 16:9 box is taller than the screen.
    final videoHeight = math.min(width * 9 / 16, height * 0.62);
    final expandedRect = Rect.fromLTWH(0, safeTop, width, videoHeight);
    final miniTop = height - widget.bottomInset - PlayerSheet.miniHeight;
    final miniRect = miniVideoRect(
      expanded: expandedRect,
      top: miniTop,
      height: PlayerSheet.miniHeight,
    );
    // The picture, not its box: held sideways the box has black margins,
    // which are shifted off-screen and clipped away as the sheet docks.
    final miniPicture = miniPictureWidth(
      expanded: expandedRect,
      height: PlayerSheet.miniHeight,
    );
    // The panel's top travels from the bar to the top of the screen, and a
    // drag moves it with the finger.
    sheet.travel = math.max(1, miniTop);

    final pageColor = theme.scaffoldBackgroundColor;
    final barColor = theme.brightness == Brightness.dark
        ? AppColors.darkElevated
        : AppColors.lightSurface;
    final bodyHeight = math.max(0.0, height - safeTop - videoHeight);

    final miniLayer = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: sheet.expand,
      onVerticalDragUpdate: _miniVerticalUpdate,
      onVerticalDragEnd: _miniVerticalEnd,
      onVerticalDragCancel: () => _miniDrag = null,
      onHorizontalDragUpdate: _miniHorizontalUpdate,
      onHorizontalDragEnd: (d) => _miniHorizontalEnd(d, width),
      child: Row(
        children: [
          // The live video sits here, drawn by the layer below.
          SizedBox(width: miniPicture),
          Expanded(child: _mini!),
        ],
      ),
    );

    return AnimatedBuilder(
      animation: Listenable.merge([sheet.animation, _dismiss]),
      builder: (context, _) {
        final t = sheet.animation.value;
        final shift = _dismiss.value;
        final panelTop = miniTop * (1 - t);
        final panelBottom = lerpDouble(
          miniTop + PlayerSheet.miniHeight,
          height,
          t,
        )!;
        final rect = sheetVideoRect(
          progress: t,
          expanded: expandedRect,
          mini: miniRect,
        ).shift(shift);
        final scale = videoHeight <= 0 ? 1.0 : rect.height / videoHeight;
        final inset = sheetPictureInset(progress: t, expanded: expandedRect);
        return Stack(
          children: [
            // The panel itself: the bar's surface when docked, the page's
            // background when open.
            Positioned(
              left: shift.dx,
              top: panelTop + shift.dy,
              width: width,
              height: math.max(0.0, panelBottom - panelTop),
              child: ColoredBox(color: Color.lerp(barColor, pageColor, t)!),
            ),
            Positioned(
              left: 0,
              top: panelTop + safeTop + videoHeight,
              width: width,
              height: bodyHeight,
              child: Visibility(
                // Off stage entirely once docked, so nothing below the bar
                // ticks, paints or takes a touch.
                visible: t > 0,
                maintainState: true,
                child: IgnorePointer(ignoring: t < 1, child: _body),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              width: width,
              height: videoHeight,
              child: Transform.translate(
                offset: rect.topLeft,
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.topLeft,
                  // Always present, so the video's place in the tree never
                  // changes; it clips nothing on a portrait phone.
                  child: ClipRect(
                    clipBehavior: inset > 0 ? Clip.hardEdge : Clip.none,
                    clipper: _SideInsetClipper(inset),
                    child: _video,
                  ),
                ),
              ),
            ),
            Positioned(
              left: shift.dx,
              top: panelTop + shift.dy,
              width: width,
              height: PlayerSheet.miniHeight,
              child: IgnorePointer(ignoring: t > 0.02, child: miniLayer),
            ),
          ],
        );
      },
    );
  }
}

enum _MiniDrag { expand, dismissDown }

/// Clips [inset] off the left and right of the video box (see
/// [sheetPictureInset]).
class _SideInsetClipper extends CustomClipper<Rect> {
  const _SideInsetClipper(this.inset);

  final double inset;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(
    inset.clamp(0.0, size.width / 2),
    0,
    size.width - inset.clamp(0.0, size.width / 2),
    size.height,
  );

  @override
  bool shouldReclip(_SideInsetClipper oldClipper) => oldClipper.inset != inset;
}

/// The video surface, or a placeholder while streams resolve. Laid out at
/// the expanded size always; the sheet scales it down for the mini player.
class _PlayerSurface extends StatelessWidget {
  const _PlayerSurface({required this.video});

  final VideoBrief video;

  @override
  Widget build(BuildContext context) {
    final playback = context.watch<PlaybackController>();
    final player = playback.player;
    final showPlayer =
        playback.current?.id == video.id && !playback.onShortsSurface;

    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Builder(
            builder: (context) {
              if (playback.error != null && showPlayer) {
                return ValueListenableBuilder<bool>(
                  valueListenable: PlayerSheetController.compact,
                  builder: (context, compact, _) => compact
                      ? _Thumbnail(url: video.thumbUrl, spinner: false)
                      : _PlaybackError(
                          message: playback.error!,
                          onRetry: playback.reloadCurrent,
                        ),
                );
              }
              if (kIsWeb) return _PreviewSurface(video: video);
              final loading = playback.isLoading && !playback.isRebuilding;
              if (player == null || !showPlayer || loading) {
                // The thumbnail under the spinner, as YouTube does, rather
                // than a black box: the page reads as the video arriving
                // instead of as something failing to load.
                return _Thumbnail(url: video.thumbUrl, spinner: true);
              }
              // Always mounted, including in audio mode.
              //
              // Returning the artwork *instead* of this widget left iOS with
              // no render surface to attach to, so the native player failed
              // every audio-only load with "Failed to load video: unknown
              // error". The artwork is painted by the controls, never in place
              // of the player.
              //
              // Nothing else is stacked here. The gestures, the stats panel
              // and the end screen are drawn by VideoControls, which the
              // plugin builds inline and in its fullscreen route alike.
              return BetterPlayer(key: playback.playerKey, controller: player);
            },
          ),
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.url, required this.spinner});

  final String url;
  final bool spinner;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (url.isNotEmpty)
          CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            fadeInDuration: Duration.zero,
            errorWidget: (_, _, _) => const SizedBox.shrink(),
          ),
        const ColoredBox(color: Color(0x55000000)),
        if (spinner)
          const Center(
            child: CircularProgressIndicator(color: AppColors.brand),
          ),
      ],
    );
  }
}

/// Makes the video draggable to minimise, without stealing the seek bar.
///
/// A plain vertical-drag detector around the player competes with the seek bar
/// for every touch, and the sheet usually wins — which is what made the seek bar
/// undraggable. This one refuses to start a drag that begins in the bottom
/// strip, so the two never contend.
class _DragToMinimise extends StatefulWidget {
  const _DragToMinimise({
    required this.child,
    required this.onUpdate,
    required this.onEnd,
    required this.onSwipeUp,
  });

  final Widget child;

  /// The finger's vertical travel since the last update, in SCREEN pixels.
  final void Function(double dy) onUpdate;

  /// The release velocity, in screen pixels per second, down positive.
  final void Function(double velocity) onEnd;

  /// An upward swipe past 80dp or 600dp/s: enter fullscreen, as on YouTube.
  /// Handled here, on the same recogniser as minimising, rather than by a
  /// second vertical-drag detector inside the player — two would fight over
  /// every vertical drag and the inner one would win, killing minimise.
  final VoidCallback onSwipeUp;

  @override
  State<_DragToMinimise> createState() => _DragToMinimiseState();
}

class _DragToMinimiseState extends State<_DragToMinimise> {
  /// Height at the bottom reserved for the seek bar and its controls.
  static const _controlsZone = 64.0;

  /// False when the gesture began over the seek bar, in which case every
  /// update is ignored until the finger lifts.
  bool _accepting = false;

  /// Net vertical travel of the current drag; negative is upwards. In the
  /// detector's local space, which is what the fullscreen rule was tuned on.
  double _dy = 0;

  /// The same travel as the screen saw it, and the last global y. This
  /// detector sits inside the sheet's `Transform.scale`, so local deltas are
  /// 1/scale too big whenever a drag starts mid-transition; the sheet is
  /// moved by the global ones instead, which follow the finger exactly.
  double _screenDy = 0;
  double? _lastGlobalY;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        // translucent, so taps still reach the player's own controls.
        behavior: HitTestBehavior.translucent,
        onVerticalDragDown: (d) {
          _accepting = d.localPosition.dy < box.maxHeight - _controlsZone;
          _dy = 0;
          _screenDy = 0;
          _lastGlobalY = null;
        },
        // From the start, not the down: the touch slop travelled before the
        // drag was accepted is not part of it, as local deltas exclude it.
        onVerticalDragStart: (d) => _lastGlobalY = d.globalPosition.dy,
        onVerticalDragUpdate: (d) {
          if (!_accepting) return;
          final y = d.globalPosition.dy;
          final screenDelta = y - (_lastGlobalY ?? y);
          _lastGlobalY = y;
          _dy += d.delta.dy;
          _screenDy += screenDelta;
          widget.onUpdate(screenDelta);
        },
        onVerticalDragEnd: (d) {
          if (_accepting) {
            final velocity = d.velocity.pixelsPerSecond.dy;
            widget.onEnd(
              screenDragVelocity(
                localVelocity: velocity,
                screenTravel: _screenDy,
                localTravel: _dy,
              ),
            );
            if (swipeEntersFullscreen(_dy, velocity)) {
              widget.onSwipeUp();
            }
          }
          _accepting = false;
        },
        onVerticalDragCancel: () => _accepting = false,
        child: widget.child,
      ),
    );
  }
}

/// Stand-in for the video surface in the browser preview, where the native
/// player plugin does not exist.
class _PreviewSurface extends StatelessWidget {
  const _PreviewSurface({required this.video});

  final VideoBrief video;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.network(
          video.thumbUrl,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => const ColoredBox(color: Colors.black),
        ),
        const ColoredBox(color: Colors.black54),
        const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.play_circle_outline, size: 48, color: Colors.white70),
              SizedBox(height: 8),
              Text(
                'Playback is not available in the browser preview',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Text(
                'Video plays on iOS and Android',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PlaybackError extends StatelessWidget {
  const _PlaybackError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.cloud_off_outlined, color: Colors.white54, size: 30),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 10),
        TextButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    ),
  );
}
