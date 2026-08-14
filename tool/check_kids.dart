// Confirms the Kids-mode topics return real videos and shorts.
import 'dart:io';
import 'package:ai_bit/src/data/search_client.dart';

Future<void> main() async {
  final c = YoutubeSearchClient();
  const topics = ['nursery rhymes', 'kids cartoon', 'cocomelon', 'kids learning videos'];
  var ok = 0;
  for (final t in topics) {
    final vids = await c.search(t);
    final shorts = await c.searchShorts('$t shorts');
    final sample = vids.isEmpty
        ? ''
        : '  e.g. ${vids.first.title}';
    stdout.writeln('${t.padRight(24)} videos=${vids.length}  '
        'shorts=${shorts.length}$sample');
    if (vids.isNotEmpty) ok++;
  }
  c.close();
  stdout.writeln(ok == topics.length
      ? '\nRESULT: every kids topic returned videos.'
      : '\nRESULT: ${topics.length - ok} kids topic(s) came back empty.');
}
