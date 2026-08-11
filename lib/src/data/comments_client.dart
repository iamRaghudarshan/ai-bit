import 'dart:convert';

import 'package:http/http.dart' as http;

/// One top-level comment.
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
}

class CommentPage {
  const CommentPage({
    required this.comments,
    this.totalLabel,
    this.continuation,
  });

  final List<VideoComment> comments;

  /// "1.2K Comments" as YouTube renders it, or null when it declines to say.
  final String? totalLabel;

  /// Token for the next page, or null at the end.
  final String? continuation;

  bool get hasMore => continuation != null;
}

/// Reads a video's comments.
///
/// `youtube_explode_dart` deprecated its comments API outright ("This interface
/// will not be supported anymore"), so this talks to `youtubei/v1/next`
/// directly.
///
/// Comments are not in the first response. That one carries a *continuation
/// token* for the comment section, which has to be posted back to get the
/// comments themselves — two round trips, by YouTube's design.
///
/// The payloads also moved: comments used to live in `commentRenderer` and now
/// arrive as `commentEntityPayload` entity mutations. Both are read, because
/// YouTube serves the old shape to some clients.
class YoutubeCommentsClient {
  YoutubeCommentsClient({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  static const _context = {
    'client': {
      'clientName': 'WEB',
      'clientVersion': '2.20250312.04.00',
      'hl': 'en',
      'gl': 'US',
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

  /// First page of comments for [videoId].
  Future<CommentPage> fetch(String videoId) async {
    final first = await _next({'videoId': videoId});

    // Comment sections are the continuation whose token sits alongside the
    // comments header; taking the last candidate avoids the "up next" one,
    // which appears first.
    final token = _commentsToken(first);
    if (token == null) {
      return const CommentPage(comments: [], totalLabel: null);
    }
    return _page(await _next({'continuation': token}));
  }

  /// A further page, using the token from [CommentPage.continuation].
  Future<CommentPage> more(String continuation) async =>
      _page(await _next({'continuation': continuation}));

  CommentPage _page(Map<String, dynamic> json) {
    final payloads = <Map<String, dynamic>>[];
    _collect(json, 'commentEntityPayload', payloads);

    final comments = <VideoComment>[];
    for (final p in payloads) {
      final comment = _fromPayload(p);
      if (comment != null) comments.add(comment);
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
      totalLabel: _totalLabel(json),
      continuation: _nextToken(json),
    );
  }

  static VideoComment? _fromPayload(Map<String, dynamic> p) {
    final props = p['properties'] as Map<String, dynamic>?;
    final author = p['author'] as Map<String, dynamic>?;
    final toolbar = p['toolbar'] as Map<String, dynamic>?;

    final text = (props?['content'] as Map?)?['content'];
    if (text is! String || text.isEmpty) return null;

    final replies = toolbar?['replyCount'];
    return VideoComment(
      author: (author?['displayName'] as String?) ?? '',
      text: text,
      avatarUrl: author?['avatarThumbnailUrl'] as String?,
      likeLabel: (toolbar?['likeCountNotliked'] ?? toolbar?['likeCountLiked'])
          as String?,
      publishedText: props?['publishedTime'] as String?,
      replyCount: replies is int
          ? replies
          : int.tryParse(replies?.toString() ?? '') ?? 0,
      isPinned: (props?['pinnedText'] as String?)?.isNotEmpty ?? false,
      isCreator: author?['isCreator'] == true,
    );
  }

  static VideoComment? _fromRenderer(Map<String, dynamic> r) {
    final text = _text(r['contentText']);
    if (text.isEmpty) return null;
    return VideoComment(
      author: _text(r['authorText']),
      text: text,
      avatarUrl: _firstUrl(r['authorThumbnail']),
      likeLabel: _text(r['voteCount']).nullIfEmpty,
      publishedText: _text(r['publishedTimeText']).nullIfEmpty,
      isPinned: _text(r['pinnedCommentBadge']).isNotEmpty,
    );
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

  /// Token for the *next* page of comments.
  static String? _nextToken(Map<String, dynamic> json) {
    final items = <Map<String, dynamic>>[];
    _collect(json, 'continuationItemRenderer', items);
    for (final item in items) {
      // A "show more" button carries its own token; a reply thread's does not
      // belong here.
      final tokens = <String>[];
      _collectStrings(item, 'token', tokens);
      if (tokens.isNotEmpty) return tokens.last;
    }
    return null;
  }

  static String? _totalLabel(Map<String, dynamic> json) {
    final headers = <Map<String, dynamic>>[];
    _collect(json, 'commentsHeaderRenderer', headers);
    for (final h in headers) {
      final label = _text(h['countText']);
      if (label.isNotEmpty) return label;
    }
    return null;
  }

  // ------------------------------------------------------------- helpers

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

extension on String {
  String? get nullIfEmpty => trim().isEmpty ? null : this;
}

class CommentsException implements Exception {
  CommentsException(this.message);
  final String message;
  @override
  String toString() => message;
}
