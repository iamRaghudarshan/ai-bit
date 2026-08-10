import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import 'models.dart';
import 'player_client.dart';
import 'preview_data.dart';
import 'search_client.dart';

/// Wraps `youtube_explode_dart` and hides its client-selection quirks behind a
/// small task-shaped API.
///
/// Streams are resolved straight from YouTube's player endpoint, which is what
/// makes playback ad-free: we never load the web player, so there is no ad
/// break to serve. The trade-off is that YouTube changes these endpoints
/// occasionally — [resolve] therefore walks a fallback chain of API clients
/// instead of trusting a single one.
class YtRepository {
  YtRepository()
    : _yt = yt.YoutubeExplode(),
      _search = YoutubeSearchClient(),
      _player = YoutubePlayerClient();

  final yt.YoutubeExplode _yt;
  final YoutubeSearchClient _search;
  final YoutubePlayerClient _player;

  /// Signed CDN URLs stay valid for roughly six hours; expire ours well before
  /// that so a long-lived app never hands a dead URL to the player.
  static const _streamTtl = Duration(hours: 2);

  final _streamCache = <String, ({PlaybackSources sources, DateTime at})>{};
  final _detailCache = <String, yt.Video>{};

  /// True in a browser build. `youtube_explode_dart` does not survive dart2js
  /// compilation, so the web target serves sample rows purely so the interface
  /// can be reviewed. Never true on iOS or Android.
  static bool get isPreview => kIsWeb;

  List<VideoBrief> _previewRows(int refreshToken) {
    final rows = [...previewVideos];
    if (refreshToken > 0) {
      // Make pull-to-refresh visibly do something.
      final shift = refreshToken % rows.length;
      return [...rows.sublist(shift), ...rows.sublist(0, shift)];
    }
    return rows;
  }

  /// Broad, evergreen topics used to fill the home feed before there is any
  /// watch history to personalise against.
  static const _coldStartTopics = [
    'music',
    'technology',
    'documentary',
    'podcast',
    'gaming',
    'news today',
    'cooking',
    'travel',
    'science explained',
    'football highlights',
  ];

  void dispose() {
    _yt.close();
    _search.close();
    _player.close();
  }

  // ------------------------------------------------------------------ feed

  /// Home feed. Personalised from watch history when there is any, otherwise
  /// a rotating slice of popular topics.
  ///
  /// [refreshToken] shifts the topic window so pull-to-refresh returns
  /// something new rather than the same rows.
  Future<List<VideoBrief>> homeFeed({
    List<String> channelIds = const [],
    int refreshToken = 0,
  }) async {
    if (isPreview) return _previewRows(refreshToken);

    final tasks = <Future<List<VideoBrief>>>[
      for (final id in channelIds.take(3)) _safe(() => channelUploads(id, limit: 8)),
    ];

    // Always mix in a couple of topic rows so the feed does not collapse into
    // the same three channels once history builds up.
    final topics = _rotate(_coldStartTopics, refreshToken);
    final topicCount = channelIds.isEmpty ? 4 : 2;
    tasks.addAll(
      topics.take(topicCount).map((t) => _safe(() => search(t, sortByViews: true))),
    );

    final results = await Future.wait(tasks);
    return _interleave(results);
  }

  /// Most-viewed videos across a rotating topic — the closest thing to a
  /// "Trending" tab available without the official Data API.
  Future<List<VideoBrief>> trending({int refreshToken = 0}) =>
      search(_rotate(_coldStartTopics, refreshToken).first, sortByViews: true);

  // ---------------------------------------------------------------- search

  Future<List<VideoBrief>> search(String query, {bool sortByViews = false}) async {
    if (isPreview) {
      // Only ever real matches against the sample set. Returning everything on
      // a miss made search look like it was ignoring the query.
      final needle = query.toLowerCase();
      return previewVideos
          .where(
            (v) =>
                v.title.toLowerCase().contains(needle) ||
                v.author.toLowerCase().contains(needle),
          )
          .toList();
    }

    // Deliberately not _yt.search.search — see YoutubeSearchClient for why the
    // package's own parser cannot read YouTube's current search response.
    return _search.search(
      query,
      params: sortByViews
          ? YoutubeSearchClient.filterByViewCount
          : YoutubeSearchClient.filterVideosOnly,
    );
  }

  Future<List<String>> suggestions(String query) async {
    if (query.trim().isEmpty) return const [];
    if (isPreview) {
      final needle = query.toLowerCase();
      return previewVideos
          .where((v) => v.title.toLowerCase().contains(needle))
          .map((v) => v.title)
          .take(6)
          .toList();
    }
    try {
      return await _yt.search.getQuerySuggestions(query);
    } catch (_) {
      return const [];
    }
  }

  // --------------------------------------------------------------- details

  Future<yt.Video> videoDetails(String videoId) async {
    final cached = _detailCache[videoId];
    if (cached != null) return cached;
    final video = await _yt.videos.get(videoId);
    _detailCache[videoId] = video;
    return video;
  }

  /// The "Up next" list under the player. Needs the full [yt.Video] because
  /// the related-video token only exists on the watch page.
  Future<List<VideoBrief>> related(yt.Video video) async {
    try {
      final list = await _yt.videos.getRelatedVideos(video);
      if (list == null) return const [];
      return list.map(VideoBrief.fromYt).toList();
    } catch (_) {
      // Related videos are a nice-to-have; fall back to same-channel uploads.
      return _safe(() => channelUploads(video.channelId.value, limit: 12));
    }
  }

  Future<List<VideoBrief>> channelUploads(String channelId, {int limit = 20}) async {
    final videos = await _yt.channels.getUploads(channelId).take(limit).toList();
    return videos.map(VideoBrief.fromYt).toList();
  }

  Future<({String title, String logoUrl})> channelInfo(String channelId) async {
    final channel = await _yt.channels.get(channelId);
    return (title: channel.title, logoUrl: channel.logoUrl);
  }

  Future<List<VideoBrief>> remotePlaylist(String playlistId, {int limit = 100}) async {
    final videos = await _yt.playlists.getVideos(playlistId).take(limit).toList();
    return videos.map(VideoBrief.fromYt).toList();
  }

  // --------------------------------------------------------------- streams

  /// Accepts a bare id, a `youtu.be/…` link, or a full watch URL.
  static String? parseVideoId(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    return yt.VideoId.parseVideoId(trimmed) ??
        (RegExp(r'^[\w-]{11}$').hasMatch(trimmed) ? trimmed : null);
  }

  /// Resolves playable stream URLs for [videoId].
  ///
  /// Preference order, and why:
  ///
  ///   1. **HLS ladder** from [YoutubePlayerClient]. Adaptive, muxed, and goes
  ///      to 2160p for on-demand video and 1080p for live. It is also the only
  ///      thing that plays a live stream at all.
  ///   2. **Progressive muxed MP4**, capped by YouTube at 360p. Only reached
  ///      when no ladder is offered.
  ///   3. **Audio only**, rather than failing outright.
  ///
  /// An earlier version went straight to (2) because `youtube_explode_dart`
  /// never surfaces `hlsManifestUrl`, which made 360p look like a hard ceiling.
  /// It was not.
  ///
  /// Re-check the ordering with `dart run tool/probe_clients.dart` if playback
  /// quality or reliability ever regresses.
  Future<PlaybackSources> resolve(String videoId, {bool audioOnly = false}) async {
    final key = '$videoId:$audioOnly';
    final cached = _streamCache[key];
    if (cached != null && DateTime.now().difference(cached.at) < _streamTtl) {
      return cached.sources;
    }

    // Ask YouTube's player endpoint first. It is the only source of the HLS
    // ladder, which is both the way to get above 360p and the only way to play
    // a live stream at all.
    try {
      final streams = await _player.fetch(videoId);
      if (streams != null) {
        if (audioOnly && streams.audioUrl != null) {
          return _cache(key, PlaybackSources(
            url: streams.audioUrl!,
            qualities: const {},
            audioOnlyUrl: streams.audioUrl,
          ));
        }
        if (streams.hlsUrl != null) {
          return _cache(key, PlaybackSources(
            url: streams.hlsUrl!,
            // Quality is chosen inside the ladder; better_player reads the
            // variants off the manifest and offers them natively.
            qualities: const {},
            audioOnlyUrl: streams.audioUrl,
            isHls: true,
            isLive: streams.isLive,
          ));
        }
        if (streams.muxedUrl != null) {
          return _cache(key, PlaybackSources(
            url: streams.muxedUrl!,
            qualities: const {},
            audioOnlyUrl: streams.audioUrl,
          ));
        }
      }
    } catch (e) {
      debugPrint('AI BIT: player endpoint failed for $videoId — $e');
    }

    Object? lastError;
    String? audioFallback;

    for (final client in _clientChain) {
      try {
        final manifest = await _yt.videos.streamsClient.getManifest(
          videoId,
          ytClients: [client],
        );
        final audioUrl = manifest.audioOnly.isEmpty
            ? null
            : manifest.audioOnly.withHighestBitrate().url.toString();

        if (audioOnly) {
          if (audioUrl != null) {
            return _cache(key, PlaybackSources(
              url: audioUrl,
              qualities: const {},
              audioOnlyUrl: audioUrl,
            ));
          }
          continue;
        }

        final combined = _combinedSources(manifest, audioUrl);
        if (combined != null) return _cache(key, combined);

        // This client has audio but no combined video track. Remember it and
        // keep looking rather than silently dropping the user to audio.
        audioFallback ??= audioUrl;
      } catch (e) {
        lastError = e;
        debugPrint('AI BIT: stream client failed for $videoId — $e');
      }
    }

    if (audioFallback != null) {
      return _cache(key, PlaybackSources(
        url: audioFallback,
        qualities: const {},
        audioOnlyUrl: audioFallback,
        videoUnavailable: true,
      ));
    }
    throw StreamResolutionException(videoId, lastError);
  }

  // ------------------------------------------------------------- downloads

  /// Picks the rendition to save for offline playback.
  ///
  /// Same constraint as [resolve]: the file has to be self-contained, so video
  /// downloads use the combined stream (360p today) while audio downloads get
  /// the highest available bitrate.
  Future<DownloadTarget> downloadTarget(
    String videoId, {
    bool audioOnly = false,
  }) async {
    Object? lastError;
    for (final client in _clientChain) {
      try {
        final manifest = await _yt.videos.streamsClient.getManifest(
          videoId,
          ytClients: [client],
        );

        if (audioOnly) {
          if (manifest.audioOnly.isEmpty) continue;
          final best = manifest.audioOnly.withHighestBitrate();
          return DownloadTarget(
            handle: best,
            totalBytes: best.size.totalBytes,
            quality: 'Audio',
            fileExtension: best.container.name,
            audioOnly: true,
          );
        }

        final muxed = manifest.muxed.toList()
          ..sort(
            (a, b) => b.videoResolution.height.compareTo(a.videoResolution.height),
          );
        if (muxed.isEmpty) continue;
        return DownloadTarget(
          handle: muxed.first,
          totalBytes: muxed.first.size.totalBytes,
          quality: muxed.first.qualityLabel,
          fileExtension: muxed.first.container.name,
          audioOnly: false,
        );
      } catch (e) {
        lastError = e;
        debugPrint('AI BIT: download client failed for $videoId — $e');
      }
    }
    throw StreamResolutionException(videoId, lastError);
  }

  /// Opens the byte stream for [target]. The caller writes it to disk and
  /// tracks progress.
  Stream<List<int>> downloadBytes(DownloadTarget target) =>
      _yt.videos.streamsClient.get(target.handle as yt.StreamInfo);

  PlaybackSources _cache(String key, PlaybackSources sources) {
    _streamCache[key] = (sources: sources, at: DateTime.now());
    return sources;
  }

  static final _clientChain = <yt.YoutubeApiClient>[
    yt.YoutubeApiClient.androidVr,
    yt.YoutubeApiClient.androidSdkless,
    // ignore: deprecated_member_use
    yt.YoutubeApiClient.android,
    yt.YoutubeApiClient.ios,
    yt.YoutubeApiClient.tv,
  ];

  /// Picks the best stream that carries video *and* audio, or null if this
  /// manifest has none.
  PlaybackSources? _combinedSources(yt.StreamManifest manifest, String? audioUrl) {
    // Adaptive HLS first when it is offered: the player handles the bitrate
    // ladder itself and it survives network changes far better than a fixed
    // progressive URL. YouTube rarely returns it for on-demand video today,
    // but live streams still do.
    final hls = manifest.hls.whereType<yt.HlsMuxedStreamInfo>().toList()
      ..sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));
    if (hls.isNotEmpty) {
      return PlaybackSources(
        url: hls.first.url.toString(),
        qualities: _qualityMap(hls.map((s) => (s.qualityLabel, s.url.toString()))),
        audioOnlyUrl: audioUrl,
        isHls: true,
      );
    }

    final muxed = manifest.muxed.toList()
      ..sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));
    if (muxed.isNotEmpty) {
      return PlaybackSources(
        url: muxed.first.url.toString(),
        qualities: _qualityMap(muxed.map((s) => (s.qualityLabel, s.url.toString()))),
        audioOnlyUrl: audioUrl,
      );
    }
    return null;
  }

  /// Collapses duplicate labels (`720p60` and `720p` both appear) keeping the
  /// first — the list is already sorted best-first.
  Map<String, String> _qualityMap(Iterable<(String, String)> entries) {
    final map = <String, String>{};
    for (final (label, url) in entries) {
      map.putIfAbsent(label, () => url);
    }
    return map;
  }

  // ---------------------------------------------------------------- helpers

  Future<List<VideoBrief>> _safe(Future<List<VideoBrief>> Function() task) async {
    try {
      return await task();
    } catch (e) {
      debugPrint('AI BIT: feed section failed — $e');
      return const [];
    }
  }

  static List<String> _rotate(List<String> source, int offset) {
    if (source.isEmpty) return source;
    final start = offset % source.length;
    return [...source.sublist(start), ...source.sublist(0, start)];
  }

  /// Round-robins the sections so no single channel or topic owns the top of
  /// the feed, dropping duplicates as it goes.
  static List<VideoBrief> _interleave(List<List<VideoBrief>> sections) {
    final out = <VideoBrief>[];
    final seen = <String>{};
    final longest = sections.fold(0, (m, s) => s.length > m ? s.length : m);
    for (var i = 0; i < longest; i++) {
      for (final section in sections) {
        if (i >= section.length) continue;
        final video = section[i];
        if (seen.add(video.id)) out.add(video);
      }
    }
    return out;
  }
}

class StreamResolutionException implements Exception {
  StreamResolutionException(this.videoId, this.cause);

  final String videoId;
  final Object? cause;

  @override
  String toString() =>
      'Could not find a playable stream for $videoId. '
      'YouTube may have changed its player, or the video is private, '
      'age-restricted or region-locked.';
}
