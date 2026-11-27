import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../data/settings.dart';
import '../../player/playback_controller.dart';
import 'queue_sheet.dart';
import 'sheets.dart';

/// The player's gear: ONE sheet, YouTube's layout — Quality, Playback speed,
/// Captions and Sleep timer each showing its current value, and "More" for
/// everything used less often.
///
/// This replaced the chip row under the video (Quality · Speed · Captions ·
/// More). Each row opens the sheet that already existed for it, so nothing
/// about how a setting behaves changed — only where it is reached from, which
/// is now the video itself, inline and fullscreen alike.
Future<void> showPlayerSettingsSheet(BuildContext context) {
  final playback = context.read<PlaybackController>();
  final settings = context.read<SettingsService>();
  final host = context;
  return showModalBottomSheet<void>(
    useRootNavigator: true,
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: AnimatedBuilder(
        animation: Listenable.merge([playback, settings]),
        builder: (context, _) {
          final sleep = playback.sleepRemaining;
          final captions = playback.activeCaptions;
          // Each row closes this sheet before opening its own, so two sheets
          // are never stacked over the video. Opened from the host's context,
          // not this sheet's, which is on its way out.
          void then(Future<void> Function(BuildContext) open) {
            Navigator.pop(sheetContext);
            if (host.mounted) open(host);
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SettingsRow(
                icon: Icons.tune,
                title: 'Quality',
                value: playback.activeQuality == null
                    ? settings.preferredQuality
                    : settings.preferredQuality == SettingsService.autoQuality
                    ? 'Auto (${playback.activeQuality})'
                    : playback.activeQuality!,
                onTap: () => then(showQualitySheet),
              ),
              _SettingsRow(
                icon: Icons.slow_motion_video,
                title: 'Playback speed',
                value: playback.speed == 1.0 ? 'Normal' : '${playback.speed}x',
                onTap: () => then(showSpeedSheet),
              ),
              _SettingsRow(
                icon: captions == null
                    ? Icons.closed_caption_off_outlined
                    : Icons.closed_caption,
                title: 'Captions',
                value: captions == null ? 'Off' : (captions.name ?? 'On'),
                onTap: () => then(showCaptionsSheet),
              ),
              _SettingsRow(
                icon: Icons.bedtime_outlined,
                title: 'Sleep timer',
                value: sleep == null
                    ? 'Off'
                    : playback.sleepsAtEndOfVideo
                    ? 'End of video'
                    : clockLabel(sleep),
                onTap: () => then(showSleepTimerSheet),
              ),
              const Divider(height: 8),
              _SettingsRow(
                icon: Icons.settings_outlined,
                title: 'More',
                value: '',
                onTap: () => then(showPlayerMoreSheet),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          const SizedBox(width: 4),
          Icon(
            Icons.chevron_right,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Dub / alternate audio-track picker, shown when a video carries more than
/// one audio track.
Future<void> showAudioTrackSheet(BuildContext context) {
  final playback = context.read<PlaybackController>();
  return showModalBottomSheet<void>(
    useRootNavigator: true,
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: AnimatedBuilder(
        animation: playback,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Audio track',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  for (final track in playback.audioTracks)
                    ListTile(
                      title: Text(
                        track.label ?? track.language ?? 'Track ${track.id}',
                      ),
                      trailing: playback.activeAudioTrack?.id == track.id
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () {
                        playback.setAudioTrack(track);
                        Navigator.pop(sheetContext);
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The gear's "More": audio only, audio track, repeat, A–B loop, queue,
/// picture-in-picture and stats — moved here unchanged from the watch page's
/// old overflow sheet.
Future<void> showPlayerMoreSheet(BuildContext context) {
  final playback = context.read<PlaybackController>();
  final settings = context.read<SettingsService>();

  return showModalBottomSheet<void>(
    useRootNavigator: true,
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: AnimatedBuilder(
        animation: Listenable.merge([playback, settings]),
        builder: (context, _) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  'More',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.headphones_outlined),
                      title: const Text('Audio only'),
                      subtitle: Text(
                        settings.audioOnly
                            ? 'Always on — set in Settings'
                            : 'Picture comes back when you return to the app',
                      ),
                      value: playback.isAudioOnly,
                      // Off with no setting behind the missing picture (a
                      // sound-only download, or YouTube answering with sound
                      // only) means "get me the picture".
                      onChanged: (v) {
                        if (!v && playback.canShowVideo) {
                          playback.showVideoAnyway();
                        } else {
                          playback.setAudioOnly(v);
                        }
                        // Close on the tap, so the change is seen rather than
                        // hidden behind the sheet.
                        Navigator.pop(sheetContext);
                      },
                    ),
                    if (playback.audioTracks.length > 1)
                      ListTile(
                        leading: const Icon(Icons.multitrack_audio),
                        title: const Text('Audio track'),
                        subtitle: Text(
                          playback.activeAudioTrack?.label ??
                              playback.activeAudioTrack?.language ??
                              'Default',
                        ),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          showAudioTrackSheet(context);
                        },
                      ),
                    ListTile(
                      leading: Icon(switch (playback.repeatMode) {
                        PlaybackRepeat.one => Icons.repeat_one,
                        _ => Icons.repeat,
                      }),
                      title: const Text('Repeat'),
                      trailing: Text(switch (playback.repeatMode) {
                        PlaybackRepeat.off => 'Off',
                        PlaybackRepeat.one => 'This video',
                        PlaybackRepeat.all => 'Queue',
                      }),
                      onTap: playback.cycleRepeatMode,
                    ),
                    ListTile(
                      leading: Icon(
                        playback.hasLoop ? Icons.repeat_on : Icons.compare_arrows,
                      ),
                      title: const Text('Loop A–B'),
                      subtitle: Text(
                        playback.hasLoop
                            ? 'Looping ${clockLabel(playback.loopA)} – '
                                  '${clockLabel(playback.loopB)}'
                            : playback.loopA != null
                            ? 'Start ${clockLabel(playback.loopA)} — '
                                  'set the end point'
                            : 'Repeat a section between two points',
                      ),
                      trailing: playback.hasLoop || playback.loopA != null
                          ? TextButton(
                              onPressed: playback.clearLoop,
                              child: const Text('Clear'),
                            )
                          : null,
                      onTap: () {
                        if (playback.loopA == null) {
                          playback.setLoopStart();
                        } else if (playback.loopB == null) {
                          playback.setLoopEnd();
                        } else {
                          playback.clearLoop();
                        }
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.queue_music),
                      title: const Text('Queue'),
                      trailing: playback.queue.isEmpty
                          ? null
                          : Text('${playback.queue.length}'),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        showQueueSheet(context);
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.picture_in_picture_alt_outlined),
                      title: const Text('Picture in picture'),
                      onTap: () async {
                        // Captured before the await: the sheet's context is
                        // gone by the time the reason comes back.
                        final messenger = ScaffoldMessenger.of(context);
                        Navigator.pop(sheetContext);
                        final failure = await playback.enterPictureInPicture();
                        if (failure != null) {
                          messenger.showSnackBar(
                            SnackBar(content: Text(failure)),
                          );
                        }
                      },
                    ),
                    SwitchListTile(
                      secondary: const Icon(Icons.analytics_outlined),
                      title: const Text('Stats for nerds'),
                      value: playback.showStats,
                      onChanged: (_) {
                        playback.toggleStats();
                        Navigator.pop(sheetContext);
                      },
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
