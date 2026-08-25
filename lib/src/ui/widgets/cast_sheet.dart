import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/dlna_client.dart';
import '../../player/playback_controller.dart';

/// Picks a TV on the local network and hands it the stream that is playing.
///
/// This is the app's Chromecast replacement: DLNA/UPnP needs no SDK, no account
/// and no registered receiver id, and nearly every smart TV of the last decade
/// answers it. `DlnaClient` does the protocol; this sheet is only the remote.
///
/// On iOS the Cast button stays Apple's own AirPlay route picker (see
/// `cast_button.dart`), because AirPlay covers Apple TV properly and iOS gates
/// the multicast that DLNA discovery needs behind an entitlement.
Future<void> showCastSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const CastSheet(),
  );
}

/// What the renderer is doing, as far as this sheet knows.
///
/// Tracked here rather than read back from the device: polling AVTransport's
/// TransportState would mean another SOAP round trip per second, and nothing
/// but a button in this sheet changes it.
enum _Transport { playing, paused, stopped }

class CastSheet extends StatefulWidget {
  const CastSheet({super.key});

  @override
  State<CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<CastSheet> {
  final DlnaClient _client = DlnaClient();

  List<DlnaDevice> _devices = const [];
  DlnaDevice? _connected;
  _Transport _transport = _Transport.stopped;

  /// The URL handed to [_connected]. Held so Play after a Pause or Stop can
  /// re-send it without depending on what the phone happens to be playing by
  /// then.
  String _castUrl = '';
  String _castTitle = '';

  bool _scanning = false;
  bool _busy = false;

  /// The last failure, shown inline. A SnackBar posts behind a modal bottom
  /// sheet, so the user would never see one from here.
  String? _message;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    // Only closes our HTTP client. The renderer deliberately keeps playing
    // after the sheet is dismissed — that is the whole point of casting — and
    // is stopped only by Stop or Disconnect.
    _client.close();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _message = null;
    });
    // discover() returns an empty list instead of throwing when multicast is
    // blocked, so there is no error path here — an empty result is explained by
    // _EmptyDevices instead.
    final found = await _client.discover();
    if (!mounted) return;
    setState(() {
      final connected = _connected;
      _devices = [
        ...found,
        // A device that answered an earlier scan but not this one is kept while
        // it is the one casting; dropping it would pull the transport controls
        // out from under a cast that is still playing.
        if (connected != null && !found.contains(connected)) connected,
      ];
      _scanning = false;
    });
  }

  /// The URL to cast, or the reason there is not one.
  ///
  /// Same constraint as the in-app player: the renderer takes exactly one URL,
  /// so what travels is the combined video+audio stream the player already
  /// opened, never a video track plus a separate audio track.
  ({String? url, String? problem}) _castable(PlaybackController playback) {
    if (playback.current == null) {
      return (
        url: null,
        problem: 'Nothing is playing. Start a video, then pick a device.',
      );
    }
    if (playback.isOffline) {
      return (
        url: null,
        problem:
            'This video is playing from a download on the phone. A TV can only '
            'fetch a URL and the app is not a web server, so downloads cannot '
            'be cast — play it online instead.',
      );
    }
    final url = playback.player?.betterPlayerDataSource?.url;
    // Belt and braces behind the isOffline check: a completed download is a
    // filesystem path, which a renderer has no way to open.
    if (url == null || !url.startsWith('http')) {
      return (
        url: null,
        problem:
            'No stream URL yet. Wait for playback to start, then try again.',
      );
    }
    return (url: url, problem: null);
  }

  Future<void> _connect(DlnaDevice device) async {
    final playback = context.read<PlaybackController>();
    final castable = _castable(playback);
    final url = castable.url;
    if (url == null) {
      setState(() => _message = castable.problem);
      return;
    }
    final title = playback.current?.title ?? '';

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await _client.play(device, url, title: title);
    } on DlnaException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = error.message;
      });
      return;
    }
    // Two copies of the same audio in one room is the first thing anyone
    // notices, so the phone stands down as soon as the TV has the stream.
    if (playback.isPlaying) await playback.togglePlayPause();
    if (!mounted) return;
    setState(() {
      _connected = device;
      _castUrl = url;
      _castTitle = title;
      _transport = _Transport.playing;
      _busy = false;
    });
  }

  /// Runs one AVTransport command and folds a refusal into [_message].
  Future<void> _command(
    Future<void> Function(DlnaDevice device) action,
    _Transport next,
  ) async {
    final device = _connected;
    if (device == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action(device);
      if (!mounted) return;
      setState(() {
        _transport = next;
        _busy = false;
      });
    } on DlnaException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = error.message;
      });
    }
  }

  /// Disconnecting stops the renderer first.
  ///
  /// Leaving a googlevideo URL playing on a TV whose only remote is this sheet
  /// is worse than stopping it: close the sheet and there is no way back to the
  /// transport controls short of the TV's own remote.
  Future<void> _disconnect() async {
    final device = _connected;
    if (device == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await _client.stop(device);
    } on DlnaException catch (error) {
      // Shown, not swallowed, but the disconnect goes through either way — a TV
      // that has stopped answering is exactly when the user wants the phone
      // back.
      if (mounted) setState(() => _message = error.message);
    }
    if (!mounted) return;
    setState(() {
      _connected = null;
      _castUrl = '';
      _castTitle = '';
      _transport = _Transport.stopped;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = _connected;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Cast to a device',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Scan again',
                  onPressed: _scanning ? null : _scan,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          // The scan is a four-second UDP wait with nothing to show for it, so
          // it needs a visible indicator or the sheet looks broken.
          if (_scanning || _busy)
            const LinearProgressIndicator(minHeight: 2)
          else
            const Divider(height: 1),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                _message!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.55,
              ),
              child: _devices.isEmpty && !_scanning
                  ? const SingleChildScrollView(child: _EmptyDevices())
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        if (_scanning && _devices.isEmpty)
                          ListTile(
                            leading: const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            title: Text(
                              'Looking for devices on this Wi-Fi…',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        for (final device in _devices)
                          _DeviceRow(
                            device: device,
                            connected: device == connected,
                            // One command at a time: the transport is a single
                            // piece of state on the renderer, and overlapping
                            // SOAP posts race each other.
                            onTap: _busy ? null : () => _connect(device),
                          ),
                      ],
                    ),
            ),
          ),
          if (connected != null) ...[
            const Divider(height: 1),
            _TransportBar(
              deviceName: connected.name,
              title: _castTitle,
              transport: _transport,
              busy: _busy,
              onPlay: () => _command(
                (device) => _client.play(device, _castUrl, title: _castTitle),
                _Transport.playing,
              ),
              onPause: () => _command(_client.pause, _Transport.paused),
              onStop: () => _command(_client.stop, _Transport.stopped),
              onDisconnect: _disconnect,
            ),
          ],
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.connected,
    required this.onTap,
  });

  final DlnaDevice device;
  final bool connected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      leading: Icon(
        connected ? Icons.cast_connected : Icons.tv,
        color: connected ? theme.colorScheme.primary : null,
      ),
      title: Text(device.name),
      subtitle: Text(
        // The host disambiguates two TVs of the same model, which report the
        // same friendlyName out of the box.
        connected ? 'Casting' : Uri.parse(device.location).host,
        style: theme.textTheme.bodySmall,
      ),
      trailing: connected
          ? Icon(Icons.check, color: theme.colorScheme.primary)
          : null,
    );
  }
}

/// The remote: play, pause, stop, disconnect.
class _TransportBar extends StatelessWidget {
  const _TransportBar({
    required this.deviceName,
    required this.title,
    required this.transport,
    required this.busy,
    required this.onPlay,
    required this.onPause,
    required this.onStop,
    required this.onDisconnect,
  });

  final String deviceName;
  final String title;
  final _Transport transport;
  final bool busy;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  final VoidCallback onStop;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playing = transport == _Transport.playing;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Playing on $deviceName',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          if (title.isNotEmpty)
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.play_arrow),
                // Play re-sends the URL, because AVTransport's plain Play is
                // not exposed separately from SetAVTransportURI here — so the
                // renderer starts the video over. Better said in the tooltip
                // than discovered by pressing it.
                tooltip: 'Play from the start',
                onPressed: busy ? null : onPlay,
              ),
              IconButton(
                icon: const Icon(Icons.pause),
                tooltip: 'Pause',
                onPressed: busy || !playing ? null : onPause,
              ),
              IconButton(
                icon: const Icon(Icons.stop),
                tooltip: 'Stop',
                onPressed: busy || transport == _Transport.stopped
                    ? null
                    : onStop,
              ),
              const Spacer(),
              TextButton(
                onPressed: busy ? null : onDisconnect,
                child: const Text('Disconnect'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Why the list is empty — which on a network that blocks multicast is the
/// normal outcome, and is indistinguishable from a broken app unless it is
/// spelled out.
class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
      child: Column(
        children: [
          Icon(
            Icons.tv_off,
            size: 40,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text('No devices found', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            'The phone and the TV have to be on the same Wi-Fi network. Guest '
            'networks, VPNs and routers with client isolation switched on all '
            'drop the discovery message.',
            textAlign: TextAlign.center,
            style: body,
          ),
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) ...[
            const SizedBox(height: 8),
            Text(
              'On iOS the search also needs Apple’s multicast entitlement. '
              'Without it the system discards it silently, so this list can '
              'stay empty with a TV in the same room. Use the AirPlay button '
              'instead.',
              textAlign: TextAlign.center,
              style: body,
            ),
          ],
          if (kIsWeb) ...[
            const SizedBox(height: 8),
            Text(
              'Casting does not work in the browser preview — a browser has no '
              'UDP sockets.',
              textAlign: TextAlign.center,
              style: body,
            ),
          ],
        ],
      ),
    );
  }
}
