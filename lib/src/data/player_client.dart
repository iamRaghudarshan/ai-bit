import 'dart:convert';

import 'package:http/http.dart' as http;

/// Talks to YouTube's `youtubei/v1/player` endpoint directly.
///
/// This exists because `youtube_explode_dart` never surfaces
/// `streamingData.hlsManifestUrl`, and that field is the whole game:
///
///   * It is an **adaptive HLS ladder** — 144p through 2160p for on-demand
///     video, 144p through 1080p for live — with audio and video already muxed.
///     AVPlayer plays it natively and switches bitrate on its own. Going
///     through the package's parsed `muxed` list instead caps playback at the
///     legacy 360p MP4, which is the only progressive stream YouTube still
///     serves.
///   * It is the **only** way to play a live stream. The package's
///     `getManifest` throws "Null check operator used on a null value" on live
///     videos for every client.
///
/// Verified against live YouTube with `tool/check_player_api.dart`.
class YoutubePlayerClient {
  YoutubePlayerClient({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  static final _endpoint = Uri.parse(
    'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
  );

  /// Ordered by what each one actually returns, measured rather than assumed:
  /// iOS is the only client giving an HLS ladder for on-demand video, and
  /// Android is the only one giving it for live. Re-check with
  /// `tool/check_player_api.dart` if playback regresses.
  static const _clients = <_ClientProfile>[
    _ClientProfile(
      name: 'ios',
      context: {
        'clientName': 'IOS',
        'clientVersion': '20.10.4',
        'deviceMake': 'Apple',
        'deviceModel': 'iPhone16,2',
        'osName': 'IOS',
        'osVersion': '18.1.0.22B83',
        'hl': 'en',
        'gl': 'US',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
      },
      userAgent:
          'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
    ),
    _ClientProfile(
      name: 'android',
      context: {
        'clientName': 'ANDROID',
        'clientVersion': '20.10.38',
        'osName': 'Android',
        'osVersion': '11',
        'hl': 'en',
        'gl': 'US',
        'timeZone': 'UTC',
        'utcOffsetMinutes': 0,
      },
      userAgent:
          'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
    ),
  ];

  void close() => _http.close();

  /// Walks the client list and returns the first response that yields
  /// something playable. Returns null when none do.
  Future<PlayerStreams?> fetch(String videoId) async {
    PlayerStreams? partial;
    String? reason;

    for (final profile in _clients) {
      try {
        final json = await _request(videoId, profile);
        final status = (json['playabilityStatus'] as Map?);
        if (status?['status'] != 'OK') {
          reason ??= status?['reason']?.toString();
          continue;
        }

        final streams = _parse(json);
        // An HLS ladder ends the search. Otherwise keep the best thing seen so
        // far, preferring anything with a picture — taking simply the first
        // response meant a client that returned audio alone beat a later one
        // that had video.
        if (streams.hlsUrl != null) return streams;
        if (partial == null || (!partial.hasVideo && streams.hasVideo)) {
          partial = streams;
        }
      } catch (_) {
        // Try the next client rather than failing the whole resolve.
        continue;
      }
    }

    if (partial != null) return partial;
    if (reason != null) throw PlayerUnavailableException(reason);
    return null;
  }

  Future<Map<String, dynamic>> _request(
    String videoId,
    _ClientProfile profile,
  ) async {
    final response = await _http
        .post(
          _endpoint,
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': profile.userAgent,
            'Origin': 'https://www.youtube.com',
          },
          body: jsonEncode({
            'context': {'client': profile.context},
            'videoId': videoId,
            'contentCheckOk': true,
            'racyCheckOk': true,
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode != 200) {
      throw PlayerUnavailableException('HTTP ${response.statusCode}');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  static PlayerStreams _parse(Map<String, dynamic> json) {
    final streaming = json['streamingData'] as Map<String, dynamic>?;
    final details = json['videoDetails'] as Map<String, dynamic>?;

    return PlayerStreams(
      hlsUrl: streaming?['hlsManifestUrl'] as String?,
      audioUrl: _bestAudio(streaming),
      muxedUrl: _bestMuxed(streaming),
      muxedQualities: _muxedQualities(streaming),
      isLive: details?['isLiveContent'] == true || details?['isLive'] == true,
    );
  }

  /// Best *playable* audio-only track, for the data-saver, screen-off and
  /// audio-download paths.
  ///
  /// Deliberately not simply the highest bitrate. YouTube's top audio track is
  /// almost always Opus in a WebM container, and iOS AVPlayer decodes neither —
  /// picking it made "Audio only" fail outright while the video itself played
  /// fine. AAC-in-MP4 is preferred and costs nothing worth having: on a typical
  /// video the choice is 136 kbps Opus against 130 kbps AAC.
  ///
  /// Formats behind `signatureCipher` are skipped — deciphering needs the
  /// player JS, and the clients above hand out plain URLs.
  static String? _bestAudio(Map<String, dynamic>? streaming) {
    final formats = streaming?['adaptiveFormats'];
    if (formats is! List) return null;

    String? bestCompatible;
    var bestCompatibleBitrate = -1;
    String? bestAny;
    var bestAnyBitrate = -1;

    for (final f in formats) {
      if (f is! Map) continue;
      final mime = f['mimeType']?.toString() ?? '';
      if (!mime.startsWith('audio/')) continue;
      final url = f['url'];
      if (url is! String || url.isEmpty) continue;

      final bitrate = (f['bitrate'] as num?)?.toInt() ?? 0;
      final isAac = mime.contains('mp4') && mime.contains('mp4a');

      if (isAac && bitrate > bestCompatibleBitrate) {
        bestCompatibleBitrate = bitrate;
        bestCompatible = url;
      }
      if (bitrate > bestAnyBitrate) {
        bestAnyBitrate = bitrate;
        bestAny = url;
      }
    }

    // Fall back to whatever exists rather than nothing: Android plays Opus
    // happily, and a track that might work beats no audio at all.
    return bestCompatible ?? bestAny;
  }

  /// Legacy progressive stream, kept only as a last resort when no HLS ladder
  /// is offered. Capped at 360p by YouTube.
  /// Every muxed rendition keyed by label, so a video with no HLS ladder can
  /// still offer a real choice instead of only "Auto".
  ///
  /// YouTube has retired almost all of these — usually the single 360p MP4 is
  /// all that comes back — but reporting one honest option beats reporting
  /// none, which is what made the picker look broken.
  static Map<String, String> _muxedQualities(Map<String, dynamic>? streaming) {
    final formats = streaming?['formats'];
    if (formats is! List) return const {};

    final out = <String, String>{};
    for (final f in formats) {
      if (f is! Map) continue;
      final url = f['url'];
      final height = (f['height'] as num?)?.toInt() ?? 0;
      if (url is! String || url.isEmpty || height <= 0) continue;
      out.putIfAbsent('${height}p', () => url);
    }
    return out;
  }

  static String? _bestMuxed(Map<String, dynamic>? streaming) {
    final formats = streaming?['formats'];
    if (formats is! List) return null;

    String? best;
    var bestHeight = -1;
    for (final f in formats) {
      if (f is! Map) continue;
      final url = f['url'];
      if (url is! String || url.isEmpty) continue;
      final height = (f['height'] as num?)?.toInt() ?? 0;
      if (height > bestHeight) {
        bestHeight = height;
        best = url;
      }
    }
    return best;
  }
}

class PlayerStreams {
  const PlayerStreams({
    this.hlsUrl,
    this.audioUrl,
    this.muxedUrl,
    this.muxedQualities = const {},
    this.isLive = false,
  });

  /// Adaptive ladder, muxed. The preferred source when present.
  final String? hlsUrl;
  final String? audioUrl;
  final String? muxedUrl;

  /// Label to URL for each muxed rendition on offer.
  final Map<String, String> muxedQualities;
  final bool isLive;

  bool get hasVideo => hlsUrl != null || muxedUrl != null;
}

class _ClientProfile {
  const _ClientProfile({
    required this.name,
    required this.context,
    required this.userAgent,
  });

  final String name;
  final Map<String, dynamic> context;
  final String userAgent;
}

class PlayerUnavailableException implements Exception {
  PlayerUnavailableException(this.reason);
  final String reason;

  @override
  String toString() => reason;
}
