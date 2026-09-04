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

/// Header cells that prove a file is NOT a playlist.
///
/// Found by running this parser over a real export: `subscriptions.csv` was
/// read as a playlist holding four videos, because channel names like
/// "CodingPhase" and "Geekyranjit" are exactly eleven characters of the same
/// alphabet a video id uses. The id shape alone cannot tell them apart, so the
/// header has to.
const _foreignHeaders = {
  'channel id',
  'channelid',
  'channel url',
  'channel title',
  'playlist id',
};

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

    // A subscriptions or playlist-index file is not a playlist of videos. Bail
    // out entirely rather than letting the fallback scan below invent one out
    // of channel names that happen to be eleven characters long.
    if (cells.any((c) => _foreignHeaders.contains(c.toLowerCase()))) {
      return const [];
    }

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

// --------------------------------------------------------------- subscriptions

/// One subscribed channel from `subscriptions/subscriptions.csv`.
class TakeoutChannel {
  const TakeoutChannel({required this.id, required this.title});

  final String id;
  final String title;
}

/// A channel id: `UC` followed by 22 more characters.
final RegExp _channelId = RegExp(r'^UC[A-Za-z0-9_-]{22}$');

/// Splits one CSV line, honouring quoted fields.
///
/// A naive `split(',')` is wrong here and the export proves it: channel titles
/// carry commas and apostrophes, so a quoted title would be torn into pieces
/// and the row silently mangled.
List<String> splitCsvLine(String line) {
  final cells = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (char == '"') {
      // A doubled quote inside a quoted field is one literal quote.
      if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
        buffer.write('"');
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (char == ',' && !inQuotes) {
      cells.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(char);
    }
  }
  cells.add(buffer.toString());
  return cells.map((c) => c.trim()).toList();
}

/// Parses `subscriptions.csv` - `Channel Id,Channel Url,Channel Title`.
///
/// Nothing here needs the network: the file already carries the id and the
/// title, which is everything the local subscriptions table stores apart from
/// an avatar. That is why an import of 180 channels is instant while a
/// playlist import of the same size takes minutes.
List<TakeoutChannel> parseSubscriptionsCsv(String csv) {
  final channels = <TakeoutChannel>[];
  final seen = <String>{};
  final text = csv.replaceFirst('\uFEFF', '');

  for (final rawLine in text.split(RegExp(r'\r\n|\r|\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;

    final cells = splitCsvLine(line);
    if (cells.isEmpty) continue;

    // Find the id wherever it sits, rather than trusting a column order that
    // has no guarantee of staying put.
    String? id;
    for (final cell in cells) {
      if (_channelId.hasMatch(cell)) {
        id = cell;
        break;
      }
    }
    if (id == null || !seen.add(id)) continue;

    // The title is the last cell that is neither the id nor a URL.
    var title = '';
    for (final cell in cells.reversed) {
      if (cell == id || cell.startsWith('http') || cell.isEmpty) continue;
      title = cell;
      break;
    }
    channels.add(TakeoutChannel(id: id, title: title.isEmpty ? id : title));
  }
  return channels;
}

// ------------------------------------------------------------- watch history

/// One watched video from `history/watch-history.html`.
class TakeoutWatch {
  const TakeoutWatch({
    required this.videoId,
    required this.title,
    required this.channelId,
    required this.author,
    this.watchedAt,
  });

  final String videoId;
  final String title;
  final String channelId;
  final String author;

  /// Null when the timestamp could not be read; the caller substitutes
  /// something sensible rather than dropping an otherwise good row.
  final DateTime? watchedAt;
}

/// One entry: the video link, its title, the channel link, its name, then the
/// timestamp before the closing `<br>`.
final RegExp _historyEntry = RegExp(
  r'watch\?v=([A-Za-z0-9_-]{11})"[^>]*>(.*?)</a><br>'
  r'<a href="[^"]*channel/(UC[A-Za-z0-9_-]{22})"[^>]*>(.*?)</a><br>'
  r'([^<]*)<br>',
  dotAll: true,
);

const _months = {
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
  'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
};

/// Reads Takeout's `Sep 4, 2026, 11:07:12 AM IST` into a local DateTime.
///
/// Two traps live in that string. The space before AM/PM is U+202F, a NARROW
/// no-break space, so `\s` in a hand-rolled split does not always catch it and
/// a plain `' '` never does. And the trailing zone is an abbreviation like IST
/// that Dart cannot parse, so it is deliberately ignored: the export is
/// already written in the exporting account's local time, which is the same
/// clock the phone is on.
DateTime? parseHistoryTimestamp(String raw) {
  // Normalise every exotic space Google emits into a plain one.
  final text = raw
      .replaceAll('\u202f', ' ')
      .replaceAll('\u00a0', ' ')
      .replaceAll('&nbsp;', ' ')
      .trim();

  final match = RegExp(
    r'([A-Za-z]{3})\s+(\d{1,2}),\s*(\d{4}),\s*(\d{1,2}):(\d{2}):(\d{2})\s*([AaPp][Mm])?',
  ).firstMatch(text);
  if (match == null) return null;

  final month = _months[match.group(1)!.toLowerCase()];
  if (month == null) return null;

  var hour = int.parse(match.group(4)!);
  final meridiem = match.group(7)?.toLowerCase();
  if (meridiem == 'pm' && hour != 12) hour += 12;
  if (meridiem == 'am' && hour == 12) hour = 0;

  return DateTime(
    int.parse(match.group(3)!),
    month,
    int.parse(match.group(2)!),
    hour,
    int.parse(match.group(5)!),
    int.parse(match.group(6)!),
  );
}

/// Unescapes the handful of HTML entities Takeout emits in titles.
String unescapeHtml(String input) => input
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ')
    .trim();

/// Parses watch history, newest first, stopping after [limit] entries.
///
/// Stopping early is the point. A real export held 28,000 entries in 28 MB,
/// and the history table keeps only its most recent few hundred anyway - so
/// reading the whole thing on a phone would cost a lot of memory to produce
/// rows that are immediately trimmed away. Takeout writes newest first, so the
/// first [limit] matches are exactly the ones worth keeping.
List<TakeoutWatch> parseWatchHistoryHtml(String html, {int limit = 500}) {
  final watches = <TakeoutWatch>[];
  final seen = <String>{};

  for (final match in _historyEntry.allMatches(html)) {
    final videoId = match.group(1)!;
    // Rewatches appear repeatedly; the first is the most recent.
    if (!seen.add(videoId)) continue;

    watches.add(
      TakeoutWatch(
        videoId: videoId,
        title: unescapeHtml(match.group(2)!),
        channelId: match.group(3)!,
        author: unescapeHtml(match.group(4)!),
        watchedAt: parseHistoryTimestamp(match.group(5)!),
      ),
    );
    if (watches.length >= limit) break;
  }
  return watches;
}
