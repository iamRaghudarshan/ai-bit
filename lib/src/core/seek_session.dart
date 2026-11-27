/// YouTube's double-tap seek, as pure state.
///
/// A double tap on one side of the video starts a *session*. Until it lapses,
/// every further tap on that side — single taps included — adds another step,
/// and the label counts up: "+10", "+20", "+30". The target is worked out
/// from where the session started rather than from the player's current
/// position, because the player reports a new position a frame or two after a
/// seek, and three quick taps read against a stale position would land on
/// +10 or +20 instead of +30.
library;

class SeekSession {
  SeekSession({
    this.window = const Duration(milliseconds: 700),
    this.stepSeconds = 10,
  });

  /// How long after the last tap the session stays open.
  final Duration window;
  final int stepSeconds;

  /// -1 rewind, 1 forward, 0 no session.
  int _side = 0;
  int _steps = 0;
  DateTime? _last;
  Duration _origin = Duration.zero;

  int get side => _side;

  /// Signed seconds accumulated in this session: -30 after three left taps.
  int get totalSeconds => _side * _steps * stepSeconds;

  /// "+20" / "-30", the label YouTube draws in the ripple.
  String get label => totalSeconds >= 0 ? '+$totalSeconds' : '$totalSeconds';

  bool isActive(DateTime now) =>
      _side != 0 && _last != null && now.difference(_last!) < window;

  /// Records a tap on [side] (-1 or 1) at [now], with the player at
  /// [position]. Returns where to seek, clamped to `0..duration` when the
  /// duration is known.
  ///
  /// A tap on the other side, or after the session has lapsed, starts a new
  /// session from [position] — so tapping right twice then left once is +20
  /// then a fresh -10, as on YouTube.
  Duration tap(
    int side, {
    required DateTime now,
    required Duration position,
    Duration duration = Duration.zero,
  }) {
    assert(side == -1 || side == 1);
    if (!isActive(now) || side != _side) {
      _side = side;
      _steps = 0;
      _origin = position;
    }
    _steps++;
    _last = now;
    var target = _origin + Duration(seconds: totalSeconds);
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    return target;
  }

  void reset() {
    _side = 0;
    _steps = 0;
    _last = null;
  }
}

/// Which side of the surface a tap at [dx] falls on, for a surface [width]
/// wide: -1 left, 1 right, 0 the middle band. The middle is where the
/// play/pause button lives, so a double tap there seeks nowhere — YouTube
/// leaves it inert too.
int seekSideFor(double dx, double width, {double band = 0.35}) {
  if (width <= 0) return 0;
  final f = dx / width;
  if (f < band) return -1;
  if (f > 1 - band) return 1;
  return 0;
}

/// Whether a fullscreen vertical swipe should leave fullscreen: far enough,
/// or fast enough, downwards.
bool swipeExitsFullscreen(double dy, double velocityY) =>
    dy > 80 || velocityY > 600;

/// Whether an inline upward swipe on the video should enter fullscreen.
bool swipeEntersFullscreen(double dy, double velocityY) =>
    dy < -80 || velocityY < -600;

/// What a pinch should do to the fit: `true` fill (cover), `false` fit
/// (contain), null leave it.
bool? pinchFill(double scale) {
  if (scale > 1.08) return true;
  if (scale < 0.92) return false;
  return null;
}
