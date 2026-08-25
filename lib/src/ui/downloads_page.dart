import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/download_manager.dart';
import '../data/models.dart';
import '../player/playback_controller.dart';
import 'watch_page.dart';
import 'widgets/video_tile.dart';

/// Offline library. Everything listed here plays with no network at all.
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  final Set<String> _selected = {};
  bool _selecting = false;

  void _clearSelection() {
    _selected.clear();
    _selecting = false;
  }

  void _beginSelection(String videoId) {
    setState(() {
      _selecting = true;
      _selected.add(videoId);
    });
  }

  void _toggle(String videoId) {
    setState(() {
      if (!_selected.remove(videoId)) _selected.add(videoId);
      // Unpicking the last row leaves selection mode rather than stranding the
      // page in a selection bar with a count of zero.
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _selectAll(List<DownloadRecord> records) {
    setState(() {
      if (_selected.length == records.length) {
        _clearSelection();
      } else {
        _selected
          ..clear()
          ..addAll(records.map((r) => r.video.id));
        _selecting = _selected.isNotEmpty;
      }
    });
  }

  Future<void> _deleteSelected(List<DownloadRecord> records) async {
    final count = _selected.length;
    if (count == 0) return;
    final unfinished = records
        .where((r) => _selected.contains(r.video.id) && !r.isComplete)
        .length;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          count == 1 ? 'Delete 1 download?' : 'Delete $count downloads?',
        ),
        content: Text(
          unfinished == 0
              ? 'The files are removed from this device. They can be '
                    'downloaded again later.'
              : 'The files are removed from this device, and $unfinished '
                    'still transferring ${unfinished == 1 ? 'is' : 'are'} '
                    'cancelled. They can be downloaded again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final downloads = context.read<DownloadManager>();
    final messenger = ScaffoldMessenger.of(context);
    // Serial, and by id: DownloadManager.cancel stops the in-flight transfer
    // before deleting, and both paths delete the file — reimplementing that
    // here would leave orphaned files in the app's private storage.
    for (final record in records) {
      if (!_selected.contains(record.video.id)) continue;
      try {
        if (record.isComplete) {
          await downloads.remove(record.video.id);
        } else {
          await downloads.cancel(record.video.id);
        }
      } catch (e) {
        // One stubborn file must not abandon the rest of the selection; say
        // which one failed rather than swallowing it.
        messenger.showSnackBar(
          SnackBar(content: Text('${record.video.title}: $e')),
        );
      }
    }
    if (!mounted) return;
    setState(_clearSelection);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          count == 1 ? 'Deleted 1 download' : 'Deleted $count downloads',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final downloads = context.watch<DownloadManager>();
    final records = downloads.all;
    final completed = records.where((r) => r.isComplete).length;

    // A transfer that finished or was removed elsewhere must not stay counted.
    final present = {for (final r in records) r.video.id};
    _selected.removeWhere((id) => !present.contains(id));
    if (_selected.isEmpty) _selecting = false;

    return Scaffold(
      appBar: AppBar(
        leading: _selecting
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Cancel selection',
                onPressed: () => setState(_clearSelection),
              )
            : null,
        title: _selecting
            ? Text('${_selected.length} selected')
            : const Text('Downloads'),
        actions: _selecting
            ? [
                IconButton(
                  icon: const Icon(Icons.select_all),
                  tooltip: _selected.length == records.length
                      ? 'Select none'
                      : 'Select all',
                  onPressed: () => _selectAll(records),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Delete downloads',
                  onPressed: () => _deleteSelected(records),
                ),
              ]
            : null,
        bottom: records.isEmpty || _selecting
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '$completed available offline • '
                      '${formatBytes(downloads.storageUsed)} used',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ),
      ),
      body: records.isEmpty
          ? const EmptyState(
              icon: Icons.download_outlined,
              title: 'No downloads yet',
              message:
                  'Tap the ⋮ menu on any video and choose Download to save it '
                  'here. Downloads play with no network and no data use.',
            )
          : ListView.separated(
              itemCount: records.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final record = records[index];
                return _DownloadTile(
                  record: record,
                  selecting: _selecting,
                  selected: _selected.contains(record.video.id),
                  onToggle: () => _toggle(record.video.id),
                  onLongPress: () => _beginSelection(record.video.id),
                );
              },
            ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({
    required this.record,
    required this.selecting,
    required this.selected,
    required this.onToggle,
    required this.onLongPress,
  });

  final DownloadRecord record;
  final bool selecting;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final downloads = context.read<DownloadManager>();

    return InkWell(
      onLongPress: selecting ? null : onLongPress,
      onTap: selecting
          ? onToggle
          : record.isComplete
          ? () => WatchPage.open(context, record.video)
          : null,
      child: ColoredBox(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.14)
            : Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selecting) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 10, top: 24),
                  child: Icon(
                    selected ? Icons.check_circle : Icons.circle_outlined,
                    size: 22,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                ),
              ],
              SizedBox(
                width: 130,
                child: Stack(
                  children: [
                    VideoThumb(video: record.video, radius: 8),
                    if (!record.isComplete)
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Center(
                            child: record.status == DownloadStatus.failed
                                ? const Icon(
                                    Icons.error_outline,
                                    color: Colors.white70,
                                  )
                                : record.status == DownloadStatus.paused
                                ? const Icon(
                                    Icons.pause_circle_outline,
                                    color: Colors.white70,
                                  )
                                : SizedBox(
                                    width: 26,
                                    height: 26,
                                    child: CircularProgressIndicator(
                                      value: record.progress,
                                      strokeWidth: 2.5,
                                      color: Colors.white,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.video.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.25),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _statusLine(record),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: record.status == DownloadStatus.failed
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.6,
                              ),
                      ),
                    ),
                  ],
                ),
              ),
              // Per-row actions have no meaning once the app bar is acting on
              // a multi-row selection.
              if (!selecting)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, size: 18),
                  onSelected: (value) async {
                    final messenger = ScaffoldMessenger.of(context);
                    try {
                      switch (value) {
                        case 'retry':
                          await downloads.enqueue(
                            record.video,
                            audioOnly: record.audioOnly,
                            quality: record.quality,
                          );
                        case 'pause':
                          await downloads.pause(record.video.id);
                        case 'resume':
                          await downloads.resume(record.video.id);
                        case 'top':
                          final order = downloads.pendingOrder;
                          final at = order.indexOf(record.video.id);
                          if (at > 0) downloads.reorderPending(at, 0);
                        case 'cancel':
                          await downloads.cancel(record.video.id);
                        case 'delete':
                          await downloads.remove(record.video.id);
                        case 'gallery':
                          await downloads.saveToGallery(record.video.id);
                          messenger.showSnackBar(
                            const SnackBar(content: Text('Saved to Photos')),
                          );
                        case 'export':
                          await downloads.exportDownload(record.video.id);
                        case 'stream':
                          if (context.mounted) {
                            context.read<PlaybackController>().play(
                              record.video,
                            );
                            WatchPage.open(context, record.video);
                          }
                      }
                    } catch (e) {
                      messenger.showSnackBar(SnackBar(content: Text('$e')));
                    }
                  },
                  itemBuilder: (context) => [
                    if (record.status == DownloadStatus.failed)
                      const PopupMenuItem(value: 'retry', child: Text('Retry')),
                    if (record.status == DownloadStatus.running ||
                        record.status == DownloadStatus.queued)
                      const PopupMenuItem(value: 'pause', child: Text('Pause')),
                    if (record.status == DownloadStatus.paused)
                      const PopupMenuItem(
                        value: 'resume',
                        child: Text('Resume'),
                      ),
                    if (record.status == DownloadStatus.queued &&
                        downloads.pendingOrder.length > 1 &&
                        downloads.pendingOrder.first != record.video.id)
                      const PopupMenuItem(
                        value: 'top',
                        child: Text('Move to top of queue'),
                      ),
                    if (!record.isComplete &&
                        record.status != DownloadStatus.failed)
                      const PopupMenuItem(
                        value: 'cancel',
                        child: Text('Cancel'),
                      ),
                    if (record.isComplete && !record.audioOnly)
                      const PopupMenuItem(
                        value: 'gallery',
                        child: Text('Save to Photos'),
                      ),
                    if (record.isComplete)
                      const PopupMenuItem(
                        value: 'export',
                        child: Text('Export / Save to Files'),
                      ),
                    if (record.isComplete)
                      const PopupMenuItem(
                        value: 'stream',
                        child: Text('Play from YouTube instead'),
                      ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Delete download'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _statusLine(DownloadRecord record) {
    final kind = record.audioOnly ? 'Audio' : record.quality;
    return switch (record.status) {
      DownloadStatus.completed =>
        '$kind • ${formatBytes(record.receivedBytes)} • Available offline',
      DownloadStatus.queued => 'Queued',
      DownloadStatus.paused => 'Paused • tap to resume',
      DownloadStatus.running =>
        record.totalBytes > 0
            ? '${formatBytes(record.receivedBytes)} of '
                  '${formatBytes(record.totalBytes)} '
                  '(${((record.progress ?? 0) * 100).toStringAsFixed(0)}%)'
            : 'Starting…',
      DownloadStatus.failed => record.error ?? 'Download failed',
    };
  }
}
