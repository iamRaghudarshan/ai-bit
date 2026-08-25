import 'package:flutter/foundation.dart';

import 'db.dart';
import 'kids_guard.dart';
import 'models.dart';
import 'settings.dart';

/// Per-channel data accounting for the usage screen.
///
/// Two very different numbers land in the same table. Downloads are **exact**:
/// every byte is counted as it passes through the download manager. Streaming is
/// an **estimate** — the native player opens the googlevideo URL itself, so no
/// Dart code ever sees those bytes and there is nothing to count. What is
/// stored for a stream is watched-duration times an approximate bitrate for
/// the rendition, which is why the screen must never present it as a carrier
/// figure: a 30% error either way is entirely possible, and re-buffering,
/// seeking and prefetch are invisible to it.
class DataUsageService {
  DataUsageService({
    required AppDatabase database,
    required SettingsService settings,
  })  : _db = database,
        // Named _config, not _settings, so the constructor keeps a plain
        // parameter instead of tripping prefer_initializing_formals on a name
        // that cannot be an initialising formal (private, and named).
        _config = settings;

  final AppDatabase _db;
  final SettingsService _config;

  /// Rough delivered bitrate in Mbps per ladder rung, from what YouTube
  /// actually serves for these heights. Deliberately a table and not a formula
  /// — the jump from 360p to 720p is not linear in pixels.
  static const _rungMbps = <int, double>{
    144: 0.09,
    240: 0.2,
    360: 0.75,
    480: 1.2,
    720: 2.5,
    1080: 4.5,
    1440: 9.0,
    2160: 18.0,
  };

  /// AAC/Opus audio-only, which is what audio-only mode and Data saver pull.
  static const _audioMbps = 0.13;

  /// Auto has no fixed rung. Where an HLS ladder exists the player settles
  /// somewhere in the middle, and where it does not the only combined stream
  /// left is 360p — so 720p splits the difference. The coarsest guess inside
  /// an already-approximate number.
  static const _autoMbps = 2.5;

  /// The `data_usage.day` key: the local calendar day as a UTC day index.
  /// Borrowed from [KidsGuard] rather than reimplemented — the two tables must
  /// bucket identically, and the off-by-one-day trap that comment describes is
  /// worth solving exactly once.
  static int _today() => KidsGuard.daysSinceEpoch(DateTime.now());

  /// Estimated bytes for [watched] at [quality].
  ///
  /// Pure and static so it can be unit-tested and called from a UI preview
  /// without a database. [quality] is any spec the app already passes around:
  /// `360p`, `1080p`, `Auto`, `Audio`, `MP3`, or an HLS track label with a
  /// height in it.
  ///
  /// An estimate, not a measurement — see the class comment. Nothing here can
  /// observe the player's real traffic.
  static int estimateStreamBytes(Duration watched, String quality) {
    if (watched <= Duration.zero) return 0;
    final mbps = _mbpsFor(quality);
    final seconds = watched.inMilliseconds / 1000;
    // Mbps is decimal megabits, as carriers and YouTube both quote it.
    return (mbps * 1000000 / 8 * seconds).round();
  }

  static double _mbpsFor(String quality) {
    final spec = quality.toLowerCase();
    if (spec.contains('audio') || spec.contains('mp3')) return _audioMbps;
    final height = _heightIn(spec);
    if (height == null || height == 0) return _autoMbps;
    // Nearest rung rather than an exact lookup: an unknown height should still
    // cost roughly what its neighbours do instead of falling back to Auto.
    var best = _rungMbps.entries.first;
    for (final entry in _rungMbps.entries) {
      if ((entry.key - height).abs() < (best.key - height).abs()) best = entry;
    }
    return best.value;
  }

  /// The vertical resolution named by a quality spec, or null when it names
  /// none (`Auto`, an empty string, a word).
  ///
  /// This deliberately does NOT strip every non-digit and parse what is left,
  /// which is what it used to do. That fused both halves of the two shapes
  /// YouTube actually hands us and priced them off the top of the ladder:
  /// `1080p60` (youtube_explode's qualityLabel for any 60fps stream) became
  /// 108060 and `1280x720` (an HLS track label) became 1280720, and both
  /// snapped to the 2160p rung — charging a 1080p60 stream 4x and a 720p
  /// track 7x what they cost.
  static int? _heightIn(String spec) {
    // `WIDTHxHEIGHT` first: the height is the half after the separator, so a
    // plain "first run of digits" rule would read the width instead.
    final sized = RegExp(r'(\d+)\s*[x\u00d7]\s*(\d+)').firstMatch(spec);
    if (sized != null) return int.tryParse(sized.group(2)!);
    // Otherwise the leading run of digits is the height and anything after it
    // is a frame rate or other suffix to ignore: `1080p60` is 1080.
    final digits = RegExp(r'\d+').firstMatch(spec);
    return digits == null ? null : int.tryParse(digits.group(0)!);
  }

  /// Books an estimated stream cost against [video]'s channel.
  ///
  /// Call it with the watched delta since the last call, not the total
  /// position — the table accumulates, so passing a running total would count
  /// the same seconds again on every tick.
  Future<void> recordStream({
    required VideoBrief video,
    required Duration watched,
    required String quality,
  }) async {
    if (!_config.trackDataUsage) return;
    await _record(
      video: video,
      bytes: estimateStreamBytes(watched, quality),
      kind: 'stream',
    );
  }

  /// Books an exact download cost against [video]'s channel. Unlike
  /// [recordStream] these bytes really passed through our code.
  Future<void> recordDownload({
    required VideoBrief video,
    required int bytes,
  }) async {
    if (!_config.trackDataUsage) return;
    await _record(video: video, bytes: bytes, kind: 'download');
  }

  Future<void> _record({
    required VideoBrief video,
    required int bytes,
    required String kind,
  }) async {
    if (bytes <= 0 || video.channelId.isEmpty) return;
    try {
      await _db.addDataUsage(
        day: _today(),
        channelId: video.channelId,
        channelTitle: video.author,
        bytes: bytes,
        kind: kind,
      );
    } catch (e) {
      // Swallowed on purpose, and logged so it is not a silent dead feature:
      // this is bookkeeping. A locked database or a failed write must never
      // interrupt playback or undo a download that already finished.
      debugPrint('AI BIT: data usage not recorded ($kind) — $e');
    }
  }

  /// Usage over the last [days] days, heaviest channel first. The day-key
  /// arithmetic lives here so no caller has to repeat it.
  Future<List<DataUsageRow>> byChannel({int days = 30}) =>
      _db.dataUsageByChannel(sinceDay: _today() - (days - 1));

  /// Total bytes over the last [days] days, optionally for `stream` or
  /// `download` alone.
  Future<int> total({int days = 30, String? kind}) =>
      _db.dataUsageTotal(sinceDay: _today() - (days - 1), kind: kind);
}
