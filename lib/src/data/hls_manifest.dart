/// Builds an HLS manifest out of YouTube's `adaptiveFormats`, for iOS.
///
/// This is the iPhone half of what `dash_manifest.dart` does for Android, and
/// it exists because the note at the top of that file used to end with a
/// shrug: "generating HLS from these formats means parsing each track's `sidx`
/// box to emit byte-range segment lists. So iOS keeps the old behaviour — the
/// HLS ladder when YouTube offers one, 360p when it does not."
///
/// That left iOS on **360p for roughly seven videos in eight**, since
/// `hlsManifestUrl` now comes back for about one in eight. AVPlayer genuinely
/// cannot play DASH and never will, so the Android route is closed here. But
/// AVPlayer has played **fragmented MP4 over HLS with byte-range segments**
/// since iOS 10, and that is exactly the shape YouTube's adaptive tracks
/// already have: one long `.mp4` per rendition, an `initRange` holding the
/// `moov`, and an `indexRange` holding a `sidx` box that lists every fragment's
/// size and duration in order.
///
/// So no transcoding, no muxing and no downloading is needed — only arithmetic.
/// Fetch the few kilobytes of `indexRange`, read the `sidx`, and the byte
/// offsets of every fragment fall out. Written as an HLS playlist those become
/// `#EXT-X-BYTERANGE` segments pointing straight at googlevideo, and AVPlayer
/// fetches them itself at full speed. The playlists are the only thing this app
/// serves; not one video byte passes through Dart.
///
/// **AVC and AAC only, and that restriction is load-bearing.** Android's
/// manifest is allowed VP9 because ExoPlayer decodes it in hardware
/// everywhere; AVPlayer decodes neither VP9 nor Opus, so a variant naming
/// either is not a lesser rendition but a broken one. In practice YouTube
/// offers `avc1` up to 1080p (above that it is AV1 only — see
/// `_downloadableVideos`, which caps HD downloads for the same reason), so iOS
/// gets a real 144p–1080p ladder where it had a single 360p stream. Capping at
/// 1080p is the price of playing at all.
///
/// Pure — no I/O, no platform calls — so every rule below is pinned by a test.
/// The caller does the two things that cannot be pure: fetching each track's
/// index range, and publishing the result (see `hls_server.dart`).
library;

import 'dart:typed_data';

import 'dash_manifest.dart';

/// One fragment of a rendition: where it is in the file and how long it plays.
class MediaSegment {
  const MediaSegment({
    required this.offset,
    required this.size,
    required this.durationUs,
  });

  /// Absolute byte offset into the rendition's URL.
  final int offset;
  final int size;
  final int durationUs;

  double get durationSeconds => durationUs / 1000000.0;
}

/// A parsed `sidx`: every fragment of one rendition, in play order.
class SegmentIndex {
  const SegmentIndex(this.segments);

  final List<MediaSegment> segments;

  bool get isEmpty => segments.isEmpty;

  double get longestSegmentSeconds {
    var longest = 0.0;
    for (final s in segments) {
      if (s.durationSeconds > longest) longest = s.durationSeconds;
    }
    return longest;
  }
}

/// Reads the `sidx` box in [bytes] — the body of the track's `indexRange`.
///
/// Returns null for anything it cannot turn into a flat list of byte ranges,
/// which the caller treats as "this rendition is not usable" rather than as an
/// error. A half-read index would produce a playlist that plays a few seconds
/// and then fails, which is far worse than falling back to the 360p stream.
///
/// [indexStart] is where [bytes] begins in the real file, and it is required
/// because `sidx` offsets are relative to the end of the `sidx` box itself —
/// the absolute offset of the first fragment is
/// `indexStart + (bytes consumed by the sidx box) + first_offset`. Getting that
/// anchor wrong does not fail loudly: it yields ranges that are *valid HTTP
/// requests for the wrong bytes*, so googlevideo answers 206 with data that is
/// not a fragment, and the only symptom is a video that will not start.
SegmentIndex? parseSegmentIndex(Uint8List bytes, {required int indexStart}) {
  final data = ByteData.sublistView(bytes);

  // Walk the top-level boxes. The index range usually holds `sidx` first, but
  // some responses put `ssix` (a sub-fragment index we have no use for) either
  // side of it, so this scans rather than assuming position zero.
  var pos = 0;
  while (pos + 8 <= bytes.length) {
    var boxSize = data.getUint32(pos);
    final type = String.fromCharCodes(bytes, pos + 4, pos + 8);
    var header = 8;
    if (boxSize == 1) {
      if (pos + 16 > bytes.length) return null;
      final large = data.getUint64(pos + 8);
      if (large > bytes.length) return null;
      boxSize = large;
      header = 16;
    } else if (boxSize == 0) {
      // "To the end of the file" — legal, and the last box if it appears.
      boxSize = bytes.length - pos;
    }
    if (boxSize < header || pos + boxSize > bytes.length) return null;

    if (type == 'sidx') {
      return _parseSidxBody(
        data,
        bodyStart: pos + header,
        boxEnd: pos + boxSize,
        // Where the byte after this box sits in the real file.
        anchor: indexStart + pos + boxSize,
      );
    }
    pos += boxSize;
  }
  return null;
}

SegmentIndex? _parseSidxBody(
  ByteData data, {
  required int bodyStart,
  required int boxEnd,
  required int anchor,
}) {
  // FullBox: one version byte then three flag bytes.
  var p = bodyStart;
  if (p + 4 > boxEnd) return null;
  final version = data.getUint8(p);
  p += 4;

  // reference_ID, timescale
  if (p + 8 > boxEnd) return null;
  p += 4;
  final timescale = data.getUint32(p);
  p += 4;
  if (timescale == 0) return null;

  // earliest_presentation_time and first_offset widen to 64-bit at version 1.
  final int firstOffset;
  if (version == 0) {
    if (p + 8 > boxEnd) return null;
    p += 4;
    firstOffset = data.getUint32(p);
    p += 4;
  } else {
    if (p + 16 > boxEnd) return null;
    p += 8;
    firstOffset = data.getUint64(p);
    p += 8;
  }

  // reserved(16), reference_count(16)
  if (p + 4 > boxEnd) return null;
  p += 2;
  final count = data.getUint16(p);
  p += 2;
  if (count == 0) return null;
  if (p + count * 12 > boxEnd) return null;

  final segments = <MediaSegment>[];
  var offset = anchor + firstOffset;
  for (var i = 0; i < count; i++) {
    final first = data.getUint32(p);
    // The top bit says whether this entry points at media or at *another*
    // `sidx`. A hierarchical index would need another fetch per level to
    // resolve, so it is declined outright rather than half-handled; YouTube
    // has only ever served the flat form.
    if (first >> 31 == 1) return null;
    final size = first & 0x7FFFFFFF;
    final duration = data.getUint32(p + 4);
    p += 12;
    if (size <= 0) return null;
    segments.add(
      MediaSegment(
        offset: offset,
        size: size,
        durationUs: (duration * 1000000) ~/ timescale,
      ),
    );
    offset += size;
  }
  return SegmentIndex(segments);
}

/// A rendition with its index read: everything needed to write its playlist.
class HlsTrack {
  const HlsTrack(this.format, this.index);

  final AdaptiveFormat format;
  final SegmentIndex index;
}

/// Video codecs AVPlayer can decode from a generated manifest.
///
/// Deliberately narrower than `dash_manifest.dart`'s set. VP9 is absent
/// because AVPlayer cannot decode it at all — there is no software fallback to
/// be slow, the variant simply fails — and AV1 is absent for both that reason
/// and the decode-cost one.
const _videoCodecs = {'avc'};

/// Audio codecs, best first. AAC is the only one AVPlayer decodes here; Opus
/// is as unplayable as VP9, so there is no fallback entry to add.
const _audioCodecs = ['aac'];

/// Which formats are worth fetching an index for, highest rung first.
///
/// Called *before* any network work precisely so that none is wasted: each
/// track needs its own ranged request for `indexRange`, so the selection is
/// made on the metadata that already arrived. One AVC rendition per height —
/// the highest bitrate of that height — plus the best AAC audio track, and the
/// audio track is last so a caller that has to truncate the list keeps the
/// ladder's top.
///
/// Returns an empty list when there is not both video and audio to offer: a
/// silent 1080p stream is worse than the 360p one it would replace, the same
/// judgement `buildDashManifest` makes by returning null.
List<AdaptiveFormat> hlsCandidates(List<AdaptiveFormat> formats) {
  final usable = formats.where((f) => f.isUsable).toList();

  final byHeight = <int, AdaptiveFormat>{};
  for (final f in usable) {
    if (!f.isVideo || f.height <= 0) continue;
    if (!_videoCodecs.contains(f.codecFamily)) continue;
    final held = byHeight[f.height];
    if (held == null || f.bitrate > held.bitrate) byHeight[f.height] = f;
  }

  final audio = _pickAudio(usable);
  if (byHeight.isEmpty || audio == null) return const [];

  final videos = byHeight.values.toList()
    ..sort((a, b) => b.height.compareTo(a.height));
  return [...videos, audio];
}

/// The single best AAC track, by bitrate, preferring the default dub.
///
/// One audio rendition rather than the whole family, unlike the DASH manifest.
/// Alternate dubs would each need their own `EXT-X-MEDIA` entry and their own
/// index fetch, and the audio-track picker is a separate feature that still
/// has the progressive path; adding a round trip per language to every video
/// open is not worth it here.
AdaptiveFormat? _pickAudio(List<AdaptiveFormat> usable) {
  for (final family in _audioCodecs) {
    final group = [
      for (final f in usable)
        if (f.isAudio && f.codecFamily == family) f,
    ];
    if (group.isEmpty) continue;
    group.sort((a, b) {
      // A video with dubs marks one track default; that is the one whose
      // language matches the video, so it leads regardless of bitrate.
      if (a.audioIsDefault != b.audioIsDefault) return a.audioIsDefault ? -1 : 1;
      if ((a.audioTrackId == null) != (b.audioTrackId == null)) {
        return a.audioTrackId == null ? -1 : 1;
      }
      return b.bitrate.compareTo(a.bitrate);
    });
    return group.first;
  }
  return null;
}

/// The playlists to publish, plus the ladder they describe.
class GeneratedHls {
  const GeneratedHls({
    required this.master,
    required this.media,
    required this.ladder,
  });

  /// The multivariant playlist. This is the one the player is handed.
  final String master;

  /// Filename to playlist body, for every variant the master references.
  final Map<String, String> media;

  /// Heights offered, highest first (`['1080p', '720p', ...]`).
  final List<String> ladder;
}

/// Builds the playlists, or null when these tracks cannot make a working set.
///
/// Null rather than a partial manifest, for the reason given in
/// `hlsCandidates`: the caller's next step is the 360p progressive stream,
/// which is the right answer whenever this cannot be done properly.
GeneratedHls? buildHls(List<HlsTrack> tracks) {
  final videos = [
    for (final t in tracks)
      if (t.format.isVideo &&
          t.format.height > 0 &&
          _videoCodecs.contains(t.format.codecFamily) &&
          !t.index.isEmpty)
        t,
  ]..sort((a, b) => b.format.height.compareTo(a.format.height));

  final audios = [
    for (final t in tracks)
      if (t.format.isAudio &&
          _audioCodecs.contains(t.format.codecFamily) &&
          !t.index.isEmpty)
        t,
  ]..sort((a, b) => b.format.bitrate.compareTo(a.format.bitrate));

  if (videos.isEmpty || audios.isEmpty) return null;
  final audio = audios.first;

  final media = <String, String>{audioPlaylistName: _mediaPlaylist(audio)};
  final master = StringBuffer()
    ..writeln('#EXTM3U')
    // Version 7 is what fragmented MP4 requires: `EXT-X-MAP` carrying an
    // initialisation segment, and a `BYTERANGE` attribute on it.
    ..writeln('#EXT-X-VERSION:7')
    ..writeln('#EXT-X-INDEPENDENT-SEGMENTS')
    ..writeln(
      '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="$_audioGroup",NAME="Audio",'
      'DEFAULT=YES,AUTOSELECT=YES,URI="$audioPlaylistName"',
    );

  for (final v in videos) {
    final name = videoPlaylistName(v.format);
    media[name] = _mediaPlaylist(v);
    final f = v.format;
    // BANDWIDTH must cover video plus audio, since that is what the client
    // will actually be pulling for this variant. Understating it is how an
    // adaptive player talks itself into a rung the connection cannot carry.
    final bandwidth = f.bitrate + audio.format.bitrate;
    master
      ..writeln(
        '#EXT-X-STREAM-INF:BANDWIDTH=$bandwidth,'
        'AVERAGE-BANDWIDTH=$bandwidth,'
        'CODECS="${f.codecs},${audio.format.codecs}",'
        'RESOLUTION=${f.width}x${f.height}'
        '${f.fps > 0 ? ',FRAME-RATE=${f.fps.toStringAsFixed(3)}' : ''}'
        ',AUDIO="$_audioGroup"',
      )
      ..writeln(name);
  }

  return GeneratedHls(
    master: master.toString(),
    media: media,
    ladder: [for (final v in videos) '${v.format.height}p'],
  );
}

const _audioGroup = 'aud';

/// Filename for the audio variant inside a published set.
const audioPlaylistName = 'a.m3u8';

/// Filename for a video rendition's variant playlist.
///
/// Keyed by itag rather than by height so two renditions of the same height
/// can never collide into one file — YouTube does ship both 30fps and 60fps
/// 1080p, and `hlsCandidates` only picks one per height *today*.
String videoPlaylistName(AdaptiveFormat format) => 'v${format.itag}.m3u8';

/// One rendition's media playlist: a single remote file, addressed in pieces.
///
/// Every segment line names the same URL and differs only in its byte range,
/// which is the whole trick — there is one `.mp4` on googlevideo and HLS is
/// perfectly happy to describe it as a sequence of ranges.
///
/// Offsets are written explicitly on every `EXT-X-BYTERANGE` rather than using
/// the shorthand that continues from the previous segment. The fragments are in
/// fact contiguous, so the shorthand would be correct — but it makes every
/// segment's position depend on the one before it, so a single wrong length
/// silently slides the whole rest of the playlist instead of breaking one
/// segment.
String _mediaPlaylist(HlsTrack track) {
  final f = track.format;
  final b = StringBuffer()
    ..writeln('#EXTM3U')
    ..writeln('#EXT-X-VERSION:7')
    ..writeln('#EXT-X-PLAYLIST-TYPE:VOD')
    ..writeln('#EXT-X-INDEPENDENT-SEGMENTS')
    // Must be at least the longest segment, and an integer. Rounded up, never
    // down: a target duration below the real maximum is a spec violation that
    // AVPlayer is entitled to reject the playlist over.
    ..writeln(
      '#EXT-X-TARGETDURATION:${track.index.longestSegmentSeconds.ceil()}',
    )
    ..writeln('#EXT-X-MEDIA-SEQUENCE:0')
    // The `moov` box. Without it the fragments are undecodable: this is where
    // the codec configuration lives.
    ..writeln(
      '#EXT-X-MAP:URI="${f.url}",'
      'BYTERANGE="${f.initEnd - f.initStart + 1}@${f.initStart}"',
    );

  for (final s in track.index.segments) {
    b
      ..writeln('#EXTINF:${s.durationSeconds.toStringAsFixed(5)},')
      ..writeln('#EXT-X-BYTERANGE:${s.size}@${s.offset}')
      ..writeln(f.url);
  }

  b.writeln('#EXT-X-ENDLIST');
  return b.toString();
}
