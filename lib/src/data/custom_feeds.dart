import 'dart:convert';

/// A feed the user described themselves.
///
/// YouTube added these in late 2026: a `+` at the top of Home where you type
/// what you want to see, and the result is saved as a chip you can switch to.
/// It is the best idea in that release, and it answers something the fixed
/// chip row never could — the categories are whatever Google chose, and
/// "Technology" is not the same request as "self-hosting homelab tutorials".
///
/// This is the local equivalent. There is no model interpreting the sentence;
/// the words are used as search terms, which for a phrase somebody typed on
/// purpose is most of the value anyway. The honest difference from YouTube's
/// version is that theirs can infer intent from a vague description and this
/// one cannot, so the help text asks for topics rather than a wish.
class CustomFeed {
  const CustomFeed({required this.name, required this.query});

  /// What the chip says. Short by necessity — it sits in a scrolling row.
  final String name;

  /// What the user typed. Split into search terms at use.
  final String query;

  /// The search terms this feed fetches.
  ///
  /// Commas and newlines separate distinct searches so "ai tools, homelab"
  /// becomes two queries rather than one unlikely phrase; plain spaces do not,
  /// because "machine learning tutorial" is one search and chopping it into
  /// three would return nothing like what was asked for.
  List<String> get queries {
    final parts = query
        .split(RegExp(r'[,\n;]+'))
        .map((p) => p.trim())
        .where((p) => p.length >= 2)
        .toList();
    return parts.isEmpty ? const [] : parts;
  }

  bool get isUsable => name.trim().isNotEmpty && queries.isNotEmpty;

  Map<String, Object?> toJson() => {'name': name, 'query': query};

  static CustomFeed? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = '${raw['name'] ?? ''}'.trim();
    final query = '${raw['query'] ?? ''}'.trim();
    if (name.isEmpty || query.isEmpty) return null;
    return CustomFeed(name: name, query: query);
  }
}

/// Encodes feeds for SharedPreferences.
///
/// One JSON string rather than a table: this is a handful of short rows that
/// are read together and written whole, which is what the preferences file is
/// for. A list of strings would have needed a separator that cannot appear in
/// a name, and users type separators.
String encodeCustomFeeds(List<CustomFeed> feeds) =>
    jsonEncode([for (final f in feeds) f.toJson()]);

/// Decodes feeds, dropping anything unreadable.
///
/// Never throws. A corrupted preference should cost the custom feeds, not the
/// Home screen — and a half-written value is exactly what a crash mid-write
/// leaves behind.
List<CustomFeed> decodeCustomFeeds(String raw) {
  if (raw.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final out = <CustomFeed>[];
    final names = <String>{};
    for (final entry in decoded) {
      final feed = CustomFeed.fromJson(entry);
      if (feed == null || !feed.isUsable) continue;
      // Names are the chip labels and the identity, so a duplicate would make
      // two chips that cannot be told apart.
      if (!names.add(feed.name.toLowerCase())) continue;
      out.add(feed);
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// How many custom feeds are allowed.
///
/// The chips share one scrolling row with the built-in categories, and past
/// about this many the row stops being navigable. It is a UI limit, not a
/// storage one.
const maxCustomFeeds = 8;
