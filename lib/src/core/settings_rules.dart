/// Why a setting will not do anything right now.
///
/// Several settings in this app quietly override each other - Data saver beats
/// the quality picker, Audio only beats anything to do with pictures, a PIN-less
/// app lock cannot lock - and the screen used to show them all as equally live
/// switches. Flipping one and watching nothing happen is indistinguishable from
/// a bug, and that is how feed previews were first reported.
///
/// Every rule here is a pure function returning either null ("this works") or a
/// sentence to show the user. Pure so each one can be pinned by a test: these
/// are exactly the rules that rot silently when a new setting is added beside
/// them.
library;

/// Why muted feed previews will not play, or null when they will.
///
/// [previewsEnabled] being false returns null on purpose: the switch already
/// reads as off, and a reason under it would be noise.
String? feedPreviewBlockedReason({
  required bool previewsEnabled,
  required bool previewsOnMobile,
  required bool dataSaver,
  required bool audioOnly,
  required bool isMobile,
  required bool somethingPlaying,
  bool batterySaver = false,
  bool batteryLow = false,
}) {
  if (!previewsEnabled) return null;
  if (somethingPlaying) return 'Paused while a video is playing.';
  if (dataSaver) return 'Off while Data saver is on.';
  if (audioOnly) return 'Off while Audio only is on.';
  // Previews are the most expensive thing the feed can do, so a battery saver
  // that did not stop them would not be saving much.
  if (batterySaver && batteryLow) return 'Off while the battery is low.';
  if (isMobile && !previewsOnMobile) {
    return 'Off on mobile data. Turn on "Previews on mobile data" below.';
  }
  return null;
}

/// Why the mobile-only data saver has nothing left to do.
String? mobileDataSaverInertReason({required bool dataSaver}) =>
    dataSaver ? 'Data saver is already on everywhere.' : null;

/// Why the mobile-only audio switch has nothing left to do.
String? mobileAudioOnlyInertReason({required bool audioOnly}) =>
    audioOnly ? 'Audio only is already on everywhere.' : null;

/// Why the quality picker cannot be used.
///
/// Two different settings take it over, and naming the right one matters: a
/// user who turned on Audio only and is told about Data saver will go and look
/// at the wrong switch.
String? qualityInertReason({
  required bool dataSaver,
  required bool audioOnly,
}) {
  if (audioOnly) return 'Audio only is on, so there is no picture to size.';
  if (dataSaver) return 'Data saver picks the lowest quality.';
  return null;
}

/// Why biometric unlock cannot be turned on.
///
/// A fingerprint with no PIN behind it is a lock with no key: every biometric
/// failure path in this app falls back to the PIN, so without one there is
/// nothing to fall back to.
String? biometricUnavailableReason({required bool hasPin}) =>
    hasPin ? null : 'Set a PIN first — biometrics fall back to it.';

/// Why a Kids daily limit is weaker than it looks.
///
/// The limit itself works without a PIN; what does not work is stopping the
/// child from leaving Kids mode when it runs out, which is the entire point of
/// setting one.
String? kidsLimitWeakReason({
  required int limitMinutes,
  required bool hasKidsPin,
}) {
  if (limitMinutes <= 0) return null;
  if (hasKidsPin) return null;
  return 'Set a Kids PIN too, or the limit can be turned off.';
}

/// Why app lock is not actually protecting anything.
String? appLockInertReason({
  required bool enabled,
  required bool hasPin,
}) {
  if (!enabled) return null;
  return hasPin ? null : 'No PIN set, so nothing is locked yet.';
}
