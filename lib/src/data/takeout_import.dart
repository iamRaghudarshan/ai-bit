/// Reads the CSV files Google Takeout produces for YouTube playlists.
///
/// This exists because the app has no Google Sign-In - deliberately, since
/// putting a real account behind a ToS-violating client risks that account -
/// and Takeout is the one route that reaches PRIVATE playlists without one.
/// The user exports their data, hands the app the files, and nothing ever
/// authenticates.
///
/// Everything here is pure string work: no I/O, no network, no plugins. That
/// is what makes the format guesses testable, which matters because Takeout's
/// layout is undocumented, has changed between exports, and is the sort of
/// thing that silently returns nothing when it drifts.
library;

/// One playlist read out of an export.
class TakeoutPlaylist {
  const TakeoutPlaylist({required this.name, required this.videoIds});

  final String name;

  /// Video ids in the order the file listed them, duplicates removed.
  final List<String> videoIds;

  bool get isEmpty => videoIds.isEmpty;
  int get length => videoIds.length;
}

/// A YouTube video id: exactly 11 characters of an unpadded base64 alphabet.
///
/// Anchored, because the point of the check is to REJECT the other columns in
/// these files - timestamps, urls, titles - not to find an id inside them.
final RegExp _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

/// Header cells Takeout has used for the video-id column across exports.
///
/// Matched case- and space-insensitively; a header that is not recognised
/// falls back to the scan in [parsePlaylistCsv], which is why an unfamiliar
/// export still imports instead of silently yielding nothing.
const _idHeaders = {'videoid', 'video id'};

/// Parses one `<name>-videos.csv` from `Takeout/YouTube and YouTube Music/
/// playlists/`, returning the video ids in file order.
///
/// Tolerant on purpose. Real exports have carried a header row, a blank line
/// before the data, a UTF-8 BOM, CRLF endings, and a trailing comment block -
/// and different exports have carried different subsets of those. Rather than
/// encode one layout, this finds the column that holds ids when it can and
/// otherwise scans every cell for something id-shaped.
List<String> parsePlaylistCsv(String csv) {
  final ids = <String>[];
  final seen = <String>{};
  var idColumn = -1;

  // A BOM survives into the first cell and would break both the header match
  // and an id sitting in column zero.
  final text = csv.replaceFirst('﻿', '');

  for (final rawLine in text.split(RegExp(r'\r\n|\r|\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    final cells = line.split(',').map((c) => c.trim()).toList();

    // Header: remember which column the ids are in, then move on. Checked on
    // every line, not just the first, because an export can carry more than
    // one section and the data does not always start where you expect.
    final headerIndex = cells.indexWhere(
      (c) => _idHeaders.contains(c.toLowerCase()),
    );
    if (headerIndex >= 0) {
      idColumn = headerIndex;
      continue;
    }

    // Preferred path: the known column.
    if (idColumn >= 0 && idColumn < cells.length) {
      final candidate = cells[idColumn];
      if (_videoId.hasMatch(candidate) && seen.add(candidate)) {
        ids.add(candidate);
      }
      continue;
    }

    // Fallback: no usable header, so take the first id-shaped cell on the row.
    for (final cell in cells) {
      if (_videoId.hasMatch(cell)) {
        if (seen.add(cell)) ids.add(cell);
        break;
      }
    }
  }
  return ids;
}

/// The playlist name implied by a Takeout file name.
///
/// Takeout names these `<playlist name>-videos.csv`. The suffix is stripped so
/// an import lands as "Road trip" rather than "Road trip-videos.csv", and a
/// file that does not follow the convention keeps its stem instead of being
/// rejected - a wrong-looking name is far better than a refused import.
String playlistNameFromFileName(String fileName) {
  var name = fileName.split(RegExp(r'[/\\]')).last;
  if (name.toLowerCase().endsWith('.csv')) {
    name = name.substring(0, name.length - 4);
  }
  const suffix = '-videos';
  if (name.toLowerCase().endsWith(suffix)) {
    name = name.substring(0, name.length - suffix.length);
  }
  name = name.trim();
  return name.isEmpty ? 'Imported playlist' : name;
}

/// Reads one file into a playlist, or null when it holds no video ids.
///
/// Null rather than an empty playlist because an export folder contains files
/// that are not playlists at all, and creating an empty local playlist for
/// each one would be worse than skipping them.
TakeoutPlaylist? readPlaylistFile({
  required String fileName,
  required String contents,
}) {
  final ids = parsePlaylistCsv(contents);
  if (ids.isEmpty) return null;
  return TakeoutPlaylist(
    name: playlistNameFromFileName(fileName),
    videoIds: ids,
  );
}
