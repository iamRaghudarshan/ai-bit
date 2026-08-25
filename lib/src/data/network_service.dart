import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Live view of the device's network transport, so the data-saver settings can
/// tell "on Wi-Fi" from "burning the user's cellular allowance".
///
/// A [ChangeNotifier] rather than a raw stream because the whole app reads it
/// through a provider; [start] subscribes and [dispose] unsubscribes, and both
/// are required — a connectivity subscription left running after the notifier
/// is gone keeps firing into a disposed object.
class NetworkService extends ChangeNotifier {
  NetworkService([Connectivity? connectivity])
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;
  StreamSubscription<List<ConnectivityResult>>? _sub;

  bool _isMobile = false;
  bool _isOnline = true;

  /// True only when the active data path is cellular — the condition the
  /// "mobile data saver" and "audio only on mobile data" settings key off.
  ///
  /// Wi-Fi, Ethernet, Bluetooth tethering and VPN are all not-mobile.
  bool get isMobile => _isMobile;

  /// False only for a reported total loss of connectivity. Defaults to true so
  /// nothing is blocked before [start] has seeded a real value.
  bool get isOnline => _isOnline;

  /// Seeds the current transport and subscribes to changes.
  Future<void> start() async {
    // The browser preview has no metered network to protect and Chrome's
    // NetworkInformation API is unreliable/absent, so web stays on the
    // defaults (not mobile, online) instead of guessing.
    if (kIsWeb) return;
    try {
      _apply(await _connectivity.checkConnectivity());
      _sub = _connectivity.onConnectivityChanged.listen(_apply);
    } catch (_) {
      // Connectivity is an optimisation, never a gate: if the platform channel
      // is missing (desktop, a test host) the defaults above mean unrestricted
      // playback rather than an app that refuses to load anything.
      _isMobile = false;
      _isOnline = true;
    }
  }

  /// connectivity_plus 7.x reports a *list* — a phone can hold Wi-Fi and
  /// cellular at once, and `satellite` arrives alongside `mobile`. The list is
  /// documented as never empty, and `none` only ever appears alone.
  void _apply(List<ConnectivityResult> results) {
    final online = results.any((r) => r != ConnectivityResult.none);
    // Wi-Fi and Ethernet win the route when both are up, so a phone with both
    // radios on is not spending mobile data and must not be throttled as if
    // it were.
    final unmetered = results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
    final mobile = !unmetered &&
        (results.contains(ConnectivityResult.mobile) ||
            results.contains(ConnectivityResult.satellite));

    if (mobile == _isMobile && online == _isOnline) return;
    _isMobile = mobile;
    _isOnline = online;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }
}
