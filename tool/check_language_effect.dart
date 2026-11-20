// What does the Settings language actually change: the videos YouTube
// returns, or only the words around them?
//
//   dart run tool/check_language_effect.dart
//
// The metadata parsers read English ("views", "ago"), so a non-English
// setting loses upload ages and view counts. Whether the fix is "parse every
// language" or "ask in English and keep the region" depends on whether `hl`
// changes the RESULTS. This compares the same requests in English and Hindi.
import 'dart:io';

import 'package:ai_bit/src/data/browse_client.dart';
import 'package:ai_bit/src/data/search_client.dart';

Future<void> main() async {
  for (final query in ['cricket highlights', 'cooking recipe', 'news today']) {
    final en = YoutubeSearchClient()..setLocale(language: 'en', region: 'IN');
    final hi = YoutubeSearchClient()..setLocale(language: 'hi', region: 'IN');
    final a = await en.search(query);
    final b = await hi.search(query);
    final shared = a.map((v) => v.id).toSet().intersection(b.map((v) => v.id).toSet());
    stdout.writeln('search "$query": en ${a.length}, hi ${b.length}, shared ${shared.length}');
    stdout.writeln('   en first: ${a.take(2).map((v) => v.title).join(' | ')}');
    stdout.writeln('   hi first: ${b.take(2).map((v) => v.title).join(' | ')}');
    stdout.writeln('   hi raw age/views: ${b.take(2).map((v) => '${v.uploadRaw} / ${v.viewCount}').join(' | ')}');
    en.close();
    hi.close();
  }
  final en = YoutubeBrowseClient()..setLocale(language: 'en', region: 'IN');
  final hi = YoutubeBrowseClient()..setLocale(language: 'hi', region: 'IN');
  final a = await en.related('dQw4w9WgXcQ');
  final b = await hi.related('dQw4w9WgXcQ');
  final shared = a.map((v) => v.id).toSet().intersection(b.map((v) => v.id).toSet());
  stdout.writeln('related: en ${a.length}, hi ${b.length}, shared ${shared.length}');
  stdout.writeln('   hi first: ${b.take(3).map((v) => '${v.title} [${v.uploadRaw} / ${v.viewCount}]').join(' | ')}');
  en.close();
  hi.close();
}
