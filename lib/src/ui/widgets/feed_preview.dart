import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../core/format.dart';
import '../../core/settings_rules.dart';
import '../../data/battery_service.dart';
import '../../data/models.dart';
import '../../data/network_service.dart';
import '../../data/settings.dart';
import '../../data/yt_repository.dart';
import '../../player/playback_controller.dart';
import 'video_tile.dart';

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
class FeedPreviewCoordinator extends ChangeNotifier {
  FeedPreviewCoordinator({
    required YtRepository repository,
    required SettingsService settings,
    required this._playback,
    this._network,
    this._battery,
  })  : _repo = repository,
        _config = settings {
    _playback.addListener(_onPlayback);
  }

  /// The moment a real video starts LOADING, any preview goes. Waiting for it
  /// to be *playing* is too late: on a phone the resolve takes seconds, and a
  /// preview that finished setting up inside that window started, took audio
  /// focus, and Android answered by stopping the video the user had just
  /// opened for good — reported as "videos don't play until I minimise and
  /// reopen". The watch page is a see-through route over the feed, so the
  /// feed's cards stay "visible" underneath it and nothing else stops them.
  void _onPlayback() {
    if (_playback.isLoading || _playback.isPlaying) {
      if (_activeId != null || _pendingId != null || _player != null) stop();
    }
  }

  final YtRepository _repo;
  final SettingsService _config;
  final PlaybackController _playback;
  final NetworkService? _network;
  final BatteryService? _battery;

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
        somethingPlaying: _playback.current != null &&
            (_playback.isPlaying || _playback.isLoading),
        batterySaver: _config.batterySaver,
        batteryLow: _battery?.isLow ?? false,
      );

  // The switch being off is not a "reason" the user needs telling, but it does
  // mean no previews - so it is checked separately from blockedReason.
  bool get _allowed =>
      !kIsWeb && _config.feedPreviews && blockedReason == null;

  bool _scrolling = false;
  VideoBrief? _pendingVideo;

  /// Previews start muted, as YouTube's do; the speaker button on the
  /// preview flips it, and the choice carries to the next preview for the
  /// rest of this screen's life rather than resetting on every card.
  bool _muted = true;
  bool get muted => _muted;

  Future<void> toggleMute() async {
    _muted = !_muted;
    notifyListeners();
    final player = _player;
    if (player == null) return;
    try {
      await player.setVolume(_muted ? 0 : 1);
    } catch (e) {
      debugPrint('AI BIT: preview volume not applied - $e');
    }
  }

  /// Told by the feed when a drag or fling starts and when it settles.
  ///
  /// Measured on an emulator, the feed scrolled at roughly half the frame
  /// rate with previews on: a preview that had started during a pause kept
  /// decoding through the next fling, because stopping waited for the
  /// visibility detector to report the card gone — late, by design — and
  /// the second player's teardown then landed mid-scroll too. YouTube silences
  /// a preview the instant you scroll and starts one only once you stop. So
  /// does this: a scroll start pauses at once (cheap) and cancels any
  /// countdown; the expensive teardown and any new preview wait for the end.
  void onScrolling(bool scrolling) {
    if (_scrolling == scrolling) return;
    _scrolling = scrolling;
    if (scrolling) {
      _dwellTimer?.cancel();
      final player = _player;
      if (player != null) unawaited(player.pause().catchError((Object _) {}));
      return;
    }
    // Settled: whichever card the visibility updates last chose is the one
    // being looked at. Anything that was previewing is now stale.
    if (_activeId != null && _activeId != _pendingVideo?.id) stop();
    final next = _pendingVideo;
    if (next != null && _pendingId == next.id && _allowed) {
      _dwellTimer?.cancel();
      _dwellTimer = Timer(_dwell, () => _start(next));
    } else if (_activeId != null) {
      final player = _player;
      if (player != null) unawaited(player.play().catchError((Object _) {}));
    }
  }

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
      _pendingVideo = video;
      _dwellTimer?.cancel();
      // Mid-scroll the countdown waits for the scroll to settle.
      if (!_scrolling) _dwellTimer = Timer(_dwell, () => _start(video));
      return;
    }

    // Scrolled away from the one that was playing or queued.
    if (_pendingId == video.id) {
      _pendingId = null;
      _dwellTimer?.cancel();
    }
    // Mid-scroll the player is already paused; the teardown waits for the
    // scroll to settle (onScrolling) so it does not land in the fling.
    if (_activeId == video.id && fraction < 0.4 && !_scrolling) stop();
  }

  Future<void> _start(VideoBrief video) async {
    if (!_allowed || _pendingId != video.id || _scrolling) return;
    await _disposePlayer();

    try {
      final sources = await _repo.resolve(video.id);
      // The user may have scrolled on during the resolve; that is the common
      // case, not an edge case, so check again rather than starting a preview
      // for a card that is gone.
      if (_pendingId != video.id || !_allowed) return;

      final controller = BetterPlayerController(
        BetterPlayerConfiguration(
          // Started by hand below, once it can no longer take audio focus.
          autoPlay: false,
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
      await controller.setVolume(_muted ? 0 : 1);
      // A muted preview must never take audio focus. Every player in the
      // vendored plugin asks for it (PATCHES.md, so a call pauses the video),
      // and focus is exclusive: a preview starting while the real video loads
      // makes Android stop the real one permanently. Mixing with others is
      // what skips the focus request.
      controller.setMixWithOthers(true);

      if (_pendingId != video.id || !_allowed) {
        controller.dispose(forceDispose: true);
        return;
      }
      await controller.play();

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
    _playback.removeListener(_onPlayback);
    _dwellTimer?.cancel();
    _stopTimer?.cancel();
    unawaited(_disposePlayer());
    super.dispose();
  }
}

/// The feed's single visibility hook for a card.
///
/// Two unrelated features need to know when a card is on screen - muted
/// previews, and the impression count the recommender ranks against - and this
/// deliberately serves both from one [VisibilityDetector] rather than nesting
/// two per card. A feed shows ten or so cards at a time and a detector reports
/// on every scroll; doubling that to save a widget nobody would read twice is
/// not a trade worth making.
///
/// Both collaborators are optional: [coordinator] is null on the web preview
/// target, where there is no player to preview with, and [onSeen] is null
/// wherever impressions are not being counted. The card itself still renders.
class FeedPreviewSlot extends StatelessWidget {
  const FeedPreviewSlot({
    super.key,
    required this.video,
    required this.child,
    this.coordinator,
    this.onSeen,
    this.rank = 0,
    this.seenFraction = 0.5,
  });

  final VideoBrief video;

  /// Drives the muted preview, when previews exist on this platform.
  final FeedPreviewCoordinator? coordinator;

  /// Called once each time the card crosses [seenFraction] on screen, with
  /// its position in the feed. The recorder behind it is responsible for not
  /// counting the same card twice, and for what the rank is worth.
  final void Function(String videoId, int rank)? onSeen;

  /// This card's position in the feed, zero-based.
  final int rank;

  /// How much of the card must be visible to count as seen.
  final double seenFraction;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: Key('feed-card-${video.id}'),
      onVisibilityChanged: (info) {
        coordinator?.onCardVisibility(video, info.visibleFraction);
        if (info.visibleFraction >= seenFraction) {
          onSeen?.call(video.id, rank);
        }
      },
      child: child,
    );
  }
}

/// The preview surface, drawn over a card's thumbnail while it is playing.
///
/// YouTube's preview chrome: a speaker button top-right, a thin accent line
/// along the bottom for how far the preview has got, and the duration badge
/// counting down — the moving picture covers the thumbnail's own badge, so
/// without one here the length of the video vanishes the moment it previews.
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
        final progress = player.videoPlayerController;
        return Positioned.fill(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Ignores pointers so the card's own tap still opens the video:
              // a preview you have to dismiss before you can watch is worse
              // than no preview.
              IgnorePointer(child: BetterPlayer(controller: player)),
              if (progress != null)
                IgnorePointer(
                  child: ListenableBuilder(
                    listenable: progress,
                    builder: (context, _) {
                      final value = progress.value;
                      final total = value.duration ?? video.duration;
                      final fraction = previewFraction(value.position, total);
                      final remaining = previewRemaining(value.position, total);
                      return Stack(
                        children: [
                          if (remaining != null && !video.isLive)
                            Positioned(
                              right: 8,
                              bottom: 8 + 2,
                              child: ThumbBadge(label: clockLabel(remaining)),
                            ),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: ResumeBar(progress: fraction, height: 2),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              Positioned(
                top: 4,
                right: 4,
                child: _MuteButton(
                  muted: coordinator.muted,
                  onPressed: coordinator.toggleMute,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.muted, required this.onPressed});

  final bool muted;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.6),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            muted ? Icons.volume_off : Icons.volume_up,
            size: 20,
            color: Colors.white,
            semanticLabel: muted ? 'Unmute preview' : 'Mute preview',
          ),
        ),
      ),
    );
  }
}

/// How far through [total] a preview at [position] is, 0..1; zero when the
/// length is unknown.
double previewFraction(Duration position, Duration? total) {
  if (total == null || total <= Duration.zero) return 0;
  return (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
}

/// Time left for the counting-down badge, or null when the length is
/// unknown. Never negative: a position a tick past a rounded duration is
/// common, and "-0:01" on a badge would look like a bug.
Duration? previewRemaining(Duration position, Duration? total) {
  if (total == null || total <= Duration.zero) return null;
  final left = total - position;
  return left.isNegative ? Duration.zero : left;
}
