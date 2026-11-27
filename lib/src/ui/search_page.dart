import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/db.dart';
import '../data/models.dart';
import '../data/search_client.dart';
import '../data/settings.dart';
import '../data/yt_repository.dart';
import 'playlist_page.dart';
import 'search_helpers.dart';
import 'search_result_cards.dart';
import 'watch_page.dart';
import 'widgets/responsive_feed.dart';
import 'widgets/sheets.dart';
import 'widgets/video_tile.dart';

/// Search, laid out and behaving like YouTube's Android app.
///
/// Two explicit states, which the old screen blurred together:
///
///  * **Editing** — the box is focused. Typing fetches completions only
///    (150ms debounce); an empty box shows recent searches. Nothing is
///    searched and nothing is recorded until a search is actually chosen —
///    submit, a suggestion, or a recent search. The old screen ran the search
///    from the same debounce as the completions and recorded every partial
///    query it found results for, so "kan", "kann" and "kanna" all landed in
///    history and fed the home feed.
///  * **Results** — the query shown as a read-only pill. Tapping it returns to
///    editing with the text selected; back from editing returns here, and back
///    from here leaves the screen.
///
/// Pasting any YouTube link still opens it directly instead of searching.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.initialQuery});

  /// Runs this search on arrival instead of opening the keyboard.
  final String? initialQuery;

  /// The route to push. A quick fade, the way YouTube's search appears over
  /// the feed, rather than the platform's page slide.
  static Route<void> route({String? initialQuery}) => PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 180),
    reverseTransitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (_, _, _) => SearchPage(initialQuery: initialQuery),
    transitionsBuilder: (_, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
  );

  static Future<void> open(BuildContext context, {String? initialQuery}) =>
      Navigator.of(context).push(route(initialQuery: initialQuery));

  @override
  State<SearchPage> createState() => SearchPageState();
}

class SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  // ------------------------------------------------------------ editing
  bool _editing = true;
  Timer? _debounce;
  List<String> _remoteSuggestions = const [];
  String _suggestionsFor = '';
  List<String> _history = const [];

  // ------------------------------------------------------------ results
  /// The query whose results are on screen; null before the first search.
  String? _query;
  SearchFilters _filters = SearchFilters.none;

  /// YouTube's own `params` for one search, from "Search instead for".
  String? _paramsOverride;
  List<SearchChip> _chips = const [];
  int _chipIndex = 0;
  List<SearchItem> _items = const [];
  final _seen = <String>{};
  String? _continuation;
  SearchCorrection? _correction;
  Set<String> _watched = const {};

  bool _loading = false;
  bool _loadingMore = false;
  bool _moreFailed = false;
  int _emptyPages = 0;
  String? _error;

  /// Bumped by every fresh first page, so a slow response for a query or
  /// chip the user has already left is dropped instead of drawn.
  int _serial = 0;

  bool get _kids => context.read<SettingsService>().kidsMode;

  SearchChip? get _activeChip =>
      _chipIndex > 0 && _chipIndex < _chips.length ? _chips[_chipIndex] : null;

  List<SearchItem> get _visibleItems => (_activeChip?.isUnwatched ?? false)
      ? withoutWatched(_items, _watched)
      : _items;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTyped);
    unawaited(_loadHistory());
    final initial = widget.initialQuery?.trim();
    if (initial != null && initial.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runQuery(initial));
    } else {
      // A pushed screen, so focusing here is safe and opens the keyboard the
      // moment it appears — the way YouTube's search does.
      _focus.requestFocus();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final history = await context.read<AppDatabase>().searchHistory();
    if (mounted) setState(() => _history = history);
  }

  // ------------------------------------------------------------- typing

  void _onTyped() {
    if (!_editing) return;
    _debounce?.cancel();
    final text = _controller.text;
    // Keep the clear button in sync before the debounce fires.
    setState(() {});
    if (text.trim().isEmpty) {
      _remoteSuggestions = const [];
      _suggestionsFor = '';
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 150), () async {
      final suggestions = await context.read<YtRepository>().suggestions(text);
      if (!mounted || _controller.text != text) return;
      setState(() {
        _remoteSuggestions = suggestions;
        _suggestionsFor = text;
      });
    });
  }

  /// From the box's search key: a pasted link opens; anything else searches.
  Future<void> _submit(String raw) async {
    final query = raw.trim();
    if (query.isEmpty) return;
    // A pasted link is a direct navigation, not a search, and is not
    // remembered as one. Playlists first: a "watch?v=…&list=…" URL holds both
    // and the list is the more specific intent.
    final playlistId = YtRepository.parsePlaylistId(query);
    if (playlistId != null) {
      _focus.unfocus();
      await PlaylistPage.openById(context, playlistId);
      return;
    }
    final videoId = YtRepository.parseVideoId(query);
    if (videoId != null) {
      _focus.unfocus();
      await _openById(videoId);
      return;
    }
    await _runQuery(query);
  }

  Future<void> _openById(String videoId) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final details = await context.read<YtRepository>().videoDetails(videoId);
      if (!mounted) return;
      await WatchPage.open(context, VideoBrief.fromYt(details));
    } catch (e) {
      debugPrint('AI BIT search: link $videoId failed — $e');
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'That link could not be opened. It may be private or removed.',
          ),
        ),
      );
    }
  }

  /// Commits [raw] as THE search: records it, shows results.
  ///
  /// The only place a search is recorded, and only for a query someone
  /// chose. Incognito skips it because recorded queries personalise the home
  /// feed; Kids mode skips it because the taste profile must not learn from
  /// a child's searches.
  Future<void> _runQuery(String raw, {String? params}) async {
    final query = raw.trim();
    if (query.isEmpty) return;
    _debounce?.cancel();
    final settings = context.read<SettingsService>();
    if (!settings.incognito && !settings.kidsMode) {
      final db = context.read<AppDatabase>();
      unawaited(db.recordSearch(query).then((_) => _loadHistory()));
    }
    _focus.unfocus();
    _editing = false;
    _controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
    setState(() {
      // A new query starts unfiltered, as YouTube does; re-running the same
      // one keeps what was chosen.
      if (query != _query) _filters = SearchFilters.none;
      _query = query;
      _paramsOverride = params;
      _chips = const [];
      _chipIndex = 0;
    });
    await _loadFirst();
  }

  /// Back to editing from the results pill, with the query selected so typing
  /// replaces it and the arrow keys can amend it.
  void _startEditing({bool clear = false}) {
    final text = clear ? '' : (_query ?? '');
    // The flag first, then the text: the controller's listener fetches
    // completions only while editing, and it fires on this assignment.
    _editing = true;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: 0, extentOffset: text.length),
    );
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _backToResults() {
    _debounce?.cancel();
    _focus.unfocus();
    _editing = false;
    final q = _query ?? '';
    _controller.value = TextEditingValue(
      text: q,
      selection: TextSelection.collapsed(offset: q.length),
    );
    setState(() {});
  }

  /// The north-west arrow: put the suggestion in the box and keep typing.
  void _fillFromSuggestion(String suggestion) {
    final text = '${suggestion.trimRight()} ';
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focus.requestFocus();
  }

  // ------------------------------------------------------------ loading

  Future<void> _loadFirst() async {
    final query = _query;
    if (query == null) return;
    final serial = ++_serial;
    final chip = _activeChip;
    setState(() {
      _loading = true;
      _error = null;
      _items = const [];
      _seen.clear();
      _continuation = null;
      _moreFailed = false;
      _emptyPages = 0;
      if (chip == null) _correction = null;
    });
    final repo = context.read<YtRepository>();
    final db = context.read<AppDatabase>();
    final kids = _kids;
    try {
      final batch = chip?.token != null
          ? await repo.searchMore(chip!.token!, kids: kids)
          : await repo.searchPage(
              query,
              params: _paramsOverride ?? _filters.toParams(),
              kids: kids,
            );
      final watched = (chip?.isUnwatched ?? false)
          ? await db.watchedVideoIds()
          : _watched;
      if (!mounted || serial != _serial) return;
      _logSkipped(batch);
      setState(() {
        _loading = false;
        _items = appendUnique(const [], batch.items, _seen);
        _continuation = batch.continuation;
        _watched = watched;
        if (chip == null) {
          // The chip bar comes with the plain query's first page; a chip's
          // own page carries the same set, so the bar is kept from here.
          _chips = batch.chips;
          final selected = _chips.indexWhere((c) => c.selected);
          _chipIndex = selected < 0 ? 0 : selected;
          _correction = batch.correction;
        }
      });
    } catch (e) {
      debugPrint('AI BIT search: "$query" failed — $e');
      if (!mounted || serial != _serial) return;
      setState(() {
        _loading = false;
        // Show what actually went wrong; there is no log to read on a phone.
        _error = '$e';
      });
    }
  }

  Future<void> _loadMore() async {
    final token = _continuation;
    if (token == null || _loading || _loadingMore || _moreFailed) return;
    final serial = _serial;
    final repo = context.read<YtRepository>();
    final kids = _kids;
    setState(() => _loadingMore = true);
    try {
      final batch = await repo.searchMore(token, kids: kids);
      if (!mounted || serial != _serial) return;
      _logSkipped(batch);
      setState(() {
        final before = _items.length;
        _items = appendUnique(_items, batch.items, _seen);
        _emptyPages = _items.length == before ? _emptyPages + 1 : 0;
        // Three pages in a row with nothing new is YouTube padding the end
        // of a result set; stop rather than fetch forever.
        _continuation = _emptyPages >= 3 ? null : batch.continuation;
        _loadingMore = false;
      });
    } catch (e) {
      debugPrint('AI BIT search: next page failed — $e');
      if (!mounted || serial != _serial) return;
      setState(() {
        _loadingMore = false;
        _moreFailed = true;
      });
    }
  }

  void _logSkipped(SearchBatch batch) {
    for (final s in batch.skipped) {
      debugPrint('AI BIT search: skipped $s');
    }
  }

  void _selectChip(int index) {
    if (index == _chipIndex || _loading) return;
    setState(() => _chipIndex = index);
    unawaited(_loadFirst());
  }

  // ------------------------------------------------------ history edits

  Future<void> _confirmRemove(String query) async {
    final db = context.read<AppDatabase>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(query, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: const Text('Remove from search history?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await db.deleteSearch(query);
    await _loadHistory();
  }

  Future<void> _confirmClearAll() async {
    final db = context.read<AppDatabase>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear search history?'),
        content: const Text(
          'Every recent search on this device will be removed. Recommendations '
          'will no longer use them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await db.clearSearchHistory();
    await _loadHistory();
  }

  // ------------------------------------------------------------ filters

  Future<void> _showFilters() async {
    final kids = _kids;
    var draft = _filters;
    final groups = [
      for (final g in YoutubeSearchClient.filters)
        // Channels, playlists and movies are doors out of Kids mode's
        // curation, and are dropped from its results anyway.
        if (kids && g.kind == SearchFilterKind.type)
          SearchFilterGroup(g.kind, g.title, [
            for (final o in g.options)
              if (o.value == null || o.value == 1 || o.value == 9) o,
          ])
        else
          g,
    ];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) {
          final theme = Theme.of(sheetContext);
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetContext).size.height * 0.85,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
                      child: Row(
                        children: [
                          Text(
                            'Search filters',
                            style: theme.textTheme.titleMedium,
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: draft.isEmpty
                                ? null
                                : () => setSheet(
                                    () => draft = SearchFilters.none,
                                  ),
                            child: const Text('Reset'),
                          ),
                        ],
                      ),
                    ),
                    for (final group in groups) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
                        child: Text(
                          group.title,
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            if (group.multiSelect)
                              ChoiceChip(
                                label: const Text('Any'),
                                selected: draft.features.isEmpty,
                                showCheckmark: false,
                                onSelected: (_) => setSheet(
                                  () => draft = draft.toggled(group.kind, null),
                                ),
                              ),
                            for (final option in group.options)
                              group.multiSelect
                                  ? FilterChip(
                                      label: Text(option.label),
                                      selected: draft.isSelected(
                                        group.kind,
                                        option.value,
                                      ),
                                      onSelected: (_) => setSheet(
                                        () => draft = draft.toggled(
                                          group.kind,
                                          option.value,
                                        ),
                                      ),
                                    )
                                  : ChoiceChip(
                                      label: Text(option.label),
                                      selected: draft.isSelected(
                                        group.kind,
                                        option.value,
                                      ),
                                      showCheckmark: false,
                                      onSelected: (_) => setSheet(
                                        () => draft = draft.toggled(
                                          group.kind,
                                          option.value,
                                        ),
                                      ),
                                    ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          child: Text(
                            draft.activeCount == 0
                                ? 'Show results'
                                : 'Show results (${draft.activeCount} '
                                      '${draft.activeCount == 1 ? 'filter' : 'filters'})',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    // Applied when the sheet closes, however it closes — swiping it away
    // after picking a filter still means "show me that".
    if (!mounted || draft == _filters) return;
    setState(() {
      _filters = draft;
      _paramsOverride = null;
      _chipIndex = 0;
      _chips = const [];
    });
    await _loadFirst();
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final hasResults = _query != null;
    // select, not read: a read inside build asserts in provider.
    final kids = context.select<SettingsService, bool>((s) => s.kidsMode);
    return PopScope(
      // Back from editing returns to the results it came from; only back
      // from the results (or from a first, empty edit) leaves the screen.
      canPop: !(_editing && hasResults),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backToResults();
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          automaticallyImplyLeading: false,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          // Swapped without a cross-fade on purpose: both halves of a fade
          // would be alive at once, and a quick tap back into editing would
          // then attach the one FocusNode to two text fields.
          title: _editing ? _searchField(context) : _queryPill(context),
          actions: [
            if (!_editing && hasResults)
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: Badge(
                  isLabelVisible: _filters.activeCount > 0,
                  label: Text('${_filters.activeCount}'),
                  child: const Icon(Icons.more_vert),
                ),
                onSelected: (value) {
                  if (value == 'filters') unawaited(_showFilters());
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'filters',
                    child: Row(
                      children: [
                        const Icon(Icons.tune, size: 20),
                        const SizedBox(width: 12),
                        Text(
                          _filters.activeCount == 0
                              ? 'Search filters'
                              : 'Search filters (${_filters.activeCount})',
                        ),
                      ],
                    ),
                  ),
                ],
              )
            else
              const SizedBox(width: 12),
          ],
        ),
        // The results stay built underneath while editing, so going back to
        // them keeps their scroll position, an expanded shelf and a channel
        // card's subscribe state; the editing layer fades over them.
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (hasResults) _resultsBody(context, kids: kids),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: _editing
                  ? ColoredBox(
                      key: const ValueKey('editing'),
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: _editingBody(context),
                    )
                  : const SizedBox.shrink(key: ValueKey('none')),
            ),
          ],
        ),
      ),
    );
  }

  /// The filled pill YouTube uses: 40dp, fully rounded.
  Widget _searchField(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasText = _controller.text.isNotEmpty;
    return Container(
      height: 40,
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        textInputAction: TextInputAction.search,
        onSubmitted: _submit,
        style: const TextStyle(fontSize: 16),
        decoration: InputDecoration(
          hintText: 'Search YouTube',
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 40,
            minHeight: 40,
          ),
          suffixIcon: hasText
              ? IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: 'Clear',
                  onPressed: () {
                    _controller.clear();
                    _focus.requestFocus();
                  },
                )
              : null,
        ),
      ),
    );
  }

  /// The results-state box: the query, read-only; a tap edits it.
  Widget _queryPill(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _startEditing,
        child: SizedBox(
          height: 40,
          child: Row(
            children: [
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  _query ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                tooltip: 'Clear',
                onPressed: () => _startEditing(clear: true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------- editing body

  Widget _editingBody(BuildContext context) {
    final text = _controller.text;
    if (text.trim().isEmpty) return _recentSearches(context);

    // Completions for exactly what is typed; until they arrive, matching past
    // searches alone, rather than the previous word's completions.
    final remote = _suggestionsFor == text ? _remoteSuggestions : const <String>[];
    final rows = mergeSuggestions(text, _history, remote);
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: rows.length,
      itemBuilder: (context, i) => _SuggestionRow(
        suggestion: rows[i],
        typed: text,
        onTap: () => _runQuery(rows[i].text),
        onFill: () => _fillFromSuggestion(rows[i].text),
        onLongPress: rows[i].fromHistory
            ? () => _confirmRemove(rows[i].text)
            : null,
      ),
    );
  }

  Widget _recentSearches(BuildContext context) {
    if (_history.isEmpty) {
      return EmptyState(
        icon: Icons.search,
        title: 'Search YouTube',
        message: YtRepository.isPreview
            ? 'Live search is unavailable in the browser preview. Try "Rick", '
                  '"Queen" or "Bunny" to match the sample videos.'
            : 'You can also paste a youtube.com or youtu.be link to open it '
                  'straight away.',
      );
    }
    return ListView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: _history.length + 1,
      itemBuilder: (context, index) {
        if (index == _history.length) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _confirmClearAll,
                child: const Text('Clear search history'),
              ),
            ),
          );
        }
        final query = _history[index];
        return _SuggestionRow(
          suggestion: SearchSuggestion(query, fromHistory: true),
          typed: '',
          onTap: () => _runQuery(query),
          onFill: () => _fillFromSuggestion(query),
          onLongPress: () => _confirmRemove(query),
        );
      },
    );
  }

  // -------------------------------------------------------- results body

  Widget _resultsBody(BuildContext context, {required bool kids}) {
    final showChips = _chips.length > 1 && !kids;
    return Column(
      children: [
        if (showChips)
          SearchChipBar(
            chips: _chips,
            selected: _chipIndex,
            onSelected: _selectChip,
          ),
        Expanded(child: _resultsContent(context)),
      ],
    );
  }

  Widget _resultsContent(BuildContext context) {
    if (_loading) return const FeedSkeleton();
    final items = _visibleItems;
    if (_error != null && items.isEmpty) {
      return EmptyState(
        icon: Icons.error_outline,
        title: 'Something went wrong',
        message: _error,
        action: FilledButton(
          onPressed: _loadFirst,
          child: const Text('Retry'),
        ),
      );
    }
    if (items.isEmpty && _continuation == null) {
      if (YtRepository.isPreview) {
        return const EmptyState(
          icon: Icons.cloud_off_outlined,
          title: 'Search needs the real app',
          message:
              'The browser preview cannot reach YouTube — the extraction '
              'library does not run in a browser, and browsers block requests '
              'to youtube.com.\n\nOnly the sample titles match here. Real '
              'search works on iOS and Android.',
        );
      }
      return EmptyState(
        icon: Icons.search_off,
        title: 'No results',
        message: _filters.isEmpty
            ? 'Try different keywords.'
            : 'Try different keywords or remove search filters.',
      );
    }

    final hasCorrection = _correction != null && _activeChip == null;
    final hasFooter = _continuation != null || _loadingMore || _moreFailed;
    final lead = hasCorrection ? 1 : 0;
    final count = lead + items.length + (hasFooter ? 1 : 0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final phone = feedColumnsFor(constraints.maxWidth) == 1;
        return ListView.builder(
          key: PageStorageKey('search-results-$_serial'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: count,
          itemBuilder: (context, index) {
            if (hasCorrection && index == 0) {
              return SearchCorrectionBanner(
                correction: _correction!,
                onSearch: (q, {params}) => _runQuery(q, params: params),
              );
            }
            final i = index - lead;
            if (i >= items.length) return _footer(context);
            // Ask for the next page while ~3 results are still to come.
            if (i >= items.length - 3 && _continuation != null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _loadMore();
              });
            }
            return _itemView(context, items[i], phone: phone);
          },
        );
      },
    );
  }

  Widget _footer(BuildContext context) {
    if (_moreFailed) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: TextButton.icon(
            onPressed: () {
              setState(() => _moreFailed = false);
              _loadMore();
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Could not load more. Retry'),
          ),
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      ),
    );
  }

  Widget _itemView(BuildContext context, SearchItem item, {required bool phone}) {
    switch (item) {
      case SearchVideoItem(:final video):
        // Full-width cards on a phone, as Home draws them; rows on a tablet,
        // which is how YouTube lays search out on a wide screen.
        return phone
            ? VideoCard(
                video: video,
                onTap: () => WatchPage.open(context, video),
                onMenu: () => showVideoMenu(context, video),
              )
            : VideoRow(
                video: video,
                onTap: () => WatchPage.open(context, video),
                onMenu: () => showVideoMenu(context, video),
              );
      case SearchChannelItem():
        return SearchChannelCard(
          key: ValueKey(item.key),
          channel: item,
        );
      case SearchPlaylistItem():
        return SearchPlaylistCard(item: item, compact: !phone);
      case SearchShortsShelf():
        return SearchShortsShelfView(
          key: ValueKey(item.key),
          shelf: item,
          // The Shorts chip's page is one big shelf; collapsing it would
          // hide the page it is.
          startExpanded: _visibleItems.whereType<SearchShortsShelf>().length ==
              _visibleItems.length,
        );
      case SearchShelf():
        return SearchShelfView(key: ValueKey(item.key), shelf: item);
    }
  }
}

/// One row under the box: a magnifier (or a clock for a past search), the
/// text with the completion in bold, and the north-west arrow that copies it
/// into the box without searching.
class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.suggestion,
    required this.typed,
    required this.onTap,
    required this.onFill,
    this.onLongPress,
  });

  final SearchSuggestion suggestion;
  final String typed;
  final VoidCallback onTap;
  final VoidCallback onFill;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = suggestion.text;
    final split = typed.isEmpty ? text.length : typedPrefixLength(text, typed);
    final base = theme.textTheme.bodyLarge;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Row(
          children: [
            Icon(
              suggestion.fromHistory ? Icons.history : Icons.search,
              size: 22,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: base,
                  children: [
                    TextSpan(text: text.substring(0, split)),
                    TextSpan(
                      text: text.substring(split),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.north_west, size: 20),
              tooltip: 'Edit',
              onPressed: onFill,
            ),
          ],
        ),
      ),
    );
  }
}
