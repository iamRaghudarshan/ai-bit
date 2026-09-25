import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/db.dart';
import '../../data/settings.dart';

/// Counts the feed cards the user has actually looked at.
///
/// This is a ranking input, not analytics. `recommender.dart` demotes a video
/// that has been put in front of someone repeatedly and never opened, which is
/// one of the features the YouTube recommender paper singles out and is what
/// makes a pull-to-refresh return something new rather than the same rows in a
/// different order.
///
/// **An impression has to mean "was on screen".** The first version of this
/// recorded every video in the fetched feed the moment it loaded — around a
/// hundred and twenty rows, of which a scrolling user sees perhaps ten. That
/// quietly penalised good videos for never having been reached, which is the
/// exact opposite of what the feature is for: the ranker would learn to bury
/// whatever it had ranked highly enough to fetch. So the count now comes from
/// the feed's visibility detector, and a card has to be genuinely on screen —
/// see [seenFraction] — before it counts.
///
/// Writes are batched. A scroll produces a steady trickle of newly seen cards,
/// and a database write per card would put SQLite on the critical path of a
/// fling.
class FeedImpressionRecorder {
  FeedImpressionRecorder({
    required AppDatabase database,
    required SettingsService settings,
  })  : _db = database,
        // Named _config to match the convention the services use, where a
        // private named initialising formal is not legal Dart.
        _config = settings;

  final AppDatabase _db;
  final SettingsService _config;

  /// How much of a card must be on screen to count as shown.
  ///
  /// Half. A card clipped by the top or bottom edge mid-scroll has not really
  /// been offered to anyone, and counting it would drift back towards the
  /// "everything that was fetched" behaviour this class exists to replace.
  static const seenFraction = 0.5;

  /// How long to let newly seen ids collect before writing them.
  static const _flushAfter = Duration(seconds: 3);

  final _pending = <String>{};

  /// Ids already written in this session, so a card scrolled past, back to and
  /// past again is one impression rather than three. Scrolling up and down a
  /// feed is not the user being offered the same video repeatedly.
  final _written = <String>{};

  Timer? _timer;
  bool _disposed = false;

  /// Whether counting is allowed at all right now.
  ///
  /// Incognito is excluded for the same reason it skips the search history:
  /// this table exists only to shape recommendations, and a mode that promises
  /// not to record what you watched must not quietly record what you were
  /// shown. Kids mode is excluded because its feed is a curated topic list
  /// rather than a recommendation — nothing there should be demoted for having
  /// appeared.
  bool get _allowed => !_config.incognito && !_config.kidsMode;

  /// Notes that [videoId] was on screen. Cheap enough for a scroll callback.
  void markSeen(String videoId) {
    if (_disposed || videoId.isEmpty || !_allowed) return;
    if (_written.contains(videoId)) return;
    if (!_pending.add(videoId)) return;
    _timer ??= Timer(_flushAfter, flush);
  }

  /// Writes whatever has been collected. Safe to call when there is nothing.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return;
    final batch = _pending.toList();
    _pending.clear();
    _written.addAll(batch);
    unawaited(
      _db.recordImpressions(batch).catchError((Object e) {
        // Logged rather than swallowed: impressions that silently stop being
        // written leave the feed repeating itself with nothing to say why,
        // which is precisely the dead feature a bare catch has hidden in this
        // codebase before.
        debugPrint('AI BIT: feed impressions not recorded - $e');
      }),
    );
  }

  /// Flushes and stops. The pending batch is written rather than dropped —
  /// leaving Home is not a reason to forget what was on screen a second ago.
  void dispose() {
    flush();
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
