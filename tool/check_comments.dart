// Are a video's comments readable, and does paging work?
//
//   dart run tool/check_comments.dart [videoId ...]
//
// youtube_explode_dart deprecated its comments API, so this exercises the
// direct implementation. Comments need two round trips -- the watch response
// only carries a continuation token -- so a first page alone does not prove
// paging works; this asks for a second.
import 'dart:io';

import 'package:ai_bit/src/data/comments_client.dart';

Future<void> main(List<String> args) async {
  final ids = args.isEmpty ? ['dQw4w9WgXcQ', 'jNQXAC9IVRw'] : args;
  final client = YoutubeCommentsClient();
  var failures = 0;

  for (final id in ids) {
    stdout.writeln('\n===== $id =====');
    try {
      final page = await client.fetch(id);
      stdout.writeln('  total   : ${page.totalLabel ?? "(not stated)"}');
      stdout.writeln('  fetched : ${page.comments.length}');
      stdout.writeln('  hasMore : ${page.hasMore}');

      if (page.comments.isEmpty) {
        stdout.writeln('  NO COMMENTS PARSED');
        failures++;
        continue;
      }

      for (final c in page.comments.take(3)) {
        final avatar = c.avatarUrl != null ? 'avatar' : 'NO AVATAR';
        stdout.writeln('   ${c.author}  ${c.likeLabel ?? "-"} likes  '
            '${c.publishedText ?? "-"}  ${c.replyCount} replies  $avatar');
        final text = c.text.replaceAll('\n', ' ');
        stdout.writeln('      ${text.substring(0, text.length.clamp(0, 70))}');
      }

      // Replies: the token is paired positionally with the comment, so a
      // mismatch shows up as the wrong thread rather than an error.
      final withReplies =
          page.comments.where((c) => c.repliesToken != null).toList();
      stdout.writeln('  with reply tokens: ${withReplies.length}');
      if (withReplies.isNotEmpty) {
        final parent = withReplies.first;
        final replies = await client.replies(parent.repliesToken!);
        stdout.writeln('  replies to "${parent.author}" '
            '(${parent.replyCount} expected): ${replies.length} fetched');
        for (final r in replies.take(2)) {
          final t = r.text.replaceAll('\n', ' ');
          stdout.writeln('     ${r.author}: '
              '${t.substring(0, t.length.clamp(0, 55))}');
        }
        if (replies.isEmpty) failures++;
      }

      // Paging is the half that silently breaks: a wrong token returns the
      // same page forever, or nothing.
      if (page.hasMore) {
        final second = await client.more(page.continuation!);
        final firstIds = page.comments.map((c) => c.text).toSet();
        final fresh = second.comments.where((c) => !firstIds.contains(c.text));
        stdout.writeln('  page 2  : ${second.comments.length} comments, '
            '${fresh.length} new');
        if (second.comments.isNotEmpty && fresh.isEmpty) {
          stdout.writeln('  WARNING: page 2 repeated page 1');
          failures++;
        }
      }
    } catch (e) {
      stdout.writeln('  FAILED $e');
      failures++;
    }
  }

  client.close();
  stdout.writeln();
  stdout.writeln(failures == 0
      ? 'RESULT: comments load and page correctly.'
      : 'RESULT: $failures problems.');
  if (failures > 0) exitCode = 1;
}

