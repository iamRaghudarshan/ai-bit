import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Rect, lerpDouble;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/physics.dart';

import '../data/models.dart';

/// The one continuous player, as a sheet: 0 is the mini player docked above
/// the navigation bar, 1 is the full watch page. See `PlayerSheet`.
///
/// Created by `RootShell` (it needs the shell's ticker) and reachable through
/// [instance] from anywhere — incoming links, root-level bottom sheets and the
/// player's own controls all run outside the shell's subtree, so a provider
/// lookup would miss them.
class PlayerSheetController extends ChangeNotifier {
  PlayerSheetController({required TickerProvider vsync})
    : animation = AnimationController(vsync: vsync) {
    animation.addListener(_onTick);
    instance = this;
  }

  /// The live controller, or null before the shell is built (tests).
  static PlayerSheetController? instance;

  /// True unless the sheet is fully expanded and settled there. The video
  /// controls read this and draw nothing while it is true, so the mini player
  /// and every frame of a drag show the bare picture, as YouTube's do.
  static final ValueNotifier<bool> compact = ValueNotifier(true);

  /// Release spring: quick, a touch of give, no visible wobble.
  static const spring = SpringDescription(mass: 1, stiffness: 500, damping: 30);

  /// How long a programmatic expand (a tap on a video) takes.
  static const expandDuration = Duration(milliseconds: 300);

  /// 0 = mini, 1 = expanded. Drives every moving part of the sheet and the
  /// navigation bar's slide; nothing rebuilds a page per frame.
  final AnimationController animation;

  /// Pixels of finger travel that take the sheet from one end to the other,
  /// set by the sheet's layout. A drag moves it 1:1 with the finger.
  double travel = 600;

  bool _expanded = false;

  /// Where the sheet is going or has settled: expanded or mini. Changes only
  /// on a decision (open, release, back), never per drag frame, so listeners
  /// — the shell's back handling and snackbar spacing — rebuild rarely.
  bool get isExpanded => _expanded;

  VideoBrief? _requested;
  String? _currentAtRequest;

  /// The video most recently opened, until the player has actually moved to
  /// it. `PlaybackController.play` can wait behind an older load, and the
  /// sheet must show what was tapped at once rather than the previous video.
  VideoBrief? get requested => _requested;

  final List<Completer<void>> _collapseWaiters = [];

  /// Opens [video] in the expanded sheet. The caller starts playback; this
  /// only presents it. Completes when the sheet next collapses or closes,
  /// which is what callers that refresh history-dependent lists wait for.
  ///
  /// Call it BEFORE starting playback: `PlaybackController.play` moves its
  /// current video and notifies synchronously, and a request made after that
  /// notification was never seen as fulfilled — it pinned the sheet to the
  /// tapped video until the player happened to move off the old one.
  Future<void> open(VideoBrief video, {String? currentId}) {
    // Reopening what is already playing asks the player for nothing, so
    // there is nothing for a request to wait on.
    _requested = currentId == video.id ? null : video;
    _currentAtRequest = currentId;
    notifyListeners();
    expand();
    final waiter = Completer<void>();
    _collapseWaiters.add(waiter);
    return waiter.future;
  }

  /// Called by the sheet whenever the player's current video changes. Once
  /// the player has moved off what was current at the request, the request is
  /// either fulfilled or superseded, and the player is the truth again.
  void playerMoved(String? currentId) {
    final requested = _requested;
    if (requested == null) return;
    if (!requestSettled(
      requestedId: requested.id,
      currentAtRequest: _currentAtRequest,
      currentId: currentId,
    )) {
      return;
    }
    _requested = null;
    notifyListeners();
  }

  /// Expands with the tap-to-open curve.
  void expand() {
    _setExpanded(true);
    if (animation.value >= 1) {
      _onTick();
      return;
    }
    animation.animateTo(
      1,
      duration: expandDuration * (1 - animation.value).clamp(0.3, 1.0),
      curve: Curves.easeOutCubic,
    );
  }

  /// Settles to the mini player.
  void collapse({double velocity = 0}) => _settle(false, velocity: velocity);

  /// Back to nothing: no video, no sheet. Used when playback stops.
  void reset() {
    animation.stop();
    animation.value = 0;
    // Clearing the request alone changes what the sheet shows, so it has to
    // notify even when the sheet was already docked.
    final notify = _requested != null && !_expanded;
    _requested = null;
    _currentAtRequest = null;
    _setExpanded(false);
    if (notify) notifyListeners();
  }

  /// Moves the sheet by a finger's vertical travel; down is positive.
  void dragBy(double dy) {
    if (travel <= 0) return;
    if (animation.isAnimating) animation.stop();
    animation.value = (animation.value - dy / travel).clamp(0.0, 1.0);
  }

  /// Ends a drag, settling in the direction [settlesExpanded] picks.
  /// [velocity] is the finger's, in pixels per second, down positive.
  void endDrag(double velocity) {
    _settle(
      settlesExpanded(progress: animation.value, velocity: velocity),
      velocity: velocity,
    );
  }

  void _settle(bool expanded, {double velocity = 0}) {
    _setExpanded(expanded);
    final target = expanded ? 1.0 : 0.0;
    if (animation.value == target) {
      _onTick();
      return;
    }
    // Finger velocity in sheet units per second, up positive.
    final unitsPerSecond = travel > 0 ? -velocity / travel : 0.0;
    animation
        .animateWith(
          SpringSimulation(spring, animation.value, target, unitsPerSecond),
        )
        // A spring ends within its tolerance, not on the target; land it
        // there exactly so "settled" tests are exact. Never runs when a newer
        // animation cancelled this one.
        .then((_) => animation.value = target);
  }

  void _setExpanded(bool expanded) {
    if (!expanded) {
      for (final waiter in _collapseWaiters) {
        if (!waiter.isCompleted) waiter.complete();
      }
      _collapseWaiters.clear();
    }
    if (_expanded == expanded) return;
    _expanded = expanded;
    notifyListeners();
    _onTick();
  }

  void _onTick() {
    compact.value = !(_expanded && animation.value >= 1);
  }

  @override
  void dispose() {
    if (identical(instance, this)) instance = null;
    for (final waiter in _collapseWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    animation.dispose();
    compact.value = true;
    super.dispose();
  }
}

// ---------------------------------------------------------------- pure rules

/// A finger moving faster than this decides the direction on release.
const sheetFlingVelocity = 600.0;

/// A sideways or downward swipe on the mini player faster than this dismisses.
const miniDismissVelocity = 800.0;

/// Whether a released drag settles expanded.
///
/// [velocity] is the finger's in pixels per second, down positive. A fling
/// decides by its direction; otherwise the sheet goes to the nearer end.
bool settlesExpanded({required double progress, required double velocity}) {
  if (velocity.abs() > sheetFlingVelocity) return velocity < 0;
  return progress >= 0.5;
}

/// Whether the player's current video, now [currentId], settles an open
/// request for [requestedId] made while [currentAtRequest] was current.
///
/// Settled once the player reaches the requested video (fulfilled) or moves
/// anywhere other than where it was at the request (superseded — another
/// video, or nothing at all). Only "still on the old video" keeps it.
bool requestSettled({
  required String requestedId,
  required String? currentAtRequest,
  required String? currentId,
}) =>
    currentId == requestedId || currentId != currentAtRequest;

/// Whether a swipe on the mini player has gone far or fast enough to close it.
///
/// [offset] is how far it has been dragged along the swipe's axis, [extent]
/// the distance that counts as "far" before [fraction] is applied (the bar's
/// width sideways), [velocity] the release speed along the same axis. A fling
/// back towards the rest position never dismisses, however fast.
///
/// [bothWays] false is the downward swipe, which may only dismiss downwards
/// (positive): a drag that started down, was taken back to rest and then
/// flung up is not a dismissal — it had been closing the player and losing
/// the queue.
bool miniDismisses({
  required double offset,
  required double extent,
  required double velocity,
  double fraction = 0.4,
  bool bothWays = true,
}) {
  if (offset == 0 && velocity == 0) return false;
  if (!bothWays && offset <= 0 && velocity <= 0) return false;
  final towardsRest = offset != 0 && velocity != 0 && offset.sign != velocity.sign;
  if (towardsRest) return false;
  if (velocity.abs() > miniDismissVelocity) return true;
  return offset.abs() > extent * fraction;
}

/// The video's on-screen rect at [progress]: [mini] at 0, [expanded] at 1.
///
/// [mini] is built with the expanded rect's aspect ratio (see
/// [miniVideoRect]), so every rect along the way has it too and the picture
/// scales uniformly rather than squashing.
Rect sheetVideoRect({
  required double progress,
  required Rect expanded,
  required Rect mini,
}) {
  final t = progress.clamp(0.0, 1.0);
  return Rect.fromLTWH(
    lerpDouble(mini.left, expanded.left, t)!,
    lerpDouble(mini.top, expanded.top, t)!,
    lerpDouble(mini.width, expanded.width, t)!,
    lerpDouble(mini.height, expanded.height, t)!,
  );
}

/// Where the video BOX sits in the mini player: [height] tall, top at [top],
/// scaled uniformly from [expanded].
///
/// The box is not always the picture. Held sideways (or on a wide window)
/// the expanded box is capped below 16:9 and the [pictureAspect] picture is
/// centred in it between black margins, so a box docked at x=0 reserved a
/// wide black strip — 229dp for a 114dp picture at 800x360. The box is
/// therefore shifted left by its scaled margin, so the PICTURE's left edge
/// lands at x=0; [miniPictureWidth] is what the bar reserves and
/// [sheetPictureInset] what is clipped off each side.
Rect miniVideoRect({
  required Rect expanded,
  required double top,
  required double height,
  double pictureAspect = 16 / 9,
}) {
  final scale = expanded.height <= 0 ? 0.0 : height / expanded.height;
  final left = _pictureMargin(expanded, pictureAspect) * scale;
  return Rect.fromLTWH(-left, top, expanded.width * scale, height);
}

/// How wide the picture is in the mini player: the space the bar reserves
/// for it before the title.
double miniPictureWidth({
  required Rect expanded,
  required double height,
  double pictureAspect = 16 / 9,
}) {
  final scale = expanded.height <= 0 ? 0.0 : height / expanded.height;
  return (expanded.width - 2 * _pictureMargin(expanded, pictureAspect)) * scale;
}

/// The black margin, in the expanded box's own (unscaled) coordinates, to
/// clip off each side of the video at [progress]: all of it docked, none of
/// it expanded, so the mini player shows only the picture and the watch page
/// is unchanged.
double sheetPictureInset({
  required double progress,
  required Rect expanded,
  double pictureAspect = 16 / 9,
}) =>
    _pictureMargin(expanded, pictureAspect) * (1 - progress.clamp(0.0, 1.0));

double _pictureMargin(Rect box, double aspect) {
  if (box.height <= 0 || aspect <= 0) return 0;
  final pictureWidth = math.min(box.width, box.height * aspect);
  return (box.width - pictureWidth) / 2;
}

/// A drag's release velocity as the SCREEN saw it.
///
/// The video's drag detector sits inside the sheet's `Transform.scale`, and
/// a recogniser reports deltas and velocity in its local space — so a drag
/// begun mid-transition, at scale s, moved the sheet 1/s px per finger px
/// and released with 1/s the speed. [screenTravel] / [localTravel] over the
/// whole drag is that scale, measured rather than assumed; it is clamped to
/// (0, 1] because the sheet never draws the video larger than expanded.
double screenDragVelocity({
  required double localVelocity,
  required double screenTravel,
  required double localTravel,
}) {
  if (localTravel.abs() < 1) return localVelocity;
  final ratio = (screenTravel / localTravel).clamp(0.0, 1.0);
  return localVelocity * ratio;
}

/// What system back does, in order of precedence.
enum SheetBackAction {
  /// Leave fullscreen.
  exitFullscreen,

  /// Collapse the expanded sheet to the mini player; nothing is popped.
  collapse,

  /// Pop the top content page (channel, playlist, settings...).
  popContent,

  /// Nothing of ours to undo: the platform's default (leave the app).
  system,
}

SheetBackAction sheetBackAction({
  required bool fullscreen,
  required bool expanded,
  required bool contentCanPop,
}) {
  if (fullscreen) return SheetBackAction.exitFullscreen;
  if (expanded) return SheetBackAction.collapse;
  if (contentCanPop) return SheetBackAction.popContent;
  return SheetBackAction.system;
}
