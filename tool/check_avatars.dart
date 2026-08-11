// How many feed rows actually carry a channel name and avatar.
//
// The cards were falling back to a coloured initial, which means avatarUrl
// arrived null. This reports the hit rate per source so the gap is visible
// rather than guessed at.
import 'dart:io';

import 'package:ai_bit/src/data/browse_client.dart';
import 'package:ai_bit/src/data/search_client.dart';

Future<void> main() async {
  final search = YoutubeSearchClient();
  final browse = YoutubeBrowseClient();

  void report(String label, List<dynamic> rows) {
    final withAvatar = rows.where((v) => v.avatarUrl != null).length;
    final withAuthor = rows.where((v) => (v.author as String).isNotEmpty).length;
    stdout.writeln('${label.padRight(24)} ${rows.length} rows  '
        'avatar=$withAvatar  author=$withAuthor');
    if (rows.isNotEmpty) {
      stdout.writeln('    first: author="${rows.first.author}" '
          'avatar=${rows.first.avatarUrl ?? 'null'}');
    }
  }

  report('search', await search.search('kannada news'));
  report('search shorts', await search.searchShorts('kannada'));

  const channelId = 'UCq-Fj5jknLsUf-MWSy4_brA';
  report('channel videos', await browse.channelVideos(channelId));
  report('channel shorts', await browse.channelShorts(channelId));

  final info = await browse.channel(channelId);
  stdout.writeln('channel header           title="${info.title}" '
      'avatar=${info.avatarUrl ?? 'null'}');

  search.close();
  browse.close();
}
