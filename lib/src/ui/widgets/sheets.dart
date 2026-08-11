import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/format.dart';
import '../../data/db.dart';
import '../../data/download_manager.dart';
import '../../data/models.dart';
import '../../data/settings.dart';
import '../../data/yt_repository.dart';
import '../../player/playback_controller.dart';
import '../channel_page.dart';

const _speedOptions = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
const _sleepOptions = [
  Duration(minutes: 5),
  Duration(minutes: 10),
  Duration(minutes: 15),
  Duration(minutes: 30),
  Duration(minutes: 45),
  Duration(hours: 1),
];

Widget _sheetHeader(BuildContext context, String title) => Padding(
  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
  child: Text(title, style: Theme.of(context).textTheme.titleMedium),
);

Future<void> showSpeedSheet(BuildContext context) {
  final playback = context.read<PlaybackController>();
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sheetHeader(context, 'Playback speed'),
          for (final speed in _speedOptions)
            ListTile(
              title: Text(speed == 1.0 ? 'Normal' : '${speed}x'),
              trailing: playback.speed == speed ? const Icon(Icons.check) : null,
              onTap: () {
                playback.setSpeed(speed);
                Navigator.pop(context);
              },
            ),
        ],
      ),
    ),
  );
}

Future<void> showSleepTimerSheet(BuildContext context) {
  final playback = context.read<PlaybackController>();
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sheetHeader(context, 'Sleep timer'),
          if (playback.sleepRemaining != null)
            ListTile(
              leading: const Icon(Icons.timer_off_outlined),
              title: const Text('Turn off'),
              subtitle: Text('${clockLabel(playback.sleepRemaining)} remaining'),
              onTap: () {
                playback.cancelSleepTimer();
                Navigator.pop(context);
              },
            ),
          for (final option in _sleepOptions)
            ListTile(
              leading: const Icon(Icons.bedtime_outlined),
              title: Text(
                option.inHours >= 1
                    ? '${option.inHours} hour'
                    : '${option.inMinutes} minutes',
              ),
              onTap: () {
                playback.startSleepTimer(option);
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Playback pauses in '
                      '${option.inHours >= 1 ? '${option.inHours}h' : '${option.inMinutes} min'}',
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    ),
  );
}

Future<void> showQualitySheet(BuildContext context) {
  final playback = context.read<PlaybackController>();
  final settings = context.read<SettingsService>();

  return showModalBottomSheet<void>(
    context: context,
    // Listens rather than reading once.
    //
    // The HLS ladder is parsed a moment after playback starts, so a sheet
    // opened promptly used to snapshot an empty track list and offer nothing
    // but "Auto" — the whole video long, because it never looked again.
    builder: (context) => AnimatedBuilder(
      animation: playback,
      builder: (context, _) {
        final options = [SettingsService.autoQuality, ...playback.qualities];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetHeader(context, 'Quality'),
              if (options.length == 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: Text(
                    playback.isLoading
                        ? 'Reading the available qualities…'
                        : 'This video is only offered in one size.',
                  ),
                ),
              for (final label in options)
                ListTile(
                  title: Text(label),
                  trailing: settings.preferredQuality == label
                      ? const Icon(Icons.check)
                      : (playback.activeQuality == label
                            ? const Icon(Icons.play_arrow, size: 18)
                            : null),
                  subtitle: label == SettingsService.autoQuality
                      ? const Text('Adjusts to your connection')
                      : (playback.activeQuality == label
                            ? const Text('Playing now')
                            : null),
                  onTap: () {
                    playback.setQuality(label);
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        );
      },
    ),
  );
}

/// Caption track picker, the CC button's sheet.
///
/// Listens rather than reading once, for the same reason the quality sheet
/// does: the tracks come off the manifest a moment after playback starts.
Future<void> showCaptionsSheet(BuildContext context) {
  final playback = context.read<PlaybackController>();

  return showModalBottomSheet<void>(
    context: context,
    builder: (context) => AnimatedBuilder(
      animation: playback,
      builder: (context, _) {
        final tracks = playback.captionTracks;
        final active = playback.activeCaptions;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetHeader(context, 'Captions'),
              if (tracks.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: Text(
                    playback.isLoading
                        ? 'Looking for caption tracks…'
                        : 'This video has no captions.',
                  ),
                ),
              ListTile(
                title: const Text('Off'),
                trailing: active == null ? const Icon(Icons.check) : null,
                onTap: () {
                  playback.setCaptions(null);
                  Navigator.pop(context);
                },
              ),
              for (final track in tracks)
                ListTile(
                  title: Text(track.name ?? 'Captions'),
                  trailing: active?.name == track.name
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    playback.setCaptions(track);
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        );
      },
    ),
  );
}

/// "Save to…" sheet. Rebuilds its own list so a playlist created inline shows
/// up without bouncing back to the caller.
Future<void> showSaveToPlaylistSheet(BuildContext context, VideoBrief video) {
  final db = context.read<AppDatabase>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _SaveToPlaylistSheet(db: db, video: video),
  );
}

class _SaveToPlaylistSheet extends StatefulWidget {
  const _SaveToPlaylistSheet({required this.db, required this.video});

  final AppDatabase db;
  final VideoBrief video;

  @override
  State<_SaveToPlaylistSheet> createState() => _SaveToPlaylistSheetState();
}

class _SaveToPlaylistSheetState extends State<_SaveToPlaylistSheet> {
  late Future<_SaveSheetData> _future = _load();

  Future<_SaveSheetData> _load() async => (
    playlists: await widget.db.playlists(),
    containing: await widget.db.playlistsContaining(widget.video.id),
  );

  void _reload() => setState(() => _future = _load());

  Future<void> _toggle(LocalPlaylist playlist, bool isIn) async {
    if (isIn) {
      await widget.db.removeFromPlaylist(playlist.id, widget.video.id);
    } else {
      await widget.db.addToPlaylist(playlist.id, widget.video);
    }
    _reload();
  }

  Future<void> _createPlaylist() async {
    final name = await showNewPlaylistDialog(context);
    if (name == null) return;
    final id = await widget.db.createPlaylist(name);
    await widget.db.addToPlaylist(id, widget.video);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<_SaveSheetData>(
        future: _future,
        builder: (context, snapshot) {
          final data = snapshot.data;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetHeader(context, 'Save to…'),
              if (data == null)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final playlist in data.playlists)
                        CheckboxListTile(
                          value: data.containing.contains(playlist.id),
                          title: Text(playlist.name),
                          subtitle: Text('${playlist.itemCount} videos'),
                          onChanged: (_) => _toggle(
                            playlist,
                            data.containing.contains(playlist.id),
                          ),
                        ),
                    ],
                  ),
                ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New playlist'),
                onTap: _createPlaylist,
              ),
            ],
          );
        },
      ),
    );
  }
}

typedef _SaveSheetData = ({List<LocalPlaylist> playlists, Set<int> containing});

Future<String?> showNewPlaylistDialog(BuildContext context, {String? initial}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(initial == null ? 'New playlist' : 'Rename playlist'),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(hintText: 'Playlist name'),
        onSubmitted: (value) {
          if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final value = controller.text.trim();
            if (value.isNotEmpty) Navigator.pop(context, value);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Download picker: what is available, and how big it is.
///
/// Sizes are fetched before anything is written, so the choice is made
/// knowingly rather than discovered from a progress bar.
Future<void> showDownloadSheet(BuildContext context, VideoBrief video) {
  final repo = context.read<YtRepository>();
  final downloads = context.read<DownloadManager>();

  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: FutureBuilder<List<DownloadOption>>(
        future: repo.downloadOptions(video.id),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(36),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final options = snapshot.data ?? const <DownloadOption>[];
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetHeader(context, 'Download'),
              if (options.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 24),
                  child: Text('Nothing downloadable for this video.'),
                ),
              for (final option in options)
                ListTile(
                  leading: Icon(
                    option.audioOnly
                        ? Icons.headphones_outlined
                        : Icons.movie_outlined,
                  ),
                  title: Text(option.label),
                  subtitle: Text(option.detail),
                  trailing: Text(
                    formatBytes(option.bytes),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    await downloads.enqueue(video, audioOnly: option.audioOnly);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Downloading — see You › Downloads'),
                      ),
                    );
                  },
                ),
              // Say why there is no 720p option, rather than leaving its
              // absence to look like an oversight.
              if (options.any((o) => !o.audioOnly))
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Text(
                    'YouTube only serves one combined video+audio file, and it '
                    'is 360p. Higher quality exists solely as separate video '
                    'and audio tracks, which cannot be saved as one playable '
                    'file without re-encoding. Streaming is still up to 4K.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}

/// Long-press / overflow menu shared by every video tile.
Future<void> showVideoMenu(
  BuildContext context,
  VideoBrief video, {
  VoidCallback? onRemove,
  String removeLabel = 'Remove',
}) {
  final playback = context.read<PlaybackController>();
  final db = context.read<AppDatabase>();
  final downloads = context.read<DownloadManager>();
  final existing = downloads.recordFor(video.id);

  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              video.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(sheetContext).textTheme.titleSmall,
            ),
          ),
          const Divider(),
          if (existing?.isComplete ?? false)
            ListTile(
              leading: const Icon(Icons.download_done, color: Colors.green),
              title: const Text('Downloaded'),
              subtitle: const Text('Plays offline. Tap to remove.'),
              onTap: () async {
                await downloads.remove(video.id);
                if (!sheetContext.mounted) return;
                Navigator.pop(sheetContext);
              },
            )
          else if (downloads.isActive(video.id))
            ListTile(
              leading: const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: const Text('Downloading…'),
              subtitle: const Text('Tap to cancel'),
              onTap: () async {
                await downloads.cancel(video.id);
                if (!sheetContext.mounted) return;
                Navigator.pop(sheetContext);
              },
            )
          else
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Download'),
              subtitle: const Text('Choose video or audio'),
              onTap: () {
                Navigator.pop(sheetContext);
                showDownloadSheet(context, video);
              },
            ),
          const Divider(height: 1),
          if (video.channelId.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: Text('Go to ${video.author}'),
              onTap: () {
                Navigator.pop(sheetContext);
                ChannelPage.open(context, video.channelId, title: video.author);
              },
            ),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: const Text('Share'),
            onTap: () {
              Navigator.pop(sheetContext);
              SharePlus.instance.share(
                ShareParams(uri: Uri.parse('https://youtu.be/${video.id}')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.queue_play_next_outlined),
            title: const Text('Play next'),
            onTap: () {
              playback.queue.isEmpty
                  ? playback.play(video)
                  : playback.play(video, upNext: playback.queue);
              Navigator.pop(sheetContext);
            },
          ),
          ListTile(
            leading: const Icon(Icons.watch_later_outlined),
            title: const Text('Save to Watch later'),
            onTap: () async {
              await db.addToPlaylist(LocalPlaylist.watchLaterId, video);
              if (!sheetContext.mounted) return;
              Navigator.pop(sheetContext);
              ScaffoldMessenger.of(
                sheetContext,
              ).showSnackBar(const SnackBar(content: Text('Saved to Watch later')));
            },
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: const Text('Save to playlist'),
            onTap: () {
              Navigator.pop(sheetContext);
              showSaveToPlaylistSheet(context, video);
            },
          ),
          if (onRemove != null)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(removeLabel),
              onTap: () {
                Navigator.pop(sheetContext);
                onRemove();
              },
            ),
        ],
      ),
    ),
  );
}
