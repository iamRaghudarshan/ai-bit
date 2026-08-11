// Does the Shorts feed actually return Shorts?
//
//   dart run tool/check_shorts.dart [topic ...]
//
// Shorts arrive as shortsLockupViewModel, which no other parser here touches --
// probing for videoRenderer, reelItemRenderer and lockupViewModel all returned
// zero. This proves the one renderer that does work still does.
import 'dart:io';

import 'package:ai_bit/src/data/search_client.dart';

Future<void> main(List<String> args) async {
  final topics = args.isEmpty
      ? ['funny', 'satisfying', 'cooking', 'animals']
      : args;
  final client = YoutubeSearchClient();
  var total = 0;

  for (final topic in topics) {
    try {
      final shorts = await client.searchShorts('$topic shorts');
      total += shorts.length;
      stdout.writeln('  ${topic.padRight(12)} ${shorts.length} shorts');
      for (final s in shorts.take(2)) {
        final title = s.title.replaceAll('\n', ' ');
        stdout.writeln('     ${s.id}  ${s.viewCount ?? "-"} views  '
            '${title.substring(0, title.length.clamp(0, 50))}');
      }
    } catch (e) {
      stdout.writeln('  ${topic.padRight(12)} FAILED $e');
    }
  }

  client.close();
  stdout.writeln();
  stdout.writeln(total > 0
      ? 'RESULT: $total shorts across ${topics.length} topics.'
      : 'RESULT: no shorts found.');
  if (total == 0) exitCode = 1;
}
