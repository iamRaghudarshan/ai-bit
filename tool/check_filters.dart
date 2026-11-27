// Checks that the search filter encoder produces parameters YouTube honours.
//
//   dart run tool/check_filters.dart [query]
//
// Walks every option of the search screen's filter panel (YouTube's Jan-2026
// taxonomy) plus combinations a single pre-baked string could never express,
// and reports what kind of results come back — so "Channels returns
// channels" is measured, not assumed. The old encoder always sent type=video,
// which made the Channel and Playlist filters return nothing at all.
import 'dart:io';

import 'package:ai_bit/src/data/search_client.dart';

String _kinds(SearchBatch b) {
  final counts = <String, int>{};
  for (final i in b.items) {
    final name = switch (i) {
      SearchVideoItem() => 'video',
      SearchChannelItem() => 'channel',
      SearchPlaylistItem() => 'playlist',
      SearchShortsShelf() => 'shorts',
      SearchShelf() => 'shelf',
    };
    counts[name] = (counts[name] ?? 0) + 1;
  }
  return '$counts';
}

Future<void> main(List<String> args) async {
  final client = YoutubeSearchClient();
  final query = args.isEmpty ? 'kannada songs' : args.join(' ');

  final cases = <String, SearchFilters>{
    'none (All)': SearchFilters.none,
  };
  for (final group in YoutubeSearchClient.filters) {
    for (final option in group.options) {
      if (option.value == null) continue;
      cases['${group.title}: ${option.label}'] =
          SearchFilters.none.toggled(group.kind, option.value);
    }
  }
  cases['week + under 3 min + popularity'] = SearchFilters.none
      .toggled(SearchFilterKind.uploadDate, 3)
      .toggled(SearchFilterKind.duration, 4)
      .toggled(SearchFilterKind.sort, 3);
  cases['videos + HD + subtitles'] = SearchFilters.none
      .toggled(SearchFilterKind.type, 1)
      .toggled(SearchFilterKind.features, 4)
      .toggled(SearchFilterKind.features, 5);
  cases['over 20 min + 4K + HDR'] = SearchFilters.none
      .toggled(SearchFilterKind.duration, 2)
      .toggled(SearchFilterKind.features, 14)
      .toggled(SearchFilterKind.features, 25);

  var failures = 0;
  for (final entry in cases.entries) {
    final sp = entry.value.toParams();
    try {
      final batch = await client.searchPage(query, params: sp);
      final videos = batch.items.whereType<SearchVideoItem>().map((v) => v.video);
      final durations = videos
          .where((v) => v.duration != null)
          .map((v) => v.duration!.inMinutes)
          .toList();
      final span = durations.isEmpty
          ? 'no durations'
          : '${durations.reduce((a, b) => a < b ? a : b)}-'
              '${durations.reduce((a, b) => a > b ? a : b)} min';
      final status = batch.items.isEmpty ? 'EMPTY' : 'ok';
      if (batch.items.isEmpty) failures++;
      stdout.writeln('${entry.key.padRight(34)} ${sp ?? '-'}'
          '\n  $status  ${_kinds(batch)}  $span');
    } catch (e) {
      failures++;
      stdout.writeln('${entry.key.padRight(34)} THREW  $e');
    }
  }
  client.close();
  stdout.writeln(failures == 0
      ? '\nRESULT: every filter returned results.'
      : '\nRESULT: $failures filter(s) came back empty or failed '
          '(a rare feature like VR180 or Location can be genuinely empty).');
}
