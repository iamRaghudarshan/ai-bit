// Query completions for the search box.
//
// These come from a different endpoint to search itself, and the package's
// version fails silently — the list was simply always empty. This proves ours
// returns something for ordinary prefixes.
import 'dart:io';

import 'package:ai_bit/src/data/search_client.dart';

Future<void> main(List<String> args) async {
  final queries = args.isEmpty
      ? ['kan', 'kannada', 'flutter tut', 'news', 'a']
      : args;
  final client = YoutubeSearchClient();
  var empty = 0;

  for (final q in queries) {
    final results = await client.suggestions(q);
    if (results.isEmpty) empty++;
    final label = '"$q"'.padRight(16);
    final sample =
        results.isEmpty ? '' : '  e.g. ${results.take(3).join(' | ')}';
    stdout.writeln('$label${results.length} suggestions$sample');
  }

  // An empty query must not call out at all.
  final blank = await client.suggestions('   ');
  stdout.writeln('blank query    ${blank.isEmpty ? 'returns nothing (correct)' : 'RETURNED ${blank.length}'}');

  client.close();
  stdout.writeln(empty == 0
      ? '\nRESULT: every prefix returned suggestions.'
      : '\nRESULT: $empty prefix(es) returned nothing.');
  if (empty > 0) exitCode = 1;
}
