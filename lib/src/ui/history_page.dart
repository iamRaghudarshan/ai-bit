import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/db.dart';
import '../data/models.dart';
import 'watch_page.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late Future<List<HistoryEntry>> _future = _load();

  Future<List<HistoryEntry>> _load() => context.read<AppDatabase>().history();

  void _reload() => setState(() => _future = _load());

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear watch history?'),
        content: const Text(
          'This removes every entry and its saved resume position. '
          'Playlists are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<AppDatabase>().clearHistory();
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Watch history'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Clear history',
            onPressed: _confirmClear,
          ),
        ],
      ),
      body: FutureBuilder<List<HistoryEntry>>(
        future: _future,
        builder: (context, snapshot) {
          final entries = snapshot.data;
          if (entries == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (entries.isEmpty) {
            return const EmptyState(
              icon: Icons.history,
              title: 'No history yet',
              message: 'Videos you watch are recorded here, on this device only.',
            );
          }
          return ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return VideoRow(
                video: entry.video,
                progress: entry.progress,
                onTap: () async {
                  await WatchPage.open(context, entry.video);
                  _reload();
                },
                onMenu: () => showVideoMenu(
                  context,
                  entry.video,
                  removeLabel: 'Remove from history',
                  onRemove: () async {
                    await context.read<AppDatabase>().deleteHistoryEntry(
                      entry.video.id,
                    );
                    _reload();
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
