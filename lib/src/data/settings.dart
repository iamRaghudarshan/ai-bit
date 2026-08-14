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
