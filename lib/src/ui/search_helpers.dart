import '../data/search_client.dart';

/// Pure pieces of the search screen, kept out of the widget so each rule has
/// a test.

/// One row under the search box while typing.
class SearchSuggestion {
  const SearchSuggestion(this.text, {this.fromHistory = false});

  final String text;

  /// A past search matching what is typed — drawn with a clock, not a
  /// magnifier, and listed first, the way YouTube does.
  final bool fromHistory;

  @override
  bool operator ==(Object other) =>
      other is SearchSuggestion &&
      other.text == text &&
      other.fromHistory == fromHistory;

  @override
  int get hashCode => Object.hash(text, fromHistory);
}

/// Past searches that start with [typed] (at most [maxHistory], newest
/// first, as [history] is ordered), then the live completions minus those.
///
/// Matched case-insensitively and de-duplicated case-insensitively, because
/// the completion service lower-cases everything and the history keeps what
/// was typed — "Kannada songs" and "kannada songs" are one row, not two.
List<SearchSuggestion> mergeSuggestions(
  String typed,
  List<String> history,
  List<String> remote, {
  int maxHistory = 3,
}) {
  final needle = typed.trim().toLowerCase();
  if (needle.isEmpty) return const [];
  final seen = <String>{};
  final out = <SearchSuggestion>[];
  for (final h in history) {
    if (out.length >= maxHistory) break;
    final lower = h.trim().toLowerCase();
    if (lower.startsWith(needle) && seen.add(lower)) {
      out.add(SearchSuggestion(h, fromHistory: true));
    }
  }
  for (final r in remote) {
    final lower = r.trim().toLowerCase();
    if (lower.isEmpty || !seen.add(lower)) continue;
    out.add(SearchSuggestion(r));
  }
  return out;
}

/// How many leading characters of [suggestion] are what was typed — drawn
/// normal, with the completion after them in bold.
///
/// Zero when the suggestion does not start with the typed text (the service
/// sometimes corrects a spelling), and then the whole row is bold: all of it
/// is something the user did not type.
int typedPrefixLength(String suggestion, String typed) {
  final t = typed.trimLeft().toLowerCase();
  if (t.isEmpty) return 0;
  return suggestion.toLowerCase().startsWith(t) ? t.length : 0;
}

/// [incoming] appended to [existing], skipping anything already shown.
///
/// [seen] is the caller's running set of [SearchItem.key]s and is updated —
/// YouTube repeats the odd result from one page on the next, and a card
/// appearing twice reads as a bug.
List<SearchItem> appendUnique(
  List<SearchItem> existing,
  List<SearchItem> incoming,
  Set<String> seen,
) => [
  ...existing,
  for (final item in incoming)
    if (seen.add(item.key)) item,
];

/// The "Unwatched" chip, applied locally.
///
/// An account-less request has no watch history on YouTube's side, so the
/// chip's server answer cannot leave out what this phone has watched — the
/// history table can. Shelves keep their unwatched videos and disappear when
/// none are left.
List<SearchItem> withoutWatched(List<SearchItem> items, Set<String> watched) {
  if (watched.isEmpty) return items;
  final out = <SearchItem>[];
  for (final item in items) {
    switch (item) {
      case SearchVideoItem(:final video):
        if (!watched.contains(video.id)) out.add(item);
      case SearchShelf(:final title, :final videos):
        final left = videos.where((v) => !watched.contains(v.id)).toList();
        if (left.isNotEmpty) out.add(SearchShelf(title: title, videos: left));
      case SearchShortsShelf(:final title, :final shorts):
        final left = shorts.where((v) => !watched.contains(v.id)).toList();
        if (left.isNotEmpty) {
          out.add(SearchShortsShelf(title: title, shorts: left));
        }
      case SearchChannelItem() || SearchPlaylistItem():
        out.add(item);
    }
  }
  return out;
}
