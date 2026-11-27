/// YouTube's scrub-preview storyboards: what the seek bar shows above the
/// thumb while dragging.
///
/// The player response carries `storyboards.playerStoryboardSpecRenderer.spec`,
/// one string of `|`-separated parts. The first is a URL template; every part
/// after it is one resolution level, `#`-separated:
///
///     width#height#count#columns#rows#intervalMs#name#sigh
///
/// e.g. `160#90#108#5#5#2000#M$M#rs$AOn4…`. A level's frames are tiled into
/// sprite sheets of `columns × rows`; sheet `n` of level `L` is the template
/// with `$L` → `L`, `$N` → the name with `$M` → `n`, plus `&sigh=<sigh>`.
/// `intervalMs` is the time between frames; 0 (only ever on the tiny
/// `default` level) means the frames are spread evenly over the video.
///
/// Measured live on 27 November 2026 (scratch probe against the `ios` and
/// `android` clients this app uses): both return a three-level spec, the
/// largest 160×90 at 2 s per frame, 5×5 per sheet, and the sheet URL built
/// this way answers 200 with an image. Pure — no I/O — so every rule here is
/// pinned by a test.
library;

class StoryboardLevel {
  const StoryboardLevel({
    required this.index,
    required this.width,
    required this.height,
    required this.count,
    required this.columns,
    required this.rows,
    required this.intervalMs,
    required this.name,
    required this.sigh,
  });

  /// Position in the spec, which is what `$L` is replaced with.
  final int index;
  final int width;
  final int height;
  final int count;
  final int columns;
  final int rows;
  final int intervalMs;
  final String name;
  final String sigh;

  int get perSheet => columns * rows;
}

/// One frame: which sheet to load and where in it the frame sits.
class StoryboardFrame {
  const StoryboardFrame({
    required this.url,
    required this.column,
    required this.row,
    required this.level,
  });

  final String url;
  final int column;
  final int row;
  final StoryboardLevel level;

  @override
  bool operator ==(Object other) =>
      other is StoryboardFrame &&
      other.url == url &&
      other.column == column &&
      other.row == row;

  @override
  int get hashCode => Object.hash(url, column, row);
}

class Storyboard {
  const Storyboard({required this.template, required this.levels});

  final String template;
  final List<StoryboardLevel> levels;

  /// Null for a missing or malformed spec — a video simply has no previews
  /// then, which is the right failure for a nicety.
  static Storyboard? parse(String? spec) {
    if (spec == null || spec.isEmpty) return null;
    final parts = spec.split('|');
    if (parts.length < 2) return null;
    final template = parts.first;
    if (!template.startsWith('http')) return null;
    final levels = <StoryboardLevel>[];
    for (var i = 1; i < parts.length; i++) {
      final f = parts[i].split('#');
      if (f.length < 8) continue;
      final width = int.tryParse(f[0]);
      final height = int.tryParse(f[1]);
      final count = int.tryParse(f[2]);
      final columns = int.tryParse(f[3]);
      final rows = int.tryParse(f[4]);
      final interval = int.tryParse(f[5]);
      if (width == null ||
          height == null ||
          count == null ||
          columns == null ||
          rows == null ||
          interval == null ||
          width <= 0 ||
          height <= 0 ||
          count <= 0 ||
          columns <= 0 ||
          rows <= 0 ||
          interval < 0) {
        continue;
      }
      levels.add(StoryboardLevel(
        index: i - 1,
        width: width,
        height: height,
        count: count,
        columns: columns,
        rows: rows,
        intervalMs: interval,
        name: f[6],
        // The signature may itself contain '#'? It does not today, but keep
        // whatever followed the seventh separator rather than truncating it.
        sigh: f.sublist(7).join('#'),
      ));
    }
    if (levels.isEmpty) return null;
    return Storyboard(template: template, levels: levels);
  }

  /// The largest level — the one worth showing at 160×90.
  StoryboardLevel get best =>
      levels.reduce((a, b) => b.width * b.height > a.width * a.height ? b : a);

  /// The frame nearest [at] in a video [total] long, from [best].
  StoryboardFrame? frameAt(Duration at, Duration total) {
    final level = best;
    final ms = at.inMilliseconds < 0 ? 0 : at.inMilliseconds;
    int frame;
    if (level.intervalMs > 0) {
      frame = ms ~/ level.intervalMs;
    } else {
      if (total <= Duration.zero) return null;
      frame = (ms / total.inMilliseconds * level.count).floor();
    }
    if (frame >= level.count) frame = level.count - 1;
    if (frame < 0) frame = 0;
    final sheet = frame ~/ level.perSheet;
    final within = frame % level.perSheet;
    final name = level.name.replaceAll(r'$M', '$sheet');
    var url = template
        .replaceAll(r'$L', '${level.index}')
        .replaceAll(r'$N', name);
    if (level.sigh.isNotEmpty) {
      url = '$url${url.contains('?') ? '&' : '?'}sigh=${level.sigh}';
    }
    return StoryboardFrame(
      url: url,
      column: within % level.columns,
      row: within ~/ level.columns,
      level: level,
    );
  }
}
