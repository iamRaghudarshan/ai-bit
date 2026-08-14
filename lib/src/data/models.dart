import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

/// The lightweight video shape the whole app passes around.
///
/// Deliberately decoupled from `youtube_explode`'s `Video`: the same struct has
/// to survive a round trip through SQLite for history and playlists, and the
/// upstream model carries a live `WatchPage` reference that cannot be stored.
class VideoBrief {
  const VideoBrief({
    required this.id,
    required this.title,
    required this.author,
    required this.channelId,
    this.duration,
    this.viewCount,
    this.uploadDate,
    this.uploadRaw,
    this.isLive = false,
    this.isShort = false,
    this.isKids = false,
    this.avatarUrl,
  });

  final String id;
  final String title;
  final String author;
  final String channelId;
  final Duration? duration;
  final int? viewCount;
  final DateTime? uploadDate;
  final String? uploadRaw;
  final bool isLive;

  /// True for a vertical Short, so watch history can keep Shorts and regular
  /// videos apart.
  final bool isShort;

  /// True when watched in Kids mode, so kids history stays out of the normal
  /// videos and shorts history.
  final bool isKids;

  /// The channel's real avatar, when the response carried one. Null falls back
  /// to a coloured initial.
  final String? avatarUrl;

  /// Copy with a different avatar.
  ///
  /// The watch page rebuilds this from the player response once details load,
  /// and that response carries no channel thumbnail — so the avatar the feed
  /// row already had has to be carried across rather than dropped.
  VideoBrief withAvatar(String? url) => VideoBrief(
        id: id,
        title: title,
        author: author,
        channelId: channelId,
        duration: duration,
        viewCount: viewCount,
        uploadDate: uploadDate,
        uploadRaw: uploadRaw,
        isLive: isLive,
        isShort: isShort,
        isKids: isKids,
        avatarUrl: url ?? avatarUrl,
      );

  /// Copy tagged as a Short. The feed parsers do not always know, so the
  /// Shorts UI marks what it plays.
  VideoBrief asShort() => VideoBrief(
        id: id,
        title: title,
        author: author,
        channelId: channelId,
        duration: duration,
        viewCount: viewCount,
        uploadDate: uploadDate,
        uploadRaw: uploadRaw,
        isLive: isLive,
        isShort: true,
        isKids: isKids,
        avatarUrl: avatarUrl,
      );

  /// Copy tagged as watched in Kids mode; keeps whatever else it was.
  VideoBrief asKids() => VideoBrief(
        id: id,
        title: title,
        author: author,
        channelId: channelId,
        duration: duration,
        viewCount: viewCount,
        uploadDate: uploadDate,
        uploadRaw: uploadRaw,
        isLive: isLive,
        isShort: isShort,
        isKids: true,
        avatarUrl: avatarUrl,
      );

  /// 480x360 with letterboxing — the only thumbnail size YouTube guarantees
  /// exists for every video. `maxresdefault` 404s on a lot of older uploads.
  String get thumbUrl => 'https://i.ytimg.com/vi/$id/hqdefault.jpg';

  String get watchUrl => 'https://www.youtube.com/watch?v=$id';

  factory VideoBrief.fromYt(yt.Video v) => VideoBrief(
    id: v.id.value,
    title: v.title,
    author: v.author,
    channelId: v.channelId.value,
    duration: v.duration,
    viewCount: v.engagement.viewCount,
    uploadDate: v.uploadDate,
    uploadRaw: v.uploadDateRaw,
    isLive: v.isLive,
  );

  Map<String, Object?> toMap() => {
    'video_id': id,
    'title': title,
    'author': author,
    'channel_id': channelId,
    'duration_ms': duration?.inMilliseconds,
    'view_count': viewCount,
    'upload_raw': uploadRaw,
    // Stored and read back as UTC so a device timezone change cannot shift
    // a stored upload date.
    'upload_date': uploadDate?.toUtc().millisecondsSinceEpoch,
    'is_live': isLive ? 1 : 0,
    'is_short': isShort ? 1 : 0,
    'is_kids': isKids ? 1 : 0,
  };

  factory VideoBrief.fromMap(Map<String, Object?> m) => VideoBrief(
    id: m['video_id']! as String,
    title: (m['title'] as String?) ?? '',
    author: (m['author'] as String?) ?? '',
    channelId: (m['channel_id'] as String?) ?? '',
    duration: m['duration_ms'] == null
        ? null
        : Duration(milliseconds: m['duration_ms']! as int),
    viewCount: m['view_count'] as int?,
    uploadRaw: m['upload_raw'] as String?,
    uploadDate: m['upload_date'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            m['upload_date']! as int,
            isUtc: true,
          ),
    isLive: (m['is_live'] as int? ?? 0) == 1,
    isShort: (m['is_short'] as int? ?? 0) == 1,
    isKids: (m['is_kids'] as int? ?? 0) == 1,
  );

  @override
  bool operator ==(Object other) => other is VideoBrief && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// A history row: the video plus where playback stopped.
class HistoryEntry {
  const HistoryEntry({
    required this.video,
    required this.position,
    required this.watchedAt,
  });

  final VideoBrief video;
  final Duration position;
  final DateTime watchedAt;

  /// 0..1, used to draw the red resume bar under the thumbnail.
  double get progress {
    final total = video.duration?.inMilliseconds ?? 0;
    if (total <= 0) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0);
  }
}

/// A user-created local playlist. [id] 1 is reserved for Watch Later.
class LocalPlaylist {
  const LocalPlaylist({
    required this.id,
    required this.name,
    required this.itemCount,
    this.coverVideoId,
  });

  static const watchLaterId = 1;

  final int id;
  final String name;
  final int itemCount;
  final String? coverVideoId;

  bool get isWatchLater => id == watchLaterId;
}

/// A YouTube channel, as shown on its own page.
class ChannelInfo {
  const ChannelInfo({
    required this.id,
    required this.title,
    this.avatarUrl,
    this.subscriberLabel,
  });

  final String id;
  final String title;
  final String? avatarUrl;

  /// Pre-rendered by YouTube, e.g. "1.2M subscribers". Kept as text because
  /// the exact wording varies by locale and channel type.
  final String? subscriberLabel;
}

/// A playlist on YouTube (not one of the local ones).
class PlaylistBrief {
  const PlaylistBrief({
    required this.id,
    required this.title,
    this.videoCount,
    this.thumbnailUrl,
    this.channelId,
  });

  final String id;
  final String title;
  final int? videoCount;
  final String? thumbnailUrl;
  final String? channelId;

  String get shareUrl => 'https://www.youtube.com/playlist?list=$id';
}

enum DownloadStatus { queued, running, completed, failed }

/// A video saved to device storage for offline playback.
class DownloadRecord {
  const DownloadRecord({
    required this.video,
    required this.filePath,
    required this.quality,
    required this.audioOnly,
    required this.totalBytes,
    required this.receivedBytes,
    required this.status,
    this.error,
  });

  final VideoBrief video;
  final String filePath;

  /// `360p`, `Audio`, … — what the user sees in the downloads list.
  final String quality;
  final bool audioOnly;

  /// 0 while the size is still unknown.
  final int totalBytes;
  final int receivedBytes;
  final DownloadStatus status;
  final String? error;

  bool get isComplete => status == DownloadStatus.completed;

  /// 0..1, or null when the total size is not known yet so the UI can show an
  /// indeterminate spinner instead of a bar stuck at zero.
  double? get progress {
    if (isComplete) return 1;
    if (totalBytes <= 0) return null;
    return (receivedBytes / totalBytes).clamp(0.0, 1.0);
  }

  DownloadRecord copyWith({
    int? totalBytes,
    int? receivedBytes,
    DownloadStatus? status,
    String? error,
  }) => DownloadRecord(
    video: video,
    filePath: filePath,
    quality: quality,
    audioOnly: audioOnly,
    totalBytes: totalBytes ?? this.totalBytes,
    receivedBytes: receivedBytes ?? this.receivedBytes,
    status: status ?? this.status,
    error: error ?? this.error,
  );

  Map<String, Object?> toMap() => {
    ...video.toMap(),
    'file_path': filePath,
    'quality': quality,
    'audio_only': audioOnly ? 1 : 0,
    'total_bytes': totalBytes,
    'received_bytes': receivedBytes,
    'status': status.name,
    'error': error,
    'created_at': DateTime.now().millisecondsSinceEpoch,
  };

  factory DownloadRecord.fromMap(Map<String, Object?> m) => DownloadRecord(
    video: VideoBrief.fromMap(m),
    filePath: m['file_path']! as String,
    quality: (m['quality'] as String?) ?? '',
    audioOnly: (m['audio_only'] as int? ?? 0) == 1,
    totalBytes: m['total_bytes'] as int? ?? 0,
    receivedBytes: m['received_bytes'] as int? ?? 0,
    status: DownloadStatus.values.firstWhere(
      (s) => s.name == m['status'],
      orElse: () => DownloadStatus.failed,
    ),
    error: m['error'] as String?,
  );
}

/// One choice in the download picker, with its real size.
class DownloadOption {
  const DownloadOption({
    required this.audioOnly,
    required this.quality,
    required this.label,
    required this.detail,
    required this.bytes,
    required this.fileExtension,
    this.needsFfmpeg = false,
  });

  final bool audioOnly;

  /// The spec the download acts on and persists: `360p`, `1080p`, `Audio` or
  /// `MP3`. What the user picked, distinct from the human [label].
  final String quality;

  /// `360p` or `Audio only`.
  final String label;
  final String detail;
  final int bytes;
  final String fileExtension;

  /// Whether this rendition has to be joined or converted after downloading,
  /// so the picker can gray it out where the native library is missing.
  final bool needsFfmpeg;
}

/// A resolved, downloadable rendition. [handle] is the opaque upstream stream
/// descriptor the repository needs to open a byte stream.
class DownloadTarget {
  const DownloadTarget({
    required this.handle,
    required this.totalBytes,
    required this.quality,
    required this.fileExtension,
    required this.audioOnly,
    this.audioHandle,
    this.audioBytes = 0,
    this.toMp3 = false,
  });

  final Object handle;
  final int totalBytes;
  final String quality;
  final String fileExtension;
  final bool audioOnly;

  /// Audio track to join to [handle] after both have downloaded.
  ///
  /// Above 360p YouTube only serves video and audio separately, so anything
  /// HD arrives as two files that have to be combined. Null when [handle] is
  /// already complete on its own.
  final Object? audioHandle;

  /// Size of [audioHandle], counted into the progress so the bar reflects
  /// everything being fetched rather than jumping when the second file starts.
  final int audioBytes;

  /// Re-encode the audio to MP3 once downloaded.
  final bool toMp3;

  bool get needsMux => audioHandle != null;

  /// Total across both files.
  int get downloadBytes => totalBytes + audioBytes;
}

/// Everything needed to hand a video to the player.
class PlaybackSources {
  const PlaybackSources({
    required this.url,
    required this.qualities,
    this.audioOnlyUrl,
    this.isHls = false,
    this.isLive = false,
    this.videoUnavailable = false,
  });

  /// The stream the player opens with.
  final String url;

  /// `{'720p': url, '360p': url}` — feeds the in-player quality switcher.
  final Map<String, String> qualities;

  /// Audio-only rendition, used by the data-saver toggle.
  final String? audioOnlyUrl;

  final bool isHls;

  /// Live streams have no duration and cannot be seeked past the edge; the
  /// player needs telling so it shows a LIVE badge instead of a broken bar.
  final bool isLive;

  /// True when we fell back to audio because YouTube offered no combined
  /// video+audio stream for this video at all. The UI surfaces this rather
  /// than leaving the user staring at a black frame.
  final bool videoUnavailable;
}
