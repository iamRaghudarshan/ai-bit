import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Channel and playlist browsing via YouTube's `youtubei/v1/browse` endpoint.
///
/// `youtube_explode_dart` can list a channel's uploads but not its playlists,
/// and its search parser is already known-broken, so browsing is done here for
/// the same reason search is: it can be fixed when YouTube changes shape.
///
/// Parsing recurses for the renderer types rather than following fixed paths.
/// YouTube reshuffles wrappers constantly and has been migrating playlist grids
/// from `gridPlaylistRenderer` to `lockupViewModel`; both are handled.
class YoutubeBrowseClient {
  YoutubeBrowseClient({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  static final _browse = Uri.parse(
    'https://www.youtube.com/youtubei/v1/browse?prettyPrint=false',
  );

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

  /// `params` selecting a channel's Playlists tab. Base64 of the protobuf
  /// YouTube's own web client sends.
  static const _playlistsTab = 'EglwbGF5bGlzdHPyBgQKAkIA';

  void close() => _http.close();

  Future<Map<String, dynamic>> _post(Map<String, dynamic> body) async {
    final response = await _http
        .post(
          _browse,
          headers: const {
            'Content-Type': 'application/json',
            'Origin': 'https://www.youtube.com',
            'Accept-Language': 'en-US,en;q=0.9',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
          },
          body: jsonEncode({'context': _context, ...body}),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw BrowseException('YouTube returned HTTP ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Header details for a channel: name, avatar, subscriber line.
  ///
  /// The modern header is a `pageHeaderViewModel` whose subscriber count sits
  /// among free-text `metadataParts` alongside the handle and video count, in
  /// no guaranteed order — so it is picked out by looking for the word rather
  /// than by position. `c4TabbedHeaderRenderer` is the older shape, still
  /// returned for some channels.
  Future<ChannelInfo> channel(String channelId) async {
    final json = await _post({'browseId': channelId});

    final modern = <Map<String, dynamic>>[];
    _collect(json, 'pageHeaderViewModel', modern);
    final legacy = <Map<String, dynamic>>[];
    _collect(json, 'c4TabbedHeaderRenderer', legacy);

    String? title;
    String? avatar;
    String? subs;
    String? handle;

    for (final h in modern) {
      title ??= _deepText(h['title'], 'content').nullIfEmpty;
      avatar ??= _firstThumbnail(h['image']);

      final parts = <String>[];
      _collectStrings(h['metadata'], 'content', parts);
      for (final p in parts) {
        final lower = p.toLowerCase();
        if (subs == null && lower.contains('subscriber')) subs = p;
        if (handle == null && p.startsWith('@')) handle = p;
      }
    }

    for (final h in legacy) {
      title ??= _text(h['title']).nullIfEmpty;
      subs ??= _text(h['subscriberCountText']).nullIfEmpty;
      avatar ??= _firstThumbnail(h['avatar']);
    }

    return ChannelInfo(
      id: channelId,
      title: title ?? '',
      avatarUrl: avatar,
      // Fall back to the handle so the line under the name is never blank.
      subscriberLabel: subs ?? handle,
    );
  }

  /// Collects every string stored under [key] anywhere in [node].
  static void _collectStrings(dynamic node, String key, List<String> out) {
    if (node is Map) {
      final v = node[key];
      if (v is String && v.trim().isNotEmpty) out.add(v);
      for (final child in node.values) {
        _collectStrings(child, key, out);
      }
    } else if (node is List) {
      for (final child in node) {
        _collectStrings(child, key, out);
      }
    }
  }

  /// Playlists published by a channel.
  Future<List<PlaylistBrief>> channelPlaylists(String channelId) async {
    final json = await _post({
      'browseId': channelId,
      'params': _playlistsTab,
    });

    final out = <PlaylistBrief>[];
    final seen = <String>{};

    // The classic grid renderer.
    final grids = <Map<String, dynamic>>[];
    _collect(json, 'gridPlaylistRenderer', grids);
    for (final g in grids) {
      final id = g['playlistId'];
      if (id is! String) continue;
      if (!seen.add(id)) continue;
      out.add(PlaylistBrief(
        id: id,
        title: _text(g['title']),
        videoCount: _digits(_text(g['videoCountShortText'])) ??
            _digits(_text(g['videoCountText'])),
        thumbnailUrl: _firstThumbnail(g),
        channelId: channelId,
      ));
    }

    // The newer lockup shape, which carries ids on a nested endpoint.
    final lockups = <Map<String, dynamic>>[];
    _collect(json, 'lockupViewModel', lockups);
    for (final l in lockups) {
      final id = l['contentId'];
      if (id is! String || !id.startsWith('PL') && !id.startsWith('UU')) continue;
      if (!seen.add(id)) continue;
      out.add(PlaylistBrief(
        id: id,
        title: _deepText(l, 'title'),
        videoCount: null,
        thumbnailUrl: _firstThumbnail(l),
        channelId: channelId,
      ));
    }

    return out;
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

  /// Handles `simpleText`, `runs`, and the newer `content`/`text` view models.
  static String _text(dynamic node) {
    if (node == null) return '';
    if (node is String) return node;
    if (node is List) return node.map(_text).join();
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

  /// Finds the first non-empty string under [key] anywhere in [node].
  static String _deepText(dynamic node, String key) {
    if (node is Map) {
      final direct = _text(node[key]);
      if (direct.isNotEmpty) return direct;
      for (final v in node.values) {
        final found = _deepText(v, key);
        if (found.isNotEmpty) return found;
      }
    } else if (node is List) {
      for (final v in node) {
        final found = _deepText(v, key);
        if (found.isNotEmpty) return found;
      }
    }
    return '';
  }

  static String? _firstThumbnail(dynamic node) {
    if (node is Map) {
      // `thumbnails` is the classic renderer shape; the newer view models call
      // the same thing `sources`. Both are lists ordered smallest to largest.
      final thumbs = node['thumbnails'] ?? node['sources'];
      if (thumbs is List && thumbs.isNotEmpty) {
        final url = (thumbs.last as Map?)?['url'];
        if (url is String && url.isNotEmpty) {
          return url.startsWith('//') ? 'https:$url' : url;
        }
      }
      for (final v in node.values) {
        final found = _firstThumbnail(v);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final v in node) {
        final found = _firstThumbnail(v);
        if (found != null) return found;
      }
    }
    return null;
  }

  static int? _digits(String label) {
    final d = label.replaceAll(RegExp(r'[^0-9]'), '');
    return d.isEmpty ? null : int.tryParse(d);
  }
}

extension on String {
  String? get nullIfEmpty => trim().isEmpty ? null : this;
}

class BrowseException implements Exception {
  BrowseException(this.message);
  final String message;
  @override
  String toString() => message;
}
