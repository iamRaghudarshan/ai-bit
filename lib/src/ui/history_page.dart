import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/db.dart';
import '../data/models.dart';
import 'watch_page.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// Watch history on three tabs — Videos, Shorts and Kids — so none buries the
/// others. Videos and Shorts exclude anything watched in Kids mode.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  // Videos and Shorts are non-kids; Kids is everything watched in Kids mode.
  late Future<List<HistoryEntry>> _videos = _db.history(shorts: false, kids: false);
  late Future<List<HistoryEntry>> _shorts = _db.history(shorts: true, kids: false);
  late Future<List<HistoryEntry>> _kids = _db.history(kids: true);

  AppDatabase get _db => context.read<AppDatabase>();

  void _reload() => setState(() {
    _videos = _db.history(shorts: false, kids: false);
    _shorts = _db.history(shorts: true, kids: false);
    _kids = _db.history(kids: true);
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
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Videos'),
            Tab(text: 'Shorts'),
            Tab(text: 'Kids'),
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
          _HistoryList(
            future: _kids,
            emptyMessage: 'What you watch in Kids mode shows up here.',
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
