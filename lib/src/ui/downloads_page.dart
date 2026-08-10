import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/download_manager.dart';
import '../data/models.dart';
import '../player/playback_controller.dart';
import 'watch_page.dart';
import 'widgets/video_tile.dart';

/// Offline library. Everything listed here plays with no network at all.
class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final downloads = context.watch<DownloadManager>();
    final records = downloads.all;
    final completed = records.where((r) => r.isComplete).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        bottom: records.isEmpty
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
              itemBuilder: (context, index) =>
                  _DownloadTile(record: records[index]),
            ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({required this.record});

  final DownloadRecord record;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final downloads = context.read<DownloadManager>();

    return InkWell(
      onTap: record.isComplete
          ? () => WatchPage.open(context, record.video)
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                          : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 18),
              onSelected: (value) async {
                switch (value) {
                  case 'retry':
                    await downloads.enqueue(
                      record.video,
                      audioOnly: record.audioOnly,
                    );
                  case 'cancel':
                    await downloads.cancel(record.video.id);
                  case 'delete':
                    await downloads.remove(record.video.id);
                  case 'stream':
                    if (context.mounted) {
                      context.read<PlaybackController>().play(record.video);
                      WatchPage.open(context, record.video);
                    }
                }
              },
              itemBuilder: (context) => [
                if (record.status == DownloadStatus.failed)
                  const PopupMenuItem(value: 'retry', child: Text('Retry')),
                if (!record.isComplete &&
                    record.status != DownloadStatus.failed)
                  const PopupMenuItem(value: 'cancel', child: Text('Cancel')),
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
    );
  }

  String _statusLine(DownloadRecord record) {
    final kind = record.audioOnly ? 'Audio' : record.quality;
    return switch (record.status) {
      DownloadStatus.completed =>
        '$kind • ${formatBytes(record.receivedBytes)} • Available offline',
      DownloadStatus.queued => 'Queued',
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
