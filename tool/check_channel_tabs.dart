// Confirms the channel Live and Shorts tabs parse into rows.
import 'dart:io';

import 'package:ai_bit/src/data/browse_client.dart';

Future<void> main(List<String> args) async {
  final channelId = args.isEmpty ? 'UCq-Fj5jknLsUf-MWSy4_brA' : args.first;
  final client = YoutubeBrowseClient();

  final videos = await client.channelVideos(channelId);
  final live = await client.channelVideos(channelId, live: true);
  final shorts = await client.channelShorts(channelId);

  stdout.writeln('videos ${videos.length}  ${videos.isEmpty ? '' : videos.first.title}');
  stdout.writeln('live   ${live.length}  ${live.isEmpty ? '' : live.first.title}');
  stdout.writeln('shorts ${shorts.length}  ${shorts.isEmpty ? '' : shorts.first.title}');
  stdout.writeln(
    videos.isNotEmpty && live.isNotEmpty && shorts.isNotEmpty
        ? 'RESULT: all three tabs parsed.'
        : 'RESULT: at least one tab came back empty.',
  );
  client.close();
}
