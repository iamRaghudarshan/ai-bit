import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Search against YouTube's own `youtubei` endpoint.
///
/// This exists because `youtube_explode_dart` 3.1.0 — the latest release —
/// cannot parse YouTube's current search response. Its parser does:
///
///     ?.firstOrNull?.getT<String>('text')
///
/// `firstOrNull` on a `List<dynamic>` is statically `dynamic`, and `getT` is an
/// extension method; Dart cannot dispatch extension methods on `dynamic`, so it
/// throws `NoSuchMethodError` at runtime. It only fires when a result carries
/// its view count as `runs` rather than `simpleText`, which is why some queries
/// worked and others died. Search was broken on every platform.
///
/// Parsing here is deliberately defensive: every field is optional, and a
/// single malformed entry is skipped rather than failing the whole page.
class YoutubeSearchClient {
  YoutubeSearchClient({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  static final _endpoint = Uri.parse(
    'https://www.youtube.com/youtubei/v1/search?prettyPrint=false',
  );

  /// The WEB client returns the richest result shape. It needs no signature
  /// work, since nothing here touches media URLs.
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

  /// `sp` parameter values. Same encoding YouTube uses in its own search URLs.
  static const filterVideosOnly = 'EgIQAQ%3D%3D';
  static const filterByViewCount = 'CAMSAhAB';

  void close() => _http.close();

  Future<List<VideoBrief>> search(String query, {String? params}) async {
    final response = await _http
        .post(
          _endpoint,
          headers: const {
            'Content-Type': 'application/json',
            'Accept-Language': 'en-US,en;q=0.9',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
            'Origin': 'https://www.youtube.com',
          },
          body: jsonEncode({
            'context': _context,
            'query': query,
            'params': params ?? filterVideosOnly,
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw SearchException('YouTube returned HTTP ${response.statusCode}');
    }

    final json = jsonDecode(utf8.decode(response.bodyBytes));
    final renderers = <Map<String, dynamic>>[];
    _collectVideoRenderers(json, renderers);

    final out = <VideoBrief>[];
    final seen = <String>{};
    for (final r in renderers) {
      final brief = _toBrief(r);
      if (brief != null && seen.add(brief.id)) out.add(brief);
    }
    return out;
  }

  /// Walks the response for `videoRenderer` nodes wherever they sit.
  ///
  /// YouTube reshuffles the wrapper objects around results regularly — shelves,
  /// section lists, reels. Recursing for the one node type we care about
  /// survives those changes, where a fixed path does not.
  static void _collectVideoRenderers(
    dynamic node,
    List<Map<String, dynamic>> out,
  ) {
    if (node is Map) {
      final renderer = node['videoRenderer'];
      if (renderer is Map<String, dynamic>) out.add(renderer);
      for (final value in node.values) {
        _collectVideoRenderers(value, out);
      }
    } else if (node is List) {
      for (final value in node) {
        _collectVideoRenderers(value, out);
      }
    }
  }

  static VideoBrief? _toBrief(Map<String, dynamic> r) {
    final id = r['videoId'];
    if (id is! String || id.isEmpty) return null;

    final title = _text(r['title']);
    if (title.isEmpty) return null;

    final isLive =
        _text(r['badges']).toLowerCase().contains('live') ||
        (r['thumbnailOverlays']?.toString().contains('LIVE') ?? false);

    return VideoBrief(
      id: id,
      title: title,
      author: _text(r['ownerText']).isNotEmpty
          ? _text(r['ownerText'])
          : _text(r['longBylineText']),
      channelId: _channelId(r) ?? '',
      duration: _duration(_text(r['lengthText'])),
      viewCount: _digits(_text(r['viewCountText'])),
      uploadRaw: _text(r['publishedTimeText']).nullIfEmpty,
      isLive: isLive,
    );
  }

  /// Handles both `{simpleText: ...}` and `{runs: [{text: ...}]}` — the exact
  /// distinction the upstream parser crashed on.
  static String _text(dynamic node) {
    if (node == null) return '';
    if (node is String) return node;
    if (node is List) return node.map(_text).join();
    if (node is! Map) return '';

    final simple = node['simpleText'];
    if (simple is String) return simple;

    final runs = node['runs'];
    if (runs is List) {
      final buffer = StringBuffer();
      for (final run in runs) {
        if (run is Map && run['text'] is String) buffer.write(run['text']);
      }
      return buffer.toString();
    }
    return '';
  }

  static String? _channelId(Map<String, dynamic> r) {
    for (final key in ['ownerText', 'longBylineText', 'shortBylineText']) {
      final runs = (r[key] as Map?)?['runs'];
      if (runs is! List) continue;
      for (final run in runs) {
        final id = (((run as Map?)?['navigationEndpoint']
                as Map?)?['browseEndpoint']
            as Map?)?['browseId'];
        if (id is String && id.isNotEmpty) return id;
      }
    }
    return null;
  }

  /// `1:02:03` or `4:13` -> Duration. Null for live streams, which have none.
  static Duration? _duration(String label) {
    if (label.trim().isEmpty) return null;
    final parts = label.trim().split(':').map(int.tryParse).toList();
    if (parts.any((p) => p == null)) return null;
    final n = parts.cast<int>();
    return switch (n.length) {
      3 => Duration(hours: n[0], minutes: n[1], seconds: n[2]),
      2 => Duration(minutes: n[0], seconds: n[1]),
      1 => Duration(seconds: n[0]),
      _ => null,
    };
  }

  /// `1,234,567 views` -> 1234567. Null when absent, which is normal for live.
  static int? _digits(String label) {
    final digits = label.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.isEmpty ? null : int.tryParse(digits);
  }
}

extension on String {
  String? get nullIfEmpty => trim().isEmpty ? null : this;
}

class SearchException implements Exception {
  SearchException(this.message);
  final String message;

  @override
  String toString() => 'Search failed: $message';
}
