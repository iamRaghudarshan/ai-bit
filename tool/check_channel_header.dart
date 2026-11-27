// Do the channel, playlist and comment parsers still read live YouTube?
//
//   dart run tool/check_channel_header.dart [channelId] [playlistId] [videoId]
//
// Checks, against real responses, everything the channel / playlist pages
// and the comments sheet rely on: the header (banner, handle, counts,
// description, links line, About token, tabs), the About panel, the Videos
// tab's sort chips (Popular must actually re-order), paging past the first
// thirty, the Shorts tab, a playlist's header and second page, and comments
// in both orders plus one replies page. Every line names its step, so a
// failure says which shape moved.
import 'dart:io';

import 'package:ai_bit/src/data/browse_client.dart';
import 'package:ai_bit/src/data/comments_client.dart';

Future<void> main(List<String> args) async {
  final channelId = args.isNotEmpty ? args[0] : 'UCBJycsmduvYEL83R_U4JriQ';
  final playlistId = args.length > 1 ? args[1] : 'UUBJycsmduvYEL83R_U4JriQ';
  final videoId = args.length > 2 ? args[2] : 'WbM7GP7QoEM';
  final browse = YoutubeBrowseClient();
  final comments = YoutubeCommentsClient();
  var failures = 0;
  void check(String step, bool ok, String detail) {
    if (!ok) failures++;
    stdout.writeln('${ok ? 'OK  ' : 'FAIL'} $step: $detail');
  }

  try {
    final info = await browse.channel(channelId);
    check('header title', info.title.isNotEmpty, info.title);
    check('header handle', info.handle?.startsWith('@') ?? false, '${info.handle}');
    check('header subscribers', info.subscriberLabel != null, '${info.subscriberLabel}');
    check('header videos', info.videoCountLabel != null, '${info.videoCountLabel}');
    check('header banner', info.bannerUrl != null, '${info.bannerUrl?.substring(0, 40)}…');
    check('header description', info.description != null, '${info.description}');
    check('header links line', info.linkLabel != null, '${info.linkLabel}');
    check('header tabs', info.tabs?.contains('videos') ?? false, '${info.tabs}');
    if (info.aboutToken != null) {
      final about = await browse.channelAbout(info.aboutToken!);
      check(
        'about panel',
        about != null && about.joinedText != null,
        '${about?.joinedText} · ${about?.viewCountText} · ${about?.country} · '
            '${about?.links.length} links '
            '${about?.links.take(2).map((l) => l.url).join(' ')}',
      );
    } else {
      check('about token', false, 'none in header');
    }

    final videos = await browse.channelTab(channelId);
    check('videos page 1', videos.videos.isNotEmpty, '${videos.videos.length} rows');
    check('videos sort chips', videos.sorts.length >= 2,
        videos.sorts.map((s) => '${s.label}${s.selected ? '*' : ''}').join(' '));
    if (videos.continuation != null) {
      final more = await browse.channelTabMore(videos.continuation!,
          tab: ChannelTab.videos, channelId: channelId);
      final overlap =
          more.videos.where((v) => videos.videos.any((w) => w.id == v.id)).length;
      check('videos page 2', more.videos.isNotEmpty && overlap == 0,
          '${more.videos.length} rows, $overlap repeated, next=${more.continuation != null}');
    } else {
      check('videos continuation', false, 'none');
    }
    if (videos.sorts.length >= 2) {
      final popular = await browse.channelTabMore(videos.sorts[1].token,
          tab: ChannelTab.videos, channelId: channelId);
      final top = popular.videos.take(3).map((v) => v.viewCount ?? 0).toList();
      check('popular order', popular.videos.isNotEmpty && top.first >= top.last,
          '${popular.videos.length} rows, top views $top');
    }

    final shorts = await browse.channelTab(channelId, tab: ChannelTab.shorts);
    check('shorts page 1', shorts.videos.isNotEmpty,
        '${shorts.videos.length} rows, next=${shorts.continuation != null}');

    final playlist = await browse.playlistPage(playlistId);
    final h = playlist.header;
    check('playlist header', h.title != 'Playlist',
        '${h.title} · by ${h.author} (${h.channelId}) · ${h.videoCount} videos · '
            '${h.viewCountLabel} · cover=${h.thumbnailUrl != null}');
    check('playlist page 1', playlist.videos.isNotEmpty,
        '${playlist.videos.length} rows, next=${playlist.continuation != null}');
    if (playlist.continuation != null) {
      final more = await browse.playlistMore(playlist.continuation!);
      check('playlist page 2', more.videos.isNotEmpty, '${more.videos.length} rows');
    }

    final top = await comments.fetch(videoId);
    check('comments top', top.comments.isNotEmpty,
        '${top.comments.length} rows, total ${top.totalLabel}, sorts '
            '${top.sorts.map((s) => s.label).join('/')}');
    final pinned = top.comments.where((c) => c.pinnedText != null).toList();
    stdout.writeln('     pinned: ${pinned.map((c) => c.pinnedText).join(', ')}; '
        'creator: ${top.comments.where((c) => c.isCreator).length}; '
        'hearted: ${top.comments.where((c) => c.isHearted).length}');
    if (top.sorts.length >= 2) {
      final newest = await comments.sorted(top.sorts, 1);
      check('comments newest', newest.comments.isNotEmpty,
          newest.comments.take(3).map((c) => c.publishedText).join(', '));
    }
    if (top.continuation != null) {
      final more = await comments.more(top.continuation!);
      final replyLike = more.comments.isEmpty;
      check('comments page 2', !replyLike, '${more.comments.length} rows');
    }
    final threaded = top.comments.firstWhere(
      (c) => c.repliesToken != null,
      orElse: () => const VideoComment(author: '', text: ''),
    );
    if (threaded.repliesToken != null) {
      final replies = await comments.repliesPage(threaded.repliesToken!);
      check('replies', replies.comments.isNotEmpty,
          '${replies.comments.length} of ${threaded.replyCount}, '
              'more=${replies.continuation != null}');
    }
  } finally {
    browse.close();
    comments.close();
  }
  stdout.writeln(failures == 0 ? '\nall good' : '\n$failures failed');
  exit(failures == 0 ? 0 : 1);
}
