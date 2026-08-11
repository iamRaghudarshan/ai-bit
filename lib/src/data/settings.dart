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

  /// When false the player pauses as the app leaves the foreground, matching
  /// stock YouTube behaviour.
  bool get backgroundPlayback => _prefs.getBool(_kBackground) ?? true;
  set backgroundPlayback(bool value) => _write(_kBackground, value);

  /// Drop the video track while the screen is off and pick it back up on
  /// unlock. Saves roughly ten times the data, since nobody is watching a
  /// locked screen.
  ///
  /// **Off by default.** Swapping the source means building a new player item
  /// and starting it while the app is already in the background, which iOS
  /// restricts — and when it fails, audio stops altogether. Silent playback is
  /// a far worse outcome than extra data, so this is opt-in.
  bool get audioOnlyWhenLocked => _prefs.getBool(_kLockedAudio) ?? false;
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
