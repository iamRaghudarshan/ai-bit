import 'dart:convert';

import 'package:http/http.dart' as http;

import 'dash_manifest.dart';

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

  /// Language and region asked for. See the note on the browse client — these
  /// were hardcoded to en/US, and `gl` in particular decides availability, not
  /// just wording.
  String _hl = 'en';
  String _gl = 'US';

  void setLocale({required String language, required String region}) {
    if (language.isNotEmpty) _hl = language;
    if (region.isNotEmpty) _gl = region;
  }

  /// The profile's context with this locale applied.
  ///
  /// Copied rather than mutated: the profiles are const and shared, and
  /// writing into one would change it for every later request.
  Map<String, dynamic> _contextFor(_ClientProfile profile) => {
        ...profile.context,
        'hl': _hl,
        'gl': _gl,
      };

  void close() => _http.close();

  /// Walks the client list and returns the first response that yields
  /// something playable. Returns null when none do.
  Future<PlayerStreams?> fetch(String videoId) async {
    final found = <PlayerStreams>[];
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
        // An HLS ladder ends the search: it is adaptive, already muxed, and
        // the one thing that plays on both platforms *and* on a live stream.
        // Nothing a later client could add would improve on it.
        if (streams.hlsUrl != null) return streams;
        found.add(streams);
      } catch (_) {
        // Try the next client rather than failing the whole resolve.
        continue;
      }
    }

    if (found.isNotEmpty) return PlayerStreams.merge(found);
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
            'context': {'client': _contextFor(profile)},
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

  /// The web-family clients, in the order worth asking with a web token.
  ///
  /// A proof-of-origin token minted in a browser engine is a *web* token, so
  /// only these clients accept it. WEB first, because it is the one the token
  /// was minted as; MWEB and TVHTML5 because they answer the same token and
  /// have, at different times, handed out byte-range URLs when WEB answered
  /// with server-side streaming instead.
  static const webClients = <WebClientProfile>[
    WebClientProfile(
      name: 'WEB',
      clientNameId: 1,
      context: {
        'clientName': 'WEB',
        'clientVersion': '2.20250312.04.00',
      },
      userAgent:
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    ),
    WebClientProfile(
      name: 'MWEB',
      clientNameId: 2,
      context: {
        'clientName': 'MWEB',
        'clientVersion': '2.20250311.03.00',
      },
      userAgent:
          'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 '
          'Safari/604.1',
    ),
    WebClientProfile(
      name: 'TVHTML5',
      clientNameId: 7,
      context: {
        'clientName': 'TVHTML5',
        'clientVersion': '7.20251105.10.00',
        'userAgent':
            'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version,gzip(gfe)',
        'originalUrl': 'https://www.youtube.com/tv',
        'theme': 'CLASSIC',
        'platform': 'DESKTOP',
        'clientFormFactor': 'UNKNOWN_FORM_FACTOR',
        'deviceMake': '',
        'deviceModel': '',
      },
      userAgent: 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version,gzip(gfe)',
    ),
  ];

  /// One web-client player request carrying a proof-of-origin token.
  ///
  /// Returns the raw response, because the formats in it are not usable yet:
  /// their URLs are behind the signature and `n` challenges, and resolving
  /// those is the attestation service's job (see `web_formats.dart`). The
  /// visitor id goes in both the context and the header, and it must be the
  /// one the token was minted against — a token bound to a different session
  /// is a token YouTube ignores.
  Future<WebPlayerResponse> fetchWeb(
    String videoId, {
    required WebClientProfile client,
    required String visitorData,
    required String poToken,
    required int signatureTimestamp,
  }) async {
    final response = await _http
        .post(
          _endpoint,
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': client.userAgent,
            'Origin': 'https://www.youtube.com',
            'Referer': 'https://www.youtube.com/watch?v=$videoId',
            'X-Goog-Visitor-Id': visitorData,
            'X-YouTube-Client-Name': '${client.clientNameId}',
            'X-YouTube-Client-Version': client.context['clientVersion']!,
          },
          body: jsonEncode({
            'context': {
              'client': {
                ...client.context,
                'hl': _hl,
                'gl': _gl,
                'visitorData': visitorData,
              },
            },
            'videoId': videoId,
            'serviceIntegrityDimensions': {'poToken': poToken},
            'playbackContext': {
              'contentPlaybackContext': {
                'signatureTimestamp': signatureTimestamp,
                'html5Preference': 'HTML5_PREF_WANTS',
              },
            },
            'contentCheckOk': true,
            'racyCheckOk': true,
          }),
        )
        .timeout(const Duration(seconds: 20));
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (response.statusCode != 200) {
      // The error body says which argument was refused; "HTTP 400" alone
      // cannot be acted on from a phone's settings screen.
      final error = json['error'];
      throw PlayerUnavailableException(
        'HTTP ${response.statusCode}'
        '${error is Map ? ' ${error['status']}: ${error['message']}' : ''}',
      );
    }
    final status = json['playabilityStatus'] as Map?;
    final streaming = json['streamingData'] as Map<String, dynamic>?;
    final details = json['videoDetails'] as Map<String, dynamic>?;
    return WebPlayerResponse(
      client: client.name,
      status: status?['status']?.toString() ?? '?',
      reason: status?['reason']?.toString(),
      hlsUrl: streaming?['hlsManifestUrl'] as String?,
      serverAbr: streaming?['serverAbrStreamingUrl'] != null,
      rawAdaptiveFormats: (streaming?['adaptiveFormats'] as List?) ?? const [],
      rawFormats: (streaming?['formats'] as List?) ?? const [],
      isLive: details?['isLiveContent'] == true || details?['isLive'] == true,
    );
  }

  static PlayerStreams _parse(Map<String, dynamic> json) {
    final streaming = json['streamingData'] as Map<String, dynamic>?;
    final details = json['videoDetails'] as Map<String, dynamic>?;

    return PlayerStreams(
      hlsUrl: streaming?['hlsManifestUrl'] as String?,
      audioUrl: _bestAudio(streaming),
      muxedUrl: _bestMuxed(streaming),
      muxedQualities: _muxedQualities(streaming),
      adaptiveFormats: _adaptiveFormats(streaming),
      isLive: details?['isLiveContent'] == true || details?['isLive'] == true,
    );
  }

  /// The separate video-only and audio-only tracks, kept so a DASH manifest
  /// can be generated from them. See `dash_manifest.dart` — this is the only
  /// route above 360p now that `hlsManifestUrl` comes back for roughly one
  /// video in eight.
  static List<AdaptiveFormat> _adaptiveFormats(Map<String, dynamic>? streaming) {
    final formats = streaming?['adaptiveFormats'];
    if (formats is! List) return const [];
    return [
      for (final f in formats) ?parseAdaptiveFormat(f),
    ];
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
    this.adaptiveFormats = const [],
    this.isLive = false,
  });

  /// Adaptive ladder, muxed. The preferred source when present.
  final String? hlsUrl;
  final String? audioUrl;
  final String? muxedUrl;

  /// Label to URL for each muxed rendition on offer.
  final Map<String, String> muxedQualities;

  /// Separate video-only and audio-only tracks, up to 2160p. Raw material for
  /// a generated DASH manifest on Android.
  final List<AdaptiveFormat> adaptiveFormats;
  final bool isLive;

  /// Whether a DASH manifest could be built from these formats — i.e. whether
  /// HD is reachable at all for this video.
  bool get hasAdaptiveVideo =>
      adaptiveFormats.any((f) => f.isVideo) &&
      adaptiveFormats.any((f) => f.isAudio);

  bool get hasVideo => hlsUrl != null || muxedUrl != null || hasAdaptiveVideo;

  /// Combines what several clients returned into the best single answer.
  ///
  /// **This exists because picking one response broke iOS.** The clients do not
  /// return the same things, and measurably so — for one ordinary video, asked
  /// on the same day:
  ///
  ///     ios      formats=0  adaptive=19     (no progressive stream at all)
  ///     android  formats=1  adaptive=26     (has the 360p progressive)
  ///
  /// The old code kept the first response that satisfied [hasVideo] and
  /// discarded the rest. Once [hasAdaptiveVideo] was folded into [hasVideo] —
  /// which it had to be, since adaptive tracks are what DASH is built from —
  /// the `ios` response began to satisfy it on adaptive tracks alone, won the
  /// slot, and the `android` response carrying the *only* stream an iPhone can
  /// play was thrown away. Android never noticed, because it rebuilds the
  /// picture from those adaptive tracks; on iOS, where AVPlayer cannot play
  /// DASH, it left nothing at all and every such video became "could not find
  /// a playable stream".
  ///
  /// So: take the best of each kind rather than the best single response. The
  /// pieces are independently signed URLs describing the same video, and
  /// nothing here combines two of them into one stream — each is a separate
  /// thing the player might be handed.
  ///
  /// The one exception is [adaptiveFormats], which is taken whole from the
  /// single richest response and never merged across responses: a DASH
  /// manifest has to describe one coherent set of tracks, and splicing two
  /// clients' views of a video is how you get a manifest whose audio and video
  /// disagree about duration.
  static PlayerStreams merge(List<PlayerStreams> all) {
    if (all.length == 1) return all.first;

    String? hls;
    String? audio;
    String? muxed;
    var muxedQualities = const <String, String>{};
    var adaptive = const <AdaptiveFormat>[];
    var isLive = false;

    for (final s in all) {
      hls ??= s.hlsUrl;
      audio ??= s.audioUrl;
      // Kept together: a label-to-URL map from one client must not be paired
      // with another client's chosen URL.
      if (muxed == null && s.muxedUrl != null) {
        muxed = s.muxedUrl;
        muxedQualities = s.muxedQualities;
      }
      if (s.adaptiveFormats.length > adaptive.length) {
        adaptive = s.adaptiveFormats;
      }
      isLive = isLive || s.isLive;
    }

    return PlayerStreams(
      hlsUrl: hls,
      audioUrl: audio,
      muxedUrl: muxed,
      muxedQualities: muxedQualities,
      adaptiveFormats: adaptive,
      isLive: isLive,
    );
  }
}

/// A web-family client, which is what a browser-minted token is good for.
class WebClientProfile {
  const WebClientProfile({
    required this.name,
    required this.clientNameId,
    required this.context,
    required this.userAgent,
  });

  final String name;

  /// The numeric id YouTube wants in `X-YouTube-Client-Name`.
  final int clientNameId;
  final Map<String, String> context;
  final String userAgent;
}

/// A web client's answer, before its formats have been made usable.
class WebPlayerResponse {
  const WebPlayerResponse({
    required this.client,
    required this.status,
    this.reason,
    this.hlsUrl,
    this.serverAbr = false,
    this.rawAdaptiveFormats = const [],
    this.rawFormats = const [],
    this.isLive = false,
  });

  final String client;
  final String status;
  final String? reason;
  final String? hlsUrl;

  /// True when the response offers server-side streaming, which is YouTube's
  /// own session protocol and not something a plain byte-range player can
  /// use. A response that is *only* that has no URLs to resolve.
  final bool serverAbr;
  final List<Object?> rawAdaptiveFormats;
  final List<Object?> rawFormats;
  final bool isLive;

  bool get isOk => status == 'OK';

  /// Whether any format carries something a URL can be made from.
  bool get hasAddressableFormats => rawAdaptiveFormats.any(
        (f) =>
            f is Map &&
            (f['url'] != null ||
                f['signatureCipher'] != null ||
                f['cipher'] != null),
      );
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
