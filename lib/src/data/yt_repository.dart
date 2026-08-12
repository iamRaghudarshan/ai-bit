import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import '../core/format.dart';
import 'browse_client.dart';
import 'comments_client.dart';
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
      _player = YoutubePlayerClient(),
      _browse = YoutubeBrowseClient(),
      _comments = YoutubeCommentsClient();

  final yt.YoutubeExplode _yt;
  final YoutubeSearchClient _search;
  final YoutubePlayerClient _player;
  final YoutubeBrowseClient _browse;
  final YoutubeCommentsClient _comments;

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
    _browse.close();
    _comments.close();
  }

  // ------------------------------------------------------------------ feed

  /// Home feed. Personalised from watch history when there is any, otherwise
  /// a rotating slice of popular topics.
  ///
  /// [refreshToken] shifts the topic window so pull-to-refresh returns
  /// something new rather than the same rows.
  Future<List<VideoBrief>> homeFeed({
    List<String> channelIds = const [],
    List<String> searches = const [],
    int refreshToken = 0,
  }) async {
    if (isPreview) return _previewRows(refreshToken);

    // Pull-to-refresh has to change what the interest signals return, not just
    // the filler topic. Rotating both lists means a different search and a
    // different channel lead the feed each time, so refreshing on an
    // established history actually moves the page instead of rebuilding it.
    final rotatedSearches = _rotate(searches, refreshToken);
    final rotatedChannels = _rotate(channelIds, refreshToken);

    final tasks = <Future<List<VideoBrief>>>[
      // What you searched for is the strongest signal of what you want next,
      // and it is the only interest signal available without an account.
      for (final q in rotatedSearches.take(4)) _safe(() => search(q)),
      for (final id in rotatedChannels.take(3))
        _safe(() => channelUploads(id, limit: 8)),
    ];

    // Top up with popular topics so a fresh install is not empty and the feed
    // does not collapse into the same few channels once history builds up.
    final topics = _rotate(_coldStartTopics, refreshToken);
    final topicCount = (searches.isEmpty && channelIds.isEmpty) ? 4 : 1;
    tasks.addAll(
      topics.take(topicCount).map((t) => _safe(() => search(t, sortByViews: true))),
    );

    final results = await Future.wait(tasks);
    // Each source returns the same ordering every time, so take a different
    // window into it per refresh. Without this the same top result from each
    // search sat at the top of the feed no matter how often you pulled.
    return _interleave(results, skip: refreshToken);
  }

  /// Most-viewed videos across a rotating topic — the closest thing to a
  /// "Trending" tab available without the official Data API.
  Future<List<VideoBrief>> trending({int refreshToken = 0}) async {
    if (isPreview) return _previewRows(refreshToken);
    final topics = _rotate(_coldStartTopics, refreshToken);
    final results = await Future.wait(
      topics.take(3).map((t) => _safe(() => search(t, sortByViews: true))),
    );
    return _interleave(results);
  }

  /// Vertical-video feed for the Shorts tab.
  ///
  /// YouTube exposes no Shorts feed this app can reach: the channel Shorts tab
  /// returns nothing, and search yields no `reelItemRenderer`. Shorts do come
  /// back from an ordinary search — as `shortsLockupViewModel`, a renderer
  /// nothing else here parses — so the feed is assembled from several topic
  /// searches, led by whatever the user has been searching for.
  ///
  /// The selection is therefore ours rather than YouTube's algorithm. It is
  /// shuffled so the tab is not identical on every visit.
  Future<List<VideoBrief>> shortsFeed({
    List<String> searches = const [],
    int refreshToken = 0,
  }) async {
    if (isPreview) return _previewRows(refreshToken);

    // Lead with the user's own interests, then broad topics.
    final topics = <String>[
      ...searches.take(2),
      ..._rotate(_shortsTopics, refreshToken).take(3),
    ];

    final results = await Future.wait(
      topics.map((t) => _safeShorts(() => _search.searchShorts('$t shorts'))),
    );
    return _interleave(results)..shuffle();
  }

  Future<List<VideoBrief>> _safeShorts(
    Future<List<VideoBrief>> Function() task,
  ) async {
    try {
      return await task();
    } catch (e) {
      debugPrint('AI BIT: shorts section failed — $e');
      return const [];
    }
  }

  static const _shortsTopics = [
    'funny',
    'satisfying',
    'life hack',
    'football',
    'cooking',
    'dance',
    'animals',
    'science',
  ];

  // ---------------------------------------------------------------- search

  Future<List<VideoBrief>> search(
    String query, {
    bool sortByViews = false,
    String? params,
  }) async {
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
      params: params ??
          (sortByViews
              ? YoutubeSearchClient.filterByViewCount
              : YoutubeSearchClient.filterVideosOnly),
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
    // Ours, not the package's: its getQuerySuggestions fails the same way its
    // search does, and the failure was swallowed here — so the suggestion list
    // was always empty and nothing ever said why.
    return _search.suggestions(query);
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

  /// A channel's uploads.
  ///
  /// The browse endpoint is tried first because `channels.getUploads` returns
  /// an empty stream — zero videos for every channel measured. The package call
  /// is kept only as a fallback in case that ever starts working again.
  /// A channel's Live tab: past and current streams.
  Future<List<VideoBrief>> channelLive(
    String channelId, {
    String channelTitle = '',
  }) async {
    if (isPreview) return const [];
    return _browse.channelVideos(
      channelId,
      channelTitle: channelTitle,
      live: true,
    );
  }

  /// A channel's Shorts tab.
  Future<List<VideoBrief>> channelShorts(
    String channelId, {
    String channelTitle = '',
  }) async {
    if (isPreview) return const [];
    return _browse.channelShorts(channelId, channelTitle: channelTitle);
  }

  Future<List<VideoBrief>> channelUploads(
    String channelId, {
    int limit = 20,
    String channelTitle = '',
  }) async {
    try {
      final videos = await _browse.channelVideos(
        channelId,
        channelTitle: channelTitle,
      );
      if (videos.isNotEmpty) return videos.take(limit).toList();
    } catch (e) {
      debugPrint('AI BIT: channel videos browse failed for $channelId — $e');
    }
    final videos = await _yt.channels.getUploads(channelId).take(limit).toList();
    return videos.map(VideoBrief.fromYt).toList();
  }

  /// Channel header. Falls back to the package when the browse endpoint
  /// returns nothing useful, since the two read different shapes and each
  /// occasionally comes back empty.
  Future<ChannelInfo> channelInfo(String channelId) async {
    try {
      final info = await _browse.channel(channelId);
      if (info.title.isNotEmpty) return info;
    } catch (e) {
      debugPrint('AI BIT: channel browse failed for $channelId — $e');
    }
    final channel = await _yt.channels.get(channelId);
    return ChannelInfo(
      id: channelId,
      title: channel.title,
      avatarUrl: channel.logoUrl,
      subscriberLabel: channel.subscribersCount == null
          ? null
          : '${compactCount(channel.subscribersCount)} subscribers',
    );
  }

  /// First page of a video's comments.
  Future<CommentPage> comments(String videoId) => _comments.fetch(videoId);

  /// A further page, using [CommentPage.continuation].
  Future<CommentPage> moreComments(String continuation) =>
      _comments.more(continuation);

  /// Replies to one comment.
  Future<List<VideoComment>> commentReplies(String token) =>
      _comments.replies(token);

  /// Playlists published by a channel.
  Future<List<PlaylistBrief>> channelPlaylists(String channelId) =>
      _browse.channelPlaylists(channelId);

  /// Title and length of a YouTube playlist.
  Future<PlaylistBrief> playlistInfo(String playlistId) async {
    final p = await _yt.playlists.get(playlistId);
    return PlaylistBrief(
      id: playlistId,
      title: p.title,
      videoCount: p.videoCount,
      channelId: null,
    );
  }

  /// Videos in a YouTube playlist.
  ///
  /// Browse first: `playlists.getVideos` returns an empty stream for every
  /// playlist measured, which is why opening a channel playlist showed nothing.
  Future<List<VideoBrief>> remotePlaylist(String playlistId, {int limit = 100}) async {
    try {
      final videos = await _browse.playlistVideos(playlistId);
      if (videos.isNotEmpty) return videos.take(limit).toList();
    } catch (e) {
      debugPrint('AI BIT: playlist browse failed for $playlistId — $e');
    }
    final videos = await _yt.playlists.getVideos(playlistId).take(limit).toList();
    return videos.map(VideoBrief.fromYt).toList();
  }

  // --------------------------------------------------------------- streams

  /// Pulls a playlist id out of a `?list=…` URL, or accepts a bare one.
  ///
  /// Checked before the video id: a `watch?v=…&list=…` link carries both, and
  /// opening the playlist is the more specific intent.
  static String? parsePlaylistId(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    final uri = Uri.tryParse(trimmed);
    final fromQuery = uri?.queryParameters['list'];
    if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;

    // A bare id. "LL" (liked) and "WL" (watch later) need an account, so they
    // are deliberately not accepted.
    if (RegExp(r'^(PL|UU|OL|RD|FL)[\w-]{10,}$').hasMatch(trimmed)) {
      return trimmed;
    }
    return null;
  }

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
            // Without these the picker showed only "Auto" on every video that
            // has no HLS ladder, which reads as broken rather than as "this
            // video only comes in one size".
            qualities: streams.muxedQualities,
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
    bool hd = false,
    bool toMp3 = false,
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
          final best = _bestPlayableAudio(manifest.audioOnly);
          return DownloadTarget(
            handle: best,
            totalBytes: best.size.totalBytes,
            quality: toMp3 ? 'MP3' : 'Audio',
            // The download lands as whatever YouTube served; the extension only
            // becomes .mp3 once the conversion has actually run.
            fileExtension: toMp3 ? 'mp3' : best.container.name,
            audioOnly: true,
            toMp3: toMp3,
          );
        }

        // HD: video-only and audio-only, joined after both arrive.
        //
        // YouTube retired combined streams above 360p, so this is the only way
        // to get 1080p or better. Both tracks are copied into one container
        // without re-encoding, which is quick and loses nothing.
        if (hd && manifest.videoOnly.isNotEmpty && manifest.audioOnly.isNotEmpty) {
          final videos = manifest.videoOnly
              .where((v) => v.container.name == 'mp4')
              .toList()
            ..sort((a, b) =>
                b.videoResolution.height.compareTo(a.videoResolution.height));
          if (videos.isNotEmpty) {
            final video = videos.first;
            final audio = _bestPlayableAudio(manifest.audioOnly);
            return DownloadTarget(
              handle: video,
              totalBytes: video.size.totalBytes,
              quality: video.qualityLabel,
              fileExtension: 'mp4',
              audioOnly: false,
              audioHandle: audio,
              audioBytes: audio.size.totalBytes,
            );
          }
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

  /// Picks AAC-in-MP4 over the higher-bitrate Opus track.
  ///
  /// Same reasoning as [YoutubePlayerClient]: iOS decodes neither WebM nor
  /// Opus, so a downloaded Opus file would save successfully and then refuse
  /// to play — a worse failure than a slightly smaller bitrate.
  static yt.AudioOnlyStreamInfo _bestPlayableAudio(
    List<yt.AudioOnlyStreamInfo> tracks,
  ) {
    final aac = tracks
        .where(
          (t) =>
              t.container.name.toLowerCase().contains('mp4') ||
              t.codec.subtype.toLowerCase().contains('mp4'),
        )
        .toList();
    final pool = aac.isNotEmpty ? aac : tracks;
    return pool.reduce(
      (a, b) => a.bitrate.compareTo(b.bitrate) >= 0 ? a : b,
    );
  }

  /// What can actually be downloaded for [videoId], with real sizes.
  ///
  /// Both are resolved together so the picker can show sizes before the user
  /// commits, rather than after a transfer has started.
  ///
  /// There is no HD option, and that is a YouTube constraint rather than a
  /// missing feature: the only single-file video stream still served is the
  /// legacy 360p MP4. Everything above it exists solely as separate video-only
  /// and audio-only tracks, or as MPEG-TS HLS segments that iOS will not play
  /// from disk — both need a muxer to become a playable file. Streaming is
  /// unaffected and still goes to 2160p.
  Future<List<DownloadOption>> downloadOptions(String videoId) async {
    final results = await Future.wait([
      _optionOrNull(videoId, audioOnly: false),
      _optionOrNull(videoId, audioOnly: true),
    ]);
    return results.whereType<DownloadOption>().toList();
  }

  Future<DownloadOption?> _optionOrNull(
    String videoId, {
    required bool audioOnly,
  }) async {
    try {
      final target = await downloadTarget(videoId, audioOnly: audioOnly);
      return DownloadOption(
        audioOnly: audioOnly,
        label: audioOnly ? 'Audio only' : target.quality,
        detail: audioOnly
            ? 'Best audio, no video'
            : 'Video with sound',
        bytes: target.totalBytes,
        fileExtension: target.fileExtension,
      );
    } catch (e) {
      debugPrint('AI BIT: no ${audioOnly ? 'audio' : 'video'} download for '
          '$videoId — $e');
      return null;
    }
  }

  /// Opens the byte stream for [target]. The caller writes it to disk and
  /// tracks progress.
  /// Bytes for one half of a download. [audio] selects the separate audio
  /// track that HD downloads have to fetch alongside the video.
  Stream<List<int>> downloadBytes(DownloadTarget target, {bool audio = false}) {
    final handle = audio ? target.audioHandle : target.handle;
    return _yt.videos.streamsClient.get(handle! as yt.StreamInfo);
  }

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
  ///
  /// [skip] drops the first n of each section, so a refresh shows what was
  /// further down rather than the same head of every list.
  static List<VideoBrief> _interleave(
    List<List<VideoBrief>> sections, {
    int skip = 0,
  }) {
    final out = <VideoBrief>[];
    final seen = <String>{};
    // Never skip so far that a short section empties out entirely.
    final shortest = sections
        .where((s) => s.isNotEmpty)
        .fold(1 << 30, (m, s) => s.length < m ? s.length : m);
    final offset = shortest == 1 << 30 ? 0 : skip % shortest;
    if (offset > 0) {
      sections = sections
          .map((s) => s.length > offset ? s.sublist(offset) : s)
          .toList();
    }
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
