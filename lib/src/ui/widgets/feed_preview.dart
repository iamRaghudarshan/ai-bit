import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../data/models.dart';
import '../../data/network_service.dart';
import '../../data/settings.dart';
import '../../data/yt_repository.dart';
import '../../player/playback_controller.dart';

/// Muted previews of the feed card you pause on, the way the YouTube app does.
///
/// Deliberately its own player, NOT [PlaybackController]'s. That one is the
/// app's single long-lived player and may be mid-video with the screen off; a
/// preview borrowing it would stop whatever the user was actually listening
/// to. This one is disposable, muted, and never touches playback state.
///
/// Three things make it affordable, and removing any of them makes the feed
/// worse than it was without previews:
///
///  * Only ONE preview exists at a time, in the card nearest the middle of the
///    screen. A feed of players decodes a feed of videos.
///  * A dwell delay. Scrolling past twenty cards must not resolve twenty
///    streams - and unlike YouTube, which serves pre-generated preview clips,
///    every preview here costs a real resolve of a second or two.
///  * It refuses to run at all while the main player has something going, and
///    off Wi-Fi unless explicitly allowed. A feed that silently streams video
///    on mobile data is a nasty way to discover where your data went.
/// Why feed previews will not run right now, or null when they will.
///
/// A free function so the Settings screen can say the same thing the
/// coordinator decided, without owning a coordinator. "Previews do not work"
/// has five separate causes here and they are indistinguishable from the
/// outside - which is exactly how this was reported, and why the reason is now
/// shown rather than kept internal.
/// Takes plain booleans rather than SettingsService so it is a pure function
/// the tests can call directly - the same reason the other rules in this app
/// that are easy to get quietly wrong live as pure helpers.
String? feedPreviewBlockedReason({
  required bool previewsEnabled,
  required bool previewsOnMobile,
  required bool dataSaver,
  required bool audioOnly,
  required bool isMobile,
  required bool somethingPlaying,
}) {
  // Nothing to say when the switch is simply off: it already shows off, and a
  // reason underneath would be noise.
  if (!previewsEnabled) return null;
  if (somethingPlaying) return 'Paused while a video is playing.';
  if (dataSaver) return 'Off because Data saver is on.';
  if (audioOnly) return 'Off because Audio only is on.';
  if (isMobile && !previewsOnMobile) {
    return 'Off on mobile data. Turn on "Previews on mobile data" below.';
  }
  return null;
}

class FeedPreviewCoordinator extends ChangeNotifier {
  FeedPreviewCoordinator({
    required YtRepository repository,
    required SettingsService settings,
    required this._playback,
    this._network,
  })  : _repo = repository,
        _config = settings;

  final YtRepository _repo;
  final SettingsService _config;
  final PlaybackController _playback;
  final NetworkService? _network;

  /// How long a card must stay put before it is worth resolving a stream for.
  static const _dwell = Duration(milliseconds: 900);

  /// Previews stop here rather than playing a whole video into a thumbnail.
  static const _maxPreview = Duration(seconds: 30);

  BetterPlayerController? _player;
  BetterPlayerController? get player => _player;

  String? _activeId;

  /// The video currently previewing, or null.
  String? get activeId => _activeId;

  String? _pendingId;
  Timer? _dwellTimer;
  Timer? _stopTimer;

  /// Why previews are not running, or null when they are allowed.
  String? get blockedReason => feedPreviewBlockedReason(
        previewsEnabled: _config.feedPreviews,
        previewsOnMobile: _config.feedPreviewsOnMobile,
        dataSaver: _config.dataSaver,
        audioOnly: _config.audioOnly,
        isMobile: _network?.isMobile ?? false,
        somethingPlaying: _playback.current != null && _playback.isPlaying,
      );

  // The switch being off is not a "reason" the user needs telling, but it does
  // mean no previews - so it is checked separately from blockedReason.
  bool get _allowed =>
      !kIsWeb && _config.feedPreviews && blockedReason == null;

  /// Called as cards scroll in and out. [fraction] is how much of the card is
  /// on screen; the most-visible card wins.
  void onCardVisibility(VideoBrief video, double fraction) {
    if (!_allowed) {
      if (_activeId != null) stop();
      return;
    }

    // Well past half on screen: this is the card being looked at.
    if (fraction >= 0.7) {
      if (_activeId == video.id || _pendingId == video.id) return;
      _pendingId = video.id;
      _dwellTimer?.cancel();
      _dwellTimer = Timer(_dwell, () => _start(video));
      return;
    }

    // Scrolled away from the one that was playing or queued.
    if (_pendingId == video.id) {
      _pendingId = null;
      _dwellTimer?.cancel();
    }
    if (_activeId == video.id && fraction < 0.4) stop();
  }

  Future<void> _start(VideoBrief video) async {
    if (!_allowed || _pendingId != video.id) return;
    await _disposePlayer();

    try {
      final sources = await _repo.resolve(video.id);
      // The user may have scrolled on during the resolve; that is the common
      // case, not an edge case, so check again rather than starting a preview
      // for a card that is gone.
      if (_pendingId != video.id || !_allowed) return;

      final controller = BetterPlayerController(
        BetterPlayerConfiguration(
          autoPlay: true,
          looping: true,
          fit: BoxFit.cover,
          aspectRatio: 16 / 9,
          handleLifecycle: false,
          autoDispose: false,
          controlsConfiguration: const BetterPlayerControlsConfiguration(
            showControls: false,
          ),
        ),
      );
      await controller.setupDataSource(
        BetterPlayerDataSource(
          BetterPlayerDataSourceType.network,
          sources.url,
          // No notification and no media session: a preview must never appear
          // on the lock screen or take over the now-playing slot.
          notificationConfiguration:
              const BetterPlayerNotificationConfiguration(showNotification: false),
        ),
      );
      await controller.setVolume(0);

      if (_pendingId != video.id || !_allowed) {
        controller.dispose(forceDispose: true);
        return;
      }

      _player = controller;
      _activeId = video.id;
      _pendingId = null;
      notifyListeners();

      _stopTimer?.cancel();
      _stopTimer = Timer(_maxPreview, stop);
    } catch (e) {
      // A preview that cannot resolve is not worth telling anyone about - the
      // thumbnail simply stays. Logged, not swallowed, so a feed where NO
      // preview ever plays is traceable.
      debugPrint('AI BIT: feed preview failed for ${video.id} - $e');
      _pendingId = null;
    }
  }

  /// Stops and tears down whatever is previewing.
  void stop() {
    _dwellTimer?.cancel();
    _stopTimer?.cancel();
    _pendingId = null;
    if (_activeId == null && _player == null) return;
    _activeId = null;
    unawaited(_disposePlayer());
    notifyListeners();
  }

  Future<void> _disposePlayer() async {
    final player = _player;
    _player = null;
    if (player == null) return;
    try {
      await player.pause();
    } catch (_) {
      // Already gone; disposing is still the right next step.
    }
    player.dispose(forceDispose: true);
  }

  @override
  void dispose() {
    _dwellTimer?.cancel();
    _stopTimer?.cancel();
    unawaited(_disposePlayer());
    super.dispose();
  }
}

/// Wraps a feed card so it can report visibility and show its preview.
class FeedPreviewSlot extends StatelessWidget {
  const FeedPreviewSlot({
    super.key,
    required this.video,
    required this.coordinator,
    required this.child,
  });

  final VideoBrief video;
  final FeedPreviewCoordinator coordinator;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: Key('preview-${video.id}'),
      onVisibilityChanged: (info) =>
          coordinator.onCardVisibility(video, info.visibleFraction),
      child: child,
    );
  }
}

/// The preview surface, drawn over a card's thumbnail while it is playing.
class FeedPreviewSurface extends StatelessWidget {
  const FeedPreviewSurface({
    super.key,
    required this.video,
    required this.coordinator,
  });

  final VideoBrief video;
  final FeedPreviewCoordinator coordinator;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: coordinator,
      builder: (context, _) {
        final player = coordinator.player;
        if (coordinator.activeId != video.id || player == null) {
          return const SizedBox.shrink();
        }
        return Positioned.fill(
          // Ignores pointers so the card's own tap still opens the video: a
          // preview you have to dismiss before you can watch is worse than no
          // preview.
          child: IgnorePointer(
            child: BetterPlayer(controller: player),
          ),
        );
      },
    );
  }
}
