import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// Guards the app behind a PIN and, optionally, the device's biometrics.
///
/// The PIN is only ever held as a sha256 digest — SettingsService keeps it in
/// appLockPinHash — because SharedPreferences is a plain XML file that a
/// rooted device, or an adb backup, can read, and people reuse PINs. This is
/// a nuisance lock for a sideloaded personal app, not a security boundary:
/// anyone who can read that file can also clear it.
class AppLockService {
  const AppLockService();

  /// sha256 hex of [pin]. Pure, so it is unit-testable without a device.
  static String hashPin(String pin) =>
      sha256.convert(utf8.encode(pin)).toString();

  /// True when [pin] hashes to [hash].
  static bool verify(String pin, String hash) {
    // An unset PIN is stored as an empty hash, and hashing the empty string
    // still produces a valid digest — so without this guard a caller that
    // enabled the lock before choosing a PIN could be let in by typing
    // nothing. An unset PIN must never validate; the caller is expected to
    // send the user through PIN setup instead.
    if (hash.isEmpty) return false;
    final candidate = hashPin(pin);
    if (candidate.length != hash.length) return false;
    // Compare every character rather than returning at the first mismatch, so
    // how long the check takes does not report how much of the digest was
    // right. Cheap here (64 chars) and it keeps the obvious attack away.
    var diff = 0;
    for (var i = 0; i < candidate.length; i++) {
      diff |= candidate.codeUnitAt(i) ^ hash.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Shows the system fingerprint / Face ID prompt.
  ///
  /// Returns false — never throws — for every unhappy path: cancelled prompt,
  /// no sensor, nothing enrolled, plugin missing (the web preview target has
  /// no local_auth implementation at all). The caller's only sensible reaction
  /// to any of them is the same one, which is to fall back to the PIN, so
  /// collapsing them into a plain false keeps that decision in one place
  /// instead of spreading platform error codes through the UI.
  Future<bool> authenticateBiometric() async {
    if (kIsWeb) return false;
    final auth = LocalAuthentication();
    try {
      // isDeviceSupported covers "no sensor and no device credential"; without
      // it local_auth throws instead of simply declining on such a device.
      if (!await auth.isDeviceSupported()) return false;
      return await auth.authenticate(
        localizedReason: 'Unlock AI BIT',
        // The prompt survives the app being backgrounded — some Android skins
        // background the app to show the fingerprint sheet, which would
        // otherwise come back as a failure the user never caused.
        persistAcrossBackgrounding: true,
      );
    } on LocalAuthException catch (e) {
      // local_auth 3.x reports "no hardware" / "not enrolled" / "locked out"
      // this way. Logged rather than swallowed silently: a biometric toggle
      // that quietly never works is exactly the kind of dead feature a bare
      // catch has hidden here before.
      debugPrint('AppLockService: biometric unavailable (${e.code})');
      return false;
    } catch (e) {
      // MissingPluginException on an unsupported target, or anything the
      // platform channel throws that the plugin did not classify.
      debugPrint('AppLockService: biometric failed ($e)');
      return false;
    }
  }
}
