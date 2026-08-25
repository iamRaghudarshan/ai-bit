import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What happens when a video ends.
enum PlaybackRepeat {
  /// Move on to the queue, or stop.
  off,

  /// Replay the same video forever.
  one,

  /// Loop the whole queue back to the start.
  all,
}

/// Persisted user preferences. Small enough that SharedPreferences beats
/// another SQLite table.
class SettingsService extends ChangeNotifier {
  SettingsService._(this._prefs);

  final SharedPreferences _prefs;

  static const _kTheme = 'theme_mode';
  static const _kQuality = 'preferred_quality';
  static const _kSpeed = 'playback_speed';
  static const _kAudioOnly = 'audio_only';
  static const _kAutoplay = 'autoplay_next';
  static const _kBackground = 'background_playback';
  static const _kLockedAudio = 'audio_only_when_locked';
  static const _kRepeat = 'repeat_mode';

  /// Sentinel for "let the player pick the highest available".
  static const autoQuality = 'Auto';

  static Future<SettingsService> load() async =>
      SettingsService._(await SharedPreferences.getInstance());

  ThemeMode get themeMode =>
      ThemeMode.values[_prefs.getInt(_kTheme) ?? ThemeMode.dark.index];
  set themeMode(ThemeMode value) => _write(_kTheme, value.index);

  String get preferredQuality => _prefs.getString(_kQuality) ?? autoQuality;
  set preferredQuality(String value) => _write(_kQuality, value);

  double get playbackSpeed => _prefs.getDouble(_kSpeed) ?? 1.0;
  set playbackSpeed(double value) => _write(_kSpeed, value);

  /// Fetch only the audio track. Saves a lot of data when the app is mostly
  /// used with the screen off.
  bool get audioOnly => _prefs.getBool(_kAudioOnly) ?? false;
  set audioOnly(bool value) => _write(_kAudioOnly, value);

  bool get autoplayNext => _prefs.getBool(_kAutoplay) ?? true;
  set autoplayNext(bool value) => _write(_kAutoplay, value);

  static const _kKidsMode = 'kids_mode';

  /// Kids mode fills the home feed with kid-friendly content instead of the
  /// usual recommendations. Off by default — the app opens as normal.
  bool get kidsMode => _prefs.getBool(_kKidsMode) ?? false;
  set kidsMode(bool value) => _write(_kKidsMode, value);

  static const _kSponsorBlock = 'sponsorblock';

  /// Auto-skip sponsor and self-promo segments via the SponsorBlock community
  /// database. On by default — it is the natural extension of an ad-free app.
  bool get sponsorBlock => _prefs.getBool(_kSponsorBlock) ?? true;
  set sponsorBlock(bool value) => _write(_kSponsorBlock, value);

  static const _kAmoled = 'amoled_black';

  /// Pure-black backgrounds in dark mode, which switch OLED pixels fully off.
  bool get amoledBlack => _prefs.getBool(_kAmoled) ?? false;
  set amoledBlack(bool value) => _write(_kAmoled, value);

  static const _kAccent = 'accent_color';

  /// Brand accent as an ARGB int. Defaults to the YouTube-ish red.
  int get accentColor => _prefs.getInt(_kAccent) ?? 0xFFFF0033;
  set accentColor(int value) => _write(_kAccent, value);

  static const _kDataSaver = 'data_saver';

  /// Minimise data use: always stream the lowest-quality rendition a video
  /// offers, and default new downloads to the smallest size. Off by default.
  ///
  /// On videos that only offer the single 360p combined stream this can go no
  /// lower than 360p — YouTube no longer serves a combined stream beneath it —
  /// but on anything with a fuller ladder it drops to 144p/240p. For the
  /// absolute least data, pair it with Audio only.
  bool get dataSaver => _prefs.getBool(_kDataSaver) ?? false;
  set dataSaver(bool value) => _write(_kDataSaver, value);

  static const _kRememberSpeed = 'remember_speed_per_channel';

  /// Remember the playback speed chosen for each channel, and reapply it the
  /// next time one of that channel's videos plays.
  bool get rememberSpeedPerChannel =>
      _prefs.getBool(_kRememberSpeed) ?? false;
  set rememberSpeedPerChannel(bool value) => _write(_kRememberSpeed, value);

  /// Reads the remembered speed for [channelId], or null if none.
  double? speedForChannel(String channelId) {
    if (!rememberSpeedPerChannel || channelId.isEmpty) return null;
    return _prefs.getDouble('speed_ch_$channelId');
  }

  void setSpeedForChannel(String channelId, double speed) {
    if (channelId.isEmpty) return;
    _prefs.setDouble('speed_ch_$channelId', speed);
  }

  /// When false the player pauses as the app leaves the foreground, matching
  /// stock YouTube behaviour.
  bool get backgroundPlayback => _prefs.getBool(_kBackground) ?? true;
  set backgroundPlayback(bool value) => _write(_kBackground, value);

  /// Switch to the audio-only stream when the app leaves the foreground.
  ///
  /// **This is what makes background playback work at all on iOS**, not a data
  /// optimisation. `better_player_plus` has no background lifecycle handling —
  /// it never detaches the video layer — and iOS suspends an AVPlayer whose
  /// AVPlayerLayer is still attached the moment the app backgrounds. An
  /// audio-only asset has no video layer to suspend, so it keeps playing.
  ///
  /// It also cuts data roughly tenfold, which is a genuine bonus rather than
  /// the point.
  bool get audioOnlyWhenLocked => _prefs.getBool(_kLockedAudio) ?? true;

  set audioOnlyWhenLocked(bool value) => _write(_kLockedAudio, value);

  /// off / one / all.
  PlaybackRepeat get repeatMode =>
      PlaybackRepeat.values[_prefs.getInt(_kRepeat) ?? PlaybackRepeat.off.index];
  set repeatMode(PlaybackRepeat value) => _write(_kRepeat, value.index);

  static const _kAppLock = 'app_lock_enabled';
  static const _kAppLockPin = 'app_lock_pin_hash';
  static const _kAppLockBiometric = 'app_lock_biometric';

  /// Require a PIN or biometric before the app opens.
  bool get appLockEnabled => _prefs.getBool(_kAppLock) ?? false;
  set appLockEnabled(bool value) => _write(_kAppLock, value);

  /// sha256 hex of the unlock PIN; empty means no PIN has been set yet.
  ///
  /// Hashed rather than stored plainly because SharedPreferences is a
  /// world-readable XML file on a rooted device, and people reuse PINs.
  String get appLockPinHash => _prefs.getString(_kAppLockPin) ?? '';
  set appLockPinHash(String value) => _write(_kAppLockPin, value);

  /// Offer fingerprint / Face ID before falling back to the PIN.
  bool get appLockBiometric => _prefs.getBool(_kAppLockBiometric) ?? false;
  set appLockBiometric(bool value) => _write(_kAppLockBiometric, value);

  static const _kIncognito = 'incognito';

  /// Stop recording watch and search history for this session. Persisted so it
  /// survives a restart — leaving it on is a deliberate choice, and silently
  /// resuming recording on next launch would be the surprising behaviour.
  bool get incognito => _prefs.getBool(_kIncognito) ?? false;
  set incognito(bool value) => _write(_kIncognito, value);

  static const _kHistoryRetention = 'history_retention_days';

  /// Auto-delete history older than this many days. 0 means keep forever,
  /// which is the existing behaviour and stays the default.
  int get historyRetentionDays => _prefs.getInt(_kHistoryRetention) ?? 0;
  set historyRetentionDays(int value) => _write(_kHistoryRetention, value);

  static const _kKidsPin = 'kids_pin_hash';
  static const _kKidsLimit = 'kids_daily_limit_minutes';

  /// sha256 hex of the PIN that guards leaving Kids mode; empty means unset,
  /// in which case the toggle is free to flip as it always was.
  String get kidsPinHash => _prefs.getString(_kKidsPin) ?? '';
  set kidsPinHash(String value) => _write(_kKidsPin, value);

  /// Daily watch allowance in Kids mode. 0 means unlimited.
  int get kidsDailyLimitMinutes => _prefs.getInt(_kKidsLimit) ?? 0;
  set kidsDailyLimitMinutes(int value) => _write(_kKidsLimit, value);

  static const _kBatterySaver = 'battery_saver';

  /// Step down quality and drop the video track when the battery runs low.
  bool get batterySaver => _prefs.getBool(_kBatterySaver) ?? false;
  set batterySaver(bool value) => _write(_kBatterySaver, value);

  static const _kAutoPip = 'auto_pip';

  /// iOS only: let the system move the video into Picture in Picture by itself
  /// when the app is left mid-video, instead of waiting for a tap.
  ///
  /// Off by default deliberately. Making this work needs a real AVPlayerLayer
  /// alive during inline playback (see PATCHES.md #17), and neither platform
  /// builds on the machine this was written on - so it ships opt-in until it
  /// has been tried on a device rather than risking the main playback path.
  bool get autoPip => _prefs.getBool(_kAutoPip) ?? false;
  set autoPip(bool value) => _write(_kAutoPip, value);

  static const _kMobileDataSaver = 'mobile_data_saver';
  static const _kMobileAudioOnly = 'mobile_audio_only';

  /// Apply the data saver only while on a metered connection, so Wi-Fi keeps
  /// full quality. Distinct from [dataSaver], which is unconditional.
  bool get mobileDataSaver => _prefs.getBool(_kMobileDataSaver) ?? false;
  set mobileDataSaver(bool value) => _write(_kMobileDataSaver, value);

  /// Play audio only while on mobile data — the cheapest setting there is.
  bool get mobileAudioOnly => _prefs.getBool(_kMobileAudioOnly) ?? false;
  set mobileAudioOnly(bool value) => _write(_kMobileAudioOnly, value);

  static const _kTrackDataUsage = 'track_data_usage';

  /// Record how many bytes each channel cost. On by default: the numbers are
  /// device-local and useless unless they have been collected all along.
  bool get trackDataUsage => _prefs.getBool(_kTrackDataUsage) ?? true;
  set trackDataUsage(bool value) => _write(_kTrackDataUsage, value);

  void _write(String key, Object value) {
    switch (value) {
      case final int v:
        _prefs.setInt(key, v);
      case final double v:
        _prefs.setDouble(key, v);
      case final bool v:
        _prefs.setBool(key, v);
      case final String v:
        _prefs.setString(key, v);
    }
    notifyListeners();
  }
}
