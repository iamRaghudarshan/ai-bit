import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import '../data/backup_service.dart';
import '../data/db.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/storage_service.dart';

/// What the app has written to the device, and how to get it back.
///
/// iOS reports a single "Documents & Data" figure for an app and offers no way
/// to clear it short of deleting the app. Downloaded videos dominate it, so
/// this breaks the total down and lets each part go independently — clearing
/// the cache should not cost you your downloads.
class StoragePage extends StatefulWidget {
  const StoragePage({super.key});

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  StorageUsage? _usage;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final usage = await context.read<StorageService>().measure();
    if (mounted) setState(() => _usage = usage);
  }

  /// Runs [action] behind a confirmation, then re-measures.
  ///
  /// All three of these delete something the user cannot get back locally, so
  /// none of them happen on a single tap.
  Future<void> _confirmAndRun({
    required String title,
    required String message,
    required String confirmLabel,
    required Future<void> Function() action,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final before = _usage?.totalBytes ?? 0;
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _measure();
    if (!mounted) return;

    final freed = before - (_usage?.totalBytes ?? before);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          freed > 0 ? 'Freed ${formatBytes(freed)}.' : 'Nothing left to clear.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final usage = _usage;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Storage')),
      body: usage == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatBytes(usage.totalBytes),
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'used on this device',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                if (usage.totalBytes > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                    child: _UsageBar(usage: usage),
                  ),
                const Divider(height: 24),
                for (final bucket in usage.all)
                  ListTile(
                    title: Text(bucket.label),
                    subtitle: Text(bucket.description),
                    isThreeLine: true,
                    trailing: Text(
                      formatBytes(bucket.bytes),
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                const Divider(height: 24),
                ListTile(
                  enabled: !_busy,
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: const Text('Clear cache'),
                  subtitle: Text(
                    'Frees ${formatBytes(usage.cache.bytes)}. Thumbnails '
                    'reload as you browse; nothing you saved is touched.',
                  ),
                  isThreeLine: true,
                  onTap: () => _confirmAndRun(
                    title: 'Clear cache?',
                    message: 'This frees ${formatBytes(usage.cache.bytes)}. '
                        'Downloads, playlists and history are not affected.',
                    confirmLabel: 'Clear',
                    action: context.read<StorageService>().clearCache,
                  ),
                ),
                ListTile(
                  enabled: !_busy && usage.downloads.itemCount > 0,
                  leading: const Icon(Icons.download_done_outlined),
                  title: const Text('Delete all downloads'),
                  subtitle: Text(
                    usage.downloads.itemCount == 0
                        ? 'Nothing downloaded.'
                        : '${usage.downloads.itemCount} video'
                            '${usage.downloads.itemCount == 1 ? '' : 's'}, '
                            '${formatBytes(usage.downloads.bytes)}. They will '
                            'have to be downloaded again.',
                  ),
                  isThreeLine: true,
                  onTap: () => _confirmAndRun(
                    title: 'Delete all downloads?',
                    message:
                        'This removes ${usage.downloads.itemCount} offline '
                        'video${usage.downloads.itemCount == 1 ? '' : 's'} and '
                        'frees ${formatBytes(usage.downloads.bytes)}. They can '
                        'be downloaded again while you are online.',
                    confirmLabel: 'Delete',
                    action: context.read<StorageService>().clearDownloads,
                  ),
                ),
                ListTile(
                  enabled: !_busy,
                  leading: const Icon(Icons.history_toggle_off),
                  title: const Text('Clear watch and search history'),
                  subtitle: const Text(
                    'Playlists, subscriptions and downloads are kept. The home '
                    'feed is built from your searches, so it will start over.',
                  ),
                  isThreeLine: true,
                  onTap: () => _confirmAndRun(
                    title: 'Clear history?',
                    message: 'Watch history, saved positions and search '
                        'history are deleted. Playlists, subscriptions and '
                        'downloads are kept.',
                    confirmLabel: 'Clear',
                    action: context.read<StorageService>().clearHistory,
                  ),
                ),
                const Divider(height: 24),
                const _SectionLabel('Backup'),
                ListTile(
                  enabled: !_busy,
                  leading: const Icon(Icons.upload_file_outlined),
                  title: const Text('Back up library'),
                  subtitle: const Text(
                    'Export playlists, subscriptions and history to a file you '
                    'can save or send elsewhere. Downloads are not included.',
                  ),
                  isThreeLine: true,
                  onTap: _backup,
                ),
                ListTile(
                  enabled: !_busy,
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('Restore from backup'),
                  subtitle: const Text(
                    'Merge a backup file into this device. Existing items are '
                    'kept; the backup is added on top.',
                  ),
                  isThreeLine: true,
                  onTap: _restore,
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Future<void> _backup() async {
    setState(() => _busy = true);
    try {
      final path = await BackupService(context.read<AppDatabase>()).export();
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path)],
          text: 'AI BIT library backup',
        ),
      );
    } catch (e) {
      if (mounted) _snack('Backup failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (picked.isEmpty) return;
    final path = picked.first.path;
    if (path == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final summary =
          await BackupService(context.read<AppDatabase>()).restore(path);
      if (mounted) _snack(summary);
    } catch (e) {
      if (mounted) _snack('Restore failed — is it an AI BIT backup? ($e)');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));
}

/// Small caps section label, matching the settings screen.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(
          label.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 1,
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
        ),
      );
}

/// Single stacked bar showing the split, so the biggest offender is obvious
/// without reading three numbers.
class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.usage});

  final StorageUsage usage;

  @override
  Widget build(BuildContext context) {
    const colours = [Color(0xFFEF5350), Color(0xFF42A5F5), Color(0xFF66BB6A)];
    final total = usage.totalBytes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                for (var i = 0; i < usage.all.length; i++)
                  if (usage.all[i].bytes > 0)
                    Expanded(
                      flex: usage.all[i].bytes,
                      child: ColoredBox(color: colours[i]),
                    ),
                // Keeps the bar full width when everything is empty.
                if (total == 0)
                  const Expanded(child: ColoredBox(color: Colors.white24)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 14,
          runSpacing: 4,
          children: [
            for (var i = 0; i < usage.all.length; i++)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 8, height: 8, color: colours[i]),
                  const SizedBox(width: 5),
                  Text(
                    usage.all[i].label,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}
