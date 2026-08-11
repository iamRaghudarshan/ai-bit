/// A titled point in a video, taken from timestamps in the description.
class VideoChapter {
  const VideoChapter({required this.start, required this.title});

  final Duration start;
  final String title;
}

/// Extracts chapters from a video description.
///
/// YouTube does not return a chapter list in any response this app can reach —
/// it derives them from the description exactly like this, and only honours
/// them when the first timestamp is 0:00 and there are at least three. Those
/// same rules are applied here so the app does not invent chapters for a
/// description that merely happens to mention a time.
List<VideoChapter> parseChapters(String description) {
  if (description.trim().isEmpty) return const [];

  // A timestamp at the start of a line, then the title after it.
  final pattern = RegExp(
    r'^\s*\(?(\d{1,2}:\d{2}(?::\d{2})?)\)?[\s\-–—:.]*(.*)$',
    multiLine: true,
  );

  final found = <VideoChapter>[];
  for (final match in pattern.allMatches(description)) {
    final stamp = match.group(1);
    final title = (match.group(2) ?? '').trim();
    if (stamp == null || title.isEmpty) continue;

    final start = _parseStamp(stamp);
    if (start == null) continue;

    // Timestamps must advance; a list that jumps backwards is a track listing
    // for something else, not chapters for this video.
    if (found.isNotEmpty && start <= found.last.start) continue;

    found.add(VideoChapter(start: start, title: title));
  }

  if (found.length < 3) return const [];
  if (found.first.start != Duration.zero) return const [];
  return found;
}

Duration? _parseStamp(String stamp) {
  final parts = stamp.split(':').map(int.tryParse).toList();
  if (parts.any((p) => p == null)) return null;
  final n = parts.cast<int>();
  return switch (n.length) {
    3 => Duration(hours: n[0], minutes: n[1], seconds: n[2]),
    2 => Duration(minutes: n[0], seconds: n[1]),
    _ => null,
  };
}

/// The chapter covering [position], or null when there are none.
VideoChapter? chapterAt(List<VideoChapter> chapters, Duration position) {
  VideoChapter? current;
  for (final chapter in chapters) {
    if (chapter.start <= position) {
      current = chapter;
    } else {
      break;
    }
  }
  return current;
}
