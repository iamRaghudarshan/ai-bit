import 'dart:convert';

import 'package:http/http.dart' as http;

/// One comment or reply.
class VideoComment {
  const VideoComment({
    required this.author,
    required this.text,
    this.avatarUrl,
    this.likeLabel,
    this.publishedText,
    this.replyCount = 0,
    this.isPinned = false,
    this.isCreator = false,
    this.repliesToken,
    this.pinnedText,
    this.isHearted = false,
    this.heartAvatarUrl,
    this.authorChannelId,
  });

  final String author;
  final String text;
  final String? avatarUrl;

  /// Pre-formatted by YouTube ("298K"), so it is kept as text rather than
  /// re-derived from a number that is not supplied.
  final String? likeLabel;
  final String? publishedText;
  final int replyCount;
  final bool isPinned;
  final bool isCreator;

  /// Token that fetches this comment's replies, when it has any.
  final String? repliesToken;

  /// "Pinned by @veritasium", exactly as YouTube words it.
  final String? pinnedText;

  /// The creator hearted this comment.
  final bool isHearted;

  /// The creator's avatar, drawn inside the heart badge.
  final String? heartAvatarUrl;

  /// The commenter's channel, for tapping through.
  final String? authorChannelId;

  VideoComment withReplies(String? token) => VideoComment(
    author: author,
    text: text,
    avatarUrl: avatarUrl,
    likeLabel: likeLabel,
    publishedText: publishedText,
    replyCount: replyCount,
    isPinned: isPinned,
    isCreator: isCreator,
    repliesToken: token,
    pinnedText: pinnedText,
    isHearted: isHearted,
    heartAvatarUrl: heartAvatarUrl,
    authorChannelId: authorChannelId,
  );
}

/// One way of ordering the comments ("Top", "Newest"), with the token that
/// fetches the first page in that order.
typedef CommentSort = ({String label, String token, bool selected});

class CommentPage {
  const CommentPage({
    required this.comments,
    this.totalLabel,
    this.continuation,
    this.sorts = const [],
  });

  final List<VideoComment> comments;

  /// "1.2K Comments" — or just "6.3K" — as YouTube renders it, or null when
  /// it declines to say.
  final String? totalLabel;

  /// Token for the next page, or null at the end.
  final String? continuation;

  /// Top / Newest, in YouTube's order. Only the first page carries them.
  final List<CommentSort> sorts;

  bool get hasMore => continuation != null;

  CommentPage withHeader({String? totalLabel, List<CommentSort>? sorts}) =>
      CommentPage(
        comments: comments,
        totalLabel: this.totalLabel ?? totalLabel,
        continuation: continuation,
        sorts: sorts ?? this.sorts,
      );
}

/// Reads a video's comments.
///
/// `youtube_explode_dart` deprecated its comments API outright ("This interface
/// will not be supported anymore"), so this talks to `youtubei/v1/next`
/// directly.
///
/// Comments are not in the first response. That one carries a *continuation
/// token* for the comment section, which has to be posted back to get the
/// comments themselves — two round trips, by YouTube's design. The first
/// response is also where the Top / Newest menu and the comment count live,
/// in the comments engagement panel's header.
///
/// The payloads also moved: comments used to live in `commentRenderer` and now
/// arrive as `commentEntityPayload` entity mutations. Both are read, because
/// YouTube serves the old shape to some clients.
class YoutubeCommentsClient {
  YoutubeCommentsClient({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  /// Language and region asked for, as YouTube's `hl` and `gl`.
  ///
  /// These were hardcoded to en/US, which quietly decided a great deal: `gl`
  /// governs what is popular and what is even available, and `hl` governs what
  /// comes back as text. An app used in India was asking America what was
  /// worth watching and then asking for it in English.
  ///
  /// Mutable rather than constructor-injected because one client instance
  /// lives for the life of the app and the setting can change under it, and a
  /// locale change must not mean rebuilding the HTTP client and losing its
  /// connection pool.
  String _hl = 'en';
  String _gl = 'US';

  void setLocale({required String language, required String region}) {
    if (language.isNotEmpty) _hl = language;
    if (region.isNotEmpty) _gl = region;
  }

  Map<String, dynamic> get _context => {
    'client': {
      'clientName': 'WEB',
      'clientVersion': '2.20250312.04.00',
      'hl': _hl,
      'gl': _gl,
      'timeZone': 'UTC',
      'utcOffsetMinutes': 0,
    },
  };

  void close() => _http.close();

  Future<Map<String, dynamic>> _next(Map<String, dynamic> body) async {
    final response = await _http
        .post(
          Uri.parse('https://www.youtube.com/youtubei/v1/next?prettyPrint=false'),
          headers: const {
            'Content-Type': 'application/json',
            'Origin': 'https://www.youtube.com',
            'Accept-Language': 'en-US,en;q=0.9',
          },
          body: jsonEncode({'context': _context, ...body}),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw CommentsException('YouTube returned HTTP ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// First page of comments for [videoId], in YouTube's Top order.
  Future<CommentPage> fetch(String videoId) async {
    final first = await _next({'videoId': videoId});
    final sorts = commentSortsOf(first);
    final total = commentCountOf(first);

    // Comment sections are the continuation whose token sits alongside the
    // comments header; taking the last candidate avoids the "up next" one,
    // which appears first. The Top entry of the sort menu is the same
    // request, so it is preferred when present.
    final token = sorts.isNotEmpty ? sorts.first.token : _commentsToken(first);
    if (token == null) {
      return CommentPage(comments: const [], totalLabel: total, sorts: sorts);
    }
    return parseCommentPage(
      await _next({'continuation': token}),
    ).withHeader(totalLabel: total, sorts: sorts);
  }

  /// The first page in another order, from a [CommentSort.token]. The sort
  /// list is carried over, with [selected] marked.
  Future<CommentPage> sorted(List<CommentSort> sorts, int selected) async {
    final page = parseCommentPage(
      await _next({'continuation': sorts[selected].token}),
    );
    return page.withHeader(
      sorts: [
        for (var i = 0; i < sorts.length; i++)
          (label: sorts[i].label, token: sorts[i].token, selected: i == selected),
      ],
    );
  }

  /// A further page, using the token from [CommentPage.continuation].
  Future<CommentPage> more(String continuation) async =>
      parseCommentPage(await _next({'continuation': continuation}));

  /// One page of replies to a comment, from [VideoComment.repliesToken] or a
  /// previous replies page's [CommentPage.continuation] ("Show more
  /// replies").
  Future<CommentPage> repliesPage(String token) async =>
      parseCommentPage(await _next({'continuation': token}));

  /// Replies for one comment, using [VideoComment.repliesToken].
  Future<List<VideoComment>> replies(String token) async =>
      (await repliesPage(token)).comments;

  /// A page of comments or replies out of a continuation response. Pure and
  /// public so its shapes are tested.
  ///
  /// Each comment is assembled from three places that share keys:
  ///
  ///   * the thread (`commentThreadRenderer`), whose `commentViewModel`
  ///     carries `commentKey`, `toolbarStateKey`, `pinnedText`, and whose
  ///     `replies` carries the replies token;
  ///   * the `commentEntityPayload` with that `key` — text, author, counts;
  ///   * the `engagementToolbarStateEntityPayload` with the toolbar key —
  ///     whether the creator hearted it.
  ///
  /// Keying them together replaces a version that paired reply tokens with
  /// comments by position. That was wrong whenever a comment without replies
  /// sat before one with them — the token list only has entries for comments
  /// that have replies, while the index counted every comment — so "13
  /// replies" opened somebody else's thread. Reply pages have no threads, so
  /// there the bare `commentViewModel`s are read in document order.
  static CommentPage parseCommentPage(Map<String, dynamic> json) {
    final payloads = <Map<String, dynamic>>[];
    _collect(json, 'commentEntityPayload', payloads);
    final byKey = {
      for (final p in payloads)
        if (p['key'] is String) p['key'] as String: p,
    };
    final states = <Map<String, dynamic>>[];
    _collect(json, 'engagementToolbarStateEntityPayload', states);
    final hearted = {
      for (final s in states)
        if (s['key'] is String &&
            s['heartState'] == 'TOOLBAR_HEART_STATE_HEARTED')
          s['key'] as String,
    };

    VideoComment? assemble(Map<String, dynamic> view, {String? repliesToken}) {
      final payload = byKey[view['commentKey']];
      if (payload == null) return null;
      final props = payload['properties'];
      final stateKey =
          view['toolbarStateKey'] ??
          (props is Map ? props['toolbarStateKey'] : null);
      return _fromPayload(
        payload,
        pinnedText: (view['pinnedText'] as String?)?.nullIfEmpty,
        hearted: hearted.contains(stateKey),
        repliesToken: repliesToken,
      );
    }

    final comments = <VideoComment>[];
    final threads = <Map<String, dynamic>>[];
    _collect(json, 'commentThreadRenderer', threads);
    if (threads.isNotEmpty) {
      for (final t in threads) {
        final views = <Map<String, dynamic>>[];
        _collectViews(t['commentViewModel'], views);
        if (views.isEmpty) continue;
        final comment = assemble(views.first, repliesToken: _firstToken(t['replies']));
        if (comment != null) comments.add(comment);
      }
    } else {
      final views = <Map<String, dynamic>>[];
      _collectViews(json, views);
      for (final v in views) {
        final comment = assemble(v);
        if (comment != null) comments.add(comment);
      }
    }

    // Payloads that no view model named: keep them rather than lose them,
    // in the order they came.
    if (comments.isEmpty && payloads.isNotEmpty) {
      comments.addAll(payloads.map((p) => _fromPayload(p)).whereType<VideoComment>());
    }

    // The older renderer shape, only when the new one gave nothing.
    if (comments.isEmpty) {
      final renderers = <Map<String, dynamic>>[];
      _collect(json, 'commentRenderer', renderers);
      for (final r in renderers) {
        final comment = _fromRenderer(r);
        if (comment != null) comments.add(comment);
      }
    }

    return CommentPage(
      comments: comments,
      totalLabel: _headerCount(json),
      continuation: _nextToken(json),
    );
  }

  static VideoComment? _fromPayload(
    Map<String, dynamic> p, {
    String? pinnedText,
    bool hearted = false,
    String? repliesToken,
  }) {
    final props = p['properties'] as Map<String, dynamic>?;
    final author = p['author'] as Map<String, dynamic>?;
    final toolbar = p['toolbar'] as Map<String, dynamic>?;

    final text = (props?['content'] as Map?)?['content'];
    if (text is! String || text.isEmpty) return null;

    final replies = toolbar?['replyCount'];
    final like = (toolbar?['likeCountNotliked'] ?? toolbar?['likeCountLiked'])
        as String?;
    final pinned =
        pinnedText ?? (props?['pinnedText'] as String?)?.nullIfEmpty;
    return VideoComment(
      author: (author?['displayName'] as String?) ?? '',
      text: text,
      avatarUrl: author?['avatarThumbnailUrl'] as String?,
      // YouTube sends a blank or "0" for an unliked comment; either way
      // there is nothing to print beside the thumb.
      likeLabel: like == null || like.trim().isEmpty || like.trim() == '0'
          ? null
          : like.trim(),
      publishedText: props?['publishedTime'] as String?,
      replyCount: replies is int
          ? replies
          : int.tryParse(replies?.toString().replaceAll(',', '') ?? '') ?? 0,
      isPinned: pinned != null,
      pinnedText: pinned,
      isCreator: author?['isCreator'] == true,
      isHearted: hearted,
      heartAvatarUrl: hearted
          ? (toolbar?['creatorThumbnailUrl'] as String?)
          : null,
      authorChannelId: author?['channelId'] as String?,
      repliesToken: repliesToken,
    );
  }

  static VideoComment? _fromRenderer(Map<String, dynamic> r) {
    final text = _text(r['contentText']);
    if (text.isEmpty) return null;
    final pinned = _text(r['pinnedCommentBadge']);
    return VideoComment(
      author: _text(r['authorText']),
      text: text,
      avatarUrl: _firstUrl(r['authorThumbnail']),
      likeLabel: _text(r['voteCount']).nullIfEmpty,
      publishedText: _text(r['publishedTimeText']).nullIfEmpty,
      isPinned: pinned.isNotEmpty,
      pinnedText: pinned.nullIfEmpty,
      isCreator: r['authorIsChannelOwner'] == true,
    );
  }

  /// The Top / Newest menu from a watch (`next`) response.
  static List<CommentSort> commentSortsOf(Map<String, dynamic> json) {
    final menus = <Map<String, dynamic>>[];
    _collect(json, 'sortFilterSubMenuRenderer', menus);
    for (final m in menus) {
      final items = m['subMenuItems'];
      if (items is! List) continue;
      final out = <CommentSort>[];
      for (final item in items) {
        if (item is! Map) continue;
        final token = _firstToken(item);
        final label = item['title'];
        if (token == null || label is! String) continue;
        out.add((label: label, token: token, selected: item['selected'] == true));
      }
      if (out.isNotEmpty) return out;
    }
    return const [];
  }

  /// The comment count from a watch response: the comments panel's header
  /// says "6.3K" under `contextualInfo`. The continuation's own header,
  /// which used to carry "1.2K Comments", now carries no count at all.
  static String? commentCountOf(Map<String, dynamic> json) {
    final panels = <Map<String, dynamic>>[];
    _collect(json, 'engagementPanelSectionListRenderer', panels);
    for (final p in panels) {
      final id = '${p['panelIdentifier'] ?? p['targetId'] ?? ''}';
      if (!id.contains('comment')) continue;
      final header = p['header'];
      final title =
          header is Map ? header['engagementPanelTitleHeaderRenderer'] : null;
      if (title is! Map) continue;
      final label = _text(title['contextualInfo']).nullIfEmpty;
      if (label != null) return label;
    }
    return null;
  }

  /// Token for the comment section, taken from the *last* continuation in the
  /// watch response — the earlier ones belong to the recommendations rail.
  static String? _commentsToken(Map<String, dynamic> json) {
    final items = <Map<String, dynamic>>[];
    _collect(json, 'continuationItemRenderer', items);
    String? last;
    for (final item in items) {
      final tokens = <String>[];
      _collectStrings(item, 'token', tokens);
      if (tokens.isNotEmpty) last = tokens.first;
    }
    return last;
  }

  /// Token for the *next* page — of comments, or of replies.
  ///
  /// Every thread with replies carries its own `continuationItemRenderer`
  /// inside `commentRepliesRenderer`, so on a page of twenty comments the
  /// first such item in the document is almost always a reply thread's. That
  /// was what this used to return, so scrolling to the bottom of the sheet
  /// appended the first comment's replies as though they were more comments.
  /// The page's own item is the one outside every thread; the last such is
  /// taken. On a replies page it is the "Show more replies" button, whose
  /// token sits under `button…command`, which [_firstToken] also reaches.
  static String? _nextToken(Map<String, dynamic> json) {
    final items = <Map<String, dynamic>>[];
    _collectOutside(json, 'continuationItemRenderer', 'commentThreadRenderer', items);
    String? last;
    for (final item in items) {
      final token = _firstToken(item);
      if (token != null) last = token;
    }
    return last;
  }

  static String? _headerCount(Map<String, dynamic> json) {
    final headers = <Map<String, dynamic>>[];
    _collect(json, 'commentsHeaderRenderer', headers);
    for (final h in headers) {
      final label = _text(h['countText']);
      if (label.isNotEmpty) return label;
    }
    return null;
  }

  // ------------------------------------------------------------- helpers

  /// Every `commentViewModel` map that names a comment (has `commentKey`), in
  /// document order. The key is used both for a wrapper and for the model
  /// inside it, so only the ones carrying the key are kept.
  static void _collectViews(dynamic node, List<Map<String, dynamic>> out) {
    if (node is Map) {
      if (node['commentKey'] is String) out.add(node.cast<String, dynamic>());
      for (final v in node.values) {
        _collectViews(v, out);
      }
    } else if (node is List) {
      for (final v in node) {
        _collectViews(v, out);
      }
    }
  }

  static String? _firstToken(dynamic node) {
    final commands = <Map<String, dynamic>>[];
    _collect(node, 'continuationCommand', commands);
    for (final c in commands) {
      final token = c['token'];
      if (token is String && token.isNotEmpty) return token;
    }
    return null;
  }

  static void _collect(
    dynamic node,
    String key,
    List<Map<String, dynamic>> out,
  ) {
    if (node is Map) {
      final hit = node[key];
      if (hit is Map<String, dynamic>) out.add(hit);
      for (final v in node.values) {
        _collect(v, key, out);
      }
    } else if (node is List) {
      for (final v in node) {
        _collect(v, key, out);
      }
    }
  }

  /// [_collect], without descending into anything stored under [skip].
  static void _collectOutside(
    dynamic node,
    String key,
    String skip,
    List<Map<String, dynamic>> out,
  ) {
    if (node is Map) {
      final hit = node[key];
      if (hit is Map<String, dynamic>) out.add(hit);
      for (final entry in node.entries) {
        if (entry.key == skip) continue;
        _collectOutside(entry.value, key, skip, out);
      }
    } else if (node is List) {
      for (final v in node) {
        _collectOutside(v, key, skip, out);
      }
    }
  }

  static void _collectStrings(dynamic node, String key, List<String> out) {
    if (node is Map) {
      final v = node[key];
      if (v is String && v.isNotEmpty) out.add(v);
      for (final child in node.values) {
        _collectStrings(child, key, out);
      }
    } else if (node is List) {
      for (final child in node) {
        _collectStrings(child, key, out);
      }
    }
  }

  static String _text(dynamic node) {
    if (node == null) return '';
    if (node is String) return node;
    if (node is! Map) return '';
    final simple = node['simpleText'];
    if (simple is String) return simple;
    final content = node['content'];
    if (content is String) return content;
    final runs = node['runs'];
    if (runs is List) {
      final b = StringBuffer();
      for (final r in runs) {
        if (r is Map && r['text'] is String) b.write(r['text']);
      }
      return b.toString();
    }
    return '';
  }

  static String? _firstUrl(dynamic node) {
    final urls = <String>[];
    _collectStrings(node, 'url', urls);
    return urls.isEmpty ? null : urls.last;
  }
}

/// One run of a comment's text: plain, or a timestamp that seeks the video.
typedef CommentSpan = ({String text, Duration? seekTo});

/// Splits [text] into plain runs and `1:23` / `1:02:03` timestamps.
///
/// What it must not take for a timestamp, each pinned by a test: `16:9`
/// (seconds need two digits), `10:30pm` (a time of day — a word character
/// right after it), `1:75` (no such second), `1:70:00` (no such minute in an
/// hours form) and the digits inside a longer number such as `2024:11:05`.
/// Pure so all of that is testable without a widget.
List<CommentSpan> splitCommentTimestamps(String text) {
  final pattern = RegExp(r'(?<![\w:])(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?![\w:])');
  final out = <CommentSpan>[];
  var at = 0;
  for (final m in pattern.allMatches(text)) {
    final hours = m.group(1) == null ? 0 : int.parse(m.group(1)!);
    final minutes = int.parse(m.group(2)!);
    final seconds = int.parse(m.group(3)!);
    if (seconds > 59) continue;
    if (m.group(1) != null && minutes > 59) continue;
    if (m.start > at) out.add((text: text.substring(at, m.start), seekTo: null));
    out.add((
      text: m.group(0)!,
      seekTo: Duration(hours: hours, minutes: minutes, seconds: seconds),
    ));
    at = m.end;
  }
  if (at < text.length) out.add((text: text.substring(at), seekTo: null));
  return out;
}

extension on String {
  String? get nullIfEmpty => trim().isEmpty ? null : this;
}

class CommentsException implements Exception {
  CommentsException(this.message);
  final String message;
  @override
  String toString() => message;
}
