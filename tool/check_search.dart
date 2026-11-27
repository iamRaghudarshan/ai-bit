// Exercises the app's own search implementation against live YouTube, and
// shows what the youtube_explode_dart parser does with the same query.
//
//   dart run tool/check_search.dart [query ...]
//
// The package's search is broken (NoSuchMethodError on `getT`), which is why
// lib/src/data/search_client.dart exists. This proves the replacement works and
// keeps the comparison visible if the package is ever fixed.
//
// It also walks the search SCREEN's path — searchPage(): mixed results in
// order, the chip bar, a spelling correction, two continuation pages and one
// chip reload — because "the feed's videos-only search works" says nothing
// about whether channels, playlists and Shorts reach the screen.
import 'dart:io';

import 'package:ai_bit/src/data/search_client.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

String _summary(SearchBatch b) {
  final counts = <String, int>{};
  for (final i in b.items) {
    final name = switch (i) {
      SearchVideoItem() => 'video',
      SearchChannelItem() => 'channel',
      SearchPlaylistItem() => 'playlist',
      SearchShortsShelf() => 'shorts-shelf',
      SearchShelf() => 'shelf',
    };
    counts[name] = (counts[name] ?? 0) + 1;
  }
  return '${b.items.length} items $counts'
      '${b.continuation == null ? '  (last page)' : ''}'
      '${b.skipped.isEmpty ? '' : '  SKIPPED ${b.skipped.length}: ${b.skipped.first}'}';
}

Future<void> main(List<String> args) async {
  final queries = args.isEmpty
      ? ['kannada', 'flutter tutorial', 'news today', 'lofi', 'mkbhd', 'flutre tutorail']
      : args;

  final mine = YoutubeSearchClient();
  final yt = YoutubeExplode();
  var failures = 0;

  for (final q in queries) {
    stdout.writeln('\n===== "$q" =====');

    try {
      final r = await mine.search(q);
      stdout.writeln('ours:    ${r.length} results');
      for (final v in r.take(3)) {
        stdout.writeln('   ${v.id}  ${v.duration}  '
            '${v.viewCount ?? '-'} views  ${v.author}');
        stdout.writeln('        ${v.title}');
      }
      if (r.isEmpty) failures++;
    } catch (e) {
      stdout.writeln('ours:    FAILED $e');
      failures++;
    }

    try {
      final r = await yt.search.search(q);
      stdout.writeln('package: ${r.length} results');
    } catch (e) {
      stdout.writeln('package: FAILED ${e.toString().split('\n').first}');
    }

    try {
      final s = await mine.search(q, params: YoutubeSearchClient.filterByViewCount);
      stdout.writeln('ours(by views): ${s.length} results');
    } catch (e) {
      stdout.writeln('ours(by views): FAILED $e');
      failures++;
    }

    // ---- the screen's path
    try {
      final first = await mine.searchPage(q);
      stdout.writeln('screen p1: ${_summary(first)}');
      for (final i in first.items.take(6)) {
        final line = switch (i) {
          SearchVideoItem(:final video) => 'video    ${video.title}',
          SearchChannelItem() =>
            'channel  ${i.title}  ${i.handle ?? '-'} · ${i.subscriberLabel ?? '-'}',
          SearchPlaylistItem(:final playlist) =>
            'playlist ${playlist.title}  (${playlist.videoCount ?? i.badge ?? '?'})',
          SearchShortsShelf(:final title, :final shorts) =>
            'shorts   "$title" x${shorts.length}',
          SearchShelf(:final title, :final videos) =>
            'shelf    "$title" x${videos.length}',
        };
        stdout.writeln('     $line');
      }
      stdout.writeln('   chips: ${first.chips.map((c) => c.label).join(' | ')}');
      final fix = first.correction;
      if (fix != null) {
        stdout.writeln(fix.autoCorrected
            ? '   showing results for "${fix.corrected}" (instead: "${fix.original}")'
            : '   did you mean "${fix.corrected}"');
      }
      if (first.items.isEmpty) failures++;

      var token = first.continuation;
      for (var page = 2; page <= 3 && token != null; page++) {
        final next = await mine.searchContinuation(token);
        stdout.writeln('screen p$page: ${_summary(next)}');
        token = next.continuation;
      }
      final chip = first.chips.where((c) => c.token != null).firstOrNull;
      if (chip != null) {
        final reload = await mine.searchContinuation(chip.token!);
        stdout.writeln('chip "${chip.label}": ${_summary(reload)}');
        if (reload.items.isEmpty) failures++;
      }
    } catch (e) {
      stdout.writeln('screen: FAILED $e');
      failures++;
    }
  }

  mine.close();
  yt.close();

  stdout.writeln();
  stdout.writeln(failures == 0
      ? 'RESULT: search works for every query.'
      : 'RESULT: $failures query variants failed.');
  if (failures > 0) exitCode = 1;
}
