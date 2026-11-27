import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/format.dart';
import '../../data/db.dart';
import '../../data/recommender.dart';
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

// Top padding is small because every sheet now carries the theme's drag
// handle above it, which already gives the header its breathing room.
Widget _sheetHeader(BuildContext context, String title) => Padding(
  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
  child: Text(title, style: Theme.of(context).textTheme.titleMedium),
);

Future<void> showSpeedSheet(BuildContext context) {
  final playback = context.read<PlaybackController>();
  return showModalBottomSheet<void>(
    context: context,
    // With the drag handle, eight 56dp rows no longer fit the default
    // 9/16-height sheet on a small phone; scroll-controlled with 48dp rows
    // and a scrolling body, it fits and never clips.
    isScrollControlled: true,
    builder: (context) => sheetTiles(SafeArea(
      child: SingleChildScrollView(child: Column(
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
      )),
    )),
  );
}

Future<void> showSleepTimerSheet(BuildContext context) {
  final playback = context.read<PlaybackController>();
  return showModalBottomSheet<void>(
    context: context,
    // With the drag handle, eight 56dp rows no longer fit the default
    // 9/16-height sheet on a small phone; scroll-controlled with 48dp rows
    // and a scrolling body, it fits and never clips.
    isScrollControlled: true,
    builder: (context) => sheetTiles(SafeArea(
      child: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sheetHeader(context, 'Sleep timer'),
          if (playback.sleepRemaining != null)
            ListTile(
              leading: const Icon(Icons.timer_off_outlined),
              title: const Text('Turn off'),
              subtitle: Text(
                playback.sleepsAtEndOfVideo
                    ? 'Stopping at the end of this video'
                    : '${clockLabel(playback.sleepRemaining)} remaining',
              ),
              onTap: () {
                playback.cancelSleepTimer();
                Navigator.pop(context);
              },
            ),
          ListTile(
            leading: const Icon(Icons.stop_circle_outlined),
            title: const Text('End of video'),
            onTap: () {
              playback.startSleepAtEndOfVideo();
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Playback stops when this video ends'),
                ),
              );
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
      )),
    )),
  );
}

Future<void> showQualitySheet(BuildContext context) {
  final playback = context.read<PlaybackController>();
  final settings = context.read<SettingsService>();

  return showModalBottomSheet<void>(
    context: context,
    // A full HLS ladder is nine entries, more than a half-height sheet fits.
    isScrollControlled: true,
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
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
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
  // The manifest rarely carries captions now; ask YouTube for the tracks.
  unawaited(playback.loadCaptions());

  return showModalBottomSheet<void>(
    context: context,
    // A video can carry many caption languages, more than a half-sheet fits.
    isScrollControlled: true,
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
                    playback.isLoading || playback.captionsLoading
                        ? 'Looking for caption tracks…'
                        : 'This video has no captions.',
                  ),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    ListTile(
                      title: const Text('Off'),
                      trailing:
                          active == null ? const Icon(Icons.check) : null,
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
                          subtitle: Text(playlist.itemCount == 1 ? '1 video' : '${playlist.itemCount} videos'),
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

Future<String?> showNewPlaylistDialog(
  BuildContext context, {
  String? initial,
}) async {
  final controller = TextEditingController(text: initial);
  try {
    return await showDialog<String>(
      context: context,
      builder: (context) => _NewPlaylistDialog(
        controller: controller,
        isRename: initial != null,
      ),
    );
  } finally {
    // Disposed in a finally: the dialog can also be dismissed by the back
    // button or a barrier tap, and every one of those paths leaked a
    // controller before.
    controller.dispose();
  }
}

/// The name prompt, as a stateful widget so Save can be DISABLED while the
/// name is empty.
///
/// It used to be an enabled button whose onPressed silently did nothing on an
/// empty name - a control that looks live and ignores you, which is the same
/// complaint that was made about feed previews.
class _NewPlaylistDialog extends StatefulWidget {
  const _NewPlaylistDialog({required this.controller, required this.isRename});

  final TextEditingController controller;
  final bool isRename;

  @override
  State<_NewPlaylistDialog> createState() => _NewPlaylistDialogState();
}

class _NewPlaylistDialogState extends State<_NewPlaylistDialog> {
  late bool _valid = widget.controller.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_check);
  }

  @override
  void dispose() {
    // The listener only, never the controller: it belongs to the caller, which
    // outlives this widget and disposes it itself.
    widget.controller.removeListener(_check);
    super.dispose();
  }

  void _check() {
    final valid = widget.controller.text.trim().isNotEmpty;
    if (valid != _valid) setState(() => _valid = valid);
  }

  void _save() {
    final value = widget.controller.text.trim();
    if (value.isEmpty) return;
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isRename ? 'Rename playlist' : 'New playlist'),
      content: TextField(
        controller: widget.controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        // A name long enough to break the row is not worth allowing; YouTube
        // caps its own at 150.
        maxLength: 150,
        decoration: const InputDecoration(
          hintText: 'Playlist name',
          counterText: '',
        ),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _valid ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
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
    // A tall video can offer eight renditions plus the footer, more than a
    // half-height sheet fits. Without this the list overflowed and dragging it
    // dismissed the sheet instead of scrolling. Scroll-controlled lets the
    // sheet grow and the list scroll inside it.
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: FutureBuilder<List<DownloadOption>>(
        future: repo.downloadOptions(video.id, allowFfmpeg: downloads.canProcess),
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
              // The header stays put; the renditions scroll under it, capped so
              // the sheet never grows past most of the screen.
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
              if (options.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 24),
                  child: Text('Nothing downloadable for this video.'),
                ),
              for (final option in options)
                ListTile(
                  leading: Icon(
                    option.audioOnly
                        ? (option.quality == 'MP3'
                            ? Icons.audiotrack_outlined
                            : Icons.headphones_outlined)
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
                    await downloads.enqueue(
                      video,
                      audioOnly: option.audioOnly,
                      quality: option.quality,
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Downloading — see You › Downloads'),
                      ),
                    );
                  },
                ),
              // Only shown where the device cannot join tracks, so the absence
              // of HD entries does not read as a bug.
              if (options.isNotEmpty && !downloads.canProcess)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: Text(
                    'Only 360p and audio can be saved on this device. Higher '
                    'quality needs the media library, which is unavailable '
                    'here. Streaming is still up to 4K.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
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

/// Long-press / overflow menu shared by every video tile.
///
/// YouTube's order and shape: single-line 48dp rows with outlined icons, no
/// title header and no subtitles — the card the user just pressed is the
/// header. Scroll-controlled with a scrolling body, because ten rows plus the
/// handle are more than the default 9/16-height sheet holds on a small phone
/// and the last rows (the dismissals) were the ones cut off.
Future<void> showVideoMenu(
  BuildContext context,
  VideoBrief video, {
  VoidCallback? onRemove,
  String removeLabel = 'Remove',
  VoidCallback? onDismissed,
}) {
  final playback = context.read<PlaybackController>();
  final db = context.read<AppDatabase>();
  final downloads = context.read<DownloadManager>();

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => sheetTiles(
      SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              menuRow(
                icon: Icons.queue_play_next_outlined,
                label: 'Play next in queue',
                // Queued after the current video, as YouTube's "Play next"
                // does — it used to start the video at once. With nothing
                // playing there is nothing to wait for, so it plays now.
                onTap: () {
                  final queued = playback.current != null;
                  final messenger = ScaffoldMessenger.maybeOf(sheetContext);
                  playback.playAfterCurrent(video);
                  Navigator.pop(sheetContext);
                  if (queued) {
                    messenger?.showSnackBar(
                      const SnackBar(
                        content: Text('Video will play next'),
                        duration: Duration(seconds: 2),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                },
              ),
              menuRow(
                icon: Icons.watch_later_outlined,
                label: 'Save to Watch later',
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  Navigator.pop(sheetContext);
                  await db.addToPlaylist(LocalPlaylist.watchLaterId, video);
                  messenger.showSnackBar(
                    const SnackBar(
                      content: Text('Saved to Watch later'),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
              ),
              menuRow(
                icon: Icons.playlist_add,
                label: 'Save to playlist',
                onTap: () {
                  Navigator.pop(sheetContext);
                  showSaveToPlaylistSheet(context, video);
                },
              ),
              // Live: the label follows the transfer while the sheet is open.
              ListenableBuilder(
                listenable: downloads,
                builder: (_, _) {
                  final record = downloads.recordFor(video.id);
                  final state = downloadMenuState(
                    record,
                    active: downloads.isActive(video.id),
                  );
                  return menuRow(
                    icon: switch (state.kind) {
                      DownloadMenuKind.done => Icons.download_done,
                      DownloadMenuKind.active => Icons.downloading_outlined,
                      DownloadMenuKind.none => Icons.download_outlined,
                    },
                    label: state.label,
                    onTap: () async {
                      switch (state.kind) {
                        case DownloadMenuKind.none:
                          Navigator.pop(sheetContext);
                          showDownloadSheet(context, video);
                        case DownloadMenuKind.done:
                          // Asked, not done on the tap: a row reading
                          // "Downloaded" that silently deletes the file is
                          // the one-tap delete this app has shipped before.
                          final ok = await _confirm(
                            sheetContext,
                            title: 'Delete download?',
                            action: 'Delete',
                          );
                          if (!ok) return;
                          await downloads.remove(video.id);
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        case DownloadMenuKind.active:
                          final ok = await _confirm(
                            sheetContext,
                            title: 'Cancel download?',
                            action: 'Cancel download',
                            dismiss: 'Keep',
                          );
                          if (!ok) return;
                          await downloads.cancel(video.id);
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                      }
                    },
                  );
                },
              ),
              menuRow(
                icon: Icons.share_outlined,
                label: 'Share',
                onTap: () {
                  Navigator.pop(sheetContext);
                  SharePlus.instance.share(
                    ShareParams(uri: Uri.parse('https://youtu.be/${video.id}')),
                  );
                },
              ),
              if (video.channelId.isNotEmpty)
                menuRow(
                  icon: Icons.account_box_outlined,
                  label: 'Go to channel',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    ChannelPage.open(context, video.channelId,
                        title: video.author);
                  },
                ),
              const Divider(height: 9, indent: 0),
              // The only place in the app where the user states a preference
              // outright. Everything the recommender otherwise knows is
              // inferred from what they watched, and inference cannot be
              // argued with; this can, which is why YouTube treats the same
              // two controls as first-class signals and why the ranker drops
              // a match entirely rather than merely demoting it.
              menuRow(
                icon: Icons.not_interested_outlined,
                label: 'Not interested',
                onTap: () async {
                  // Taken before the await: the sheet is closing, and looking
                  // a messenger up from a context afterwards is the async-gap
                  // bug the analyzer is right to object to.
                  final messenger = ScaffoldMessenger.of(context);
                  Navigator.pop(sheetContext);
                  await db.addNotInterested(
                    id: video.id,
                    kind: DislikeKind.video,
                    // Kept so the dismissal can generalise weakly through the
                    // title's words rather than applying to this one id alone.
                    title: video.title,
                  );
                  onDismissed?.call();
                  _confirmDismissal(
                    messenger,
                    db,
                    message: 'We will stop recommending this video.',
                    id: video.id,
                    kind: DislikeKind.video,
                  );
                },
              ),
              if (video.channelId.isNotEmpty)
                menuRow(
                  icon: Icons.block_outlined,
                  label: "Don't recommend channel",
                  onTap: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    Navigator.pop(sheetContext);
                    await db.addNotInterested(
                      id: video.channelId,
                      kind: DislikeKind.channel,
                    );
                    onDismissed?.call();
                    _confirmDismissal(
                      messenger,
                      db,
                      message: 'We will stop recommending ${video.author}.',
                      id: video.channelId,
                      kind: DislikeKind.channel,
                    );
                  },
                ),
              if (onRemove != null)
                menuRow(
                  icon: Icons.delete_outline,
                  label: removeLabel,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    onRemove();
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    ),
  );
}

/// One single-line menu row: a 24dp outlined icon and a label, 48dp tall.
Widget menuRow({
  required IconData icon,
  required String label,
  required VoidCallback onTap,
}) =>
    ListTile(
      leading: Icon(icon, size: 24),
      title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: onTap,
    );

/// Sheet list styling: 48dp single-line rows with YouTube's icon gap.
///
/// Applied per sheet rather than in the global ListTileTheme, because a 48dp
/// minimum there would also shrink every Settings row, where 56 is right.
Widget sheetTiles(Widget child) => Builder(
      builder: (context) => ListTileTheme.merge(
        minTileHeight: 48,
        minLeadingWidth: 24,
        horizontalTitleGap: 20,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        titleTextStyle: Theme.of(context).textTheme.bodyLarge?.copyWith(
              fontSize: 15,
              color: Theme.of(context).colorScheme.onSurface,
            ),
        child: child,
      ),
    );

/// What the menu's download row says, and does.
enum DownloadMenuKind { none, active, done }

/// Pure so the label is testable: "Download video", "Downloading 42%"
/// (or "Downloading…" before the size is known, and "Queued" for one waiting
/// its turn), "Downloaded".
({DownloadMenuKind kind, String label}) downloadMenuState(
  DownloadRecord? record, {
  required bool active,
}) {
  if (record?.isComplete ?? false) {
    return (kind: DownloadMenuKind.done, label: 'Downloaded');
  }
  if (active && record != null) {
    if (record.status == DownloadStatus.queued) {
      return (kind: DownloadMenuKind.active, label: 'Download queued');
    }
    final p = record.progress;
    return (
      kind: DownloadMenuKind.active,
      label: p == null ? 'Downloading…' : 'Downloading ${(p * 100).floor()}%',
    );
  }
  return (kind: DownloadMenuKind.none, label: 'Download video');
}

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String action,
  String dismiss = 'Cancel',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(dismiss),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Confirms a dismissal and offers to take it back.
///
/// [onDismissed] on the menu is deliberately distinct from `onRemove`: the
/// latter means "take this out of the playlist you are looking at" and firing
/// it here would delete the video, which is emphatically not what "not
/// interested" asks for.
///
/// Undo is not politeness here. A dismissal is near-absolute in the ranker —
/// a channel one is a hard exclusion — so a mis-tap would otherwise remove a
/// channel from the feed permanently, with no indication that it had happened
/// and nothing in the UI to reverse it.
void _confirmDismissal(
  ScaffoldMessengerState messenger,
  AppDatabase db, {
  required String message,
  required String id,
  required DislikeKind kind,
}) {
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 6),
      // The SDK now keeps any snackbar with an action on screen until it is
      // dismissed (persist defaults to `action != null`), so this "Undo"
      // never left: still showing minutes later on the watch page, and
      // covering the video in Picture in Picture. Found on an emulator.
      persist: false,
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => db.removeNotInterested(id: id, kind: kind),
      ),
    ),
  );
}
