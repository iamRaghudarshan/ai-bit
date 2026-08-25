import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/db.dart';
import '../data/models.dart';
import 'watch_page.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// Watch history on three tabs — Videos, Shorts and Kids — so none buries the
/// others. Videos and Shorts exclude anything watched in Kids mode.
///
/// The page owns the loaded rows rather than handing a `Future` to each tab,
/// because two features need to know what is currently on screen: select-all
/// has to enumerate the active tab's ids, and the search box has to swap the
/// rows under an open selection.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this)
    ..addListener(_onTabChanged);
  int _tabIndex = 0;

  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  bool _searchOpen = false;
  String _query = '';

  /// Videos, Shorts, Kids. `null` means "still loading for the first time";
  /// a later reload keeps the old rows visible so filtering does not flash a
  /// spinner between every keystroke.
  List<List<HistoryEntry>?> _entries = [null, null, null];

  /// Guards against a slow earlier load landing after a newer one. Typing
  /// fires overlapping queries, and the stale answer must not win.
  int _loadToken = 0;

  final Set<String> _selected = {};
  bool _selecting = false;

  AppDatabase get _db => context.read<AppDatabase>();

  List<HistoryEntry> get _current => _entries[_tabIndex] ?? const [];

  @override
  void initState() {
    super.initState();
    _search.addListener(_onTyped);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabs.index == _tabIndex) return;
    setState(() {
      _tabIndex = _tabs.index;
      // A selection is per tab: ids picked on Videos are not visible on Kids,
      // and deleting rows you can no longer see is not what the count showed.
      _clearSelection();
    });
  }

  void _reload() => _load();

  Future<void> _load() async {
    final token = ++_loadToken;
    final query = _query;

    // One query per tab, filtered in SQL. Splitting a single unfiltered query
    // in Dart would be one scan instead of three, but SQLite spends its LIMIT
    // before the split, so a Kids search could come back with nothing after
    // the cap was filled by regular history that never reaches the Kids tab.
    // An empty query goes down the same path: searchWatchHistory falls back to
    // the plain history() list, with the same shorts/kids meaning.
    final videos = await _db.searchWatchHistory(
      query,
      shorts: false,
      kids: false,
    );
    final shorts = await _db.searchWatchHistory(
      query,
      shorts: true,
      kids: false,
    );
    final kids = await _db.searchWatchHistory(query, kids: true);

    if (!mounted || token != _loadToken) return;
    setState(() {
      _entries = [videos, shorts, kids];
      // A row that just left the list must not stay counted in the app bar.
      final visible = {for (final e in _current) e.video.id};
      _selected.removeWhere((id) => !visible.contains(id));
      if (_selected.isEmpty) _selecting = false;
    });
  }

  // ------------------------------------------------------------------ search

  void _onTyped() {
    final text = _search.text.trim();
    // Repaint for the clear button even before the debounce fires.
    setState(() {});
    if (text == _query) return;

    _debounce?.cancel();
    if (text.isEmpty) {
      // Clearing is not typing — going back to the full list should feel
      // instant rather than waiting out a debounce that no keystroke follows.
      _query = '';
      _load();
      return;
    }
    // 250ms: a fast typist costs one query, not one per keystroke.
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _query = text;
      _load();
    });
  }

  void _closeSearch() {
    _debounce?.cancel();
    // Clear first: the listener sees an empty box and reloads the full list.
    // Doing it after the setState would leave the filtered rows on screen with
    // no search field to explain why.
    _search.clear();
    setState(() => _searchOpen = false);
  }

  // --------------------------------------------------------------- selection

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
      // Unpicking the last row leaves selection mode, so the page cannot sit
      // in a selection bar with nothing selected and no obvious way out.
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _selectAll() {
    setState(() {
      final ids = _current.map((e) => e.video.id);
      if (_selected.length == _current.length) {
        _clearSelection();
      } else {
        _selected
          ..clear()
          ..addAll(ids);
        _selecting = _selected.isNotEmpty;
      }
    });
  }

  Future<void> _deleteSelected() async {
    final count = _selected.length;
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          count == 1 ? 'Remove 1 video?' : 'Remove $count videos?',
        ),
        content: const Text(
          'They are removed from watch history along with their saved resume '
          'position. Downloads and playlists are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final db = _db;
    final ids = _selected.toList();
    for (final id in ids) {
      await db.deleteHistoryEntry(id);
    }
    if (!mounted) return;
    setState(_clearSelection);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count == 1 ? 'Removed 1 video' : 'Removed $count videos',
        ),
      ),
    );
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
    await _db.clearHistory();
    if (!mounted) return;
    setState(_clearSelection);
    _reload();
  }

  // ------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _selecting
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Cancel selection',
                onPressed: () => setState(_clearSelection),
              )
            : _searchOpen
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Close search',
                onPressed: _closeSearch,
              )
            : null,
        title: _selecting
            ? Text('${_selected.length} selected')
            : _searchOpen
            ? TextField(
                controller: _search,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search watch history',
                  border: InputBorder.none,
                  isDense: true,
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 20),
                          onPressed: _search.clear,
                        ),
                ),
              )
            : const Text('Watch history'),
        actions: _selecting
            ? [
                IconButton(
                  icon: const Icon(Icons.select_all),
                  tooltip: _selected.length == _current.length
                      ? 'Select none'
                      : 'Select all',
                  onPressed: _current.isEmpty ? null : _selectAll,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Remove from history',
                  onPressed: _deleteSelected,
                ),
              ]
            : [
                if (!_searchOpen)
                  IconButton(
                    icon: const Icon(Icons.search),
                    tooltip: 'Search history',
                    onPressed: () => setState(() => _searchOpen = true),
                  ),
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
        // Swiping between tabs while picking rows would silently change what
        // the count refers to; the selection bar pins the view instead.
        physics: _selecting ? const NeverScrollableScrollPhysics() : null,
        children: [
          _list(
            0,
            'Videos you watch are recorded here, on this device only.',
          ),
          _list(1, 'Shorts you watch show up here.'),
          _list(2, 'What you watch in Kids mode shows up here.'),
        ],
      ),
    );
  }

  Widget _list(int index, String emptyMessage) {
    final entries = _entries[index];
    if (entries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (entries.isEmpty) {
      return EmptyState(
        icon: _query.isEmpty ? Icons.history : Icons.search_off,
        title: _query.isEmpty ? 'Nothing here yet' : 'No matches',
        message: _query.isEmpty
            ? emptyMessage
            : 'Nothing in this tab matches "$_query".',
      );
    }
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: entries.length,
      itemBuilder: (context, i) => _row(entries[i]),
    );
  }

  Widget _row(HistoryEntry entry) {
    final id = entry.video.id;

    return VideoRow(
      video: entry.video,
      progress: entry.progress,
      // Null outside selection mode, so the row looks like every other feed's;
      // in selection mode the tile draws its own circle and tint.
      selected: _selecting ? _selected.contains(id) : null,
      onLongPress: _selecting ? null : () => _beginSelection(id),
      onTap: _selecting
          ? () => _toggle(id)
          : () async {
              await WatchPage.open(context, entry.video);
              _reload();
            },
      // The per-row menu is a single-row action; it has no meaning once a
      // multi-row selection is what the app bar is acting on.
      onMenu: _selecting
          ? null
          : () => showVideoMenu(
              context,
              entry.video,
              removeLabel: 'Remove from history',
              onRemove: () async {
                await _db.deleteHistoryEntry(id);
                _reload();
              },
            ),
    );
  }
}
