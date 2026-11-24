import 'dart:async';
import 'dart:io';
import 'dart:math' show Random;

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, debugPrint, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/chapters.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../data/battery_service.dart';
import '../data/data_usage_service.dart';
import '../data/db.dart';
import '../data/kids_guard.dart';
import '../data/models.dart';
import '../data/network_service.dart';
import '../data/settings.dart';
import '../data/sponsorblock_client.dart';
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
  /// [kidsGuard], [batteryService], [networkService] and [dataUsage] are
  /// optional so the controller keeps working — exactly as it did before they
  /// existed — when they have not been wired up yet. Every use of them is
  /// null-guarded rather than assumed, because a missing battery reading or
  /// connectivity result must never be able to stop playback.
  ///
  /// The two `…Service` names are spelt out rather than shortened to match
  /// their fields, which would trip prefer_initializing_formals on a named
  /// parameter that cannot be private.
  PlaybackController({
    required YtRepository repository,
    required AppDatabase database,
    required SettingsService settings,
    KidsGuard? kidsGuard,
    BatteryService? batteryService,
    NetworkService? networkService,
    DataUsageService? dataUsage,
  }) : _repo = repository,
       _db = database,
       _config = settings,
       _kids = kidsGuard,
       _battery = batteryService,
       _network = networkService,
       _usage = dataUsage {
    // Own the lifecycle rather than letting better_player have it: its handling
    // is disabled so background audio survives, which leaves the screen-off
    // transition ours to act on.
    WidgetsBinding.instance.addObserver(this);
  }

  final YtRepository _repo;
  final AppDatabase _db;
  final SettingsService _config;
  final KidsGuard? _kids;
  final BatteryService? _battery;
  final NetworkService? _network;
  final DataUsageService? _usage;
  final SponsorBlockClient _sponsorBlock = SponsorBlockClient();

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
    // Both sources, merged. Returning the ladder *or* the muxed list meant a
    // video that has both showed only one of them, which is why the picker
    // looked short of options.
    final labels = <String>{
      for (final h in _ladderHeights) '${h}p',
      ...?_sources?.qualities.keys,
    };
    final sorted = labels.toList()
      ..sort((a, b) {
        int height(String l) => int.tryParse(l.replaceAll(RegExp('[^0-9]'), '')) ?? 0;
        return height(b).compareTo(height(a));
      });
    return sorted;
  }

  /// Caption tracks the current video offers, read off the HLS manifest.
  ///
  /// better_player already parses these — `useAsmsSubtitles` is on for every
  /// ladder source — but nothing ever offered them, so a video with subtitles
  /// played without any way to turn them on.
  ///
  /// When the manifest has none — most videos, since few get a YouTube HLS
  /// ladder now — the tracks fetched by [loadCaptions] are offered instead.
  List<BetterPlayerSubtitlesSource> get captionTracks {
    final fromManifest = _player?.betterPlayerSubtitlesSourceList
            .where((s) => s.type != BetterPlayerSubtitlesSourceType.none)
            .toList() ??
        const <BetterPlayerSubtitlesSource>[];
    if (fromManifest.isNotEmpty) return fromManifest;
    return _fetchedCaptionsFor == _current?.id ? _fetchedCaptions : const [];
  }

  List<BetterPlayerSubtitlesSource> _fetchedCaptions = const [];
  String? _fetchedCaptionsFor;
  bool _captionsLoading = false;

  /// True while [loadCaptions] is asking YouTube for the track list.
  bool get captionsLoading => _captionsLoading;

  /// Fetches the current video's caption tracks, once, when the captions
  /// sheet is opened — not for every video, since most are never asked.
  Future<void> loadCaptions() async {
    final video = _current;
    if (video == null || _isOffline) return;
    if (_fetchedCaptionsFor == video.id || _captionsLoading) return;
    _captionsLoading = true;
    notifyListeners();
    try {
      final tracks = await _repo.captionTracks(video.id);
      if (_current?.id != video.id) return;
      _fetchedCaptions = [
        for (final t in tracks)
          BetterPlayerSubtitlesSource(
            type: BetterPlayerSubtitlesSourceType.network,
            name: t.name,
            urls: [t.url],
          ),
      ];
      _fetchedCaptionsFor = video.id;
    } finally {
      _captionsLoading = false;
      notifyListeners();
    }
  }

  /// The caption track showing now, or null when they are off.
  BetterPlayerSubtitlesSource? get activeCaptions {
    final selected = _player?.betterPlayerSubtitlesSource;
    if (selected == null ||
        selected.type == BetterPlayerSubtitlesSourceType.none) {
      return null;
    }
    return selected;
  }

  /// Turns captions on, or off when [track] is null.
  Future<void> setCaptions(BetterPlayerSubtitlesSource? track) async {
    final player = _player;
    if (player == null) return;
    var source = track ??
        BetterPlayerSubtitlesSource(
          type: BetterPlayerSubtitlesSourceType.none,
        );
    // A track fetched from YouTube's caption manifest is downloaded and
    // cleaned here rather than handed to the player as a URL: the player's
    // parser cannot read YouTube's WebVTT as served (see captions.dart), and
    // failing on it silently showed no captions at all.
    if (track != null && _fetchedCaptions.contains(track)) {
      final url = track.urls?.firstOrNull;
      final content = url == null ? null : await _repo.captionVtt(url);
      if (content == null) {
        debugPrint('AI BIT: caption track "${track.name}" could not be read');
        return;
      }
      source = BetterPlayerSubtitlesSource(
        type: BetterPlayerSubtitlesSourceType.memory,
        name: track.name,
        content: content,
      );
    }
    await player.setupSubtitleSource(source);
    notifyListeners();
  }

  /// Alternate audio tracks (dubs), when the HLS manifest carries them — one
  /// per distinct name.
  ///
  /// YouTube's ladder lists the same audio once per bitrate group, so a video
  /// with no dubs at all reported two tracks both called "Default" and the
  /// More sheet offered a picker with two identical rows. Only tracks that a
  /// person could tell apart are kept.
  List<BetterPlayerAsmsAudioTrack> get audioTracks =>
      distinctAudioTracks(_player?.betterPlayerAsmsAudioTracks ?? const []);

  /// The first track for each distinct label (or language), in order.
  static List<BetterPlayerAsmsAudioTrack> distinctAudioTracks(
    List<BetterPlayerAsmsAudioTrack> tracks,
  ) {
    final seen = <String>{};
    return [
      for (final t in tracks)
        if (seen.add((t.label ?? t.language ?? '').trim().toLowerCase())) t,
    ];
  }

  BetterPlayerAsmsAudioTrack? get activeAudioTrack =>
      _player?.betterPlayerAsmsAudioTrack;

  /// Switches to a dub / alternate audio track.
  void setAudioTrack(BetterPlayerAsmsAudioTrack track) {
    _player?.setAudioTrack(track);
    notifyListeners();
  }

  /// The rendition actually playing, or null while on Auto.
  String? get activeQuality {
    final height = _player?.betterPlayerAsmsTrack?.height ?? 0;
    if (height > 0) return '${height}p';

    // A progressive source has no track to read, so the rendition is whichever
    // label the current URL belongs to. Without this the picker never marked
    // anything as playing on a video with no HLS ladder.
    final url = _player?.betterPlayerDataSource?.url;
    final qualities = _sources?.qualities ?? const <String, String>{};
    for (final entry in qualities.entries) {
      if (entry.value == url) return entry.key;
    }
    return null;
  }

  bool _isOffline = false;

  /// True when the current video is coming from a downloaded file.
  bool get isOffline => _isOffline;

  /// True when the current video is playing as audio because YouTube served no
  /// combined video+audio stream for it.
  bool get isAudioFallback => _sources?.videoUnavailable ?? false;

  /// True whenever there is no picture — the user asked for audio only, this
  /// video started on mobile data with "audio only on mobile" set, or we had to
  /// fall back to it.
  bool get isAudioOnly =>
      _config.audioOnly ||
      _sessionAudio ||
      _mobileAudio ||
      isAudioFallback ||
      _offlineAudio;

  /// True when the permanent Settings switch is why there is no picture, so
  /// the player can say so instead of leaving it a mystery.
  bool get audioOnlyFromSettings => _config.audioOnly;

  /// Audio only, switched on from the watch page.
  ///
  /// Not the Settings default. The watch page used to write the global
  /// setting, so one tap meant sound-only for every video from then on, across
  /// restarts — and turning the screen back on never brought the picture back,
  /// which is what people expect it to do. This lasts until the app is left
  /// and returned to (screen off and on, or another app and back), then the
  /// picture returns by itself.
  bool _sessionAudio = false;

  /// The app was left while [_sessionAudio] was on; coming back ends it.
  bool _sessionAudioLeft = false;

  /// The switch on the watch page. Instant: no reload, no gap, no position
  /// lost — audio mode plays the same stream with the picture covered, so
  /// there is nothing to rebuild. Turning it OFF clears every "no picture"
  /// reason the user can override, the Settings default included, because
  /// someone who flips the switch to see the video means it.
  Future<void> setAudioOnly(bool on) async {
    _sessionAudio = on;
    _sessionAudioLeft = false;
    if (!on) {
      if (_config.audioOnly) _config.audioOnly = false;
      _mobileAudio = false;
    }
    await refreshAudioMode();
  }

  /// Re-applies the rendition audio mode calls for after it changed — the
  /// smallest rung while nothing is shown, the normal choice once it is.
  /// A track selection on a ladder; on a single progressive stream there is
  /// nothing to change, only the cover to show or hide.
  Future<void> refreshAudioMode() async {
    _qualityToken++; // any pending "apply when ready" is now stale
    notifyListeners();
    _syncWakelock();
    final player = _player;
    if (player == null || _current == null || _isOffline) return;
    final adaptive =
        player.betterPlayerAsmsTracks.isNotEmpty || (_sources?.isDash ?? false);
    if (!adaptive || _ladderHeights.isEmpty) return;
    await _applyQuality(
      isAudioOnly
          ? _lowestQuality
          : qualityForConditions(
              ladder: [for (final h in _ladderHeights) '${h}p'],
              preferred: _config.preferredQuality,
              lowest: _config.dataSaver || _mobileSaving,
              stepDown: _batterySaving,
            ),
    );
    notifyListeners();
  }

  /// True while a sound-only download is what is playing. It has no picture,
  /// so the surface showed a black box with a spinner that never stopped;
  /// treating it as audio mode gives it the artwork view instead.
  bool _offlineAudio = false;
  bool get isOfflineAudio => _offlineAudio;

  // ---------------------------------------------------- saving conditions
  //
  // Battery and network are read **once per video**, at load, and held for its
  // whole length. Acting on them the moment they change would mean a mid-video
  // rendition switch, and on a progressive source that is a full data-source
  // rebuild: the position is lost and the outgoing player reports STATE_ENDED,
  // which the end screen then believes. So a battery going flat or Wi-Fi
  // dropping takes effect on the *next* video, never on the one playing.

  /// Battery saver is on and the battery was low when this video loaded.
  bool _batterySaving = false;

  /// Mobile data saver is on and this video loaded on a cellular route.
  bool _mobileSaving = false;

  /// Audio-only-on-mobile is on and this video loaded on a cellular route.
  bool _mobileAudio = false;

  /// True while the current video is being kept small to spare the battery.
  bool get isBatterySaving => _batterySaving;

  /// True while the current video is being kept small to spare mobile data —
  /// either the lowest rendition or the audio-only path.
  bool get isMobileSaving => _mobileSaving || _mobileAudio;

  /// Reads the saving conditions for the video about to load. Offline playback
  /// clears them in [_play] once the file is known: a local file spends neither
  /// mobile data nor a meaningful amount of radio power.
  void _captureSavingConditions() {
    _batterySaving = _config.batterySaver && (_battery?.isLow ?? false);
    final onMobile = _network?.isMobile ?? false;
    _mobileSaving = onMobile && _config.mobileDataSaver;
    _mobileAudio = onMobile && _config.mobileAudioOnly;
  }

  /// The rendition to open a video at, given its ladder and the conditions in
  /// force. Pure and static so the rule can be tested without a player.
  ///
  /// [ladder] is the label list off the manifest in any order, [preferred] the
  /// saved default (or [SettingsService.autoQuality]), [lowest] the "spend as
  /// little as possible" modes — audio only, Data saver, mobile data saver,
  /// screen off — and [stepDown] the softer battery-saver rule, which gives up
  /// one rung rather than dropping to the floor.
  static String qualityForConditions({
    required List<String> ladder,
    required String preferred,
    required bool lowest,
    required bool stepDown,
  }) {
    int height(String label) =>
        int.tryParse(label.replaceAll(RegExp('[^0-9]'), '')) ?? 0;

    final rungs = ladder.where((l) => height(l) > 0).toList()
      ..sort((a, b) => height(a).compareTo(height(b)));
    // Nothing numbered to choose from: hand back Auto for the saving modes, so
    // the caller leaves the ladder alone rather than applying a label that
    // means nothing here.
    if (rungs.isEmpty) return lowest ? SettingsService.autoQuality : preferred;
    if (lowest) return rungs.first;
    if (!stepDown) return preferred;

    // One rung below whatever would otherwise have played. Auto means the
    // player was free to climb to the top, so the step is measured from there.
    final ceiling = preferred == SettingsService.autoQuality
        ? height(rungs.last)
        : height(preferred);
    // Measured from the rung that would really have played, not from the
    // request: _applyQuality already snaps a preference of 1080p down to the
    // 720p a video actually offers, so stepping from 1080p would have handed
    // back that same 720p and saved nothing.
    final reachable = rungs.where((l) => height(l) <= ceiling);
    final effective = reachable.isEmpty
        ? height(rungs.first)
        : height(reachable.last);
    final below = rungs.where((l) => height(l) < effective);
    return below.isEmpty ? rungs.first : below.last;
  }

  bool _loading = false;
  bool get isLoading => _loading;

  /// True while the current video's source is being rebuilt in place — the
  /// HD upgrade landing, an audio-only toggle, a progressive quality change.
  /// The same native player is reused, so the surface should stay up rather
  /// than drop to a loading placeholder mid-video.
  bool get isRebuilding => _switchingQuality;

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
    onInterruptionBegan: _pauseForInterruption,
    onInterruptionEnded: _resumeAfterInterruption,
    // Headphones out or Bluetooth gone: pause and stay paused. Resuming here
    // would play out loud, which is never what was wanted.
    onOutputLost: () {
      _forgetInterruption();
      unawaited(_player?.pause());
      _playing = false;
      notifyListeners();
    },
  );

  /// True when playback was stopped by the system rather than by the user, so
  /// only that case resumes on its own.
  bool _pausedByInterruption = false;

  void _pauseForInterruption() {
    if (!(_player?.isPlaying() ?? false)) return;
    _pausedByInterruption = true;
    _persistPosition(force: true);
    unawaited(_player?.pause());
    _playing = false;
    notifyListeners();
  }

  void _resumeAfterInterruption() {
    if (!_pausedByInterruption) return;
    _pausedByInterruption = false;
    unawaited(_player?.play());
    _playing = true;
    notifyListeners();
  }

  /// Clears the flag without resuming, for the cases that must stay paused.
  void _forgetInterruption() => _pausedByInterruption = false;

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
    if (_sleepAtEnd) {
      final left = _duration - _position;
      return left.isNegative ? Duration.zero : left;
    }
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
  /// Serialises loads and identifies the newest one.
  ///
  /// Every toggle of Audio only reloads the video, and a second toggle before
  /// the first had finished ran two setupDataSource calls against the same
  /// native player at once. One of them never completed, so the spinner stayed
  /// up while the earlier source carried on playing — video "stuck loading"
  /// with audio still running. Loads now queue, and a load that has been
  /// superseded stops rather than fighting the newer one.
  int _playToken = 0;
  Future<void>? _pendingLoad;

  /// The longest a new load waits behind an older one, and the longest an
  /// attach waits for the native player to report the source ready.
  static const _loadWaitLimit = Duration(seconds: 15);

  Future<void> play(
    VideoBrief video, {
    List<VideoBrief> upNext = const [],
    bool recordHistory = true,
    bool rebuild = false,
  }) async {
    // Supersede whatever is loading now, before waiting for it: the older load
    // checks this token after each step and stands down, instead of finishing
    // a resolve and an attach for a video nobody wants any more.
    _playToken++;
    // Wait for any load already running, so two never touch the player at once
    // — but not forever. A load stuck on a dead connection used to hold every
    // later tap behind it, so no video at all would start until the app was
    // restarted.
    final previous = _pendingLoad;
    if (previous != null) {
      try {
        await previous.timeout(_loadWaitLimit);
      } catch (_) {
        // Its own caller reported it, or it is stuck; either way this one
        // carries on.
      }
    }
    final completer = Completer<void>();
    _pendingLoad = completer.future;
    try {
      await _play(
        video,
        upNext: upNext,
        recordHistory: recordHistory,
        rebuild: rebuild,
      );
    } finally {
      if (identical(_pendingLoad, completer.future)) _pendingLoad = null;
      // Whatever happened, the spinner comes down. A load that returned early
      // used to leave it up forever with the previous source still playing.
      if (_loading) {
        _loading = false;
        notifyListeners();
      }
      completer.complete();
    }
  }

  /// [rebuild] re-creates the source for the video that is already current —
  /// an audio-only toggle, or the HD upgrade landing — so it skips the
  /// "same video, just resume" shortcut and records nothing: the watch row
  /// exists and the sitting already counted this video.
  Future<void> _play(
    VideoBrief video, {
    List<VideoBrief> upNext = const [],
    bool recordHistory = true,
    bool rebuild = false,
  }) async {
    final token = ++_playToken;
    if (!rebuild &&
        _current?.id == video.id &&
        _player != null &&
        _error == null) {
      // Re-tapping the currently loaded video should just resume it.
      await _player!.play();
      return;
    }

    final leaving = _current;
    if (recordHistory && leaving != null && leaving.id != video.id) {
      _pushHistory(leaving);
    }

    // Bank what the outgoing video was owed before _current moves on, or its
    // last partial batch would be charged to the video replacing it.
    _flushWatchTime();
    _watchMillis = 0;
    _watchTickAt = null;
    _captureSavingConditions();

    // Going from one video to another is the strongest edge the local
    // co-visitation graph can hold: a related list is what YouTube believes
    // about everybody, while this is what this person actually did. Recorded
    // before _current moves on, and never in incognito, where the point of the
    // mode is that nothing about this sequence is kept.
    final previous = _current;
    if (previous != null && previous.id != video.id && !_config.incognito) {
      unawaited(
        _db.recordWatchTransition(previous.id, video.id).catchError((Object e) {
          debugPrint('AI BIT: watch transition not recorded - $e');
        }),
      );
    }

    // From here until _attach has swapped the native source, the outgoing
    // player is still ticking and its listener is still attached. Those ticks
    // must not be read as the new video's: they were being saved under the new
    // id, so the next video resumed from wherever the previous one had got to
    // — "starts from the middle", and on a shorter video "ends at once".
    _awaitingSource = true;
    _current = video;
    // A deliberate reopen earns a fresh automatic retry; only a second failure
    // without leaving the video is treated as genuine.
    _recoveredVideoId = null;
    // Recorded for the session-aware "up next" ordering. Deduplicated so a
    // replay does not weigh twice, and capped because only the recent tail of
    // a sitting is informative.
    _sessionPlayed
      ..removeWhere((v) => v.id == video.id)
      ..add(video);
    if (_sessionPlayed.length > 30) _sessionPlayed.removeAt(0);
    _queue
      ..clear()
      ..addAll(upNext.where((v) => v.id != video.id));
    // An explicit list (a playlist, a queue the user built) is followed as
    // given; no list means the queue will be YouTube's suggestions for this
    // video, filled in by _fillQueueIfEmpty.
    if (!rebuild) _queueIsSuggested = upNext.isEmpty;
    // A new queue has no original order to restore.
    _unshuffledQueue = null;
    _loading = true;
    _error = null;
    _position = Duration.zero;
    _duration = video.duration ?? Duration.zero;
    notifyListeners();

    // Incognito records nothing at all: no history row here and no resume
    // position later (see _persistPosition). Losing "carry on where you left
    // off" is the deliberate price of the mode — a private session that still
    // remembered where it got to would not be private.
    if (!_config.incognito && !rebuild) {
      // Mark what was watched in Kids mode, so it lands in kids history rather
      // than the normal videos/shorts lists.
      unawaited(
        _db.recordWatch(_config.kidsMode ? video.asKids() : video),
      );
    }
    if (!rebuild) _loadSponsorSegments(video.id);

    // The browser preview has no native player plugin. Stop after recording
    // the selection so every screen still renders and can be reviewed.
    if (kIsWeb) {
      _awaitingSource = false;
      _loading = false;
      _duration = video.duration ?? Duration.zero;
      notifyListeners();
      return;
    }

    final startTimer = Stopwatch()..start();
    try {
      // A finished download always wins: it plays instantly, costs no data and
      // works with no network at all.
      final offlinePath = await _offlineFile(video.id);
      debugPrint('AI BIT start: ${video.id} offline check '
          '${startTimer.elapsedMilliseconds}ms');
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
      _offlineAudio =
          offlinePath != null && await _db.isAudioDownload(video.id);
      if (_isOffline) {
        // A file already on disk costs no mobile data and no download radio
        // time, so there is nothing to save by degrading it.
        _batterySaving = false;
        _mobileSaving = false;
        _mobileAudio = false;
      }
      if (token != _playToken) return;
      debugPrint('AI BIT start: ${video.id} sources ready '
          '${startTimer.elapsedMilliseconds}ms');
      final resumeAt = await _db.resumePosition(video.id);
      // Closed or replaced while the position was read.
      if (token != _playToken) return;
      await _attach(video, sources, startAt: resumeAt);
      debugPrint('AI BIT start: ${video.id} player attached '
          '${startTimer.elapsedMilliseconds}ms');
      if (token != _playToken) {
        // Closed with the mini player's X while the source was being set up.
        // stop() has already torn down the player it saw, but an attach that
        // had to create one made it after that, and left alone it would play
        // with no bar on screen to stop it.
        if (_current == null) _discardOrphanPlayer();
        return;
      }
      _followUpgrade(video, sources, token);
      _loading = false;
      // Opening a video after the day's Kids allowance is gone loads it and
      // stops, rather than refusing: the controller never puts up a dialog, it
      // exposes kidsLimitReached and lets the UI say so.
      _enforceKidsLimit();
      notifyListeners();
      if (!rebuild) unawaited(_fillQueueIfEmpty(video));
      // After the attach, so warming the next video never competes with
      // starting this one. A queue filled later warms through replaceQueue.
      _warmNext();
    } catch (e) {
      if (token != _playToken) return;
      _awaitingSource = false;
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

  /// True from the moment [_current] moves to a new video until [_attach] has
  /// handed the native player its source. The position listener ignores every
  /// tick in that window, because they belong to the video being left.
  bool _awaitingSource = false;

  Future<void> _attach(
    VideoBrief video,
    PlaybackSources sources, {
    Duration? startAt,
  }) async {
    final dataSource = _dataSource(
      video,
      _preferredUrl(sources),
      isHls: sources.isHls,
      isDash: sources.isDash,
    );

    if (_player == null) {
      _player = BetterPlayerController(_configuration(startAt: startAt))
        ..setBetterPlayerGlobalKey(playerKey)
        ..addEventsListener(_onPlayerEvent);
      await _setup(_player!, dataSource);
      unawaited(_syncAutomaticPip());
    } else {
      final player = _player!;
      await _setup(player, dataSource);
      // stop() may have run while the source was being set up.
      if (!identical(_player, player)) return;
      if (startAt != null) await player.seekTo(startAt);
      await player.play();
    }
    final player = _player;
    if (player == null) return;

    player.videoPlayerController?.removeListener(_onValueChanged);
    player.videoPlayerController?.addListener(_onValueChanged);
    // The source now belongs to this video; its ticks count again.
    _awaitingSource = false;
    // Prefer a speed remembered for this channel, falling back to the global
    // default. Applied here so it takes effect the moment the video loads.
    final channelSpeed = _config.speedForChannel(video.channelId);
    await player.setSpeed(channelSpeed ?? _config.playbackSpeed);

    _cancelCountdown();
    _endScreen = false;
    // A loop and chapters belong to one video; a new source starts without.
    _loopA = null;
    _loopB = null;
    _chapters = const [];

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

  /// Hands [player] a new source, waiting at most [_loadWaitLimit] for it.
  ///
  /// `setupDataSource` completes only when the native player reports the
  /// source ready, which on a connection that has quietly died is never.
  /// Every later load queued behind that one, so a single stalled video
  /// stopped every other video from starting — "some videos do not play"
  /// until the app was killed. Past the limit the attach carries on: the
  /// player keeps trying in the background and reports buffering, an error or
  /// playback through its events as usual, so nothing is lost by not waiting.
  Future<void> _setup(
    BetterPlayerController player,
    BetterPlayerDataSource source,
  ) async {
    await player.setupDataSource(source).timeout(
      _loadWaitLimit,
      onTimeout: () {
        debugPrint('AI BIT: source still not ready after '
            '${_loadWaitLimit.inSeconds}s — carrying on without it');
      },
    );
  }

  /// Builds the data source for one URL of [video]. Shared by the initial load
  /// and by the screen-off track swap, so both stay configured identically.
  BetterPlayerDataSource _dataSource(
    VideoBrief video,
    String url, {
    required bool isHls,
    bool isDash = false,
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
      videoFormat: isHls
          ? BetterPlayerVideoFormat.hls
          : (isDash ? BetterPlayerVideoFormat.dash : null),
      // Only reaches the cache manager on iOS, which is bypassed here — kept
      // because Android's ExoPlayer does use it to pick a extractor for a URL
      // with no file extension.
      // Describe the URL that is actually being loaded, not the mode. Audio
      // mode now stays on the video file and simply hides the picture, so
      // claiming 'm4a' would have told ExoPlayer to expect the wrong container.
      videoExtension: isHls || isDash
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
      // Start playing sooner. ExoPlayer's default waits for 3s of video to
      // buffer before it begins; 1s is enough to start smoothly and cuts the
      // spinner-before-play noticeably. minBuffer/maxBuffer stay large so once
      // playing it still buffers well ahead. Android-only — iOS AVPlayer manages
      // its own start buffer.
      bufferingConfiguration: const BetterPlayerBufferingConfiguration(
        minBufferMs: 20000,
        maxBufferMs: 60000,
        bufferForPlaybackMs: 1000,
        bufferForPlaybackAfterRebufferMs: 3000,
      ),
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
    // A generated DASH manifest needs no waiting at all: the ladder came from
    // the document the app wrote, not from the player's parser, so it is known
    // before the first frame.
    for (var attempt = 0; attempt < 30; attempt++) {
      if (token != _qualityToken) return;
      if ((_player?.betterPlayerAsmsTracks.isNotEmpty ?? false) ||
          ((_sources?.isDash ?? false) && _ladderHeights.isNotEmpty)) {
        // Worked out here, inside the loop, and not before it.
        //
        // Audio mode picks the smallest rendition, which is read off the track
        // list — and that list is empty until the manifest has been parsed.
        // Computing it up front therefore always returned "Auto" and returned
        // early, so audio-only streamed the full-size video behind the artwork
        // and saved no data at all.
        final wanted = qualityForConditions(
          ladder: [for (final h in _ladderHeights) '${h}p'],
          preferred: _config.preferredQuality,
          lowest: isAudioOnly ||
              _droppedVideo ||
              _config.dataSaver ||
              _mobileSaving,
          stepDown: _batterySaving,
        );
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
    // Audio-only-on-mobile takes the same path for the same reason: it is the
    // existing audio mode, not a second one.
    if (_config.audioOnly || _sessionAudio || _mobileAudio) return sources.url;

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
        // Inert in the vendored copy, and left here only to say so: the
        // plugin no longer touches the wakelock at all (PATCHES.md #23).
        // _syncWakelock owns it, because a flag read once on a fullscreen
        // route change cannot describe a player that outlives every widget.
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
      // Restart a finished video instead of sitting on the last frame: neither
      // AVPlayer nor ExoPlayer rewinds on play() when already at the end, so
      // tapping play after a video completed did nothing. Seek to zero first.
      if (_duration > Duration.zero &&
          _position >= _duration - const Duration(milliseconds: 800)) {
        await player.seekTo(Duration.zero);
        if (_endScreen) dismissEndScreen();
      }
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
    final channel = _current?.channelId;
    if (channel != null) _config.setSpeedForChannel(channel, value);
    await _player?.setSpeed(value);
    notifyListeners();
  }

  /// Switches rendition, and remembers the choice so every later video opens
  /// at the same quality rather than reverting to Auto.
  /// Whether a `finished` event reflects the video actually running out.
  ///
  /// Rebuilding a data source — which is how the plugin changes quality on a
  /// progressive stream — makes the outgoing player report that it ended. Taken
  /// at face value that put the end screen over a video which had just
  /// restarted from zero. A real finish lands within a few seconds of the
  /// duration; anything earlier is the teardown talking.
  ///
  /// An unknown duration is treated as genuine, since there is nothing to
  /// compare against and suppressing it would strand the end of the video.
  static bool isGenuineFinish({
    required Duration position,
    required Duration duration,
  }) {
    if (duration <= Duration.zero) return true;
    return position >= duration - const Duration(seconds: 5);
  }

  /// Whether switching to HD is still worth a rebuild at [position].
  ///
  /// Not in the last half-minute: the rebuild costs a visible reload and, with
  /// the outgoing player's STATE_ENDED suppressed as teardown noise, an
  /// upgrade landing there once stranded the video on its last frame with no
  /// end screen and no autoplay. An unknown duration is treated as worthwhile,
  /// since there is nothing to say the end is near.
  static bool upgradeWorthwhile({
    required Duration position,
    required Duration duration,
  }) {
    if (duration <= Duration.zero) return true;
    return duration - position >= const Duration(seconds: 30);
  }

  /// True while a deliberate quality change is tearing the source down, so the
  /// events that come out of it are not mistaken for the video ending.
  bool _switchingQuality = false;

  Future<void> setQuality(String label) async {
    _config.preferredQuality = label;
    final resumeAt = _position;
    final wasPlaying = _player?.isPlaying() ?? false;
    _switchingQuality = true;
    try {
      await _applyQuality(label);
      // setResolution restores the position itself, but a track switch on the
      // ladder does not move it and a failed switch can land at zero. Putting
      // it back is cheap and covers both.
      if (resumeAt > const Duration(seconds: 3)) {
        await _player?.seekTo(resumeAt);
        if (wasPlaying) await _player?.play();
      }
    } finally {
      _switchingQuality = false;
    }
    notifyListeners();
  }

  /// Heights the loaded source can play, smallest first.
  ///
  /// Two sources, because the two adaptive formats report differently. For HLS
  /// `better_player` parses the ladder and exposes it as ASMS tracks. For a
  /// generated DASH manifest it never will — its ASMS `parse` hands every
  /// manifest to the HLS parser whatever the format — so the ladder comes from
  /// `PlaybackSources.ladder`, which the app filled in when it *built* that
  /// manifest. Nothing has to be parsed back out of a document we wrote.
  List<int> get _ladderHeights {
    final tracks = _player?.betterPlayerAsmsTracks ?? const [];
    if (tracks.isNotEmpty) {
      return tracks
          .map((t) => t.height ?? 0)
          .where((h) => h > 0)
          .toSet()
          .toList()
        ..sort();
    }
    return (_sources?.ladder ?? const [])
        .map((l) => int.tryParse(l.replaceAll(RegExp('[^0-9]'), '')) ?? 0)
        .where((h) => h > 0)
        .toSet()
        .toList()
      ..sort();
  }

  /// Label of the smallest rendition on offer, used by audio mode.
  String get _lowestQuality {
    final heights = _ladderHeights;
    return heights.isEmpty ? SettingsService.autoQuality : '${heights.first}p';
  }

  /// Caps the ladder at [height] on an adaptive source.
  ///
  /// `setTrack` is only ever `setMaxVideoSize(width, height)` plus
  /// `setMaxVideoBitrate` on ExoPlayer's track selector, so it works on a DASH
  /// source exactly as well as on an HLS one — it never looks at the manifest.
  /// The width is deliberately a number nothing can exceed rather than a
  /// guessed 16:9 companion: ExoPlayer drops a track that breaches *either*
  /// bound, and a portrait video at 1080p is 608 wide, so pairing 1080 with a
  /// computed 1920 would be fine while pairing it with a computed 607 would
  /// exclude the very rung being asked for. The request is "no taller than
  /// this", so only the height is constrained.
  Future<void> _capHeight(BetterPlayerController player, int height) =>
      player.setTrack(BetterPlayerAsmsTrack('', 100000, height, 0, 0, '', ''));

  /// Applies [label] to whatever is loaded now.
  ///
  /// HLS renditions are switched by selecting a track; a progressive source has
  /// separate URLs per quality instead.
  Future<void> _applyQuality(String label) async {
    final player = _player;
    if (player == null) return;

    final isAdaptive =
        player.betterPlayerAsmsTracks.isNotEmpty || (_sources?.isDash ?? false);

    if (label == SettingsService.autoQuality) {
      // An empty default track hands the choice back to the bitrate ladder.
      if (isAdaptive) {
        await player.setTrack(BetterPlayerAsmsTrack.defaultTrack());
      }
      return;
    }

    final wanted = int.tryParse(label.replaceAll(RegExp('[^0-9]'), ''));
    if (wanted != null && isAdaptive) {
      // Nearest at or below the request, so asking for 1080p on a video that
      // tops out at 720p plays 720p rather than silently doing nothing.
      final at = _ladderHeights.where((h) => h <= wanted).toList();
      if (at.isNotEmpty) {
        await _capHeight(player, at.last);
        return;
      }
      // Asking for less than the smallest rung: take the smallest rather than
      // leaving the ladder uncapped, which is what audio mode depends on.
      if (_ladderHeights.isNotEmpty) {
        await _capHeight(player, _ladderHeights.first);
        return;
      }
    }

    // A label with no number in it means nothing here; the Auto case above has
    // already been handled.
    if (wanted == null) return;

    // Progressive sources: nearest at or below, the same rule the ladder uses.
    // An exact-label lookup meant a preference of 1080p did nothing at all on a
    // video whose best muxed rendition is 360p, rather than playing the 360p.
    final available = _sources?.qualities ?? const <String, String>{};
    if (available.isEmpty) return;

    int height(String l) => int.tryParse(l.replaceAll(RegExp('[^0-9]'), '')) ?? 0;
    final candidates = available.entries
        .where((e) => height(e.key) > 0 && height(e.key) <= wanted)
        .toList()
      ..sort((a, b) => height(b.key).compareTo(height(a.key)));

    // Nothing small enough: take the smallest there is rather than ignoring
    // the request entirely.
    final chosen = candidates.isNotEmpty
        ? candidates.first
        : (available.entries.toList()
              ..sort((a, b) => height(a.key).compareTo(height(b.key))))
            .first;

    if (chosen.value != player.betterPlayerDataSource?.url) {
      await player.setResolution(chosen.value);
    }
  }

  /// Which video the last automatic recovery was spent on.
  ///
  /// Scoped to the video rather than a plain bool so that moving on and coming
  /// back gets a fresh attempt, while a stream that is genuinely broken cannot
  /// loop: the second failure for the same video is reported.
  String? _recoveredVideoId;

  /// One automatic retry when the native player throws.
  ///
  /// "Sometimes a video just fails" was reported with no pattern, and the
  /// pattern is that a googlevideo URL is perishable in more ways than one.
  /// It carries an expiry stamp; it can be refused for an address that has
  /// since changed network; the generated DASH manifest it points at lives in
  /// the OS cache directory, which the system may reclaim at any moment; and
  /// an HLS ladder fetched hours ago can simply stop serving. All of those
  /// arrive here as one opaque exception from the platform, and all of them
  /// have the same cure — ask YouTube again, skipping the cache, and carry on
  /// from where the video had got to.
  ///
  /// Before this, the only recovery offered was a sentence asking the user to
  /// reopen the video, which is exactly what the app can do for itself.
  Future<void> _recoverFromFailure(String? detail) async {
    final video = _current;
    final message = detail == null || detail.isEmpty
        ? 'Playback failed. Reopen the video to try again.'
        : 'Playback failed: $detail';

    // Never while a load is in flight: the exception may be the outgoing
    // source's teardown during a rebuild, and attaching a fallback from here
    // would run a second setupDataSource against the one in progress — the
    // "stuck loading with audio still running" that play() serialises
    // against. Wait for it, then look at what the player is doing: a source
    // that is playing or buffering has not failed.
    final pending = _pendingLoad;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    if (_switchingQuality) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      if (_current?.id != video?.id) return;
      final value = _player?.videoPlayerController?.value;
      if (_playing || (value?.isBuffering ?? false)) return;
    }
    if (_current?.id != video?.id) return;

    // Offline files do not expire, so a failure there is a real one — a
    // truncated or deleted download, which re-resolving cannot mend.
    if (video == null || _isOffline || _recoveredVideoId == video.id) {
      _error = message;
      notifyListeners();
      return;
    }
    _recoveredVideoId = video.id;

    final resumeAt = _position;

    // A manifest this app generated is the one case where re-resolving is the
    // wrong move: it would rebuild the same document from the same tracks and
    // fail in the same way. `fallbackUrl` is the progressive stream from the
    // same response — lower resolution, but a genuinely different route, and
    // one that is not subject to the serving cap that makes HD stop partway
    // through. Taking it costs the viewer some sharpness instead of the rest
    // of the video.
    final fallback = _sources?.fallbackUrl;
    if (fallback != null && fallback.isNotEmpty) {
      debugPrint(
        'AI BIT: generated manifest failed ($detail) — '
        'falling back to the progressive stream for ${video.id}',
      );
      final sources = PlaybackSources(
        url: fallback,
        qualities: const {},
        audioOnlyUrl: _sources?.audioOnlyUrl,
      );
      try {
        _sources = sources;
        _error = null;
        notifyListeners();
        await _attach(video, sources, startAt: resumeAt);
        return;
      } catch (e) {
        if (_current?.id != video.id) return;
        _error = message;
        notifyListeners();
        return;
      }
    }

    debugPrint('AI BIT: playback failed ($detail) — re-resolving ${video.id}');
    try {
      final sources = await _repo.resolve(video.id, force: true);
      if (_current?.id != video.id) return;
      _sources = sources;
      _error = null;
      notifyListeners();
      await _attach(video, sources, startAt: resumeAt);
    } catch (e) {
      if (_current?.id != video.id) return;
      // Report the original failure, not the retry's: the first one is what
      // the user saw, and a network error on the retry would mislead.
      _error = message;
      notifyListeners();
    }
  }

  /// Switches to the HD sources when [PlaybackSources.upgrade] delivers them.
  ///
  /// Playback has already started on the stream that was available at once;
  /// this waits for the better one in the background and, if the viewer is
  /// still on the same video, rebuilds the player at the current position —
  /// the same rebuild an audio-only toggle does. Every "still relevant" check
  /// matters: the upgrade can land after the user has moved on, after a
  /// download finished, or after a quality switch replaced the sources.
  void _followUpgrade(VideoBrief video, PlaybackSources sources, int token) {
    final upgrade = sources.upgrade;
    if (upgrade == null) return;
    unawaited(upgrade().then((better) async {
      if (better == null) return;
      if (token != _playToken || _current?.id != video.id) return;
      if (_isOffline || !identical(_sources, sources)) return;
      // Audio mode plays the lowest rendition on purpose; HD is no upgrade.
      if (isAudioOnly) return;
      // Not when the video is about to finish, has finished, or is counting
      // down to the next one. The rebuild cancels the countdown and the
      // outgoing player's STATE_ENDED is suppressed as teardown noise, so an
      // upgrade landing here left the video parked on its last frame with no
      // end screen and no autoplay — a worse outcome than thirty seconds of
      // 360p, which is all that would be gained.
      if (_endScreen || _countdownTimer != null) return;
      if (!upgradeWorthwhile(position: _position, duration: _duration)) return;
      debugPrint('AI BIT: switching ${video.id} to HD at $_position');
      await reloadCurrent();
    }).catchError((Object e) {
      debugPrint('AI BIT: HD upgrade not applied — $e');
    }));
  }

  /// Re-resolves the current video after an audio-only toggle or when the HD
  /// upgrade lands, keeping the playback position, the queue, the chapters and
  /// the shuffle state.
  Future<void> reloadCurrent() async {
    final video = _current;
    if (video == null) return;
    final resumeAt = _position;
    final chapters = _chapters;
    final unshuffled = _unshuffledQueue;
    // Same guard as a quality switch: rebuilding the player makes the outgoing
    // one report STATE_ENDED, and with the duration momentarily unknown that
    // reads as a genuine finish — so toggling Audio only would throw up the end
    // screen over the still-playing video. Suppress it across the rebuild.
    _switchingQuality = true;
    _endScreen = false;
    try {
      // `rebuild` rather than nulling _current first: with _current gone for
      // the length of the load, the watch page's "is the player on my video"
      // checks failed, and an up-next list that finished loading in that window
      // was never handed to the queue — the rail was full and autoplay had
      // nothing. The watch row and the session record are also left alone.
      await play(
        video,
        upNext: _queue.toList(),
        recordHistory: false,
        rebuild: true,
      );
      if (resumeAt > const Duration(seconds: 3)) await seek(resumeAt);
      if (_current?.id == video.id) {
        _chapters = chapters;
        _unshuffledQueue = unshuffled;
      }
    } finally {
      // Held a moment longer: the STATE_ENDED from the torn-down player can
      // land just after the rebuild returns, so clearing the guard at once
      // would still let it through.
      Timer(const Duration(milliseconds: 800), () {
        _switchingQuality = false;
        if (_current?.id != video.id) return;
        // The guard also kept `initialized` from applying the saved quality to
        // the new source, so do it now; and if the video genuinely ended while
        // the guard was up, that finish was dropped — recover it rather than
        // leaving the last frame on screen with nothing following.
        unawaited(_applyPreferredQualityWhenReady());
        if (!_playing &&
            _duration > Duration.zero &&
            _position > Duration.zero &&
            isGenuineFinish(position: _position, duration: _duration)) {
          _persistPosition(force: true);
          unawaited(_onFinished());
        }
      });
    }
  }

  /// Swaps in a new autoplay queue — used once the watch page has finished
  /// loading the real "up next" list.
  // ---------------------------------------------------------- SponsorBlock

  List<SponsorSegment> _segments = const [];

  /// The category of the segment just auto-skipped, for a brief toast; cleared
  /// by the UI after showing it.
  String? sponsorSkipNotice;

  void _loadSponsorSegments(String videoId) {
    _segments = const [];
    if (!_config.sponsorBlock) return;
    unawaited(
      _sponsorBlock.segments(videoId).then((segs) {
        // Only apply if still on the same video.
        if (_current?.id == videoId) _segments = segs;
      }, onError: (Object _) {}),
    );
  }

  /// Skips [_position] past any sponsor segment it has entered. Called from the
  /// position listener, which runs about once a second.
  /// How much of the start of a video is never skipped.
  ///
  /// A second guard behind the category list. Whatever SponsorBlock says, a
  /// video has to begin where the viewer pressed play: jumping before the
  /// first frame is seen reads as the app being broken, not as a feature, and
  /// there is no way for the viewer to tell the difference. A segment that
  /// starts inside this window is left alone; one that starts after it is
  /// skipped as normal.
  static const _neverSkipBefore = Duration(seconds: 2);

  void _applySponsorSkip() {
    if (_segments.isEmpty) return;
    for (final seg in _segments) {
      if (seg.start < _neverSkipBefore) continue;
      // A small tolerance at the end so a segment that finishes just past the
      // playhead is not re-triggered.
      if (_position >= seg.start && _position < seg.end - const Duration(milliseconds: 300)) {
        sponsorSkipNotice = seg.label;
        unawaited(seek(seg.end));
        notifyListeners();
        return;
      }
    }
  }

  // ------------------------------------------------------------- chapters

  List<VideoChapter> _chapters = const [];
  List<VideoChapter> get chapters => _chapters;

  /// The chapter covering the current position, or null.
  VideoChapter? get currentChapter =>
      _chapters.isEmpty ? null : chapterAt(_chapters, _position);

  /// Set by the watch page once the description has been parsed.
  void setChapters(List<VideoChapter> chapters) {
    _chapters = chapters;
    notifyListeners();
  }

  // ------------------------------------------------------------- A–B loop

  Duration? _loopA;
  Duration? _loopB;

  Duration? get loopA => _loopA;
  Duration? get loopB => _loopB;
  bool get hasLoop => _loopA != null && _loopB != null;

  /// Marks the current position as the loop's start (A).
  void setLoopStart() {
    _loopA = _position;
    // Keep A before B; drop a stale B that now sits behind the new A.
    if (_loopB != null && _loopB! <= _loopA!) _loopB = null;
    notifyListeners();
  }

  /// Marks the current position as the loop's end (B). Ignored if it is not
  /// after A.
  void setLoopEnd() {
    if (_loopA == null || _position <= _loopA!) return;
    _loopB = _position;
    notifyListeners();
  }

  void clearLoop() {
    _loopA = null;
    _loopB = null;
    notifyListeners();
  }

  /// Replaces the queue with [videos] — YouTube's suggestions for the video
  /// now playing, unless [suggested] says it is a list the user chose.
  void replaceQueue(List<VideoBrief> videos, {bool suggested = true}) {
    _queue
      ..clear()
      ..addAll(videos.where((v) => v.id != _current?.id));
    _queueIsSuggested = suggested;
    // A wholesale replacement leaves nothing of the old order to restore.
    _unshuffledQueue = null;
    notifyListeners();
    _warmNext();
  }

  /// Resolves the head of the queue ahead of time, so autoplay and the Next
  /// button start from a cached stream instead of a fresh player request.
  /// Shorts already warm their neighbours from the Shorts page.
  void _warmNext() {
    if (kIsWeb || _queue.isEmpty || _config.dataSaver) return;
    final next = _queue.first;
    if (next.isLive) return;
    _repo.prefetch(next.id);
  }

  /// Whether the queue is YouTube's suggestions for the current video rather
  /// than a list the user chose (a playlist, a built queue).
  ///
  /// It decides what autoplay does next. Reported as "with the screen off the
  /// next video is fully different from what was playing": autoplay took the
  /// next video from the queue and carried the REST of that queue over, so
  /// the third, fourth and fifth videos all came from the first video's
  /// suggestions, drifting further from what was actually playing each time.
  /// With the screen on the watch page happened to replace the queue for each
  /// new video, which is why it only showed with the screen off. A suggested
  /// queue is now rebuilt from each new video's own suggestions, as YouTube's
  /// autoplay does; a chosen list is still followed in order.
  bool _queueIsSuggested = true;
  bool get queueIsSuggested => _queueIsSuggested;

  /// Queues [video] to play right after the current one — YouTube's "Play
  /// next". It used to start the video at once, which is "play now".
  void playAfterCurrent(VideoBrief video) {
    if (_current == null) {
      unawaited(play(video));
      return;
    }
    if (video.id == _current?.id) return;
    _queue
      ..removeWhere((v) => v.id == video.id)
      ..insert(0, video);
    _unshuffledQueue = null;
    notifyListeners();
    unawaited(_remote.sync(hasPrevious: hasPrevious, hasNext: hasNext));
  }

  /// Videos already played, newest last. Gives "previous" something to mean —
  /// a queue alone only ever moves forward.
  final List<VideoBrief> _playHistory = [];

  /// Everything played since the app started, newest last.
  ///
  /// Deliberately separate from [_playHistory], which is the back-stack and is
  /// *consumed* by [playPrevious] — stepping back would erase exactly the
  /// record this needs to keep. Nothing here is ever popped.
  ///
  /// It exists because "up next" is a session question, not a lifetime one.
  /// YouTube's own description of that surface says the video being watched is
  /// the main signal, and the rest of the sitting is the context around it: a
  /// list that keeps offering what was played twenty minutes ago is the loop
  /// people complain about in autoplay. Capped, and not persisted — a new
  /// launch is a new sitting.
  final List<VideoBrief> _sessionPlayed = [];

  /// What has been played in this sitting, oldest first.
  List<VideoBrief> get playedThisSession => List.unmodifiable(_sessionPlayed);

  bool get hasNext => _queue.isNotEmpty;
  bool get hasPrevious => _playHistory.isNotEmpty;

  Future<void> playNext() async {
    if (_queue.isEmpty) return;
    final next = _queue.removeAt(0);
    if (!_queueIsSuggested) {
      await play(next, upNext: _queue.toList());
      return;
    }
    // Suggested queue: what follows [next] is decided by [next]'s own
    // suggestions, not by the list of the video before it. The old list is
    // kept only as a fallback, so a failed fetch never ends the session.
    final fallback = _queue.toList();
    await play(next);
    if (_current?.id != next.id) return;
    final filled = await _fillQueueIfEmpty(next);
    if (!filled && _queue.isEmpty && _current?.id == next.id) {
      replaceQueue(fallback.where((v) => v.id != next.id).toList());
    }
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
    // Going back keeps the queue's kind: a suggested one stays suggested.
    final suggested = _queueIsSuggested;
    await play(previous, upNext: rest, recordHistory: false);
    if (_current?.id == previous.id) _queueIsSuggested = suggested;
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

  /// The queue as it stood before it was shuffled, or null when it is not
  /// shuffled. Kept so the button can be a toggle rather than a one-way door —
  /// a shuffle with no way back loses the order the up-next list was built in.
  List<VideoBrief>? _unshuffledQueue;

  bool get isQueueShuffled => _unshuffledQueue != null;

  /// [items] in a random order, deterministic for a given [seed].
  ///
  /// Pure and static so the ordering can be tested; `List.shuffle` seeded from
  /// the clock cannot be. Fisher–Yates, which is the only shuffle that leaves
  /// every permutation equally likely.
  static List<T> shuffledOrder<T>(List<T> items, int seed) {
    final out = List<T>.of(items);
    final random = Random(seed);
    for (var i = out.length - 1; i > 0; i--) {
      final j = random.nextInt(i + 1);
      final held = out[i];
      out[i] = out[j];
      out[j] = held;
    }
    return out;
  }

  /// Toggles a random order over the queue, leaving whatever is playing alone.
  ///
  /// Unshuffling restores the original order of the videos still queued and
  /// appends anything added while shuffled, rather than resurrecting entries
  /// that were played or removed in the meantime.
  void shuffleQueue() {
    final original = _unshuffledQueue;
    if (original == null) {
      _unshuffledQueue = List.of(_queue);
      final shuffled = shuffledOrder(
        _queue,
        DateTime.now().microsecondsSinceEpoch,
      );
      _queue
        ..clear()
        ..addAll(shuffled);
    } else {
      final queued = {for (final video in _queue) video.id};
      final restored = [
        for (final video in original)
          if (queued.contains(video.id)) video,
      ];
      final known = {for (final video in restored) video.id};
      restored.addAll(_queue.where((v) => !known.contains(v.id)));
      _queue
        ..clear()
        ..addAll(restored);
      _unshuffledQueue = null;
    }
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
    if (_queueIsSuggested) {
      // Picking a suggestion is choosing that video: what follows it is its
      // own suggestions, exactly as when autoplay reaches it.
      _queue.removeRange(0, index);
      await playNext();
      return;
    }
    final rest = _queue.skip(index + 1).toList();
    await play(video, upNext: rest);
  }

  /// Decides what follows a finished video: repeat it, advance the queue, or
  /// wrap the queue around.
  Future<void> _onFinished() async {
    // A Short loops, as it does on YouTube, whatever the repeat setting. The
    // Shorts tab left its queue empty on the understanding that "repeat
    // handles the rest", but repeat is a user setting that defaults to off,
    // so every Short played once and then sat paused on its last frame —
    // seen on an emulator as a Short "stuck" at 11 and 21 seconds.
    // "End of video" on the sleep timer: this finish is the stopping point.
    // The end screen shows, with nothing counting down after it.
    if (_sleepAtEnd) {
      _sleepAtEnd = false;
      _endScreen = true;
      _cancelCountdown();
      notifyListeners();
      return;
    }
    if (_current?.isShort ?? false) {
      await seek(Duration.zero);
      await _player?.play();
      return;
    }
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
        // A last chance for an empty queue, so a fill that failed or was
        // still in flight at the start does not end the session here.
        final finished = _current;
        if (_config.autoplayNext && !hasNext && finished != null) {
          await _fillQueueIfEmpty(finished);
          if (_current?.id != finished.id) return; // the user moved on
        }
        _startEndScreen();
    }
  }

  /// The in-flight fill, shared so the start-of-video and end-of-video calls
  /// for one video make one request between them.
  Future<bool>? _queueFill;
  String? _queueFillFor;

  /// Fills an empty autoplay queue from [video]'s own related list.
  ///
  /// The queue used to be filled only by the watch page, once its up-next
  /// list had loaded. Leave that page before it loaded — minimise to the mini
  /// player, go home, lock the phone — and its result was dropped with the
  /// widget, so the queue stayed empty and the video simply ended: "autoplay
  /// next audio or video not working", for exactly the way people listen.
  /// The player owns the queue, so it now fills it itself; the watch page,
  /// when open, still replaces it with its own list a moment later, which is
  /// the same request ranked the same way.
  ///
  /// Never for a Short, which loops rather than advancing, and never over a
  /// queue someone already gave it (a playlist, "play next"). Returns whether
  /// there is now something to play next.
  Future<bool> _fillQueueIfEmpty(VideoBrief video) {
    if (_queue.isNotEmpty) return Future.value(true);
    if (kIsWeb || video.isShort) return Future.value(false);
    final running = _queueFill;
    if (running != null && _queueFillFor == video.id) return running;
    final fill = () async {
      try {
        final raw = await _repo.related(
          video.id,
          channelId: video.channelId,
          title: video.title,
          channelTitle: video.author,
        );
        final played = {for (final v in _sessionPlayed) v.id};
        var next = raw
            .where((v) => v.id != video.id && !played.contains(v.id))
            .toList();
        if (next.isEmpty) next = raw.where((v) => v.id != video.id).toList();
        // Ranked the way the watch page ranks it, so autoplay plays what the
        // list would have shown. Kids mode takes YouTube's order as it is:
        // its viewing is kept out of the taste profile on purpose.
        if (!_config.kidsMode && next.isNotEmpty) {
          try {
            next = _repo.personalisedUpNext(
              current: video,
              related: next,
              profile: await _db.tasteProfile(coVisitSeeds: [video.id]),
              impressions: await _db.feedImpressions(),
              recentlyPlayed: playedThisSession,
            );
          } catch (e) {
            debugPrint('AI BIT: autoplay queue left unranked - $e');
          }
        }
        if (_current?.id != video.id) return false;
        if (_queue.isEmpty && next.isNotEmpty) {
          replaceQueue(next);
          unawaited(_remote.sync(hasPrevious: hasPrevious, hasNext: hasNext));
        }
        return _queue.isNotEmpty;
      } catch (e) {
        debugPrint('AI BIT: autoplay queue not filled for ${video.id} - $e');
        return false;
      } finally {
        if (_queueFillFor == video.id) {
          _queueFill = null;
          _queueFillFor = null;
        }
      }
    }();
    _queueFill = fill;
    _queueFillFor = video.id;
    return fill;
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
    // Backgrounded — screen off, or another app in front — there is no screen
    // to count down on, and nothing holds the device awake across ten silent
    // seconds: the player's own wake lock drops the moment it reports ended,
    // so on a phone with the display dark the timer routinely never fired and
    // the night's listening stopped after one video. Go straight on, which is
    // also what YouTube does when it is not being looked at.
    if (!_foreground && _config.autoplayNext && hasNext) {
      _endScreen = false;
      notifyListeners();
      unawaited(playNext());
      return;
    }
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
      'Mode': isAudioOnly || _droppedVideo ? 'Audio only' : 'Video',
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

  /// Enters Picture in Picture, returning null on success or a short reason it
  /// could not start.
  ///
  /// Every branch here used to return silently, so a device where PiP was
  /// refused was indistinguishable from a dead button - which is exactly how
  /// it was reported. The caller is expected to show the reason.
  Future<String?> enterPictureInPicture() async {
    if (kIsWeb) return 'Not available in the browser preview.';
    final player = _player;
    if (player == null) return 'Nothing is playing yet.';
    if (!await player.isPictureInPictureSupported()) {
      return 'This device does not support Picture in Picture.';
    }
    // The plugin measures the player's on-screen frame through this key and
    // force-unwraps its context, so an unmounted player throws rather than
    // failing gracefully. Checked here instead.
    if (playerKey.currentContext == null) {
      return 'The player is not on screen.';
    }
    try {
      // The plugin now answers with the reason iOS refused, rather than
      // returning success regardless - see PATCHES.md #21.
      // Timed out rather than awaited indefinitely. The native side has to
      // answer on every path for this to resolve, and a plugin that forgets
      // one leaves the button dead with no way to tell - which is exactly how
      // this bug presented.
      final failure = await player
          .enablePictureInPicture(playerKey)
          .timeout(
            const Duration(seconds: 6),
            onTimeout: () => 'Picture in Picture did not respond.',
          );
      if (failure != null) debugPrint('AI BIT: PiP refused - $failure');
      return failure;
    } catch (e) {
      debugPrint('AI BIT: Picture in Picture failed to start - $e');
      return 'Picture in Picture could not start.';
    }
  }

  /// Arms or disarms iOS's automatic Picture in Picture for the current video.
  ///
  /// Called after every data source rather than once at startup: iOS needs a
  /// layer bound to the player that is playing now, and this app reuses one
  /// long-lived controller across videos, so a layer armed for the previous
  /// video would be pointing at the wrong thing. Android arms the Activity
  /// instead and does not care, but re-arming costs nothing there.
  ///
  /// A no-op on other platforms and when the setting is off, and deliberately
  /// not awaited by the caller - failing to arm a convenience must never delay
  /// playback starting.
  Future<void> _syncAutomaticPip() async {
    final player = _player;
    if (player == null) return;
    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await player.setAutomaticPictureInPicture(
        playerKey,
        enabled: _config.autoPip,
      );
    } catch (e) {
      // Logged, not swallowed: an auto-PiP that silently never arms is exactly
      // the dead feature CLAUDE.md warns about.
      debugPrint('AI BIT: could not arm automatic PiP - $e');
    }
  }

  /// Stops playback and takes the now-playing bar off the screen.
  ///
  /// Ordered so that **nothing can stop the bar going away**, which is the one
  /// thing the user is asking for by pressing the button. It was reported as
  /// "close is not working", and the shape of the old version explains how:
  /// bookkeeping ran first and `notifyListeners()` ran last, so an exception
  /// anywhere in between left the bar on screen. Two ways that happened:
  ///
  ///   * `_flushWatchTime()` writes to SQLite. A failure there — a closed
  ///     database during teardown, a disk error — threw before `_current` was
  ///     ever cleared, so playback did not stop at all.
  ///   * `dispose(forceDispose: true)` reaches into the native player, and it
  ///     ran *before* the single `notifyListeners()`. A throw there left the
  ///     controller correctly stopped and the UI never told about it, so the
  ///     bar stayed up showing a video that was no longer playing — and
  ///     pressing close again did nothing, because by then there was nothing
  ///     left to stop.
  ///
  /// So the state is cleared and listeners are notified in the middle, with
  /// the fallible work on either side wrapped. Bookkeeping still goes first,
  /// because both calls read fields that are about to be cleared.
  /// Disposes a player an attach created after [stop] had already run.
  void _discardOrphanPlayer() {
    final player = _player;
    _player = null;
    _playing = false;
    if (player == null) return;
    debugPrint('AI BIT: dropping a player that started after close');
    try {
      player.videoPlayerController?.removeListener(_onValueChanged);
      player.removeEventsListener(_onPlayerEvent);
      player.dispose(forceDispose: true);
    } catch (e) {
      debugPrint('AI BIT: could not dispose the orphan player — $e');
    }
    notifyListeners();
  }

  Future<void> stop() async {
    final player = _player;

    try {
      _cancelSleepTimer();
      // Before the fields the decision reads are cleared below.
      _releaseWakelock();
      // Bank the last partial batch while _current still says what it belongs
      // to. Losing a few seconds of watch time is a far smaller failure than
      // refusing to stop, so this is reported and stepped over.
      _flushWatchTime();
    } catch (e) {
      debugPrint('AI BIT: could not bank state while stopping — $e');
    }

    // Everything still in flight belongs to the video being closed: a load
    // part-way through its resolve, a pending HD upgrade, a quality wait and
    // the end-screen countdown. Each used to carry on after the X and start
    // the video again — or the next one — with no bar on screen to stop it.
    _playToken++;
    _qualityToken++;
    _cancelCountdown();
    _endScreen = false;
    _loading = false;
    _awaitingSource = false;
    _error = null;
    _queue.clear();
    _unshuffledQueue = null;

    _watchMillis = 0;
    _watchTickAt = null;
    _player = null;
    _current = null;
    _sources = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _playing = false;
    // Before the native teardown, not after it: this is what removes the bar,
    // and it must not be hostage to a plugin call that can throw.
    notifyListeners();

    try {
      player?.videoPlayerController?.removeListener(_onValueChanged);
      player?.removeEventsListener(_onPlayerEvent);
      player?.dispose(forceDispose: true);
    } catch (e) {
      debugPrint('AI BIT: could not dispose the player while stopping — $e');
    }
  }


  // ------------------------------------------------------ screen wakelock

  /// Whether this controller currently asks the system to keep the screen on.
  ///
  /// The app owns this rather than the player widget, and that is the whole
  /// point. `better_player` armed the wakelock in exactly one place — the
  /// transition *into* its fullscreen route — and released it unconditionally
  /// on the way out. Three things followed, and all three were reported as
  /// "the screen goes off while I am watching":
  ///
  ///   * Inline playback and the Shorts tab never held it at all, because
  ///     neither ever enters that route.
  ///   * Picture in Picture enters and leaves fullscreen *programmatically*
  ///     (the plugin calls `enterFullScreen()` when PiP starts and
  ///     `exitFullScreen()` when it stops), so leaving PiP released the
  ///     wakelock while the video carried on playing inline. This app arms PiP
  ///     automatically, so that happened without the user touching anything.
  ///   * Nothing ever re-armed it. It was a one-shot on a route change, so
  ///     once any of the above dropped it, it stayed dropped for the rest of
  ///     the video — "plays fine, then the screen goes off after a while".
  ///
  /// So the plugin no longer touches it at all (PATCHES.md #23) and this is
  /// the single owner. It is derived from playback state and re-evaluated on
  /// every player event, which means it is self-healing: any path that stops
  /// playback or backgrounds the app releases it, and resuming takes it back.
  bool _wakelockHeld = false;

  /// True when the screen should be kept awake: something is playing, it has
  /// a picture worth looking at, and the app is actually in front.
  ///
  /// Audio-only is deliberately excluded rather than overlooked — it is the
  /// mode whose entire purpose is listening with the screen off, and holding
  /// the screen on there would burn the battery it exists to save. The same
  /// goes for a dropped video track, which only happens once the app is
  /// already in the background.
  bool get _shouldKeepScreenOn =>
      _player != null &&
      _playing &&
      !isAudioOnly &&
      !_droppedVideo &&
      _foreground;

  /// Tracks the foreground/background state the wakelock decision needs.
  /// `didChangeAppLifecycleState` already runs here for the screen-off track
  /// swap, so this costs nothing extra.
  bool _foreground = true;

  /// Applies [_shouldKeepScreenOn], cheaply enough to call from every event.
  ///
  /// Never awaited by its callers: the answer is advisory and a failed toggle
  /// must not be able to interrupt playback. It is logged rather than
  /// swallowed, because a wakelock that silently stops working is exactly the
  /// dead feature this codebase keeps relearning about bare catches.
  void _syncWakelock() {
    final wanted = _shouldKeepScreenOn;
    if (wanted == _wakelockHeld) return;
    _wakelockHeld = wanted;
    unawaited(
      (wanted ? WakelockPlus.enable() : WakelockPlus.disable()).catchError((
        Object e,
      ) {
        // Put the flag back so the next event retries rather than believing a
        // toggle that never happened.
        _wakelockHeld = !wanted;
        debugPrint('AI BIT: could not ${wanted ? 'hold' : 'release'} the '
            'screen wakelock — $e');
      }),
    );
  }

  /// Releases the wakelock without consulting the playback state.
  ///
  /// Used on teardown, where the fields this decision reads have already been
  /// cleared and [_syncWakelock] would be reasoning about a half-dismantled
  /// controller.
  void _releaseWakelock() {
    if (!_wakelockHeld) return;
    _wakelockHeld = false;
    unawaited(
      WakelockPlus.disable().catchError((Object e) {
        debugPrint('AI BIT: could not release the screen wakelock — $e');
      }),
    );
  }
  // ------------------------------------------------- screen-off audio mode

  /// True while the video track has been dropped because the screen is off.
  bool _droppedVideo = false;
  bool get isVideoDropped => _droppedVideo;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      // Not `inactive`. That fires for anything that merely covers the app —
      // a notification banner, Control Centre, the app switcher — and dropping
      // the rendition for each of them made the picture visibly churn between
      // sizes during ordinary use. `hidden` and `paused` mean the app really
      // has gone away.
      //
      // This used to need `inactive` because it swapped the data source, which
      // has to happen while the app can still act. It is a track selection
      // now, and those are fine once backgrounded.
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // Release the screen wakelock on the way out, not on the way back in.
        // Audio may well carry on playing in the background, and asking the
        // system to keep a screen awake that the user has just left is how a
        // background-audio app becomes a battery complaint.
        _foreground = false;
        if (_sessionAudio) _sessionAudioLeft = true;
        _syncWakelock();
        unawaited(_dropVideoTrack());
      case AppLifecycleState.resumed:
        _foreground = true;
        if (_sessionAudioLeft) {
          // Back on the screen after listening away from it: the picture
          // returns, which is what turning the screen on is asking for.
          _sessionAudioLeft = false;
          _sessionAudio = false;
          unawaited(refreshAudioMode());
        }
        _syncWakelock();
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
    if (isAudioOnly) return; // already at the lowest rung by choice
    final player = _player;
    if (player == null || _current == null) return;
    if (_isOffline) return; // a local file costs no data

    // Only ever a track selection, never a new data source.
    //
    // Swapping the source here rebuilt the player, and this fires on far more
    // than a locked screen — the app switcher, Control Centre, even a
    // notification banner all raise `inactive`. Minimising the app therefore
    // stopped playback and came back at zero, which is the one thing this app
    // exists to avoid. Selecting a lower rung costs nothing and never
    // interrupts.
    //
    // Videos with no ladder simply keep playing at full size. No saving is
    // worth losing background playback over.
    if (_ladderHeights.isEmpty) return;
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
    // Back to whatever this video was loaded to play at, which is not always
    // the saved preference: a video started on a low battery or on mobile data
    // must not silently climb back to full quality just because the screen
    // came on.
    await _applyQuality(
      qualityForConditions(
        ladder: [for (final h in _ladderHeights) '${h}p'],
        preferred: _config.preferredQuality,
        lowest: _config.dataSaver || _mobileSaving,
        stepDown: _batterySaving,
      ),
    );
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

  /// Stops once the current video finishes, instead of after a fixed time —
  /// YouTube's "End of video". Nothing autoplays after it.
  void startSleepAtEndOfVideo() {
    _cancelSleepTimer();
    _sleepAtEnd = true;
    notifyListeners();
  }

  bool _sleepAtEnd = false;
  bool get sleepsAtEndOfVideo => _sleepAtEnd;

  void cancelSleepTimer() {
    _cancelSleepTimer();
    notifyListeners();
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDeadline = null;
    _sleepAtEnd = false;
  }

  // -------------------------------------------------------------- events

  void _onPlayerEvent(BetterPlayerEvent event) {
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.finished:
        // Only when the video really has run out.
        //
        // Changing quality on a progressive source goes through the plugin's
        // setResolution, which tears the data source down and builds it again.
        // The dying player reports STATE_ENDED on the way out, and that was
        // taken at face value: the end screen appeared over a video that had
        // just restarted from zero, while the old audio kept playing. A
        // genuine finish happens within a few seconds of the duration.
        if (_switchingQuality) break;
        if (!isGenuineFinish(position: _position, duration: _duration)) break;
        _persistPosition(force: true);
        unawaited(_onFinished());
      case BetterPlayerEventType.exception:
        unawaited(_recoverFromFailure(event.parameters?['exception']?.toString()));
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
        // Not while a quality change is rebuilding the source — that would
        // re-enter the very function doing the rebuilding.
        if (!_switchingQuality) unawaited(_applyPreferredQualityWhenReady());
      case BetterPlayerEventType.play:
      case BetterPlayerEventType.pause:
        _playing = _player?.isPlaying() ?? false;
        // Pausing can be the last value change for a while, so the wakelock
        // decision cannot wait for the position listener to notice.
        _syncWakelock();
        notifyListeners();
      default:
        break;
    }
  }

  /// Mirrors the native player's value into plain fields the UI can watch,
  /// throttled to one notification per second so the mini player does not
  /// rebuild on every position tick.
  void _onValueChanged() {
    // Still the previous video's player talking; see _awaitingSource.
    if (_awaitingSource) return;
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
    _accrueWatchTime();

    // A–B loop: jump back to A once playback passes B.
    final a = _loopA;
    final b = _loopB;
    if (a != null && b != null && _position >= b) {
      unawaited(seek(a));
    }

    _applySponsorSkip();

    // Re-asserted from the position listener rather than only on transitions,
    // which is what makes the wakelock self-healing: it fires several times a
    // second while playing and costs a bool comparison when nothing has moved,
    // so anything that drops the lock behind our back is corrected within a
    // tick instead of lasting the rest of the video.
    _syncWakelock();

    final second = Duration(seconds: _position.inSeconds);
    if (_lastNotified != second) {
      _lastNotified = second;
      ticker.value = second;
    }

    // A full rebuild only for the things that change the page, not the clock.
    if (wasPlaying != _playing || hadDuration != _duration) notifyListeners();
  }

  // ------------------------------------------- watched time and accounting

  /// How much watched time is allowed to pile up before it is written.
  ///
  /// Both consumers — the Kids allowance and the data-usage estimate — are
  /// database writes, so they are batched rather than run from the position
  /// listener directly; that listener fires many times a second.
  static const _accountingInterval = Duration(seconds: 15);

  /// The longest gap between two position ticks that still counts as watching.
  /// Anything longer means the listener stopped firing at all — a stall, a
  /// suspended app — and charging that time to the allowance would be wrong.
  static const _maxTickGap = Duration(seconds: 5);

  DateTime? _watchTickAt;
  int _watchMillis = 0;

  /// Accumulates wall-clock watching time. Driven from the existing position
  /// listener on purpose: a second timer would have to be started, stopped and
  /// disposed in step with playback, and would be one more thing to get wrong
  /// around backgrounding.
  ///
  /// Wall clock and not the position delta, because seeking, the A–B loop and
  /// a sponsor skip all move the position without any time passing — a
  /// twenty-minute jump would otherwise spend twenty minutes of a child's
  /// allowance and book twenty minutes of data.
  void _accrueWatchTime() {
    final now = DateTime.now();
    final last = _watchTickAt;
    _watchTickAt = now;
    if (!_playing) {
      // Bank the remainder at the pause rather than holding it until playback
      // resumes, which may be never.
      _flushWatchTime();
      return;
    }
    if (last == null) return;
    final delta = now.difference(last);
    if (delta <= Duration.zero || delta > _maxTickGap) return;
    _watchMillis += delta.inMilliseconds;
    if (_watchMillis >= _accountingInterval.inMilliseconds) _flushWatchTime();
  }

  /// Writes whole banked seconds out to the Kids allowance and the data-usage
  /// estimate, keeping the sub-second remainder for the next batch.
  void _flushWatchTime() {
    final seconds = _watchMillis ~/ 1000;
    if (seconds <= 0) return;
    _watchMillis -= seconds * 1000;

    final guard = _kids;
    if (guard != null && _config.kidsMode) {
      unawaited(
        guard.addWatched(seconds).then(
          (_) => _enforceKidsLimit(),
          // Logged rather than swallowed: a failing write here means the
          // allowance silently stops counting, which looks like the limit
          // feature was never switched on.
          onError: (Object e) =>
              debugPrint('AI BIT: kids allowance not recorded — $e'),
        ),
      );
    }

    final labelled = _current;
    // The label the ranker learns from. It only ever updates a row that
    // already exists, so a video reached from search or a channel page - which
    // was never a recommendation - is silently ignored rather than being
    // trained on as though the ranker had suggested it.
    //
    // Driven from here rather than from a timer because this already runs
    // every fifteen seconds and on every stop, which is exactly the cadence
    // the label wants: early enough that a bail-out is recorded, often enough
    // that the final figure is close to what was really watched.
    if (labelled != null && !_config.incognito && _duration > Duration.zero) {
      final completion =
          (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
      unawaited(
        _db.markExampleOpened(labelled.id, completion).catchError((Object e) {
          debugPrint('AI BIT: ranking label not recorded - $e');
        }),
      );
    }

    final usage = _usage;
    final video = _current;
    // A downloaded file spends no data, so it is not booked against anything.
    if (usage != null && video != null && !_isOffline) {
      unawaited(
        usage.recordStream(
          video: video,
          watched: Duration(seconds: seconds),
          // The rendition actually playing, which is what audio-only and the
          // savers have already stepped down. Audio mode is not billed at an
          // audio bitrate: it plays the video stream with the picture covered,
          // so its real cost is the lowest rung, not an audio track.
          quality: activeQuality ?? _config.preferredQuality,
        ),
      );
    }
  }

  // ---------------------------------------------------------- kids allowance

  /// True when Kids mode is on and today's watch allowance is spent.
  ///
  /// The controller only pauses; it shows nothing. What the child sees is the
  /// UI's decision, which is why there is no dialog anywhere in here.
  bool get kidsLimitReached =>
      _config.kidsMode && (_kids?.limitReached ?? false);

  void _enforceKidsLimit() {
    if (!kidsLimitReached) return;
    // Not an interruption: this must not resume by itself when a call ends.
    _forgetInterruption();
    unawaited(_player?.pause());
    _playing = false;
    notifyListeners();
  }

  void _persistPosition({bool force = false}) {
    final video = _current;
    if (video == null) return;
    // Incognito leaves no resume trail, for the reason given in _play.
    if (_config.incognito) return;
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
    // The wakelock is process-wide, so a controller that goes away holding it
    // would leave the screen awake with nothing playing.
    _releaseWakelock();
    _cancelSleepTimer();
    _cancelCountdown();
    _player?.videoPlayerController?.removeListener(_onValueChanged);
    _player?.removeEventsListener(_onPlayerEvent);
    _player?.dispose(forceDispose: true);
    _sponsorBlock.close();
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
