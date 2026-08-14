import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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

  /// Kid-friendly topics for the home feed in Kids mode. Evergreen, broadly
  /// safe search terms — the app cannot enforce YouTube's own age gating, so
  /// this curates rather than filters.
  static const _kidsTopics = [
    'nursery rhymes',
    'kids cartoon',
    'cocomelon',
    'kids learning videos',
    'peppa pig',
    'kids songs',
    'chota bheem',
    'kids science experiments',
    'abc for kids',
    'moral stories for kids',
  ];

  static const _kidsShortsTopics = [
    'kids cartoon',
    'nursery rhyme',
    'funny animals',
    'kids learning',
    'kids craft',
    'cartoon',
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
    bool kids = false,
  }) async {
    if (isPreview) return _previewRows(refreshToken);

    // Kids mode ignores the personal signals entirely and draws only from the
    // curated kid topics, so nothing from normal watch history leaks in.
    if (kids) {
      final topics = _rotate(_kidsTopics, refreshToken).take(6);
      final results = await Future.wait(
        topics.map((t) => _safe(() => search(t, sortByViews: true))),
      );
      return _interleave(results, skip: refreshToken);
    }

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
    bool kids = false,
  }) async {
    if (isPreview) return _previewRows(refreshToken);

    // Kids mode draws only from kid-friendly shorts topics.
    final topics = kids
        ? _rotate(_kidsShortsTopics, refreshToken).take(4).toList()
        : <String>[
            ...searches.take(2),
            ..._rotate(_shortsTopics, refreshToken).take(3),
          ];

    final results = await Future.wait(
      topics.map((t) => _safeShorts(() => _search.searchShorts('$t shorts'))),
    );
    return (_interleave(results)..shuffle())
        .map((v) => v.asShort())
        .toList();
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
  /// Warms the stream cache for [videoId] without playing it, so a following
  /// [resolve] returns instantly. Used to preload the next Shorts the way
  /// YouTube does, turning the network round-trip on swipe into a cache hit.
  ///
  /// Fire-and-forget: failures are swallowed, and a video already cached is
  /// skipped so this costs nothing when called repeatedly.
  void prefetch(String videoId) {
    if (_streamCache.containsKey('$videoId:false')) return;
    if (!_prefetching.add(videoId)) return;
    unawaited(
      resolve(videoId).then((_) {}, onError: (Object _) {}).whenComplete(
        () => _prefetching.remove(videoId),
      ),
    );
  }

  final _prefetching = <String>{};

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
    int? requestedHeight,
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
          final videos = _downloadableVideos(manifest);
          if (videos.isNotEmpty) {
            // The requested height exactly where it exists, otherwise the
            // nearest below it, otherwise the best there is — so a picker entry
            // always resolves to something rather than failing.
            final video = requestedHeight == null
                ? videos.first
                : (videos.firstWhere(
                    (v) => v.videoResolution.height == requestedHeight,
                    orElse: () => videos.firstWhere(
                      (v) => v.videoResolution.height <= requestedHeight,
                      orElse: () => videos.last,
                    ),
                  ));
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

  /// Video-only MP4 renditions to offer for HD download, tallest first, with
  /// H.264/AVC preferred over AV1.
  ///
  /// YouTube serves 1440p and 2160p **only** as AV1, and Apple's Photos and
  /// AVPlayer reject AV1 on most iPhones — a 4K download saves and then fails
  /// to play or export ("unsupported format", which is exactly what a 4K
  /// download hit). Preferring AVC caps HD at a universally compatible 1080p,
  /// the same "playable beats bigger" rule as [_bestPlayableAudio]. AV1 is used
  /// only when a video offers nothing else.
  static List<yt.VideoOnlyStreamInfo> _downloadableVideos(
    yt.StreamManifest manifest,
  ) {
    final mp4 = manifest.videoOnly
        .where((v) => v.container.name == 'mp4')
        .toList();
    final avc = mp4
        .where((v) => v.videoCodec.toLowerCase().startsWith('avc'))
        .toList();
    final chosen = avc.isNotEmpty ? avc : mp4;
    chosen.sort(
      (a, b) => b.videoResolution.height.compareTo(a.videoResolution.height),
    );
    return chosen;
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

  /// Every rendition that can actually be downloaded, with real sizes, so the
  /// picker shows the choice before anything transfers.
  ///
  /// One combined 360p file needs no processing. Everything above it is a
  /// video-only track joined to audio, and audio can be converted to MP3 —
  /// both need FFmpeg, so they are only offered when [allowFfmpeg] is true and
  /// flagged with `needsFfmpeg` either way.
  Future<List<DownloadOption>> downloadOptions(
    String videoId, {
    required bool allowFfmpeg,
  }) async {
    for (final client in _clientChain) {
      try {
        final manifest = await _yt.videos.streamsClient.getManifest(
          videoId,
          ytClients: [client],
        );

        final options = <DownloadOption>[];
        final audio = manifest.audioOnly.isEmpty
            ? null
            : _bestPlayableAudio(manifest.audioOnly);
        final audioBytes = audio?.size.totalBytes ?? 0;

        // HD renditions, tallest first, only where they can be joined.
        if (allowFfmpeg && audio != null) {
          final videos = _downloadableVideos(manifest);
          final seen = <int>{};
          for (final v in videos) {
            final h = v.videoResolution.height;
            if (h <= 360 || !seen.add(h)) continue;
            options.add(DownloadOption(
              audioOnly: false,
              quality: '${h}p',
              label: '${h}p',
              detail: 'Video with sound, joined on device',
              bytes: v.size.totalBytes + audioBytes,
              fileExtension: 'mp4',
              needsFfmpeg: true,
            ));
          }
        }

        // The one combined file, which always works.
        final muxed = manifest.muxed.toList()
          ..sort((a, b) =>
              b.videoResolution.height.compareTo(a.videoResolution.height));
        if (muxed.isNotEmpty) {
          final m = muxed.first;
          options.add(DownloadOption(
            audioOnly: false,
            quality: m.qualityLabel,
            label: m.qualityLabel,
            detail: 'Video with sound',
            bytes: m.size.totalBytes,
            fileExtension: m.container.name,
          ));
        }

        // Audio, and MP3 where it can be converted.
        if (audio != null) {
          options.add(DownloadOption(
            audioOnly: true,
            quality: 'Audio',
            label: 'Audio only',
            detail: 'Best audio, no video',
            bytes: audioBytes,
            fileExtension: audio.container.name,
          ));
          if (allowFfmpeg) {
            options.add(DownloadOption(
              audioOnly: true,
              quality: 'MP3',
              label: 'MP3',
              detail: 'Audio converted for older players',
              bytes: audioBytes,
              fileExtension: 'mp3',
              needsFfmpeg: true,
            ));
          }
        }

        if (options.isNotEmpty) return options;
      } catch (e) {
        debugPrint('AI BIT: download options failed for $videoId — $e');
      }
    }
    return const [];
  }

  /// Opens the byte stream for [target]. The caller writes it to disk and
  /// tracks progress.
  /// Bytes for one half of a download. [audio] selects the separate audio
  /// track that HD downloads have to fetch alongside the video.
  Stream<List<int>> downloadBytes(DownloadTarget target, {bool audio = false}) {
    final handle = (audio ? target.audioHandle : target.handle) as yt.StreamInfo;
    return _rangedDownload(handle);
  }

  /// Fetches a progressive stream in bounded ranged chunks instead of one long
  /// open request.
  ///
  /// The one-request approach was the whole cause of "download stalled — no
  /// data received": YouTube throttles a single sustained googlevideo request
  /// down to nothing after the first burst, so on a phone the transfer would
  /// hang and the watchdog killed it. Asking for ~8 MB at a time keeps every
  /// request short enough to run at full speed. A chunk that stalls or errors
  /// is retried from exactly where it stopped — the bytes already yielded are
  /// on disk — so a hiccup costs one chunk, not the whole download.
  ///
  /// Anything this cannot range over — fragmented DASH, or a stream whose size
  /// YouTube did not report — falls back to the package's own streaming.
  Stream<List<int>> _rangedDownload(yt.StreamInfo info) async* {
    final total = info.size.totalBytes;
    if (total <= 0 || info.fragments.isNotEmpty) {
      yield* _yt.videos.streamsClient.get(info);
      return;
    }

    const chunkSize = 8 * 1024 * 1024; // 8 MB per request.
    const chunkTimeout = Duration(seconds: 25);
    const maxAttempts = 3;

    final client = http.Client();
    try {
      var received = 0;
      while (received < total) {
        final end = (received + chunkSize >= total ? total : received + chunkSize) - 1;
        var attempt = 0;
        while (true) {
          try {
            final request = http.Request('GET', info.url)
              ..headers['Range'] = 'bytes=$received-$end';
            final response =
                await client.send(request).timeout(chunkTimeout);
            if (response.statusCode != 206 && response.statusCode != 200) {
              throw http.ClientException(
                'Unexpected status ${response.statusCode}',
                info.url,
              );
            }
            // A gap between packets longer than the timeout is a stall, not a
            // slow link — turn it into a retry rather than an endless wait.
            await for (final data in response.stream.timeout(chunkTimeout)) {
              received += data.length;
              yield data;
            }
            break; // chunk complete
          } catch (e) {
            if (++attempt >= maxAttempts) rethrow;
            await Future<void>.delayed(Duration(seconds: attempt));
            // Loop retries from the current `received`, resuming the chunk.
          }
        }
      }
    } finally {
      client.close();
    }
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
