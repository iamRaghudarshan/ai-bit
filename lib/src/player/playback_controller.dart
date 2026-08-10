import 'dart:async';
import 'dart:io';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../data/settings.dart';
import '../data/yt_repository.dart';

/// Owns the one and only video player for the whole app.
///
/// Keeping a single long-lived [BetterPlayerController] here — rather than one
/// per screen — is what allows audio to survive leaving the watch page, the app
/// going to the background, and the screen locking. The `BetterPlayer` widget on
/// the watch page merely attaches a render surface to it.
class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required YtRepository repository,
    required AppDatabase database,
    required SettingsService settings,
  }) : _repo = repository,
       _db = database,
       _config = settings;

  final YtRepository _repo;
  final AppDatabase _db;
  final SettingsService _config;

  /// Attached to the `BetterPlayer` widget so native Picture-in-Picture can
  /// find the player's frame on screen.
  final GlobalKey playerKey = GlobalKey();

  BetterPlayerController? _player;
  BetterPlayerController? get player => _player;

  VideoBrief? _current;
  VideoBrief? get current => _current;

  final List<VideoBrief> _queue = [];
  List<VideoBrief> get queue => List.unmodifiable(_queue);

  PlaybackSources? _sources;
  Map<String, String> get qualities => _sources?.qualities ?? const {};

  bool _isOffline = false;

  /// True when the current video is coming from a downloaded file.
  bool get isOffline => _isOffline;

  /// True when the current video is playing as audio because YouTube served no
  /// combined video+audio stream for it.
  bool get isAudioFallback => _sources?.videoUnavailable ?? false;

  /// True whenever there is no picture — either the user asked for audio only
  /// or we had to fall back to it.
  bool get isAudioOnly => _config.audioOnly || isAudioFallback;

  bool _loading = false;
  bool get isLoading => _loading;

  String? _error;
  String? get error => _error;

  Duration _position = Duration.zero;
  Duration get position => _position;

  Duration _duration = Duration.zero;
  Duration get duration => _duration;

  bool _playing = false;
  bool get isPlaying => _playing;

  bool get hasVideo => _current != null;

  double get speed => _config.playbackSpeed;

  Timer? _sleepTimer;
  DateTime? _sleepDeadline;

  /// Wall-clock remaining on the sleep timer, or null when it is off.
  Duration? get sleepRemaining {
    final deadline = _sleepDeadline;
    if (deadline == null) return null;
    final left = deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  DateTime _lastPositionWrite = DateTime.fromMillisecondsSinceEpoch(0);
  Duration? _lastNotified;

  // ------------------------------------------------------------------- play

  /// Loads [video] and starts playing. [upNext] becomes the autoplay queue.
  Future<void> play(VideoBrief video, {List<VideoBrief> upNext = const []}) async {
    if (_current?.id == video.id && _player != null && _error == null) {
      // Re-tapping the currently loaded video should just resume it.
      await _player!.play();
      return;
    }

    _current = video;
    _queue
      ..clear()
      ..addAll(upNext.where((v) => v.id != video.id));
    _loading = true;
    _error = null;
    _position = Duration.zero;
    _duration = video.duration ?? Duration.zero;
    notifyListeners();

    unawaited(_db.recordWatch(video));

    // The browser preview has no native player plugin. Stop after recording
    // the selection so every screen still renders and can be reviewed.
    if (kIsWeb) {
      _loading = false;
      _duration = video.duration ?? Duration.zero;
      notifyListeners();
      return;
    }

    try {
      // A finished download always wins: it plays instantly, costs no data and
      // works with no network at all.
      final offlinePath = await _offlineFile(video.id);
      final sources = offlinePath != null
          ? PlaybackSources(url: offlinePath, qualities: const {})
          : await _repo.resolve(video.id, audioOnly: _config.audioOnly);
      _sources = sources;
      _isOffline = offlinePath != null;
      final resumeAt = await _db.resumePosition(video.id);
      await _attach(video, sources, startAt: resumeAt);
      _loading = false;
      notifyListeners();
    } catch (e) {
      _loading = false;
      _error = e is StreamResolutionException
          ? e.toString()
          : 'Could not start playback. Check your connection and try again.';
      notifyListeners();
    }
  }

  Future<void> _attach(
    VideoBrief video,
    PlaybackSources sources, {
    Duration? startAt,
  }) async {
    final dataSource = BetterPlayerDataSource(
      _isOffline
          ? BetterPlayerDataSourceType.file
          : BetterPlayerDataSourceType.network,
      _preferredUrl(sources),
      liveStream: video.isLive,
      resolutions: sources.qualities.isEmpty ? null : sources.qualities,
      // Turning the notification on is not cosmetic: better_player treats a
      // visible notification as "the host app manages playback", which is what
      // suppresses its built-in pause-on-background and pause-when-offscreen.
      notificationConfiguration: BetterPlayerNotificationConfiguration(
        showNotification: _config.backgroundPlayback,
        title: video.title,
        author: video.author,
        imageUrl: video.thumbUrl,
        notificationChannelName: 'AI Tube playback',
        activityName: 'MainActivity',
      ),
      // Caching a local file would just duplicate it on disk.
      cacheConfiguration: _isOffline
          ? const BetterPlayerCacheConfiguration()
          : const BetterPlayerCacheConfiguration(
              useCache: true,
              preCacheSize: 5 * 1024 * 1024,
              maxCacheSize: 200 * 1024 * 1024,
              maxCacheFileSize: 50 * 1024 * 1024,
            ),
    );

    if (_player == null) {
      _player = BetterPlayerController(_configuration(startAt: startAt))
        ..setBetterPlayerGlobalKey(playerKey)
        ..addEventsListener(_onPlayerEvent);
      await _player!.setupDataSource(dataSource);
    } else {
      await _player!.setupDataSource(dataSource);
      if (startAt != null) await _player!.seekTo(startAt);
      await _player!.play();
    }

    _player!.videoPlayerController?.removeListener(_onValueChanged);
    _player!.videoPlayerController?.addListener(_onValueChanged);
    await _player!.setSpeed(_config.playbackSpeed);
  }

  /// Resolves the on-disk path for a completed download, dropping the record
  /// if the file has gone missing (restored backup, manual cleanup).
  Future<String?> _offlineFile(String videoId) async {
    final path = await _db.completedDownloadPath(videoId);
    if (path == null) return null;
    return await File(path).exists() ? path : null;
  }

  String _preferredUrl(PlaybackSources sources) {
    if (_isOffline) return sources.url;
    if (_config.audioOnly && sources.audioOnlyUrl != null) {
      return sources.audioOnlyUrl!;
    }
    final wanted = _config.preferredQuality;
    if (wanted != SettingsService.autoQuality) {
      final exact = sources.qualities[wanted];
      if (exact != null) return exact;
    }
    return sources.url;
  }

  BetterPlayerConfiguration _configuration({Duration? startAt}) =>
      BetterPlayerConfiguration(
        autoPlay: true,
        startAt: startAt,
        fit: BoxFit.contain,
        aspectRatio: 16 / 9,
        expandToFill: false,
        // The controller outlives every widget that renders it; without this,
        // popping the watch page would tear down the native player.
        autoDispose: false,
        handleLifecycle: false,
        allowedScreenSleep: false,
        autoDetectFullscreenDeviceOrientation: true,
        // A no-op keeps better_player from pausing when the surface scrolls
        // out of view — that is exactly the background case we want to keep.
        playerVisibilityChangedBehavior: (_) {},
        errorBuilder: (context, message) => _PlayerError(message: message),
        controlsConfiguration: BetterPlayerControlsConfiguration(
          enablePip: true,
          enableQualities: true,
          enablePlaybackSpeed: true,
          enableSubtitles: true,
          enableAudioTracks: false,
          enableRetry: true,
          progressBarPlayedColor: AppColors.brand,
          progressBarHandleColor: AppColors.brand,
          progressBarBufferedColor: Colors.white54,
          progressBarBackgroundColor: Colors.white24,
          loadingColor: AppColors.brand,
          overflowModalColor: AppColors.darkSurface,
          overflowModalTextColor: Colors.white,
          overflowMenuIconsColor: Colors.white,
          controlBarColor: Colors.black38,
        ),
      );

  // ----------------------------------------------------------- transport

  Future<void> togglePlayPause() async {
    final player = _player;
    if (player == null) return;
    if (player.isPlaying() ?? false) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  Future<void> seek(Duration to) async => _player?.seekTo(to);

  Future<void> skip(Duration delta) async {
    final target = _position + delta;
    await seek(target < Duration.zero ? Duration.zero : target);
  }

  Future<void> setSpeed(double value) async {
    _config.playbackSpeed = value;
    await _player?.setSpeed(value);
    notifyListeners();
  }

  /// Switches rendition. [label] must be a key of [qualities], or
  /// [SettingsService.autoQuality] to go back to the default ladder.
  Future<void> setQuality(String label) async {
    final sources = _sources;
    if (sources == null) return;
    _config.preferredQuality = label;
    final url = label == SettingsService.autoQuality
        ? sources.url
        : sources.qualities[label];
    if (url == null) return;
    await _player?.setResolution(url);
    notifyListeners();
  }

  /// Re-resolves the current video after an audio-only toggle, keeping the
  /// playback position.
  Future<void> reloadCurrent() async {
    final video = _current;
    if (video == null) return;
    final resumeAt = _position;
    _current = null;
    await play(video, upNext: _queue.toList());
    if (resumeAt > const Duration(seconds: 3)) await seek(resumeAt);
  }

  /// Swaps in a new autoplay queue — used once the watch page has finished
  /// loading the real "up next" list.
  void replaceQueue(List<VideoBrief> videos) {
    _queue
      ..clear()
      ..addAll(videos.where((v) => v.id != _current?.id));
    notifyListeners();
  }

  Future<void> playNext() async {
    if (_queue.isEmpty) return;
    final next = _queue.removeAt(0);
    await play(next, upNext: _queue.toList());
  }

  Future<void> enterPictureInPicture() async {
    final player = _player;
    if (player == null) return;
    if (!await player.isPictureInPictureSupported()) return;
    await player.enablePictureInPicture(playerKey);
  }

  Future<void> stop() async {
    _cancelSleepTimer();
    final player = _player;
    _player = null;
    _current = null;
    _sources = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _playing = false;
    player?.videoPlayerController?.removeListener(_onValueChanged);
    player?.removeEventsListener(_onPlayerEvent);
    player?.dispose(forceDispose: true);
    notifyListeners();
  }

  // --------------------------------------------------------- sleep timer

  void startSleepTimer(Duration duration) {
    _cancelSleepTimer();
    _sleepDeadline = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () {
      _player?.pause();
      _sleepDeadline = null;
      _sleepTimer = null;
      notifyListeners();
    });
    notifyListeners();
  }

  void cancelSleepTimer() {
    _cancelSleepTimer();
    notifyListeners();
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDeadline = null;
  }

  // -------------------------------------------------------------- events

  void _onPlayerEvent(BetterPlayerEvent event) {
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.finished:
        _persistPosition(force: true);
        if (_config.autoplayNext) unawaited(playNext());
      case BetterPlayerEventType.exception:
        _error = 'Playback failed. The stream link may have expired — '
            'pull to refresh, or reopen the video.';
        notifyListeners();
      case BetterPlayerEventType.play:
      case BetterPlayerEventType.pause:
        _playing = _player?.isPlaying() ?? false;
        notifyListeners();
      default:
        break;
    }
  }

  /// Mirrors the native player's value into plain fields the UI can watch,
  /// throttled to one notification per second so the mini player does not
  /// rebuild on every position tick.
  void _onValueChanged() {
    final value = _player?.videoPlayerController?.value;
    if (value == null) return;

    _position = value.position;
    if (value.duration != null && value.duration! > Duration.zero) {
      _duration = value.duration!;
    }
    _playing = value.isPlaying;
    _persistPosition();

    final second = Duration(seconds: _position.inSeconds);
    if (_lastNotified != second) {
      _lastNotified = second;
      notifyListeners();
    }
  }

  void _persistPosition({bool force = false}) {
    final video = _current;
    if (video == null) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastPositionWrite) < const Duration(seconds: 5)) {
      return;
    }
    _lastPositionWrite = now;
    unawaited(_db.savePosition(video.id, _position));
  }

  @override
  void dispose() {
    _cancelSleepTimer();
    _player?.videoPlayerController?.removeListener(_onValueChanged);
    _player?.removeEventsListener(_onPlayerEvent);
    _player?.dispose(forceDispose: true);
    super.dispose();
  }
}

class _PlayerError extends StatelessWidget {
  const _PlayerError({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white70, size: 32),
            const SizedBox(height: 8),
            Text(
              message ?? 'This video could not be played.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    ),
  );
}
