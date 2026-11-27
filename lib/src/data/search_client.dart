import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;

import 'package:http/http.dart' as http;

import 'browse_client.dart' show videoCountFromBadge;
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

  /// `sp` parameter values.
  ///
  /// Raw base64 with real `=` padding, **not** the URL-encoded `%3D` form seen
  /// in browser address bars — these go in a JSON body, and the encoded version
  /// silently returns an empty page.
  static const filterVideosOnly = 'EgIQAQ==';

  /// Videos under four minutes. The Shorts feed narrows further client-side.
  static final filterShort = buildParams(duration: 1);
  static final filterByViewCount = buildParams(sortBy: 3);

  /// `uploadDate` field values, for asking a search to stay inside a window.
  ///
  /// These exist because [filterByViewCount] on its own means "the most-viewed
  /// videos of all time matching this query", and the most-viewed video about
  /// almost any topic is years old. Used unwindowed to build the home feed it
  /// is a greatest-hits query, which is exactly how a feed fills up with
  /// six-year-old videos: ranking can only ever order what candidate
  /// generation found, so no amount of freshness weighting downstream can
  /// rescue a candidate pool that contains nothing recent.
  ///
  /// Combined with [buildParams]'s `sortBy`, `uploadDate: uploadedThisWeek`
  /// reads as "the most-watched thing about this in the last week", which is
  /// what a recommendation feed actually wants.
  static const uploadedThisWeek = 3;
  static const uploadedThisMonth = 4;
  static const uploadedThisYear = 5;

  /// The search screen's filter panel, in YouTube's own January 2026 order
  /// and taxonomy: Type, Duration, Upload date, Features, Prioritize.
  ///
  /// The values are protobuf field values (or, for Features, field numbers)
  /// rather than finished `sp` strings — every one of them was read out of the
  /// `searchFilterOptionsDialogRenderer` a live search returns, which carries
  /// YouTube's own single-filter `sp` for each option, so they are measured
  /// rather than remembered. Each pre-baked string encodes one field and
  /// nothing else, so [encodeParams] combines the choices into the single
  /// message YouTube actually expects.
  ///
  /// "Last hour" and "Rating"/"Upload date" sorting are gone because YouTube
  /// removed them from the panel; "Under 3 minutes" is value 4 and the old
  /// "Under 4 minutes" (value 1) is no longer offered by YouTube either.
  static const filters = <SearchFilterGroup>[
    SearchFilterGroup(SearchFilterKind.type, 'Type', [
      SearchFilterOption('Any', null),
      SearchFilterOption('Videos', 1),
      SearchFilterOption('Shorts', 9),
      SearchFilterOption('Channels', 2),
      SearchFilterOption('Playlists', 3),
      SearchFilterOption('Movies', 4),
    ]),
    SearchFilterGroup(SearchFilterKind.duration, 'Duration', [
      SearchFilterOption('Any', null),
      SearchFilterOption('Under 3 minutes', 4),
      SearchFilterOption('3 - 20 minutes', 5),
      SearchFilterOption('Over 20 minutes', 2),
    ]),
    SearchFilterGroup(SearchFilterKind.uploadDate, 'Upload date', [
      SearchFilterOption('Any time', null),
      SearchFilterOption('Today', 2),
      SearchFilterOption('This week', 3),
      SearchFilterOption('This month', 4),
      SearchFilterOption('This year', 5),
    ]),
    // Multi-select. Each value is the FIELD NUMBER of a boolean in the nested
    // filter message, not a value of one field — which is why fields above 15
    // (VR180 26, HDR 25, Location 23) need two-byte varint tags.
    SearchFilterGroup(SearchFilterKind.features, 'Features', [
      SearchFilterOption('Live', 8),
      SearchFilterOption('4K', 14),
      SearchFilterOption('HD', 4),
      SearchFilterOption('Subtitles/CC', 5),
      SearchFilterOption('Creative Commons', 6),
      SearchFilterOption('360°', 15),
      SearchFilterOption('VR180', 26),
      SearchFilterOption('3D', 7),
      SearchFilterOption('HDR', 25),
      SearchFilterOption('Location', 23),
    ]),
    SearchFilterGroup(SearchFilterKind.sort, 'Prioritize', [
      SearchFilterOption('Relevance', null),
      SearchFilterOption('Popularity', 3),
    ]),
  ];

  /// Encodes the chosen filters into the `sp` parameter, or null when nothing
  /// is chosen — the "All" search, which must send no `params` at all so that
  /// channels, playlists and Shorts come back mixed in with videos.
  ///
  /// The wire format is a two-field protobuf: field 1 is the sort order, and
  /// field 2 is a nested message holding upload date (1), type (2), duration
  /// (3) and one boolean field per feature. Written out by hand with real
  /// varints rather than pulling in a protobuf runtime; fields are emitted in
  /// ascending order, which is what YouTube's own strings do.
  static String? encodeParams({
    int? sortBy,
    int? uploadDate,
    int? type,
    int? duration,
    Iterable<int> features = const [],
  }) {
    final fields = <int, int>{
      1: ?uploadDate,
      2: ?type,
      3: ?duration,
      for (final f in features)
        if (f > 3) f: 1,
    };
    final nested = <int>[
      for (final field in fields.keys.toList()..sort())
        ..._protoField(field, fields[field]!),
    ];
    final message = <int>[
      if (sortBy != null) ..._protoField(1, sortBy),
      if (nested.isNotEmpty) ...[0x12, ..._varint(nested.length), ...nested],
    ];
    return message.isEmpty ? null : base64.encode(message);
  }

  static List<int> _varint(int value) {
    final out = <int>[];
    var v = value;
    while (v >= 0x80) {
      out.add((v & 0x7F) | 0x80);
      v >>= 7;
    }
    out.add(v);
    return out;
  }

  /// A varint field: tag `(field << 3) | 0`, then the value.
  static List<int> _protoField(int field, int value) => [
    ..._varint(field << 3),
    ..._varint(value),
  ];

  /// Encodes filters for the FEED's callers, which always want videos only.
  ///
  /// Defaults the type to videos, which is what every candidate-generation
  /// query wants; the search screen uses [encodeParams] instead, where "no
  /// type" is a real choice.
  static String buildParams({
    int? sortBy,
    int? uploadDate,
    int? type,
    int? duration,
  }) =>
      encodeParams(
        sortBy: sortBy,
        uploadDate: uploadDate,
        type: type ?? 1,
        duration: duration,
      )!;

  /// The `Accept-Language` header for a language and region.
  ///
  /// It was hardcoded to en-US while the body asked for the configured `hl`,
  /// which is two different answers to one question. `hi` + `IN` reads
  /// `hi-IN,hi;q=0.9,en;q=0.8`: English kept as a last resort, because a
  /// missing translation is better shown in English than not at all.
  static String acceptLanguageFor(String hl, String gl) {
    final lang = hl.trim().isEmpty ? 'en' : hl.trim();
    final base = lang.split(RegExp('[-_]')).first.toLowerCase();
    final region = gl.trim().toUpperCase();
    final primary = lang.contains(RegExp('[-_]'))
        ? lang.replaceAll('_', '-')
        : (region.isEmpty ? base : '$base-$region');
    final parts = <String>[
      primary,
      if (primary != base) '$base;q=0.9',
      if (base != 'en') 'en;q=0.8',
    ];
    return parts.join(',');
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Accept-Language': acceptLanguageFor(_hl, _gl),
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'Origin': 'https://www.youtube.com',
  };

  void close() => _http.close();

  /// Query completions for the search box.
  ///
  /// Replaces `youtube_explode_dart`'s `getQuerySuggestions`, which fails the
  /// same way its search does — the extension-on-dynamic `getT` bug — and the
  /// caller swallowed the error, so the suggestion list was silently always
  /// empty.
  ///
  /// This is the endpoint the site itself uses. `client=firefox` asks for
  /// plain JSON: `["kannada", ["kannada song", …]]`. The default response is
  /// JSONP wrapped in `window.google.ac.h(...)`, which would have to be
  /// unwrapped by hand.
  Future<List<String>> suggestions(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    final uri = Uri.https('suggestqueries.google.com', '/complete/search', {
      'client': 'firefox',
      'ds': 'yt', // YouTube's corpus, not the web's
      'q': trimmed,
    });

    try {
      final response = await _http.get(uri).timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) return const [];

      final decoded = jsonDecode(response.body);
      if (decoded is! List || decoded.length < 2) return const [];
      final entries = decoded[1];
      if (entries is! List) return const [];

      return entries.whereType<String>().take(10).toList();
    } catch (_) {
      // A dead suggestion service must not stop anyone searching.
      return const [];
    }
  }

  /// One page of the search SCREEN: mixed results in YouTube's order, the
  /// chip bar, a spelling correction and the token for the next page.
  ///
  /// [params] null is the "All" search and sends no `params` at all — the
  /// feed's [search] defaults to videos-only, which is exactly why channels,
  /// playlists and Shorts never appeared on the screen and the Channel filter
  /// always came back empty. [safetyMode] asks for YouTube's Restricted Mode
  /// (`context.user.enableSafetyMode`), which Kids mode turns on.
  Future<SearchBatch> searchPage(
    String query, {
    String? params,
    bool safetyMode = false,
  }) async {
    return _postAndParse({
      'context': _contextWith(safetyMode: safetyMode),
      'query': query,
      'params': ?params,
    });
  }

  /// The next page, or a chip's fresh first page — both are a continuation
  /// token POSTed in place of the query. A next page arrives as
  /// `appendContinuationItemsAction`, a chip as `reloadContinuationItemsCommand`
  /// carrying a whole new results renderer; [parseSearchResponse] reads both.
  Future<SearchBatch> searchContinuation(
    String token, {
    bool safetyMode = false,
  }) async {
    return _postAndParse({
      'context': _contextWith(safetyMode: safetyMode),
      'continuation': token,
    });
  }

  /// POSTs a search and parses the answer OFF the UI thread.
  ///
  /// A search page is 0.5-1 MB of JSON. Decoding it and walking every
  /// renderer on the UI isolate cost seconds on a phone — the request itself
  /// answers in about one — and froze the skeleton's shimmer while it ran.
  /// The response bytes are handed to a short-lived isolate instead.
  Future<SearchBatch> _postAndParse(Map<String, dynamic> body) async {
    final watch = Stopwatch()..start();
    final response = await _http
        .post(_endpoint, headers: _headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw SearchException('YouTube returned HTTP ${response.statusCode}');
    }
    final fetched = watch.elapsedMilliseconds;
    final bytes = response.bodyBytes;
    // No isolates on the web preview, which never reaches this client anyway.
    final batch = kIsWeb
        ? parseSearchResponse(jsonDecode(utf8.decode(bytes)))
        : await Isolate.run(
            () => parseSearchResponse(jsonDecode(utf8.decode(bytes))),
          );
    debugPrint(
      'AI BIT search: ${bytes.length ~/ 1024}KB fetched in ${fetched}ms, '
      'parsed by ${watch.elapsedMilliseconds}ms, ${batch.items.length} items',
    );
    return batch;
  }

  Map<String, dynamic> _contextWith({required bool safetyMode}) => {
    ..._context,
    if (safetyMode) 'user': {'enableSafetyMode': true},
  };

  Future<dynamic> _post(Map<String, dynamic> body) async {
    final response = await _http
        .post(_endpoint, headers: _headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw SearchException('YouTube returned HTTP ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  /// Reads a search response — first page, next page or chip reload — into
  /// a [SearchBatch]. Pure, so every shape has a test.
  ///
  /// Items are read IN ORDER from each `itemSectionRenderer`, because the
  /// order is YouTube's layout: a channel card sits where its relevance puts
  /// it, a Shorts shelf between the third and fourth video. The old parser
  /// collected `videoRenderer`s from anywhere, which also pulled the videos
  /// out of shelves and flattened everything into one list.
  static SearchBatch parseSearchResponse(dynamic json) {
    final items = <SearchItem>[];
    final seen = <String>{};
    String? token;
    SearchCorrection? correction;
    final skipped = <String>[];

    void add(SearchItem item) {
      if (seen.add(item.key)) items.add(item);
    }

    void walk(dynamic node) {
      if (node is Map) {
        final section = node['itemSectionRenderer'];
        if (section is Map) {
          final contents = section['contents'];
          if (contents is List) {
            for (final entry in contents) {
              if (entry is! Map) continue;
              final fix = _correctionFrom(entry);
              if (fix != null) {
                correction ??= fix;
                continue;
              }
              try {
                final item = _itemFrom(entry);
                if (item != null) add(item);
              } catch (e) {
                // One malformed entry must not cost the page. Counted rather
                // than swallowed — the screen logs it and check_search prints
                // it — because a renderer that always throws is a parser that
                // needs updating, and a silent catch is how this codebase has
                // hidden dead features before.
                skipped.add('${entry.keys.first}: $e');
              }
            }
          }
          return;
        }
        final cont = node['continuationItemRenderer'];
        if (cont is Map) {
          final t = _continuationToken(cont);
          if (t != null) token = t;
          return;
        }
        for (final entry in node.entries) {
          // The sidebar carries its own sections that are not results.
          if (entry.key == 'secondaryContents') continue;
          walk(entry.value);
        }
      } else if (node is List) {
        for (final v in node) {
          walk(v);
        }
      }
    }

    walk(json);
    return SearchBatch(
      items: items,
      continuation: token,
      chips: _chipsFrom(json),
      correction: correction,
      skipped: skipped,
    );
  }

  static String? _continuationToken(Map cont) {
    final found = <Map<String, dynamic>>[];
    _collectKey(cont, 'continuationCommand', found);
    for (final c in found) {
      final t = c['token'];
      if (t is String && t.isNotEmpty) return t;
    }
    return null;
  }

  /// The chip bar under the search box: All, Shorts, Videos, Unwatched,
  /// Recently uploaded, Live — the set varies per query. "All" carries no
  /// token; it is the plain query.
  static List<SearchChip> _chipsFrom(dynamic json) {
    final raw = <Map<String, dynamic>>[];
    _collectKey(json, 'chipCloudChipRenderer', raw);
    final out = <SearchChip>[];
    final labels = <String>{};
    for (final c in raw) {
      final label = _text(c['text']);
      if (label.isEmpty || !labels.add(label)) continue;
      final found = <Map<String, dynamic>>[];
      _collectKey(c['navigationEndpoint'], 'continuationCommand', found);
      final token = found.isEmpty ? null : found.first['token'] as String?;
      out.add(SearchChip(
        label: label,
        token: token,
        selected: c['isSelected'] == true,
      ));
    }
    return out;
  }

  static SearchCorrection? _correctionFrom(Map entry) {
    final showing = entry['showingResultsForRenderer'];
    if (showing is Map) {
      final corrected = _endpointQuery(showing['correctedQueryEndpoint']) ??
          _text(showing['correctedQuery']);
      final original = _endpointQuery(showing['originalQueryEndpoint']) ??
          _text(showing['originalQuery']);
      if (corrected.isEmpty) return null;
      return SearchCorrection(
        corrected: corrected,
        original: original.isEmpty ? null : original,
        autoCorrected: true,
        originalParams: _endpointParams(showing['originalQueryEndpoint']),
      );
    }
    final didYouMean = entry['didYouMeanRenderer'];
    if (didYouMean is Map) {
      final corrected = _endpointQuery(didYouMean['correctedQueryEndpoint']) ??
          _text(didYouMean['correctedQuery']);
      if (corrected.isEmpty) return null;
      return SearchCorrection(corrected: corrected, autoCorrected: false);
    }
    return null;
  }

  static String? _endpointQuery(dynamic endpoint) {
    final q = ((endpoint as Map?)?['searchEndpoint'] as Map?)?['query'];
    return q is String && q.isNotEmpty ? q : null;
  }

  /// "Search instead for" carries a `params` (URL-encoded in the response)
  /// telling YouTube not to correct the query again.
  static String? _endpointParams(dynamic endpoint) {
    final p = ((endpoint as Map?)?['searchEndpoint'] as Map?)?['params'];
    if (p is! String || p.isEmpty) return null;
    try {
      return Uri.decodeComponent(p);
    } catch (_) {
      return p;
    }
  }

  static SearchItem? _itemFrom(Map entry) {
    final video = entry['videoRenderer'] ?? entry['movieRenderer'];
    if (video is Map<String, dynamic>) {
      final brief = _toBrief(video);
      return brief == null ? null : SearchVideoItem(brief);
    }
    final channel = entry['channelRenderer'];
    if (channel is Map<String, dynamic>) return _channelFrom(channel);
    final lockup = entry['lockupViewModel'];
    if (lockup is Map<String, dynamic>) return _playlistFrom(lockup);
    final grid = entry['gridShelfViewModel'] ?? entry['reelShelfRenderer'];
    if (grid is Map<String, dynamic>) {
      final shorts = shortsFromLockups(grid);
      if (shorts.isEmpty) return null;
      final header = <Map<String, dynamic>>[];
      _collectKey(grid['header'], 'sectionHeaderViewModel', header);
      final title = header.isNotEmpty
          ? _text(header.first['headline'])
          : _text(grid['title']);
      return SearchShortsShelf(title: title, shorts: shorts);
    }
    final shelf = entry['shelfRenderer'];
    if (shelf is Map<String, dynamic>) {
      final renderers = <Map<String, dynamic>>[];
      _collectVideoRenderers(shelf['content'], renderers);
      final videos = <VideoBrief>[];
      final ids = <String>{};
      for (final r in renderers) {
        final b = _toBrief(r);
        if (b != null && ids.add(b.id)) videos.add(b);
      }
      if (videos.isNotEmpty) {
        return SearchShelf(title: _text(shelf['title']), videos: videos);
      }
      // A shelf of Shorts in the older renderer shape.
      final shorts = shortsFromLockups(shelf);
      if (shorts.isNotEmpty) {
        return SearchShortsShelf(title: _text(shelf['title']), shorts: shorts);
      }
      return null;
    }
    final short = entry['shortsLockupViewModel'];
    if (short is Map<String, dynamic>) {
      final shorts = shortsFromLockups(entry);
      return shorts.isEmpty
          ? null
          : SearchShortsShelf(title: '', shorts: shorts);
    }
    // horizontalCardListRenderer of macroMarkersListItemRenderer is a video's
    // chapter list, and everything else is ads, prompts or promos.
    return null;
  }

  static SearchChannelItem? _channelFrom(Map<String, dynamic> c) {
    final id = c['channelId'];
    if (id is! String || id.isEmpty) return null;
    final title = _text(c['title']);
    if (title.isEmpty) return null;
    final labels = channelLabels(
      _text(c['subscriberCountText']),
      _text(c['videoCountText']),
    );
    return SearchChannelItem(
      id: id,
      title: title,
      avatarUrl: _avatar(c['thumbnail']),
      handle: labels.handle,
      subscriberLabel: labels.subscribers,
    );
  }

  /// Which of a channel result's two labels is the @handle and which the
  /// subscriber count.
  ///
  /// The field names lie: measured November 2026, `videoCountText` holds
  /// "21.5M subscribers" and `subscriberCountText` holds "@mkbhd". Older
  /// responses had them the right way round, with a video count where the
  /// subscribers now are — so the handle is identified by its `@`, and a
  /// "N videos" label is never mistaken for a subscriber count.
  static ({String? handle, String? subscribers}) channelLabels(
    String subscriberCountText,
    String videoCountText,
  ) {
    final a = subscriberCountText.trim();
    final b = videoCountText.trim();
    if (a.startsWith('@')) {
      return (handle: a, subscribers: b.isEmpty ? null : b);
    }
    if (b.startsWith('@')) {
      return (handle: b, subscribers: a.isEmpty ? null : a);
    }
    return (handle: null, subscribers: a.isEmpty ? null : a);
  }

  static SearchPlaylistItem? _playlistFrom(Map<String, dynamic> l) {
    final id = l['contentId'];
    if (id is! String || id.isEmpty) return null;
    final type = l['contentType'];
    if (type != 'LOCKUP_CONTENT_TYPE_PLAYLIST' &&
        type != 'LOCKUP_CONTENT_TYPE_ALBUM' &&
        type != 'LOCKUP_CONTENT_TYPE_PODCAST') {
      return null;
    }
    final meta = <Map<String, dynamic>>[];
    _collectKey(l, 'lockupMetadataViewModel', meta);
    final title = meta.isEmpty ? '' : _text(meta.first['title']);
    if (title.isEmpty) return null;

    int? count;
    String? badge;
    final badges = <Map<String, dynamic>>[];
    _collectKey(l, 'thumbnailBadgeViewModel', badges);
    for (final b in badges) {
      final text = _text(b['text']);
      badge ??= text.isEmpty ? null : text;
      count ??= videoCountFromBadge(text);
    }

    // The byline is the first metadata row: "Channel • Playlist".
    String? byline;
    final rows = <Map<String, dynamic>>[];
    _collectKey(l['metadata'], 'contentMetadataViewModel', rows);
    final rowList = rows.isEmpty ? null : rows.first['metadataRows'];
    if (rowList is List && rowList.isNotEmpty && rowList.first is Map) {
      final parts = (rowList.first as Map)['metadataParts'];
      if (parts is List) {
        final texts = [
          for (final p in parts)
            if (p is Map) _text(p['text']),
        ].where((t) => t.isNotEmpty).toList();
        if (texts.isNotEmpty) byline = texts.join(' • ');
      }
    }

    final watch = <Map<String, dynamic>>[];
    _collectKey(l, 'watchEndpoint', watch);
    final firstVideo = watch.isEmpty ? null : watch.first['videoId'] as String?;

    return SearchPlaylistItem(
      playlist: PlaylistBrief(
        id: id,
        title: title,
        videoCount: count,
        thumbnailUrl: _largestImage(l['contentImage']),
      ),
      byline: byline,
      badge: badge,
      firstVideoId: firstVideo,
    );
  }

  static String? _largestImage(dynamic node) {
    String? best;
    var bestWidth = -1;
    void walk(dynamic n) {
      if (n is Map) {
        final list = n['sources'] ?? n['thumbnails'];
        if (list is List) {
          for (final s in list) {
            final url = (s as Map?)?['url'];
            final w = (s?['width'] as num?)?.toInt() ?? 0;
            if (url is String && url.isNotEmpty && w > bestWidth) {
              best = _https(url);
              bestWidth = w;
            }
          }
          if (best != null) return;
        }
        for (final v in n.values) {
          if (best != null) return;
          walk(v);
        }
      } else if (n is List) {
        for (final v in n) {
          if (best != null) return;
          walk(v);
        }
      }
    }

    walk(node);
    return best;
  }

  Future<List<VideoBrief>> search(String query, {String? params}) async {
    final response = await _http
        .post(
          _endpoint,
          headers: _headers,
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
    final json = await _post({'context': _context, 'query': query});
    return shortsFromLockups(json);
  }

  /// Every `shortsLockupViewModel` under [json], in order, as Shorts.
  static List<VideoBrief> shortsFromLockups(dynamic json) {
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
  ///
  /// Every `url` key used to be collected and the last one taken on the
  /// assumption it was the largest image. It is not: the renderer also carries
  /// the channel's own address, so results came back as `/@SomeChannel` — a
  /// path, not a picture. Every request for it failed and every card fell back
  /// to a coloured initial, which is why the feed showed letters.
  ///
  /// Only real image hosts are accepted now, and the widest is preferred.
  static String? _avatar(dynamic node) {
    final candidates = <MapEntry<int, String>>[];

    void walk(dynamic n) {
      if (n is Map) {
        final url = n['url'];
        if (url is String && _isImageUrl(url)) {
          candidates.add(
            MapEntry((n['width'] as num?)?.toInt() ?? 0, _https(url)),
          );
        }
        for (final child in n.values) {
          walk(child);
        }
      } else if (n is List) {
        for (final child in n) {
          walk(child);
        }
      }
    }

    walk(node);
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.key.compareTo(a.key));
    return candidates.first.value;
  }

  static String _https(String url) =>
      url.startsWith('//') ? 'https:$url' : url;

  /// Google serves avatars from these hosts and nothing else does.
  static bool _isImageUrl(String url) {
    final full = _https(url);
    if (!full.startsWith('http')) return false;
    return full.contains('ggpht.com') ||
        full.contains('googleusercontent.com') ||
        full.contains('ytimg.com');
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
    // The newer view models (lockups, section headers) say `content`.
    final content = node['content'];
    if (content is String) return content;

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

enum SearchFilterKind { type, duration, uploadDate, features, sort }

/// A group in the search filter sheet.
///
/// Every group but Features is single-choice and has an "Any" option (value
/// null) to return to; Features is multi-select and "Any" means none ticked.
/// YouTube encodes combinations into a single protobuf `sp` value, and a
/// combined value cannot be built by concatenating the individual ones — that
/// is [YoutubeSearchClient.encodeParams]'s job.
class SearchFilterGroup {
  const SearchFilterGroup(this.kind, this.title, this.options);

  final SearchFilterKind kind;
  final String title;
  final List<SearchFilterOption> options;

  bool get multiSelect => kind == SearchFilterKind.features;
}

class SearchFilterOption {
  const SearchFilterOption(this.label, this.value);

  final String label;

  /// Protobuf value for this option (for Features, the field number); null
  /// means "no filter" — the default for that group.
  final int? value;
}

/// The search screen's chosen filters. Immutable; empty means "All".
class SearchFilters {
  const SearchFilters({
    this.type,
    this.duration,
    this.uploadDate,
    this.features = const {},
    this.sortBy,
  });

  static const none = SearchFilters();

  final int? type;
  final int? duration;
  final int? uploadDate;
  final Set<int> features;
  final int? sortBy;

  bool get isEmpty =>
      type == null &&
      duration == null &&
      uploadDate == null &&
      features.isEmpty &&
      sortBy == null;

  /// For the small badge on the overflow button.
  int get activeCount =>
      (type == null ? 0 : 1) +
      (duration == null ? 0 : 1) +
      (uploadDate == null ? 0 : 1) +
      features.length +
      (sortBy == null ? 0 : 1);

  /// The `sp` value, or null for none — see
  /// [YoutubeSearchClient.encodeParams].
  String? toParams() => YoutubeSearchClient.encodeParams(
    sortBy: sortBy,
    uploadDate: uploadDate,
    type: type,
    duration: duration,
    features: features,
  );

  int? valueFor(SearchFilterKind kind) => switch (kind) {
    SearchFilterKind.type => type,
    SearchFilterKind.duration => duration,
    SearchFilterKind.uploadDate => uploadDate,
    SearchFilterKind.sort => sortBy,
    SearchFilterKind.features => null,
  };

  bool isSelected(SearchFilterKind kind, int? value) =>
      kind == SearchFilterKind.features
          ? (value == null ? features.isEmpty : features.contains(value))
          : valueFor(kind) == value;

  /// The filters after tapping [value] in a [kind] group: a single-choice
  /// group switches to it (null returns to Any); Features toggles it, and
  /// null clears them all.
  SearchFilters toggled(SearchFilterKind kind, int? value) {
    switch (kind) {
      case SearchFilterKind.features:
        final next = value == null
            ? <int>{}
            : ({...features}..toggle(value));
        return _copy(features: next);
      case SearchFilterKind.type:
        return _copy(type: () => value);
      case SearchFilterKind.duration:
        return _copy(duration: () => value);
      case SearchFilterKind.uploadDate:
        return _copy(uploadDate: () => value);
      case SearchFilterKind.sort:
        return _copy(sortBy: () => value);
    }
  }

  SearchFilters _copy({
    int? Function()? type,
    int? Function()? duration,
    int? Function()? uploadDate,
    Set<int>? features,
    int? Function()? sortBy,
  }) =>
      SearchFilters(
        type: type == null ? this.type : type(),
        duration: duration == null ? this.duration : duration(),
        uploadDate: uploadDate == null ? this.uploadDate : uploadDate(),
        features: features ?? this.features,
        sortBy: sortBy == null ? this.sortBy : sortBy(),
      );

  @override
  bool operator ==(Object other) =>
      other is SearchFilters &&
      other.type == type &&
      other.duration == duration &&
      other.uploadDate == uploadDate &&
      other.sortBy == sortBy &&
      other.features.length == features.length &&
      other.features.containsAll(features);

  @override
  int get hashCode => Object.hash(
    type,
    duration,
    uploadDate,
    sortBy,
    Object.hashAllUnordered(features),
  );
}

extension on Set<int> {
  void toggle(int value) {
    if (!remove(value)) add(value);
  }
}

/// One entry in the search results, in YouTube's order.
sealed class SearchItem {
  const SearchItem();

  /// Identity for de-duplicating across pages: YouTube repeats the odd result
  /// on the next page, and a repeated card reads as a bug.
  String get key;
}

class SearchVideoItem extends SearchItem {
  const SearchVideoItem(this.video);
  final VideoBrief video;
  @override
  String get key => 'v:${video.id}';
}

class SearchChannelItem extends SearchItem {
  const SearchChannelItem({
    required this.id,
    required this.title,
    this.avatarUrl,
    this.handle,
    this.subscriberLabel,
  });

  final String id;
  final String title;
  final String? avatarUrl;

  /// "@mkbhd", when the response carries one.
  final String? handle;

  /// "21.5M subscribers", as YouTube rendered it.
  final String? subscriberLabel;

  ChannelInfo get info => ChannelInfo(
    id: id,
    title: title,
    avatarUrl: avatarUrl,
    subscriberLabel: subscriberLabel,
  );

  @override
  String get key => 'c:$id';
}

class SearchPlaylistItem extends SearchItem {
  const SearchPlaylistItem({
    required this.playlist,
    this.byline,
    this.badge,
    this.firstVideoId,
  });

  final PlaylistBrief playlist;

  /// "Channel • Playlist", the lockup's first metadata row.
  final String? byline;

  /// The thumbnail badge's own text — "9 videos", or "Mix".
  final String? badge;

  /// The first video's id. A Mix (`RD…`) cannot be browsed as a playlist —
  /// it is generated per viewer — so tapping one plays this instead.
  final String? firstVideoId;

  bool get isMix => playlist.id.startsWith('RD');

  @override
  String get key => 'p:${playlist.id}';
}

/// A row of Shorts, drawn as a horizontal shelf of 9:16 tiles.
class SearchShortsShelf extends SearchItem {
  const SearchShortsShelf({required this.title, required this.shorts});
  final String title;
  final List<VideoBrief> shorts;
  @override
  String get key => 'shorts:${shorts.first.id}';
}

/// A titled shelf of videos — "Latest from Marques Brownlee".
class SearchShelf extends SearchItem {
  const SearchShelf({required this.title, required this.videos});
  final String title;
  final List<VideoBrief> videos;
  @override
  String get key => 'shelf:$title:${videos.first.id}';
}

/// One chip in the bar above the results. [token] null is "All" — the plain
/// query; every other chip is a continuation that returns a fresh first page.
class SearchChip {
  const SearchChip({required this.label, this.token, this.selected = false});
  final String label;
  final String? token;
  final bool selected;

  /// Whether this is the chip the app filters locally against watch history,
  /// since an account-less request has no history for YouTube to use.
  bool get isUnwatched => label.trim().toLowerCase() == 'unwatched';
}

/// "Showing results for X / Search instead for Y" (auto-corrected), or "Did
/// you mean X" (not).
class SearchCorrection {
  const SearchCorrection({
    required this.corrected,
    required this.autoCorrected,
    this.original,
    this.originalParams,
  });

  final String corrected;
  final String? original;
  final bool autoCorrected;

  /// The `params` YouTube attaches to "Search instead for", which tells it not
  /// to correct the query a second time.
  final String? originalParams;
}

/// One page of the search screen.
class SearchBatch {
  const SearchBatch({
    this.items = const [],
    this.continuation,
    this.chips = const [],
    this.correction,
    this.skipped = const [],
  });

  final List<SearchItem> items;

  /// Token for the next page; null when this is the last one.
  final String? continuation;
  final List<SearchChip> chips;
  final SearchCorrection? correction;

  /// Entries the parser could not read, with why — for logging.
  final List<String> skipped;
}

/// Adds a kid-safe term to a query typed in Kids mode, unless it has one.
///
/// Kids mode curates the home feed from a fixed list of kid topics; a search
/// box that answered anything at all would be the way out of that curation,
/// so a search there asks for "`<query>` for kids". A query that already names
/// a kid-ish subject — "peppa pig cartoon", "nursery rhymes" — is left alone,
/// since appending to it only makes the results worse.
String kidsSafeQuery(String query) {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return trimmed;
  final words = trimmed.toLowerCase().split(RegExp(r'[^a-z0-9]+'));
  const kidTerms = {
    'kid',
    'kids',
    'child',
    'children',
    'childrens',
    'nursery',
    'rhyme',
    'rhymes',
    'toddler',
    'toddlers',
    'preschool',
    'baby',
    'babies',
    'cartoon',
    'cartoons',
  };
  if (words.any(kidTerms.contains)) return trimmed;
  return '$trimmed for kids';
}

/// What Kids mode keeps from a page of results: videos, Shorts and shelves.
///
/// Channels and playlists are dropped because they are doors: a channel page
/// and a playlist are not searched with the kid-safe term or Restricted Mode,
/// so opening one leaves the curated content entirely.
List<SearchItem> kidsSafeItems(List<SearchItem> items) => [
  for (final item in items)
    if (item is SearchVideoItem ||
        item is SearchShortsShelf ||
        item is SearchShelf)
      item,
];

/// Lays a page of results out the way YouTube's PHONE app does.
///
/// The screen asks the WEB client, whose answer is the desktop layout: for a
/// query like "how to make pasta" that leads with two Shorts shelves before
/// any video, and carries five Shorts shelves in fourteen videos. The ANDROID
/// client — what the YouTube app itself asks — answers the same query with
/// videos first and a single Shorts shelf after the first to third result
/// (measured side by side, November 2026). Its response is a 3-6 MB Litho
/// tree that cannot be parsed reasonably, so the app's layout is rebuilt here
/// from the web answer instead: every Shorts shelf on the page is merged into
/// ONE "Shorts" shelf, placed after the [firstPage] ? 2nd : 3rd result.
///
/// A page that is nothing but Shorts — the Shorts chip — is left as it is.
/// Pure, and tested.
List<SearchItem> phoneSearchLayout(
  List<SearchItem> items, {
  required bool firstPage,
}) {
  final shelves = items.whereType<SearchShortsShelf>().toList();
  if (shelves.length == items.length) return items;
  if (shelves.isEmpty) return items;
  final rest = [
    for (final item in items)
      if (item is! SearchShortsShelf) item,
  ];
  final ids = <String>{};
  final shorts = [
    for (final shelf in shelves)
      for (final s in shelf.shorts)
        if (ids.add(s.id)) s,
  ];
  final at = (firstPage ? 2 : 3).clamp(0, rest.length);
  return [
    ...rest.sublist(0, at),
    SearchShortsShelf(title: 'Shorts', shorts: shorts),
    ...rest.sublist(at),
  ];
}

class SearchException implements Exception {
  SearchException(this.message);
  final String message;

  @override
  String toString() => 'Search failed: $message';
}
