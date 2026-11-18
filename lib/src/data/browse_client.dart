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

  static final _nextUri = Uri.parse(
    'https://www.youtube.com/youtubei/v1/next?prettyPrint=false',
  );

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

  /// `params` selecting a channel's Playlists tab. Base64 of the protobuf
  /// YouTube's own web client sends.
  static const _playlistsTab = 'EglwbGF5bGlzdHPyBgQKAkIA';

  void close() => _http.close();

  Future<Map<String, dynamic>> _post(
    Map<String, dynamic> body, {
    Uri? endpoint,
  }) async {
    final response = await _http
        .post(
          endpoint ?? _browse,
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
  /// Channel name and avatar out of a browse response.
  ///
  /// Every channel-tab response carries the page header already, so the rows
  /// can be labelled from the same request rather than arriving blank. They
  /// used to inherit whatever title the caller happened to pass — an empty
  /// string when a channel was opened directly — and no avatar at all.
  static ({String? title, String? avatar}) _headerOf(
    Map<String, dynamic> json,
  ) {
    final modern = <Map<String, dynamic>>[];
    _collect(json, 'pageHeaderViewModel', modern);
    for (final h in modern) {
      final title = _deepText(h['title'], 'content').nullIfEmpty;
      final avatar = _firstThumbnail(h['image']);
      if (title != null || avatar != null) {
        return (title: title, avatar: avatar);
      }
    }

    final legacy = <Map<String, dynamic>>[];
    _collect(json, 'c4TabbedHeaderRenderer', legacy);
    for (final h in legacy) {
      return (
        title: _text(h['title']).nullIfEmpty,
        avatar: _firstThumbnail(h['avatar']),
      );
    }
    return (title: null, avatar: null);
  }

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

  /// `params` selecting a channel's Videos tab.
  ///
  /// Only this plain form works. The sort variants documented elsewhere
  /// (`…YAyABMAE=` for Popular and so on) return an empty page, so ordering
  /// other than "latest" is done on the fetched set instead.
  static const _videosTab = 'EgZ2aWRlb3PyBgQKAjoA';

  /// `params` for the Live tab, which returns past and current streams under
  /// the same `lockupViewModel` the Videos tab uses.
  static const _liveTab = 'EgdzdHJlYW1z8gYECgJ6AA==';

  /// `params` for the Shorts tab. These come back as `shortsLockupViewModel`
  /// instead, so they need their own parser.
  static const _shortsTab = 'EgZzaG9ydHPyBgUKA5oBAA==';

  /// A channel's uploads.
  ///
  /// Needed because `youtube_explode_dart`'s `channels.getUploads` returns an
  /// empty stream — measured against two channels, zero videos in both. The
  /// channel page uses `richItemRenderer` wrapping `lockupViewModel`, with no
  /// `videoRenderer` anywhere, which is why the package finds nothing.
  Future<List<VideoBrief>> channelVideos(
    String channelId, {
    String channelTitle = '',
    bool live = false,
  }) async {
    final json = await _post({
      'browseId': channelId,
      'params': live ? _liveTab : _videosTab,
    });
    final header = _headerOf(json);
    final title = channelTitle.isNotEmpty ? channelTitle : (header.title ?? '');

    final lockups = <Map<String, dynamic>>[];
    _collect(json, 'lockupViewModel', lockups);

    final out = <VideoBrief>[];
    final seen = <String>{};
    for (final l in lockups) {
      if (l['contentType'] != 'LOCKUP_CONTENT_TYPE_VIDEO') continue;
      final id = l['contentId'];
      if (id is! String || id.isEmpty || !seen.add(id)) continue;

      // metadata reads as [title, "733K views", "1 day ago", …menu items].
      final parts = <String>[];
      _collectStrings(l['metadata'], 'content', parts);
      if (parts.isEmpty) continue;

      final views = parts.firstWhere(
        (p) => p.toLowerCase().contains('view'),
        orElse: () => '',
      );
      final age = parts.firstWhere(
        (p) => p.toLowerCase().contains('ago') || p.toLowerCase().contains('stream'),
        orElse: () => '',
      );

      out.add(VideoBrief(
        id: id,
        title: parts.first,
        author: title,
        avatarUrl: header.avatar,
        channelId: channelId,
        duration: _durationFromBadge(l['contentImage']),
        viewCount: _parseCompact(views),
        uploadRaw: age.isEmpty ? null : age,
        isLive: views.toLowerCase().contains('watching'),
      ));
    }
    return out;
  }

  /// Related / up-next videos for a watch page, via the `next` endpoint.
  ///
  /// `youtube_explode_dart`'s `getRelatedVideos` throws on YouTube's current
  /// `lockupViewModel` response (it tries to parse "Streamed …" as a date), so
  /// the app was always falling back to same-channel uploads. Parsing the
  /// response here — with the same lockup and duration-badge reading the channel
  /// tabs use — gives real suggestions that carry their **duration**, which the
  /// package's broken path dropped.
  Future<List<VideoBrief>> related(String videoId) async {
    final json = await _post({'videoId': videoId}, endpoint: _nextUri);

    final lockups = <Map<String, dynamic>>[];
    _collect(json, 'lockupViewModel', lockups);

    final out = <VideoBrief>[];
    final seen = <String>{};
    for (final l in lockups) {
      if (l['contentType'] != 'LOCKUP_CONTENT_TYPE_VIDEO') continue;
      final id = l['contentId'];
      if (id is! String || id.isEmpty || id == videoId || !seen.add(id)) {
        continue;
      }

      // metadata reads as [title, channel, "733K views", "1 day ago", …].
      final parts = <String>[];
      _collectStrings(l['metadata'], 'content', parts);
      if (parts.isEmpty) continue;

      final views = parts.firstWhere(
        (p) => p.toLowerCase().contains('view'),
        orElse: () => '',
      );
      final age = parts.firstWhere(
        (p) =>
            p.toLowerCase().contains('ago') ||
            p.toLowerCase().contains('stream'),
        orElse: () => '',
      );
      // The channel name is the metadata line that is neither the title nor the
      // views/age stats.
      final author = parts.skip(1).firstWhere(
        (p) =>
            p != views &&
            p != age &&
            !p.toLowerCase().contains('view') &&
            !p.toLowerCase().contains('watching'),
        orElse: () => '',
      );
      // A UC… browseId points at the video's channel, for tapping through.
      final browseIds = <String>[];
      _collectStrings(l, 'browseId', browseIds);
      final channelId = browseIds.firstWhere(
        (b) => b.startsWith('UC'),
        orElse: () => '',
      );

      out.add(VideoBrief(
        id: id,
        title: parts.first,
        author: author,
        channelId: channelId,
        duration: _durationFromBadge(l['contentImage']),
        viewCount: _parseCompact(views),
        uploadRaw: age.isEmpty ? null : age,
        isLive: views.toLowerCase().contains('watching'),
      ));
    }
    return out;
  }

  /// Reads `12:34` out of the thumbnail's duration badge.
  ///
  /// Both key names are collected: the badge stores its label under `text` in
  /// some responses and `content` in others, and looking for only one of them
  /// left every channel video without a duration.
  static Duration? _durationFromBadge(dynamic contentImage) {
    final texts = <String>[];
    _collectStrings(contentImage, 'content', texts);
    _collectStrings(contentImage, 'text', texts);
    for (final t in texts) {
      if (!RegExp(r'^\d{1,2}(:\d{2}){1,2}$').hasMatch(t.trim())) continue;
      final parts = t.trim().split(':').map(int.parse).toList();
      return switch (parts.length) {
        3 => Duration(hours: parts[0], minutes: parts[1], seconds: parts[2]),
        2 => Duration(minutes: parts[0], seconds: parts[1]),
        _ => null,
      };
    }
    return null;
  }

  /// `733K views` -> 733000. The channel page abbreviates where search does
  /// not, so the raw digits alone would be off by a factor of a thousand.
  static int? _parseCompact(String label) {
    final match = RegExp(
      r'([\d.,]+)\s*([KMB])?',
      caseSensitive: false,
    ).firstMatch(label.trim());
    if (match == null) return null;
    final number = double.tryParse(match.group(1)!.replaceAll(',', ''));
    if (number == null) return null;
    final multiplier = switch (match.group(2)?.toUpperCase()) {
      'K' => 1000,
      'M' => 1000000,
      'B' => 1000000000,
      _ => 1,
    };
    return (number * multiplier).round();
  }

  /// Videos inside a playlist.
  ///
  /// Needed because `playlists.getVideos` returns an empty stream — zero for
  /// every playlist measured, the same failure as `channels.getUploads`. The
  /// playlist page is browsed as `VL` + the playlist id, and its videos come
  /// back as `lockupViewModel`, not `playlistVideoRenderer`.
  Future<List<VideoBrief>> playlistVideos(String playlistId) async {
    final json = await _post({'browseId': 'VL$playlistId'});

    final lockups = <Map<String, dynamic>>[];
    _collect(json, 'lockupViewModel', lockups);

    final out = <VideoBrief>[];
    final seen = <String>{};
    for (final l in lockups) {
      if (l['contentType'] != 'LOCKUP_CONTENT_TYPE_VIDEO') continue;
      final id = l['contentId'];
      if (id is! String || id.isEmpty || !seen.add(id)) continue;

      // metadata reads as [title, channel, "715K views"].
      final parts = <String>[];
      _collectStrings(l['metadata'], 'content', parts);
      if (parts.isEmpty) continue;

      final views = parts.firstWhere(
        (p) => p.toLowerCase().contains('view'),
        orElse: () => '',
      );

      out.add(VideoBrief(
        id: id,
        title: parts.first,
        author: parts.length > 1 && !parts[1].toLowerCase().contains('view')
            ? parts[1]
            : '',
        channelId: '',
        duration: _durationFromBadge(l['contentImage']),
        viewCount: _parseCompact(views),
      ));
    }
    return out;
  }

  /// Playlists published by a channel.
  /// A channel's Shorts.
  ///
  /// The tab returns `shortsLockupViewModel`, which carries neither a duration
  /// nor an upload date — only a title and a view count — so the rows are
  /// thinner than the Videos tab's on purpose.
  Future<List<VideoBrief>> channelShorts(
    String channelId, {
    String channelTitle = '',
  }) async {
    final json = await _post({'browseId': channelId, 'params': _shortsTab});
    final header = _headerOf(json);
    final title = channelTitle.isNotEmpty ? channelTitle : (header.title ?? '');

    final lockups = <Map<String, dynamic>>[];
    _collect(json, 'shortsLockupViewModel', lockups);

    final out = <VideoBrief>[];
    final seen = <String>{};
    for (final l in lockups) {
      final id = _shortsId(l);
      if (id == null || !seen.add(id)) continue;

      final titles = <String>[];
      _collectStrings(l['overlayMetadata'], 'content', titles);
      if (titles.isEmpty) continue;

      final views = titles.length > 1 ? titles[1] : '';
      out.add(VideoBrief(
        id: id,
        title: titles.first,
        author: title,
        avatarUrl: header.avatar,
        channelId: channelId,
        viewCount: _parseCompact(views),
      ));
    }
    return out;
  }

  /// The video id sits on the tap command rather than a plain field.
  static String? _shortsId(Map<String, dynamic> lockup) {
    final ids = <String>[];
    _collectStrings(lockup['onTap'], 'videoId', ids);
    if (ids.isNotEmpty) return ids.first;
    final entity = lockup['entityId'];
    if (entity is String && entity.startsWith('shorts-shelf-item-')) {
      return entity.substring('shorts-shelf-item-'.length);
    }
    return null;
  }

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

    // The newer lockup shape, which is the only one a real channel returns
    // now: a channel measured in November 2026 gave 27 `lockupViewModel`s and
    // zero `gridPlaylistRenderer`s, so everything below is the live path and
    // the grid branch above is the fallback.
    final lockups = <Map<String, dynamic>>[];
    _collect(json, 'lockupViewModel', lockups);
    for (final l in lockups) {
      final id = l['contentId'];
      if (id is! String) continue;
      // Prefer what the lockup says it is. The id-prefix test is kept as a
      // fallback for a lockup with no contentType, but on its own it was both
      // too narrow and too broad — it missed album playlists (`OLAK5uy_…`) and
      // would have accepted anything else beginning "PL".
      final type = l['contentType'];
      final looksRight = type is String
          ? type == 'LOCKUP_CONTENT_TYPE_PLAYLIST' ||
              type == 'LOCKUP_CONTENT_TYPE_ALBUM'
          : id.startsWith('PL') || id.startsWith('UU') || id.startsWith('OLAK');
      if (!looksRight) continue;
      if (!seen.add(id)) continue;
      out.add(PlaylistBrief(
        id: id,
        title: _deepText(l, 'title'),
        videoCount: _lockupVideoCount(l),
        thumbnailUrl: _firstThumbnail(l),
        channelId: channelId,
      ));
    }

    return out;
  }

  /// Number of videos in a playlist lockup.
  ///
  /// This was returning null for every playlist, which is why the channel
  /// Playlists tab showed "Playlist" under each row where YouTube shows
  /// "9 videos" — the information was in the response the whole time.
  ///
  /// It lives in the thumbnail's overlay badge, not in the metadata rows:
  ///
  ///   contentImage.collectionThumbnailViewModel.primaryThumbnail
  ///     .thumbnailViewModel.overlays[].thumbnailOverlayBadgeViewModel
  ///     .thumbnailBadges[].thumbnailBadgeViewModel.text   -> "9 videos"
  ///
  /// The metadata rows beside it read "Playlist" and "View full playlist", so
  /// a general search for the first number anywhere in the lockup is not safe
  /// either — the badge is the only place the count appears. Addressed by
  /// collecting badge view models rather than by walking that whole path,
  /// because the path has changed shape before and the badge has not.
  static int? _lockupVideoCount(Map<String, dynamic> lockup) {
    final badges = <Map<String, dynamic>>[];
    _collect(lockup, 'thumbnailBadgeViewModel', badges);
    for (final badge in badges) {
      final count = videoCountFromBadge(_text(badge['text']));
      if (count != null) return count;
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

/// Reads a playlist's video count out of a thumbnail badge's text.
///
/// Pure and public so each shape it has to survive gets a test, which is the
/// habit this codebase arrived at the hard way: the data-usage estimator read
/// `1080p60` as 108060 because it stripped every non-digit and assumed it had
/// seen all the shapes.
///
/// What arrives here, measured against a real channel:
///
///   * `"9 videos"` — the ordinary case.
///   * `"1 video"` — singular, so the pattern cannot require the "s".
///   * `"1,204 videos"` — grouped, and the separator is locale-dependent:
///     a German response says `"1.204 Videos"`. Both separators are stripped
///     rather than parsed, because a thousands separator never carries
///     meaning here and treating `.` as a decimal point would read 1.204 as
///     one video.
///   * `"Playlist"` — the sibling metadata row, which must yield null rather
///     than a number. This is why the word "video" has to be matched at all
///     instead of taking the first run of digits in the lockup.
///
/// Returns null when the text is not a count, so the caller can keep looking
/// at the other badges.
int? videoCountFromBadge(String text) {
  final match = RegExp(
    r'([\d][\d,.   ]*)\s*(video|videos|Video|Videos)\b',
  ).firstMatch(text);
  if (match == null) return null;
  final digits = match.group(1)!.replaceAll(RegExp(r'[^\d]'), '');
  if (digits.isEmpty) return null;
  return int.tryParse(digits);
}

class BrowseException implements Exception {
  BrowseException(this.message);
  final String message;
  @override
  String toString() => message;
}
