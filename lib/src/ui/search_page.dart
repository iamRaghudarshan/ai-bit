import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/db.dart';
import '../data/models.dart';
import '../data/search_client.dart';
import '../data/settings.dart';
import '../data/yt_repository.dart';
import 'playlist_page.dart';
import 'watch_page.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// Search, plus the paste-a-link path: dropping any YouTube URL in the field
/// opens that video directly instead of searching for its id.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => SearchPageState();
}

class SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  Timer? _debounce;
  List<String> _suggestions = const [];

  /// Whether the completion list is on screen.
  ///
  /// It used to be shown only when there were no results — but the same
  /// debounce that fetches the completions also runs the search, so results
  /// arrived a moment later and hid them again. In practice the list never
  /// appeared. It belongs to the typing state, not to whether a search
  /// happens to have returned anything.
  bool _showSuggestions = false;

  /// What you have searched for before, newest first.
  List<String> _history = const [];
  List<VideoBrief> _results = const [];
  bool _searching = false;
  String? _error;

  /// Chosen filter per group title; null entries mean "no filter".
  final Map<String, SearchFilterOption> _filters = {};

  String? get _filterParams {
    // Every chosen filter goes into one encoded message. Picking whichever was
    // "most specific" and discarding the others meant a date filter quietly
    // cancelled the videos-only default, and no two filters ever applied
    // together.
    if (_filters.values.every((o) => o.value == null)) return null;
    return YoutubeSearchClient.buildParams(
      sortBy: _filters['Sort by']?.value,
      uploadDate: _filters['Upload date']?.value,
      duration: _filters['Duration']?.value,
      type: _filters['Type']?.value,
    );
  }

  int get _activeFilterCount =>
      _filters.values.where((o) => o.value != null).length;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTyped);
    // Dismissing the keyboard means you have finished typing, so the
    // completions make way for the results rather than sitting over them.
    _focus.addListener(_onFocusChanged);
    unawaited(_loadHistory());
    // Search is a pushed screen now, not a kept-alive tab, so focusing here is
    // safe and opens the keyboard the moment it appears — the way YouTube's
    // search does.
    _focus.requestFocus();
  }

  Future<void> _loadHistory() async {
    final history = await context.read<AppDatabase>().searchHistory();
    if (mounted) setState(() => _history = history);
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus && _showSuggestions) {
      setState(() => _showSuggestions = false);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  void _onTyped() {
    _debounce?.cancel();
    final query = _controller.text;
    if (query.trim().isEmpty) {
      setState(() {
        _suggestions = const [];
        _showSuggestions = false;
        _results = const [];
        _error = null;
        _searching = false;
      });
      return;
    }
    // Keep the clear button in sync even before the debounce fires.
    setState(() {});

    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final repo = context.read<YtRepository>();
      final suggestions = await repo.suggestions(query);
      if (!mounted || _controller.text != query) return;
      setState(() {
        _suggestions = suggestions;
        // Only while the box still has focus: results are what you want to
        // see once you have stopped typing.
        _showSuggestions = _focus.hasFocus && suggestions.isNotEmpty;
      });
      await _runSearch(query, showSpinner: _results.isEmpty);
    });
  }

  Future<void> _runSearch(String query, {bool showSpinner = true}) async {
    if (query.trim().isEmpty) return;
    if (showSpinner && mounted) setState(() => _searching = true);
    try {
      final results = await context.read<YtRepository>().search(
        query,
        params: _filterParams,
      );
      if (!mounted || _controller.text.trim() != query.trim()) return;
      // Only remember searches that found something — a typo that returned
      // nothing should not shape the home feed.
      //
      // Incognito is checked here too, not just on the watch path. The setting
      // promises to "stop recording watch and search history", and this was
      // the half that kept writing: recorded queries also feed the
      // personalised home feed, so an incognito search would have surfaced in
      // the recommendations afterwards.
      if (results.isNotEmpty &&
          mounted &&
          !context.read<SettingsService>().incognito) {
        unawaited(context.read<AppDatabase>().recordSearch(query));
      }
      setState(() {
        _results = results;
        _searching = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        // Show what actually went wrong. "Check your connection" was wrong
        // often enough to be useless — there is no log to read on a phone.
        _error = 'Search failed: $e';
      });
    }
  }

  Future<void> _submit(String rawQuery) async {
    final query = rawQuery.trim();
    if (query.isEmpty) return;
    _debounce?.cancel();
    _focus.unfocus();

    // A pasted link is a direct navigation, not a search. Playlists are checked
    // first: a "watch?v=…&list=…" URL contains both, and the list is the more
    // specific intent.
    final playlistId = YtRepository.parsePlaylistId(query);
    if (playlistId != null) {
      await PlaylistPage.openById(context, playlistId);
      return;
    }
    final videoId = YtRepository.parseVideoId(query);
    if (videoId != null) {
      await _openById(videoId);
      return;
    }
    setState(() {
      _suggestions = const [];
      _showSuggestions = false;
    });
    await _runSearch(query);
    // The list is what you see when the box is cleared, so it has to include
    // what was just searched.
    await _loadHistory();
  }

  Future<void> _openById(String videoId) async {
    setState(() => _searching = true);
    try {
      final details = await context.read<YtRepository>().videoDetails(videoId);
      if (!mounted) return;
      setState(() => _searching = false);
      await WatchPage.open(context, VideoBrief.fromYt(details));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = 'That link could not be opened. It may be private or removed.';
      });
    }
  }

  void _useSuggestion(String suggestion) {
    _controller.value = TextEditingValue(
      text: suggestion,
      selection: TextSelection.collapsed(offset: suggestion.length),
    );
    _submit(suggestion);
  }

  Future<void> _showFilters() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Row(
                    children: [
                      Text(
                        'Search filters',
                        style: Theme.of(sheetContext).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          setSheetState(_filters.clear);
                          setState(() {});
                        },
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                ),
                for (final group in YoutubeSearchClient.filters) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
                    child: Text(
                      group.title.toUpperCase(),
                      style: Theme.of(sheetContext).textTheme.labelSmall
                          ?.copyWith(letterSpacing: 1),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final option in group.options)
                          ChoiceChip(
                            label: Text(option.label),
                            selected: _filters[group.title]?.label ==
                                    option.label ||
                                (_filters[group.title] == null &&
                                    option.value == null),
                            showCheckmark: false,
                            onSelected: (_) {
                              setSheetState(() {
                                if (option.value == null) {
                                  _filters.remove(group.title);
                                } else {
                                  _filters[group.title] = option;
                                }
                              });
                              setState(() {});
                            },
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                // Choosing a chip only records the choice; the search re-runs
                // when the sheet closes. Without a button to close it there was
                // nothing to press after picking a filter, so it read as though
                // filtering did nothing at all.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: Text(
                        _activeFilterCount == 0
                            ? 'Show results'
                            : 'Show results ($_activeFilterCount filters)',
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // Re-run with whatever the sheet left selected.
    if (_controller.text.trim().isNotEmpty) {
      await _runSearch(_controller.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _controller.text.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        // Only when this page was pushed. As a bottom-nav tab there is nothing
        // to go back to, and a dead arrow is worse than none.
        leading: Navigator.of(context).canPop()
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: Badge(
              isLabelVisible: _activeFilterCount > 0,
              label: Text('$_activeFilterCount'),
              child: const Icon(Icons.tune),
            ),
            tooltip: 'Filters',
            onPressed: _showFilters,
          ),
        ],
        title: TextField(
          controller: _controller,
          focusNode: _focus,
          textInputAction: TextInputAction.search,
          onSubmitted: _submit,
          decoration: InputDecoration(
            hintText: 'Search or paste a YouTube link',
            prefixIcon: const Icon(Icons.search, size: 20),
            border: InputBorder.none,
            isDense: true,
            suffixIcon: hasText
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    onPressed: _controller.clear,
                  )
                : null,
          ),
        ),
      ),
      body: _buildBody(hasText),
    );
  }

  Widget _buildBody(bool hasText) {
    if (!hasText) {
      // Your own searches, rather than a paragraph explaining how to search.
      // An empty box is where you are most likely to want something you
      // looked for before.
      if (_history.isNotEmpty) {
        return ListView.builder(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          itemCount: _history.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
                child: Row(
                  children: [
                    Text(
                      'Recent searches',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () async {
                        await context.read<AppDatabase>().clearSearchHistory();
                        await _loadHistory();
                      },
                      child: const Text('Clear all'),
                    ),
                  ],
                ),
              );
            }
            final query = _history[index - 1];
            return ListTile(
              leading: const Icon(Icons.history, size: 20),
              title: Text(query, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Remove',
                onPressed: () async {
                  await context.read<AppDatabase>().deleteSearch(query);
                  await _loadHistory();
                },
              ),
              onTap: () {
                _controller.text = query;
                _submit(query);
              },
            );
          },
        );
      }
      return EmptyState(
        icon: Icons.search,
        title: 'Search YouTube',
        message: YtRepository.isPreview
            ? 'Live search is unavailable in the browser preview. Try "Rick", '
                  '"Queen" or "Bunny" to match the sample videos.'
            : 'Results appear as you type. You can also paste any '
                  'youtube.com or youtu.be link to open it straight away.',
      );
    }
    if (_searching && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _results.isEmpty) {
      return EmptyState(
        icon: Icons.error_outline,
        title: 'Something went wrong',
        message: _error,
        action: FilledButton(
          onPressed: () => _submit(_controller.text),
          child: const Text('Retry'),
        ),
      );
    }
    if (_showSuggestions && _suggestions.isNotEmpty) {
      return ListView.builder(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        itemCount: _suggestions.length,
        itemBuilder: (context, index) {
          final suggestion = _suggestions[index];
          return ListTile(
            leading: const Icon(Icons.search, size: 20),
            title: Text(suggestion, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => _useSuggestion(suggestion),
          );
        },
      );
    }
    if (_results.isEmpty) {
      // Be explicit about *why* there is nothing, rather than implying the
      // query simply had no matches on YouTube.
      if (YtRepository.isPreview) {
        return EmptyState(
          icon: Icons.cloud_off_outlined,
          title: 'Search needs the real app',
          message:
              'The browser preview cannot reach YouTube — the extraction '
              'library does not run in a browser, and browsers block requests '
              'to youtube.com.\n\nOnly these sample titles match here. Real '
              'search works on iOS and Android.',
          action: OutlinedButton.icon(
            onPressed: () {
              _controller.clear();
              _focus.unfocus();
            },
            icon: const Icon(Icons.list_alt),
            label: const Text('Show sample videos'),
          ),
        );
      }
      return const EmptyState(
        icon: Icons.search_off,
        title: 'No results',
        message: 'Try a different search.',
      );
    }
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final video = _results[index];
        return VideoRow(
          video: video,
          onTap: () => WatchPage.open(context, video),
          onMenu: () => showVideoMenu(context, video),
        );
      },
    );
  }
}
