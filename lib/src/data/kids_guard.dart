import 'package:flutter/foundation.dart';

import 'db.dart';
import 'settings.dart';

/// Tracks how long Kids mode has been watched today and says when the daily
/// allowance is spent.
///
/// Takes its database and settings by injection, the way DownloadManager and
/// PlaybackController do, so a test can hand it a throwaway database and so
/// there is still exactly one AppDatabase for the whole app.
class KidsGuard extends ChangeNotifier {
  KidsGuard({required AppDatabase database, required SettingsService settings})
    : _db = database,
      // Named _config for the same reason PlaybackController's copy is: the
      // field holds the live settings object, and `_settings = settings`
      // trips prefer_initializing_formals on a named parameter.
      _config = settings;

  final AppDatabase _db;
  final SettingsService _config;

  int _day = daysSinceEpoch(DateTime.now());
  int _secondsUsed = 0;

  /// The day key used by the `kids_usage` table: whole days since the epoch,
  /// counted on the user's **local** calendar.
  ///
  /// The local y/m/d is re-read as a UTC instant before dividing, so the
  /// division lands on the day the user would name. Dividing the raw local
  /// timestamp instead would roll the day over at local midnight *minus the
  /// UTC offset* — in IST (+5:30) a child's allowance would reset at 5:30am
  /// and every evening would be charged to the following day. Pure, and worth
  /// a test, because a wrong answer here is invisible until midnight.
  static int daysSinceEpoch(DateTime when) {
    final local = when.toLocal();
    return DateTime.utc(
          local.year,
          local.month,
          local.day,
        ).millisecondsSinceEpoch ~/
        Duration.millisecondsPerDay;
  }

  /// Reads today's total from the database. Call once at startup.
  Future<void> load() async {
    _day = daysSinceEpoch(DateTime.now());
    _secondsUsed = await _db.kidsSecondsOn(_day);
    notifyListeners();
  }

  /// Seconds of Kids-mode playback recorded for the current local day.
  int get secondsUsedToday => _secondsUsed;

  /// The configured allowance in seconds; 0 means unlimited.
  int get limitSeconds => _config.kidsDailyLimitMinutes * 60;

  /// False when the allowance is unlimited, so a caller can skip the countdown
  /// entirely instead of interpreting [remainingSeconds].
  bool get hasLimit => limitSeconds > 0;

  /// Seconds left today, floored at 0 — or -1 when there is no limit, which is
  /// deliberately not a large number: a UI that formats it as a duration shows
  /// something obviously wrong rather than a plausible-looking countdown that
  /// never ends. Check [hasLimit] first.
  int get remainingSeconds {
    if (!hasLimit) return -1;
    final left = limitSeconds - _secondsUsed;
    return left < 0 ? 0 : left;
  }

  /// The setting is read live rather than cached, so raising the limit from
  /// the settings screen lifts the block immediately.
  ///
  /// kidsDailyLimitMinutes == 0 means unlimited, so this is always false then.
  bool get limitReached => hasLimit && _secondsUsed >= limitSeconds;

  /// Adds watched time. Called from a ticker while a video plays, which is why
  /// the database write upserts one row per day instead of appending.
  Future<void> addWatched(int seconds) async {
    if (seconds <= 0) return;
    final today = daysSinceEpoch(DateTime.now());
    if (today != _day) {
      // A session running past midnight must start spending the new day's
      // allowance, not keep charging yesterday's row — otherwise a child
      // watching at 11:58pm stays blocked into the next morning until the app
      // is restarted.
      _day = today;
      _secondsUsed = await _db.kidsSecondsOn(today);
    }
    await _db.addKidsSeconds(_day, seconds);
    _secondsUsed += seconds;
    notifyListeners();
  }
}
