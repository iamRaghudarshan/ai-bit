import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';

/// Live view of the battery, so the battery-saver setting can step playback
/// down before the phone dies rather than after.
///
/// A [ChangeNotifier] behind a provider, like `NetworkService`: [start]
/// subscribes and [dispose] must cancel, or the state stream and the poll timer
/// outlive the notifier and fire into a disposed object.
class BatteryService extends ChangeNotifier {
  BatteryService([Battery? battery]) : _battery = battery ?? Battery();

  final Battery _battery;
  StreamSubscription<BatteryState>? _sub;
  Timer? _poll;

  int _level = 100;
  bool _charging = false;

  /// Charge percentage, 0–100. Defaults to 100 so nothing is throttled before
  /// [start] has read a real value.
  int get level => _level;

  /// True below the 20% mark while running on the battery. Charging is excluded
  /// deliberately — a phone on a charger at 15% is filling up, and degrading
  /// playback there would be pure annoyance.
  bool get isLow => _level <= 20 && !_charging;

  /// battery_plus exposes a stream for the charging *state* but not for the
  /// level, so the level is re-read on every state change and polled in
  /// between. A percent takes minutes of real use to move, so a minute is a
  /// generous interval, not a busy loop.
  static const _pollInterval = Duration(minutes: 1);

  /// Seeds level and charging state, then subscribes.
  Future<void> start() async {
    // The Battery Status API is removed or permission-gated in current
    // browsers, and the preview target has no playback to protect anyway, so
    // web keeps the defaults (full, not low).
    if (kIsWeb) return;
    try {
      _apply(await _battery.batteryLevel, await _battery.batteryState);
      _sub = _battery.onBatteryStateChanged.listen((state) async {
        _apply(await _battery.batteryLevel, state);
      });
      _poll = Timer.periodic(_pollInterval, (_) => _refreshLevel());
    } catch (_) {
      // Missing platform channel (desktop, a test host) or a denied read. The
      // defaults above mean "full battery", i.e. no saver kicks in — a battery
      // reading is an optimisation and must never stop playback.
      _level = 100;
      _charging = false;
    }
  }

  Future<void> _refreshLevel() async {
    try {
      _apply(await _battery.batteryLevel, null);
    } catch (_) {
      // A single failed poll is not worth surfacing; the last known level
      // stands and the next tick tries again.
    }
  }

  /// [state] is null when only the level was re-read, which leaves the charging
  /// flag as the stream last reported it.
  void _apply(int level, BatteryState? state) {
    final charging = state == null
        ? _charging
        : state == BatteryState.charging || state == BatteryState.full;

    if (level == _level && charging == _charging) return;
    _level = level;
    _charging = charging;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _poll?.cancel();
    _poll = null;
    super.dispose();
  }
}
