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

  static const _kDownloadHd = 'download_hd';
  static const _kDownloadMp3 = 'download_mp3';

  /// Download the best video available rather than the 360p combined file.
  ///
  /// Off by default: an HD download fetches two files and joins them, so it
  /// costs several times the data and a little time at the end. That should be
  /// asked for rather than assumed.
  bool get downloadHd => _prefs.getBool(_kDownloadHd) ?? false;
  set downloadHd(bool value) {
    _prefs.setBool(_kDownloadHd, value);
    notifyListeners();
  }

  /// Convert downloaded audio to MP3 instead of leaving it as AAC.
  ///
  /// Off by default: AAC is what YouTube serves and every player reads it, so
  /// converting is a re-encode that costs quality for compatibility with older
  /// hardware.
  bool get downloadMp3 => _prefs.getBool(_kDownloadMp3) ?? false;
  set downloadMp3(bool value) {
    _prefs.setBool(_kDownloadMp3, value);
    notifyListeners();
  }
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
