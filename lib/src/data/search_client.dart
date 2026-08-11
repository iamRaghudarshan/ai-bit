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

  /// `sp` parameter values.
  ///
  /// Raw base64 with real `=` padding, **not** the URL-encoded `%3D` form seen
  /// in browser address bars — these go in a JSON body, and the encoded version
  /// silently returns an empty page.
  static const filterVideosOnly = 'EgIQAQ==';

  /// Videos under four minutes. The Shorts feed narrows further client-side.
  static const filterShort = 'EgIYAQ==';
  static const filterByViewCount = 'CAMSAhAB';

  /// Single-choice search filters, matching YouTube's own filter panel.
  static const filters = <SearchFilterGroup>[
    SearchFilterGroup('Sort by', [
      SearchFilterOption('Relevance', null),
      SearchFilterOption('Upload date', 'CAI='),
      SearchFilterOption('View count', 'CAM='),
      SearchFilterOption('Rating', 'CAE='),
    ]),
    SearchFilterGroup('Upload date', [
      SearchFilterOption('Any time', null),
      SearchFilterOption('Last hour', 'EgIIAQ=='),
      SearchFilterOption('Today', 'EgIIAg=='),
      SearchFilterOption('This week', 'EgIIAw=='),
      SearchFilterOption('This month', 'EgIIBA=='),
      SearchFilterOption('This year', 'EgIIBQ=='),
    ]),
    SearchFilterGroup('Duration', [
      SearchFilterOption('Any', null),
      SearchFilterOption('Under 4 minutes', 'EgIYAQ=='),
      SearchFilterOption('Over 20 minutes', 'EgIYAg=='),
    ]),
    SearchFilterGroup('Type', [
      SearchFilterOption('Video', 'EgIQAQ=='),
      SearchFilterOption('Channel', 'EgIQAg=='),
      SearchFilterOption('Playlist', 'EgIQAw=='),
      SearchFilterOption('Movie', 'EgIQBA=='),
    ]),
  ];

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

  /// Shorts for the vertical feed.
  ///
  /// Shorts are not `videoRenderer`s and never appear in a normal search parse
  /// — they come back as `shortsLockupViewModel`, which is why probing for
  /// `videoRenderer`, `reelItemRenderer` and `lockupViewModel` all returned
  /// zero. The duration filter is deliberately not used: it returns an empty
  /// page for these queries, while an unfiltered search returns 30.
  Future<List<VideoBrief>> searchShorts(String query) async {
    final response = await _http
        .post(
          _endpoint,
          headers: const {
            'Content-Type': 'application/json',
            'Accept-Language': 'en-US,en;q=0.9',
            'Origin': 'https://www.youtube.com',
          },
          body: jsonEncode({'context': _context, 'query': query}),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw SearchException('YouTube returned HTTP ${response.statusCode}');
    }

    final json = jsonDecode(utf8.decode(response.bodyBytes));
    final lockups = <Map<String, dynamic>>[];
    _collectKey(json, 'shortsLockupViewModel', lockups);

    final out = <VideoBrief>[];
    final seen = <String>{};
    for (final s in lockups) {
      final ids = <String>[];
      _collectStringKey(s, 'videoId', ids);
      if (ids.isEmpty || !seen.add(ids.first)) continue;

      // overlayMetadata carries the title and view count; accessibilityText is
      // a single readable sentence used as the fallback.
      final texts = <String>[];
      _collectStringKey(s['overlayMetadata'], 'content', texts);
      final title = texts.isNotEmpty
          ? texts.first
          : (s['accessibilityText'] as String? ?? '');
      if (title.isEmpty) continue;

      final views = texts.length > 1 ? texts[1] : '';

      out.add(
        VideoBrief(
          id: ids.first,
          title: title,
          author: '',
          channelId: '',
          viewCount: _compact(views),
        ),
      );
    }
    return out;
  }

  static void _collectKey(
    dynamic node,
    String key,
    List<Map<String, dynamic>> out,
  ) {
    if (node is Map) {
      final hit = node[key];
      if (hit is Map<String, dynamic>) out.add(hit);
      for (final v in node.values) {
        _collectKey(v, key, out);
      }
    } else if (node is List) {
      for (final v in node) {
        _collectKey(v, key, out);
      }
    }
  }

  static void _collectStringKey(dynamic node, String key, List<String> out) {
    if (node is Map) {
      final v = node[key];
      if (v is String && v.isNotEmpty) out.add(v);
      for (final child in node.values) {
        _collectStringKey(child, key, out);
      }
    } else if (node is List) {
      for (final child in node) {
        _collectStringKey(child, key, out);
      }
    }
  }

  /// `1.2M views` -> 1200000. Shorts abbreviate where search results do not.
  static int? _compact(String label) {
    final m = RegExp(r'([\d.,]+)\s*([KMB])?', caseSensitive: false)
        .firstMatch(label.trim());
    if (m == null) return null;
    final n = double.tryParse(m.group(1)!.replaceAll(',', ''));
    if (n == null) return null;
    final mult = switch (m.group(2)?.toUpperCase()) {
      'K' => 1000,
      'M' => 1000000,
      'B' => 1000000000,
      _ => 1,
    };
    return (n * mult).round();
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

    // Matching 'LIVE' anywhere in the stringified overlays was far too loose:
    // it fires on unrelated style enums, so ordinary videos were marked live.
    // A live video is then handed to the player as a live stream, which has no
    // duration and cannot be seeked -- and setting up an audio-only source that
    // way threw, which is what "Could not start playback" was.
    final isLive = _isLiveBadge(r);

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
      avatarUrl: _avatar(r['channelThumbnailSupportedRenderers']),
    );
  }

  /// The channel's avatar, buried a few renderers deep in each result.
  static String? _avatar(dynamic node) {
    final urls = <String>[];
    _collectStringKey(node, 'url', urls);
    // Last entry is the largest.
    final url = urls.isEmpty ? null : urls.last;
    if (url == null) return null;
    return url.startsWith('//') ? 'https:$url' : url;
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

  /// True only when YouTube actually says the video is live.
  static bool _isLiveBadge(Map<String, dynamic> r) {
    final badges = <String>[];
    _collectStringKey(r['badges'], 'style', badges);
    _collectStringKey(r['badges'], 'label', badges);
    if (badges.any((b) => b.toUpperCase().contains('LIVE_NOW'))) return true;

    // The overlay carries an explicit style rather than free text.
    final styles = <String>[];
    _collectStringKey(r['thumbnailOverlays'], 'style', styles);
    return styles.any((s) => s.toUpperCase() == 'LIVE');
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

/// A row in the search filter sheet.
///
/// Only one option per group can apply: YouTube encodes combinations into a
/// single protobuf `sp` value, and a combined value cannot be built by
/// concatenating the individual ones.
class SearchFilterGroup {
  const SearchFilterGroup(this.title, this.options);

  final String title;
  final List<SearchFilterOption> options;
}

class SearchFilterOption {
  const SearchFilterOption(this.label, this.params);

  final String label;

  /// null means "no filter" — the default for that group.
  final String? params;
}

class SearchException implements Exception {
  SearchException(this.message);
  final String message;

  @override
  String toString() => 'Search failed: $message';
}
