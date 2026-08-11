import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The lock screen's skip buttons.
///
/// better_player_plus sets `nextTrackCommand.isEnabled` and
/// `previousTrackCommand.isEnabled` to `false` and attaches no handler, so the
/// buttons on the lock screen and in Control Centre were permanently greyed
/// out with no option to turn them on. `AppDelegate` claims the commands back
/// — they are a process-wide singleton — and this is the Dart half of that
/// bridge.
///
/// The plugin disables them again inside its own setup for every new data
/// source, so [sync] has to run after each video starts rather than once.
class RemoteCommands {
  RemoteCommands({
    required this.onNext,
    required this.onPrevious,
    required this.onInterruptionBegan,
    required this.onInterruptionEnded,
    required this.onOutputLost,
  }) {
    if (_supported) _channel.setMethodCallHandler(_handle);
  }

  static const _channel = MethodChannel('ai.bit/remote_commands');

  final VoidCallback onNext;
  final VoidCallback onPrevious;

  /// A call, alarm or other app has taken the audio session.
  final VoidCallback onInterruptionBegan;

  /// The interruption is over and the system says it is fine to resume.
  final VoidCallback onInterruptionEnded;

  /// Headphones unplugged or Bluetooth disconnected.
  final VoidCallback onOutputLost;

  /// Android's notification controls come from the plugin's own player
  /// notification, which already carries the buttons.
  bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  bool? _lastPrevious;
  bool? _lastNext;

  /// Greys the buttons out when there is nothing to skip to, the way a music
  /// app does at the ends of a queue.
  Future<void> sync({required bool hasPrevious, required bool hasNext}) async {
    if (!_supported) return;
    if (hasPrevious == _lastPrevious && hasNext == _lastNext) return;
    _lastPrevious = hasPrevious;
    _lastNext = hasNext;
    try {
      await _channel.invokeMethod('setTrackAvailability', {
        'hasPrevious': hasPrevious,
        'hasNext': hasNext,
      });
    } on PlatformException {
      // An older build without the native half; the buttons simply stay off.
    } on MissingPluginException {
      // Same, but for a build where the channel was never registered. This
      // went unnoticed once already because only PlatformException was caught.
    }
  }

  /// Forces the next [sync] through even if the flags have not changed, for
  /// when the plugin has just reset the commands behind our back.
  void invalidate() {
    _lastPrevious = null;
    _lastNext = null;
  }

  Future<dynamic> _handle(MethodCall call) async {
    switch (call.method) {
      case 'next':
        onNext();
      case 'previous':
        onPrevious();
      case 'interruptionBegan':
        onInterruptionBegan();
      case 'interruptionEnded':
        onInterruptionEnded();
      case 'outputLost':
        onOutputLost();
    }
    return null;
  }
}
