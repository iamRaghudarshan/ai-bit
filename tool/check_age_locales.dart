// What does YouTube write for "N days ago" in each language Settings offers,
// and does the ranker's parser read it?
//
//   dart run tool/check_age_locales.dart
//
// Found on an emulator: with the language set to Hindi the upload ages came
// back as "6 दिन पहले", and the parser — English only — returned null for
// every one, which silently switches off the ranker's freshness term. This
// collects the real strings per language from search results (whose age
// field is located structurally, not by an English keyword), and from the
// `next` endpoint's related list, and reports how many parse.
import 'dart:io';

import 'package:ai_bit/src/data/browse_client.dart';
import 'package:ai_bit/src/data/recommender.dart';
import 'package:ai_bit/src/data/search_client.dart';

Future<void> main() async {
  const languages = ['en', 'hi', 'bn', 'te', 'mr', 'ta', 'gu', 'kn', 'ml', 'pa', 'ur'];
  var failing = 0;
  for (final hl in languages) {
    final search = YoutubeSearchClient()..setLocale(language: hl, region: 'IN');
    final browse = YoutubeBrowseClient()..setLocale(language: hl, region: 'IN');
    try {
      final found = [
        ...await search.search('music'),
        ...await search.search('news'),
        ...await browse.related('dQw4w9WgXcQ'),
      ];
      final ages = found.map((r) => r.uploadRaw).whereType<String>().where((s) => s.isNotEmpty).toList();
      final views = found.where((r) => r.viewCount != null).length;
      final sample = found.where((r) => r.viewCount != null).skip(40).take(3)
          .map((r) => r.viewCount).join(', ');
      final parsed = ages.where((a) => parseRelativeAgeSeconds(a) != null).length;
      final unparsed = ages.where((a) => parseRelativeAgeSeconds(a) == null).toSet();
      if (parsed < ages.length || ages.length < found.length ~/ 2) failing++;
      stdout.writeln('$hl  rows ${found.length}  ages ${ages.length}  parsed $parsed  views $views  related view sample: $sample');
      if (unparsed.isNotEmpty) stdout.writeln('    unparsed: ${unparsed.take(8).join(' | ')}');
    } catch (e) {
      stdout.writeln('$hl  FAILED $e');
    } finally {
      search.close();
      browse.close();
    }
  }
  stdout.writeln(failing == 0 ? '\nALL PARSE' : '\n$failing language(s) with gaps');
  if (failing > 0) exitCode = 1;
}
