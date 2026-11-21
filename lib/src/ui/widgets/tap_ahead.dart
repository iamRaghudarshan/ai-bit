import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../data/models.dart';
import '../../data/settings.dart';
import '../../data/yt_repository.dart';

/// Resolves a video's stream while its card sits on screen, before any tap.
///
/// Finding the stream is a player request to YouTube (two clients, asked
/// together) plus an end-of-file probe — 0.3 s on a good line and several
/// seconds on a weak one — and it used to start only when the card was
/// tapped. YouTube's own app has the answer before the finger lands. Here a
/// card that stays at least [fraction] visible for [dwell] is handed to
/// [YtRepository.prefetch], so the tap is a cache hit or joins the request
/// already in flight.
///
/// The dwell is what keeps a fling cheap: cards that scroll straight past
/// never fire, and the repository also caps how many run at once. Only JSON
/// and a two-byte probe are fetched, never video, and nothing is done with
/// Data saver on.
class TapAhead extends StatefulWidget {
  const TapAhead({
    super.key,
    required this.video,
    required this.child,
    this.fraction = 0.6,
    this.dwell = const Duration(milliseconds: 450),
  });

  final VideoBrief video;
  final Widget child;
  final double fraction;
  final Duration dwell;

  @override
  State<TapAhead> createState() => _TapAheadState();
}

class _TapAheadState extends State<TapAhead> {
  Timer? _timer;
  bool _done = false;

  void _onVisibility(VisibilityInfo info) {
    if (_done) return;
    if (info.visibleFraction >= widget.fraction) {
      _timer ??= Timer(widget.dwell, _fire);
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _fire() {
    _timer = null;
    if (!mounted || _done) return;
    _done = true;
    if (widget.video.isLive) return;
    try {
      if (context.read<SettingsService>().dataSaver) return;
      context.read<YtRepository>().prefetch(widget.video.id);
    } on ProviderNotFoundException {
      // A widget test or a screen built outside the app's providers: nothing
      // to warm, and the card itself is unaffected.
    }
  }

  @override
  void didUpdateWidget(TapAhead oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.id != widget.video.id) {
      _timer?.cancel();
      _timer = null;
      _done = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: ValueKey('tap-ahead-${widget.video.id}-${identityHashCode(this)}'),
      onVisibilityChanged: _onVisibility,
      child: widget.child,
    );
  }
}
