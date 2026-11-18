/// Builds an MPEG-DASH manifest out of YouTube's `adaptiveFormats`.
///
/// This is how the app plays anything above 360p, and it exists because of a
/// change on YouTube's side rather than a change of mind here.
///
/// The player takes exactly one URL, so historically only a *combined*
/// video+audio stream was playable. YouTube retired all of those above the
/// legacy 360p MP4, leaving two ways up: `hlsManifestUrl`, an adaptive ladder
/// the iOS client used to return for everything, and the separate video-only
/// and audio-only tracks in `adaptiveFormats`. The app took the first.
///
/// As of November 2026 the player endpoint returns `hlsManifestUrl` for
/// roughly **one video in eight** — measured, not guessed, across clients and
/// video ages. Every other video fell through to the 360p progressive stream,
/// which is exactly the "HD never plays, it is always 360p" that was reported.
/// Meanwhile `adaptiveFormats` still carries plain unciphered URLs all the way
/// to 2160p for the same videos.
///
/// A DASH manifest is how those separate tracks become one URL. It is a small
/// XML document naming each rendition and the byte ranges of its index, and
/// the manifest itself can live on local disk while every segment is fetched
/// from googlevideo — so nothing has to be downloaded or muxed first. ExoPlayer
/// then does the work the player could not do before: it plays a video track
/// and an audio track together, and adapts between rungs on its own.
///
/// **Android only**, and that is a platform fact rather than a shortcut.
/// AVPlayer has never supported DASH and Apple has no plans to add it; the iOS
/// answer is HLS, and generating HLS from these formats means parsing each
/// track's `sidx` box to emit byte-range segment lists. So iOS keeps the old
/// behaviour — the HLS ladder when YouTube offers one, 360p when it does not —
/// and `PlaybackSources.isDash` is never set there. See `canUseDash`.
///
/// Pure, so every rule below is pinned by a test: no I/O, no platform calls.
library;

/// One entry from `streamingData.adaptiveFormats`.
class AdaptiveFormat {
  const AdaptiveFormat({
    required this.itag,
    required this.url,
    required this.mimeType,
    required this.codecs,
    required this.bitrate,
    required this.durationMs,
    required this.initStart,
    required this.initEnd,
    required this.indexStart,
    required this.indexEnd,
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.audioSampleRate = 0,
    this.audioChannels = 0,
    this.audioTrackId,
    this.audioIsDefault = false,
  });

  final int itag;
  final String url;

  /// The base type only — `video/mp4`, `audio/webm`. Codecs are split out
  /// because DASH wants them in a separate attribute.
  final String mimeType;
  final String codecs;
  final int bitrate;
  final int durationMs;
  final int initStart;
  final int initEnd;
  final int indexStart;
  final int indexEnd;
  final int width;
  final int height;
  final int fps;
  final int audioSampleRate;
  final int audioChannels;

  /// Set only on videos with alternate dub tracks.
  final String? audioTrackId;
  final bool audioIsDefault;

  bool get isVideo => mimeType.startsWith('video/');
  bool get isAudio => mimeType.startsWith('audio/');

  /// A format is usable only if it can be addressed by byte range.
  ///
  /// A missing `url` means the format is behind `signatureCipher`, which needs
  /// the player JS to decipher. A missing index range means it is a
  /// progressive stream rather than an indexed one, and DASH `SegmentBase`
  /// has nothing to point at. Both are dropped rather than emitted broken:
  /// one bad Representation can fail the whole manifest.
  bool get isUsable =>
      url.isNotEmpty &&
      mimeType.isNotEmpty &&
      durationMs > 0 &&
      indexEnd > indexStart &&
      initEnd >= initStart;

  /// Which decoder family this is, so renditions that cannot adapt between
  /// each other end up in different AdaptationSets.
  String get codecFamily {
    final c = codecs.toLowerCase();
    if (c.startsWith('avc')) return 'avc';
    if (c.startsWith('vp9') || c.startsWith('vp09')) return 'vp9';
    if (c.startsWith('av01')) return 'av1';
    if (c.startsWith('mp4a')) return 'aac';
    if (c.startsWith('opus')) return 'opus';
    return c.isEmpty ? 'other' : c.split('.').first;
  }
}

/// Parses one `adaptiveFormats` entry. Returns null for anything unusable.
///
/// Every numeric field here arrives as a *string* in some responses and a
/// number in others — `initRange.start` is `"0"`, `height` is `1080` — so each
/// is read through [_int] rather than cast. That is the same lesson the
/// data-usage estimator learned: a value from someone else's API has more
/// shapes than the one in front of you.
AdaptiveFormat? parseAdaptiveFormat(Object? raw) {
  if (raw is! Map) return null;
  final url = raw['url'];
  if (url is! String || url.isEmpty) return null;

  final full = raw['mimeType']?.toString() ?? '';
  if (full.isEmpty) return null;

  // `video/mp4; codecs="avc1.64002A"` -> ('video/mp4', 'avc1.64002A')
  final semicolon = full.indexOf(';');
  final mimeType = (semicolon < 0 ? full : full.substring(0, semicolon)).trim();
  var codecs = '';
  if (semicolon >= 0) {
    final match =
        RegExp(r'codecs\s*=\s*"?([^";]+)"?').firstMatch(full.substring(semicolon));
    codecs = match?.group(1)?.trim() ?? '';
  }

  final init = raw['initRange'];
  final index = raw['indexRange'];

  final format = AdaptiveFormat(
    itag: _int(raw['itag']),
    url: url,
    mimeType: mimeType,
    codecs: codecs,
    bitrate: _int(raw['bitrate']) > 0
        ? _int(raw['bitrate'])
        : _int(raw['averageBitrate']),
    durationMs: _int(raw['approxDurationMs']),
    initStart: init is Map ? _int(init['start']) : 0,
    initEnd: init is Map ? _int(init['end']) : -1,
    indexStart: index is Map ? _int(index['start']) : 0,
    indexEnd: index is Map ? _int(index['end']) : -1,
    width: _int(raw['width']),
    height: _int(raw['height']),
    fps: _int(raw['fps']),
    audioSampleRate: _int(raw['audioSampleRate']),
    audioChannels: _int(raw['audioChannels']),
    audioTrackId: (raw['audioTrack'] is Map)
        ? (raw['audioTrack'] as Map)['id']?.toString()
        : null,
    audioIsDefault: (raw['audioTrack'] is Map)
        ? (raw['audioTrack'] as Map)['audioIsDefault'] == true
        : false,
  );
  return format.isUsable ? format : null;
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

/// Video codecs allowed into a generated manifest, and why AV1 is not.
///
/// AV1 is the only codec YouTube serves above 1080p for some videos, and it is
/// also the one most likely to fall to a *software* decoder on a mid-range
/// phone — where 4K AV1 does not decode in real time and playback stutters
/// rather than looking better. ExoPlayer would happily pick it. VP9 is
/// hardware-decoded on essentially every Android device since 2015 and reaches
/// 2160p, so excluding AV1 costs nothing and removes the one way this feature
/// could be worse than the 360p it replaces.
///
/// Same rule, and the same reason, as `_downloadableVideos` preferring AVC for
/// HD downloads: playable beats bigger.
const _allowedVideoCodecs = {'avc', 'vp9'};

/// Audio codecs allowed, best first.
///
/// AAC leads for the reason given in `YoutubePlayerClient._bestAudio` — it is
/// universally decodable and costs nothing worth having against Opus. Opus is
/// kept as a fallback because Android decodes it fine and some videos offer
/// nothing else.
const _audioCodecPreference = ['aac', 'opus'];

/// The heights a generated manifest will actually offer, highest first.
///
/// The app needs this because it cannot read the ladder back out of the
/// player: `better_player`'s ASMS parser only understands HLS — its `parse`
/// hands every manifest to the HLS parser regardless of format — so a DASH
/// source populates no track list. That is fine, because the app *generated*
/// the manifest and therefore already knows exactly what is in it. The quality
/// picker is fed from here, and switching rungs goes through `setTrack`, which
/// is just `setMaxVideoSize` on ExoPlayer's track selector and cares nothing
/// for how the manifest was parsed.
List<String> dashLadder(List<AdaptiveFormat> formats) {
  final heights = <int>{};
  for (final f in formats) {
    if (!f.isVideo || !f.isUsable) continue;
    if (!_allowedVideoCodecs.contains(f.codecFamily)) continue;
    if (f.height > 0) heights.add(f.height);
  }
  final sorted = heights.toList()..sort((a, b) => b.compareTo(a));
  return [for (final h in sorted) '${h}p'];
}

/// Builds a static DASH manifest, or null when these formats cannot make one.
///
/// Returns null rather than a half-manifest whenever there is not both a video
/// and an audio Representation to emit: a manifest with no audio plays silent,
/// which is worse than the 360p stream it would have replaced. The caller
/// falls back on null.
String? buildDashManifest(List<AdaptiveFormat> formats) {
  final usable = formats.where((f) => f.isUsable).toList();

  final videos = [
    for (final f in usable)
      if (f.isVideo &&
          _allowedVideoCodecs.contains(f.codecFamily) &&
          f.height > 0)
        f,
  ];
  final audios = _pickAudio(usable);
  if (videos.isEmpty || audios.isEmpty) return null;

  // The longest track wins. Video and audio durations differ by a few
  // milliseconds on almost every video, and declaring the shorter one would
  // clip the end off.
  var durationMs = 0;
  for (final f in [...videos, ...audios]) {
    if (f.durationMs > durationMs) durationMs = f.durationMs;
  }
  if (durationMs <= 0) return null;

  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" '
      'profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" '
      'type="static" mediaPresentationDuration="${_duration(durationMs)}" '
      'minBufferTime="PT1.5S">',
    )
    ..writeln('  <Period duration="${_duration(durationMs)}">');

  // One AdaptationSet per codec family. A set is the unit ExoPlayer adapts
  // within, and it can only switch between renditions a single decoder
  // handles — mixing AVC and VP9 in one set makes a stream that claims to be
  // switchable and is not.
  for (final family in _allowedVideoCodecs) {
    final group = videos.where((f) => f.codecFamily == family).toList()
      ..sort((a, b) => a.height.compareTo(b.height));
    if (group.isEmpty) continue;
    b
      ..writeln(
        '    <AdaptationSet mimeType="${group.first.mimeType}" '
        'contentType="video" segmentAlignment="true" '
        'subsegmentAlignment="true" startWithSAP="1" '
        'subsegmentStartsWithSAP="1" bitstreamSwitching="true">',
      )
      ..write(group.map(_videoRepresentation).join())
      ..writeln('    </AdaptationSet>');
  }

  // Audio is grouped by dub track so a video with alternate languages keeps
  // them apart; the player picks the default and the existing audio-track
  // picker can ask for another.
  final byTrack = <String?, List<AdaptiveFormat>>{};
  for (final f in audios) {
    byTrack.putIfAbsent(f.audioTrackId, () => []).add(f);
  }
  for (final entry in byTrack.entries) {
    final group = entry.value..sort((a, b) => a.bitrate.compareTo(b.bitrate));
    final isDefault = entry.key == null || group.any((f) => f.audioIsDefault);
    b
      ..writeln(
        '    <AdaptationSet mimeType="${group.first.mimeType}" '
        'contentType="audio" segmentAlignment="true" '
        'subsegmentAlignment="true" startWithSAP="1" '
        'subsegmentStartsWithSAP="1" bitstreamSwitching="true"'
        '${entry.key == null ? '' : ' lang="${_escape(entry.key!)}"'}>',
      )
      ..writeln(
        '      <Role schemeIdUri="urn:mpeg:dash:role:2011" '
        'value="${isDefault ? 'main' : 'alternate'}"/>',
      )
      ..write(group.map(_audioRepresentation).join())
      ..writeln('    </AdaptationSet>');
  }

  b
    ..writeln('  </Period>')
    ..writeln('</MPD>');
  return b.toString();
}

/// Audio renditions to include: every rung of the best codec family available.
///
/// All of one family rather than a single track, so ExoPlayer can drop the
/// audio bitrate on a weak connection instead of stalling the video.
List<AdaptiveFormat> _pickAudio(List<AdaptiveFormat> usable) {
  for (final family in _audioCodecPreference) {
    final group = [
      for (final f in usable)
        if (f.isAudio && f.codecFamily == family) f,
    ];
    if (group.isNotEmpty) return group;
  }
  return const [];
}

String _videoRepresentation(AdaptiveFormat f) => '      '
    '<Representation id="${f.itag}" codecs="${_escape(f.codecs)}" '
    'width="${f.width}" height="${f.height}" '
    '${f.fps > 0 ? 'frameRate="${f.fps}" ' : ''}'
    'bandwidth="${f.bitrate}">\n'
    '${_segmentBase(f)}'
    '      </Representation>\n';

String _audioRepresentation(AdaptiveFormat f) => '      '
    '<Representation id="${f.itag}" codecs="${_escape(f.codecs)}" '
    '${f.audioSampleRate > 0 ? 'audioSamplingRate="${f.audioSampleRate}" ' : ''}'
    'bandwidth="${f.bitrate}">\n'
    '        <AudioChannelConfiguration '
    'schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" '
    'value="${f.audioChannels > 0 ? f.audioChannels : 2}"/>\n'
    '${_segmentBase(f)}'
    '      </Representation>\n';

String _segmentBase(AdaptiveFormat f) => '        '
    '<BaseURL>${_escape(f.url)}</BaseURL>\n'
    '        <SegmentBase indexRange="${f.indexStart}-${f.indexEnd}" '
    'indexRangeExact="true">\n'
    '          <Initialization range="${f.initStart}-${f.initEnd}"/>\n'
    '        </SegmentBase>\n';

/// `PT123.456S`, the only duration format DASH accepts.
String _duration(int ms) {
  final seconds = ms / 1000.0;
  return 'PT${seconds.toStringAsFixed(3)}S';
}

/// XML-escapes a value for an element body or attribute.
///
/// This is the single most important line in the file. A googlevideo URL is
/// a query string of twenty-odd parameters joined by `&`, and an unescaped `&`
/// makes the document malformed — the whole manifest fails to parse and the
/// video does not play at all, which looks nothing like an escaping bug from
/// the outside.
String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
