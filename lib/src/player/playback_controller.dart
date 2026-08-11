import 'dart:async';
import 'dart:io';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../data/db.dart';
import '../data/models.dart';
import '../data/settings.dart';
import '../data/yt_repository.dart';
import '../ui/widgets/video_controls.dart';
import 'remote_commands.dart';

/// Owns the one and only video player for the whole app.
///
/// Keeping a single long-lived [BetterPlayerController] here — rather than one
/// per screen — is what allows audio to survive leaving the watch page, the app
/// going to the background, and the screen locking. The `BetterPlayer` widget on
/// the watch page merely attaches a render surface to it.
class PlaybackController extends ChangeNotifier with WidgetsBindingObserver {
  PlaybackController({
    required YtRepository repository,
    required AppDatabase database,
    required SettingsService settings,
  }) : _repo = repository,
       _db = database,
       _config = settings {
    // Own the lifecycle rather than letting better_player have it: its handling
    // is disabled so background audio survives, which leaves the screen-off
    // transition ours to act on.
    WidgetsBinding.instance.addObserver(this);
  }

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

  /// Selectable qualities, best first.
  ///
  /// With HLS the renditions are not URLs we hold — better_player parses the
  /// ladder off the manifest into tracks. Reading `_sources.qualities` alone
  /// left the picker showing nothing but "Auto" on every HD video, because the
  /// HLS path deliberately stores an empty map.
  List<String> get qualities {
    final tracks = _player?.betterPlayerAsmsTracks ?? const [];
    final heights = tracks
        .map((t) => t.height ?? 0)
        .where((h) => h > 0)
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));
    if (heights.isNotEmpty) return heights.map((h) => '${h}p').toList();
    return _sources?.qualities.keys.toList() ?? const [];
  }

  /// The rendition actually playing, or null while on Auto.
  String? get activeQuality {
    final height = _player?.betterPlayerAsmsTrack?.height ?? 0;
    return height > 0 ? '${height}p' : null;
  }

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

  /// Lock-screen skip buttons, which the player plugin leaves disabled.
  late final RemoteCommands _remote = RemoteCommands(
    onNext: () => unawaited(playNext()),
    onPrevious: () => unawaited(playPrevious()),
  );

  /// Position ticks, kept off [notifyListeners] on purpose.
  ///
  /// Everything on the watch page listens to this controller, so a per-second
  /// notification rebuilt the up-next list, the comment preview and the
  /// description once a second for the whole video. Only the seek bar and the
  /// mini player's progress line actually care about the position, so they
  /// listen here instead and the rest of the page rebuilds when something
  /// genuinely changes.
  final ValueNotifier<Duration> ticker = ValueNotifier(Duration.zero);
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
  ///
  /// Set [recordHistory] false when stepping *backwards*, so the video being
  /// left does not get pushed onto the history it was just taken from.
  Future<void> play(
    VideoBrief video, {
    List<VideoBrief> upNext = const [],
    bool recordHistory = true,
  }) async {
    if (_current?.id == video.id && _player != null && _error == null) {
      // Re-tapping the currently loaded video should just resume it.
      await _player!.play();
      return;
    }

    final leaving = _current;
    if (recordHistory && leaving != null && leaving.id != video.id) {
      _pushHistory(leaving);
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
          // Resolved in full even in audio mode.
          //
          // Asking the repository for audio-only handed back the bare
          // googlevideo audio URL as the only source — no HLS ladder, no
          // progressive file. AVURLAsset works out its format from the path
          // extension and that URL has none, so AVPlayer failed the load
          // outright: "Failed to load video: unknown error". Every later fix
          // was operating on sources that had already been narrowed to the one
          // URL that cannot play.
          //
          // Audio mode is a player-side concern: same stream as video, lowest
          // rendition, picture covered.
          : await _repo.resolve(video.id);
      _sources = sources;
      _isOffline = offlinePath != null;
      final resumeAt = await _db.resumePosition(video.id);
      await _attach(video, sources, startAt: resumeAt);
      _loading = false;
      notifyListeners();
    } catch (e) {
      _loading = false;
      // Always carry the real reason. A generic "check your connection" sent
      // three rounds of debugging in the wrong direction while the connection
      // was fine.
      _error = e is StreamResolutionException
          ? e.toString()
          : 'Could not start playback: $e';
      notifyListeners();
    }
  }

  Future<void> _attach(
    VideoBrief video,
    PlaybackSources sources, {
    Duration? startAt,
  }) async {
    final dataSource = _dataSource(
      video,
      _preferredUrl(sources),
      isHls: sources.isHls,
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

    _cancelCountdown();
    _endScreen = false;

    // Setting a data source resets the remote commands inside the plugin, so
    // the skip buttons have to be re-armed for every video rather than once.
    _remote.invalidate();
    unawaited(_remote.sync(hasPrevious: hasPrevious, hasNext: hasNext));

    // Again shortly after. The plugin builds its now-playing info once the
    // artwork has been fetched, and disables the skip commands as part of that
    // — so a single re-arm at setup time can be undone a moment later.
    Timer(const Duration(milliseconds: 1200), () {
      _remote.invalidate();
      unawaited(_remote.sync(hasPrevious: hasPrevious, hasNext: hasNext));
    });

    // Carry the chosen quality across videos. The tracks only exist once the
    // manifest has been read, so this waits for them rather than firing at
    // setup and finding an empty list.
    unawaited(_applyPreferredQualityWhenReady());
  }

  /// Builds the data source for one URL of [video]. Shared by the initial load
  /// and by the screen-off track swap, so both stay configured identically.
  BetterPlayerDataSource _dataSource(
    VideoBrief video,
    String url, {
    required bool isHls,
  }) {
    return BetterPlayerDataSource(
      _isOffline
          ? BetterPlayerDataSourceType.file
          : BetterPlayerDataSourceType.network,
      url,
      // Audio-only is never live: the audio track is a finite file even for a
      // live video, and declaring it live gives the player an item with no
      // duration to seek in.
      liveStream: !isAudioOnly &&
          ((_sources?.isLive ?? false) || video.isLive),
      // Tell the player it is HLS. The manifest URL has no .m3u8 extension, so
      // without the hint AVPlayer guesses from the path and gets it wrong.
      videoFormat: isHls ? BetterPlayerVideoFormat.hls : null,
      // Only reaches the cache manager on iOS, which is bypassed here — kept
      // because Android's ExoPlayer does use it to pick a extractor for a URL
      // with no file extension.
      // Describe the URL that is actually being loaded, not the mode. Audio
      // mode now stays on the video file and simply hides the picture, so
      // claiming 'm4a' would have told ExoPlayer to expect the wrong container.
      videoExtension: isHls
          ? null
          : (url == _sources?.audioOnlyUrl ? 'm4a' : 'mp4'),
      // Let better_player read the ladder's variants off the manifest, which is
      // what puts real quality and subtitle options in the overflow menu.
      useAsmsTracks: isHls,
      useAsmsSubtitles: isHls,
      resolutions: (_sources?.qualities.isEmpty ?? true)
          ? null
          : _sources!.qualities,
      // Turning the notification on is not cosmetic: better_player treats a
      // visible notification as "the host app manages playback", which is what
      // suppresses its built-in pause-on-background and pause-when-offscreen.
      notificationConfiguration: BetterPlayerNotificationConfiguration(
        showNotification: _config.backgroundPlayback,
        title: video.title,
        author: video.author,
        imageUrl: video.thumbUrl,
        notificationChannelName: 'AI BIT playback',
        activityName: 'MainActivity',
      ),
      // Identify as the client the stream was issued to. The URLs serve fine
      // without this today, but YouTube has bound streams to the requesting
      // client before and it costs nothing to match.
      headers: _isOffline
          ? null
          : const {
              'User-Agent':
                  'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
            },
      // Caching is OFF deliberately. With useCache the iOS plugin plays through
      // CachingPlayerItem — a custom AVAssetResourceLoader — instead of a plain
      // AVPlayerItem, and that path fails on googlevideo URLs, which redirect,
      // carry expiring query parameters and rely on exact range semantics. It
      // was the cause of "Playback failed" on device while the same URL served
      // HTTP 206 to a plain client. Offline use is served by real downloads.
      cacheConfiguration: const BetterPlayerCacheConfiguration(),
    );
  }

  /// Resolves the on-disk path for a completed download, dropping the record
  /// if the file has gone missing (restored backup, manual cleanup).
  Future<String?> _offlineFile(String videoId) async {
    final path = await _db.completedDownloadPath(videoId);
    if (path == null) return null;
    return await File(path).exists() ? path : null;
  }

  /// Identifies the video a pending quality application belongs to.
  ///
  /// Each load bumps this. Without it, the loop started for one video was
  /// still running when the next began, and whichever finished last won — so
  /// opening a second video often played it at the previous one's rendition,
  /// or dropped audio mode entirely.
  int _qualityToken = 0;

  /// Waits for the HLS ladder, then applies the quality this mode calls for.
  Future<void> _applyPreferredQualityWhenReady() async {
    final token = ++_qualityToken;

    // Roughly nine seconds. Three was not enough: a manifest fetched over a
    // slow connection routinely arrived after the loop had already given up,
    // which is why audio mode "came after a while" on one video and never
    // arrived on the next.
    for (var attempt = 0; attempt < 30; attempt++) {
      if (token != _qualityToken) return;
      if ((_player?.betterPlayerAsmsTracks.isNotEmpty ?? false)) {
        // Worked out here, inside the loop, and not before it.
        //
        // Audio mode picks the smallest rendition, which is read off the track
        // list — and that list is empty until the manifest has been parsed.
        // Computing it up front therefore always returned "Auto" and returned
        // early, so audio-only streamed the full-size video behind the artwork
        // and saved no data at all.
        final wanted = (_config.audioOnly || _droppedVideo)
            ? _lowestQuality
            : _config.preferredQuality;
        if (wanted == SettingsService.autoQuality) return;
        await _applyQuality(wanted);
        if (token != _qualityToken) return;
        notifyListeners();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  String _preferredUrl(PlaybackSources sources) {
    if (_isOffline) return sources.url;

    // Audio mode never picks its own URL.
    //
    // It plays exactly what video mode plays and covers the picture, dropping
    // to the ladder's smallest rendition once the manifest is parsed. Choosing
    // the bare googlevideo audio URL instead was the whole bug: AVURLAsset
    // identifies a stream by its path extension, that URL has none, and
    // AVPlayer refuses it. There is now no branch that can reach it — if a
    // video plays, its audio plays, because they are the same source.
    if (_config.audioOnly) return sources.url;

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
          // Custom, because the built-in controls have no notion of a queue:
          // there is no way to reach the next or previous video from the video
          // surface itself. See VideoControls.
          playerTheme: BetterPlayerTheme.custom,
          customControlsBuilder: (controller, onVisibilityChanged, _) =>
              VideoControls(
                controller: controller,
                onVisibilityChanged: onVisibilityChanged,
              ),
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

  double _volume = 1;

  /// 0..1. Mirrored here because the platform player has no readable getter.
  double get volume => _volume;

  Future<void> setVolume(double value) async {
    _volume = value.clamp(0.0, 1.0);
    await _player?.setVolume(_volume);
    notifyListeners();
  }

  Future<void> setSpeed(double value) async {
    _config.playbackSpeed = value;
    await _player?.setSpeed(value);
    notifyListeners();
  }

  /// Switches rendition, and remembers the choice so every later video opens
  /// at the same quality rather than reverting to Auto.
  Future<void> setQuality(String label) async {
    _config.preferredQuality = label;
    await _applyQuality(label);
    notifyListeners();
  }

  /// Label of the smallest rendition on offer, used by audio mode.
  String get _lowestQuality {
    final tracks = _player?.betterPlayerAsmsTracks ?? const [];
    final heights = tracks
        .map((t) => t.height ?? 0)
        .where((h) => h > 0)
        .toList()
      ..sort();
    return heights.isEmpty ? SettingsService.autoQuality : '${heights.first}p';
  }

  /// Applies [label] to whatever is loaded now.
  ///
  /// HLS renditions are switched by selecting a track; a progressive source has
  /// separate URLs per quality instead.
  Future<void> _applyQuality(String label) async {
    final player = _player;
    if (player == null) return;

    if (label == SettingsService.autoQuality) {
      // An empty default track hands the choice back to the bitrate ladder.
      if (player.betterPlayerAsmsTracks.isNotEmpty) {
        await player.setTrack(BetterPlayerAsmsTrack.defaultTrack());
      }
      return;
    }

    final wanted = int.tryParse(label.replaceAll(RegExp('[^0-9]'), ''));
    if (wanted != null && player.betterPlayerAsmsTracks.isNotEmpty) {
      // Nearest at or below the request, so asking for 1080p on a video that
      // tops out at 720p plays 720p rather than silently doing nothing.
      final candidates = player.betterPlayerAsmsTracks
          .where((t) => (t.height ?? 0) > 0 && (t.height ?? 0) <= wanted)
          .toList()
        ..sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
      if (candidates.isNotEmpty) {
        await player.setTrack(candidates.first);
        return;
      }
    }

    final url = _sources?.qualities[label];
    if (url != null) await player.setResolution(url);
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

  /// Videos already played, newest last. Gives "previous" something to mean —
  /// a queue alone only ever moves forward.
  final List<VideoBrief> _playHistory = [];

  bool get hasNext => _queue.isNotEmpty;
  bool get hasPrevious => _playHistory.isNotEmpty;

  Future<void> playNext() async {
    if (_queue.isEmpty) return;
    final next = _queue.removeAt(0);
    await play(next, upNext: _queue.toList());
  }

  /// Steps back to the previously played video, pushing the current one to the
  /// front of the queue so going forward again returns to it.
  ///
  /// Restarts the current video instead when it is more than three seconds in —
  /// the behaviour every music player has, and what the button is reached for
  /// most often.
  Future<void> playPrevious() async {
    if (_position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      await _player?.play();
      return;
    }
    if (_playHistory.isEmpty) {
      await seek(Duration.zero);
      return;
    }
    final leaving = _current;
    final previous = _playHistory.removeLast();
    final rest = [?leaving, ..._queue];
    await play(previous, upNext: rest, recordHistory: false);
  }

  void _pushHistory(VideoBrief video) {
    _playHistory
      ..removeWhere((v) => v.id == video.id)
      ..add(video);
    if (_playHistory.length > 50) _playHistory.removeAt(0);
    notifyListeners();
  }

  PlaybackRepeat get repeatMode => _config.repeatMode;

  /// Cycles off → one → all → off, which is how the button reads.
  void cycleRepeatMode() {
    final next = PlaybackRepeat
        .values[(_config.repeatMode.index + 1) % PlaybackRepeat.values.length];
    _config.repeatMode = next;
    _player?.setLooping(next == PlaybackRepeat.one);
    notifyListeners();
  }

  /// Reorders the queue randomly, keeping whatever is playing where it is.
  void shuffleQueue() {
    _queue.shuffle();
    notifyListeners();
  }

  /// Moves a queued video.
  ///
  /// Used with `onReorderItem`, which already accounts for the removal, so
  /// [newIndex] is the final position and needs no adjustment.
  void reorderQueue(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _queue.length) return;
    final video = _queue.removeAt(oldIndex);
    _queue.insert(newIndex.clamp(0, _queue.length), video);
    notifyListeners();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);
    notifyListeners();
  }

  /// Jumps straight to a queued video, dropping everything before it — the
  /// entries you skipped past are not ones you want played next.
  Future<void> playFromQueue(int index) async {
    if (index < 0 || index >= _queue.length) return;
    final video = _queue[index];
    final rest = _queue.skip(index + 1).toList();
    await play(video, upNext: rest);
  }

  /// Decides what follows a finished video: repeat it, advance the queue, or
  /// wrap the queue around.
  Future<void> _onFinished() async {
    switch (_config.repeatMode) {
      case PlaybackRepeat.one:
        await seek(Duration.zero);
        await _player?.play();
      case PlaybackRepeat.all:
        if (_queue.isNotEmpty) {
          // Send the finished video to the back so the queue keeps cycling.
          final finished = _current;
          await playNext();
          if (finished != null) _queue.add(finished);
        } else {
          await seek(Duration.zero);
          await _player?.play();
        }
      case PlaybackRepeat.off:
        _startEndScreen();
    }
  }

  // ---------------------------------------------------------------- end screen

  bool _endScreen = false;
  int _countdown = 0;
  Timer? _countdownTimer;

  /// True once a video has finished and the suggestions are showing.
  bool get showEndScreen => _endScreen;

  /// Seconds left before the next video starts; zero when nothing is counting.
  int get autoplayCountdown => _countdown;

  /// What to offer when a video ends. The watch page falls back to its own
  /// up-next rail when the queue is empty.
  List<VideoBrief> get endScreenSuggestions => _queue.take(4).toList();

  /// Shows the suggestions, and counts down only when there is something to
  /// play next and the user has asked for autoplay. Ending on a still frame
  /// with no explanation is what the countdown replaces.
  void _startEndScreen() {
    _endScreen = true;
    _cancelCountdown();
    if (_config.autoplayNext && hasNext) {
      _countdown = 10;
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        _countdown--;
        if (_countdown <= 0) {
          timer.cancel();
          _countdownTimer = null;
          _endScreen = false;
          unawaited(playNext());
        }
        notifyListeners();
      });
    }
    notifyListeners();
  }

  /// Stops the countdown but leaves the suggestions up, so a cancelled
  /// autoplay still lets you pick something.
  void cancelAutoplay() {
    _cancelCountdown();
    notifyListeners();
  }

  /// Clears the end screen, for replaying or picking a suggestion.
  void dismissEndScreen() {
    _cancelCountdown();
    _endScreen = false;
    notifyListeners();
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _countdown = 0;
  }

  // ------------------------------------------------------------ stats overlay

  bool _showStats = false;
  bool get showStats => _showStats;

  void toggleStats() {
    _showStats = !_showStats;
    notifyListeners();
  }

  /// What YouTube's "Stats for nerds" panel reports, as far as this player
  /// exposes it. Buffer health is the gap between what has downloaded and
  /// where playback is, which is the number worth watching when a stream
  /// stutters.
  Map<String, String> get stats {
    final value = _player?.videoPlayerController?.value;
    final size = value?.size;
    final sources = _sources;

    Duration buffered = Duration.zero;
    for (final range in value?.buffered ?? const []) {
      if (range.end > buffered) buffered = range.end;
    }
    final ahead = buffered - _position;

    return {
      'Video ID': _current?.id ?? '—',
      'Resolution': size == null || size.width == 0
          ? '—'
          : '${size.width.round()}x${size.height.round()}',
      'Quality': _config.preferredQuality,
      'Delivery': _isOffline
          ? 'Downloaded file'
          : (sources?.isHls ?? false)
              ? 'HLS adaptive'
              : 'Progressive MP4',
      'Mode': _config.audioOnly || _droppedVideo ? 'Audio only' : 'Video',
      'Buffer health': ahead.isNegative
          ? '0.0 s'
          : '${(ahead.inMilliseconds / 1000).toStringAsFixed(1)} s',
      'Position': '${clockLabel(_position)} / ${clockLabel(_duration)}',
      'Speed': '${_config.playbackSpeed}x',
      'Volume': '${((value?.volume ?? 1) * 100).round()}%',
    };
  }

  /// Replays the finished video from the start.
  Future<void> replay() async {
    dismissEndScreen();
    await seek(Duration.zero);
    await _player?.play();
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

  // ------------------------------------------------- screen-off audio mode

  /// True while the video track has been dropped because the screen is off.
  bool _droppedVideo = false;
  bool get isVideoDropped => _droppedVideo;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      // `inactive` fires while the app is still allowed to act; `paused` fires
      // once it is already backgrounded, where starting playback is restricted.
      // Swapping on `paused` was too late, which is why background audio
      // stopped rather than continuing.
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        unawaited(_dropVideoTrack());
      case AppLifecycleState.resumed:
        unawaited(_restoreVideoTrack());
      default:
        break;
    }
  }

  /// Drops to the smallest rendition while nothing can be seen.
  ///
  /// Video is many times the data of audio and none of it is being looked at
  /// behind a locked screen.
  ///
  /// This used to swap the source to the bare audio URL, which does not load
  /// at all — AVURLAsset identifies a stream by its path extension and a
  /// googlevideo audio URL has none, so locking the screen tore down working
  /// playback and replaced it with a failure. Selecting a lower rung of the
  /// ladder already loaded costs nearly as little, and playback never stops:
  /// there is no reload, no gap and no position to restore.
  Future<void> _dropVideoTrack() async {
    if (!_config.audioOnlyWhenLocked || _droppedVideo) return;
    if (_config.audioOnly) return; // already at the lowest rung by choice
    final player = _player;
    if (player == null || _current == null) return;
    if (_isOffline) return; // a local file costs no data
    if (player.betterPlayerAsmsTracks.isEmpty) return; // nothing to step down
    if (!(player.isPlaying() ?? false)) return;

    _droppedVideo = true;
    await _applyQuality(_lowestQuality);
  }

  /// Puts the chosen quality back on unlock. Also a track selection, so the
  /// picture returns without interrupting the audio.
  Future<void> _restoreVideoTrack() async {
    if (!_droppedVideo) return;
    _droppedVideo = false;
    if (_player == null || _current == null) return;
    await _applyQuality(_config.preferredQuality);
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
        unawaited(_onFinished());
      case BetterPlayerEventType.exception:
        // Carry the platform's own description through. A generic message here
        // meant a device failure could not be told apart from an expired link,
        // and there is no console to read on someone else's phone.
        final detail = event.parameters?['exception']?.toString();
        _error = detail == null || detail.isEmpty
            ? 'Playback failed. Reopen the video to try again.'
            : 'Playback failed: $detail';
        notifyListeners();
      // Android's notification and lock-screen skip buttons, delivered by the
      // vendored plugin. iOS routes the same taps through AppDelegate's
      // MPRemoteCommandCenter handlers instead.
      case BetterPlayerEventType.skipToNext:
        unawaited(playNext());
      case BetterPlayerEventType.skipToPrevious:
        unawaited(playPrevious());
      // The ladder is parsed by the time the player initialises, so this
      // usually lands well before the polling loop notices.
      case BetterPlayerEventType.initialized:
        unawaited(_applyPreferredQualityWhenReady());
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
    final wasPlaying = _playing;
    final hadDuration = _duration;
    if (value.duration != null && value.duration! > Duration.zero) {
      _duration = value.duration!;
    }
    _playing = value.isPlaying;
    _persistPosition();

    final second = Duration(seconds: _position.inSeconds);
    if (_lastNotified != second) {
      _lastNotified = second;
      ticker.value = second;
    }

    // A full rebuild only for the things that change the page, not the clock.
    if (wasPlaying != _playing || hadDuration != _duration) notifyListeners();
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
    WidgetsBinding.instance.removeObserver(this);
    _cancelSleepTimer();
    _cancelCountdown();
    _player?.videoPlayerController?.removeListener(_onValueChanged);
    _player?.removeEventsListener(_onPlayerEvent);
    _player?.dispose(forceDispose: true);
    ticker.dispose();
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
