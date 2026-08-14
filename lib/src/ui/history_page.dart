import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/db.dart';
import '../data/models.dart';
import 'watch_page.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// Watch history, with Videos and Shorts kept on separate tabs so one does not
/// bury the other.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  late Future<List<HistoryEntry>> _videos = _load(shorts: false);
  late Future<List<HistoryEntry>> _shorts = _load(shorts: true);

  Future<List<HistoryEntry>> _load({required bool shorts}) =>
      context.read<AppDatabase>().history(shorts: shorts);

  void _reload() => setState(() {
    _videos = _load(shorts: false);
    _shorts = _load(shorts: true);
  });

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear watch history?'),
        content: const Text(
          'This removes every entry — videos and Shorts — and its saved resume '
          'position. Playlists are not affected.',
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
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Videos'),
            Tab(text: 'Shorts'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _HistoryList(
            future: _videos,
            emptyMessage:
                'Videos you watch are recorded here, on this device only.',
            onChanged: _reload,
          ),
          _HistoryList(
            future: _shorts,
            emptyMessage: 'Shorts you watch show up here.',
            onChanged: _reload,
          ),
        ],
      ),
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({
    required this.future,
    required this.emptyMessage,
    required this.onChanged,
  });

  final Future<List<HistoryEntry>> future;
  final String emptyMessage;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<HistoryEntry>>(
      future: future,
      builder: (context, snapshot) {
        final entries = snapshot.data;
        if (entries == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (entries.isEmpty) {
          return EmptyState(
            icon: Icons.history,
            title: 'Nothing here yet',
            message: emptyMessage,
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
                onChanged();
              },
              onMenu: () => showVideoMenu(
                context,
                entry.video,
                removeLabel: 'Remove from history',
                onRemove: () async {
                  await context.read<AppDatabase>().deleteHistoryEntry(
                    entry.video.id,
                  );
                  onChanged();
                },
              ),
            );
          },
        );
      },
    );
  }
}
