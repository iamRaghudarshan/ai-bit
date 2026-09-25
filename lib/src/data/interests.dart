/// What the user says they want to see, as opposed to what the app infers.
///
/// Everything else in the recommender watches behaviour and draws conclusions.
/// This is the other half: a person who has just installed the app has no
/// behaviour to draw conclusions from, and asking them beats guessing. It also
/// fixes the one case the ranker genuinely cannot — **cold start**. Before
/// this, a fresh install fell back to a fixed list of evergreen topics (music,
/// gaming, cooking, football) that describe nobody in particular, and the feed
/// stayed generic until enough history accumulated to displace it.
///
/// Declared interests do not override what is learnt; they seed it. A chosen
/// topic's words go into the same `topicWeights` the profile builds from
/// searches and watched titles, so from the first launch the feed behaves as
/// though the user had already searched for those things — and as real
/// behaviour arrives it is weighed alongside, not behind.
///
/// Pure, and deliberately: this is a table of strings and the rules for
/// turning them into search terms, which is exactly the kind of thing that
/// should be testable without a network or a phone.
library;

/// One thing a user can say they are interested in.
class Interest {
  const Interest({
    required this.id,
    required this.label,
    required this.queries,
  });

  /// Stable key, stored in preferences. Never shown, and never renamed — a
  /// changed id silently unselects whatever the user had chosen.
  final String id;

  /// What the picker shows.
  final String label;

  /// Search terms this interest expands into.
  ///
  /// Several per interest rather than one, because a single query returns one
  /// slice of a subject and a feed built from it looks like a search results
  /// page. They are also what gets tokenised into the taste profile, which is
  /// why they read as phrases a person would type rather than as tags.
  final List<String> queries;
}

/// The catalogue, in the order the picker shows it.
///
/// Broad rather than exhaustive. A list long enough to cover everybody is one
/// nobody reads to the end of, and anything missing is still reachable the way
/// it always was — by searching for it, which the profile then learns from.
const interestCatalogue = <Interest>[
  Interest(
    id: 'tech',
    label: 'Technology',
    queries: ['technology news', 'gadget review', 'smartphone review'],
  ),
  Interest(
    id: 'ai',
    label: 'AI',
    queries: [
      'artificial intelligence explained',
      'ai tools',
      'machine learning tutorial',
    ],
  ),
  Interest(
    id: 'news',
    label: 'News',
    queries: ['news today', 'world news', 'breaking news'],
  ),
  Interest(
    id: 'coding',
    label: 'Programming',
    queries: ['programming tutorial', 'software engineering', 'coding project'],
  ),
  Interest(
    id: 'business',
    label: 'Business & finance',
    queries: ['business news', 'stock market analysis', 'personal finance'],
  ),
  Interest(
    id: 'science',
    label: 'Science',
    queries: ['science explained', 'space exploration', 'physics explained'],
  ),
  Interest(
    id: 'education',
    label: 'Learning',
    queries: ['educational video', 'how it works', 'explained simply'],
  ),
  Interest(
    id: 'gaming',
    label: 'Gaming',
    queries: ['gaming', 'gameplay walkthrough', 'game review'],
  ),
  Interest(
    id: 'music',
    label: 'Music',
    queries: ['music', 'new songs', 'live performance'],
  ),
  Interest(
    id: 'movies',
    label: 'Film & TV',
    queries: ['movie review', 'film trailer', 'series breakdown'],
  ),
  Interest(
    id: 'comedy',
    label: 'Comedy',
    queries: ['stand up comedy', 'funny videos', 'sketch comedy'],
  ),
  Interest(
    id: 'sports',
    label: 'Sports',
    queries: ['sports highlights', 'match highlights', 'football highlights'],
  ),
  Interest(
    id: 'cricket',
    label: 'Cricket',
    queries: ['cricket highlights', 'cricket analysis', 'ipl highlights'],
  ),
  Interest(
    id: 'fitness',
    label: 'Fitness & health',
    queries: ['workout routine', 'fitness tips', 'healthy eating'],
  ),
  Interest(
    id: 'cooking',
    label: 'Food & cooking',
    queries: ['cooking recipe', 'street food', 'easy recipes'],
  ),
  Interest(
    id: 'travel',
    label: 'Travel',
    queries: ['travel vlog', 'travel guide', 'places to visit'],
  ),
  Interest(
    id: 'cars',
    label: 'Cars & motoring',
    queries: ['car review', 'motorcycle review', 'car news'],
  ),
  Interest(
    id: 'diy',
    label: 'DIY & making',
    queries: ['diy project', 'woodworking', 'home improvement'],
  ),
  Interest(
    id: 'documentary',
    label: 'Documentary',
    queries: ['documentary', 'history documentary', 'investigation'],
  ),
  Interest(
    id: 'podcast',
    label: 'Podcasts & talks',
    queries: ['podcast episode', 'interview', 'talk'],
  ),
  Interest(
    id: 'art',
    label: 'Art & design',
    queries: ['art tutorial', 'graphic design', 'photography tips'],
  ),
  Interest(
    id: 'spiritual',
    label: 'Devotional',
    queries: ['bhajan', 'devotional songs', 'spiritual talk'],
  ),
];

/// Looks an interest up, or null when the stored id is no longer in the
/// catalogue — which is the normal outcome after a catalogue edit, not an
/// error, so callers skip rather than throw.
Interest? interestById(String id) {
  for (final interest in interestCatalogue) {
    if (interest.id == id) return interest;
  }
  return null;
}

/// Every search term the chosen [ids] expand into, de-duplicated and in
/// catalogue order.
///
/// Order is the catalogue's rather than the user's selection order on purpose:
/// selection order is an artefact of which chip was tapped first and carries
/// no meaning, and a feed whose composition depended on it would change for
/// no reason the user could see.
List<String> interestQueries(Iterable<String> ids) {
  final chosen = ids.toSet();
  final out = <String>[];
  final seen = <String>{};
  for (final interest in interestCatalogue) {
    if (!chosen.contains(interest.id)) continue;
    for (final query in interest.queries) {
      if (seen.add(query)) out.add(query);
    }
  }
  return out;
}

/// A content language the app can ask YouTube for.
class ContentLanguage {
  const ContentLanguage({
    required this.code,
    required this.label,
  });

  /// The `hl` value sent to YouTube's endpoints. Empty means "use the
  /// device's own language", resolved at the call site.
  final String code;
  final String label;
}

/// A region, which YouTube treats separately from language: `gl` decides what
/// is popular and what is available, `hl` decides what the labels say. Somebody
/// in India reading English wants `gl=IN, hl=en`, and collapsing the two into
/// one setting gets that person the wrong feed.
class ContentRegion {
  const ContentRegion({required this.code, required this.label});

  /// The `gl` value. Empty means "use the device's own country".
  final String code;
  final String label;
}

/// Languages offered in the picker. Not the full ISO list — that is a wall of
/// text nobody scrolls — but the ones this app is plausibly used in.
const languageCatalogue = <ContentLanguage>[
  ContentLanguage(code: '', label: 'Match my device'),
  ContentLanguage(code: 'en', label: 'English'),
  ContentLanguage(code: 'hi', label: 'हिन्दी (Hindi)'),
  ContentLanguage(code: 'bn', label: 'বাংলা (Bengali)'),
  ContentLanguage(code: 'te', label: 'తెలుగు (Telugu)'),
  ContentLanguage(code: 'mr', label: 'मराठी (Marathi)'),
  ContentLanguage(code: 'ta', label: 'தமிழ் (Tamil)'),
  ContentLanguage(code: 'gu', label: 'ગુજરાતી (Gujarati)'),
  ContentLanguage(code: 'kn', label: 'ಕನ್ನಡ (Kannada)'),
  ContentLanguage(code: 'ml', label: 'മലയാളം (Malayalam)'),
  ContentLanguage(code: 'pa', label: 'ਪੰਜਾਬੀ (Punjabi)'),
  ContentLanguage(code: 'ur', label: 'اردو (Urdu)'),
  ContentLanguage(code: 'ar', label: 'العربية (Arabic)'),
  ContentLanguage(code: 'es', label: 'Español'),
  ContentLanguage(code: 'pt', label: 'Português'),
  ContentLanguage(code: 'fr', label: 'Français'),
  ContentLanguage(code: 'de', label: 'Deutsch'),
  ContentLanguage(code: 'ru', label: 'Русский'),
  ContentLanguage(code: 'ja', label: '日本語 (Japanese)'),
  ContentLanguage(code: 'ko', label: '한국어 (Korean)'),
  ContentLanguage(code: 'id', label: 'Bahasa Indonesia'),
];

const regionCatalogue = <ContentRegion>[
  ContentRegion(code: '', label: 'Match my device'),
  ContentRegion(code: 'IN', label: 'India'),
  ContentRegion(code: 'US', label: 'United States'),
  ContentRegion(code: 'GB', label: 'United Kingdom'),
  ContentRegion(code: 'AE', label: 'United Arab Emirates'),
  ContentRegion(code: 'AU', label: 'Australia'),
  ContentRegion(code: 'CA', label: 'Canada'),
  ContentRegion(code: 'DE', label: 'Germany'),
  ContentRegion(code: 'FR', label: 'France'),
  ContentRegion(code: 'ES', label: 'Spain'),
  ContentRegion(code: 'BR', label: 'Brazil'),
  ContentRegion(code: 'JP', label: 'Japan'),
  ContentRegion(code: 'KR', label: 'South Korea'),
  ContentRegion(code: 'ID', label: 'Indonesia'),
  ContentRegion(code: 'SG', label: 'Singapore'),
  ContentRegion(code: 'ZA', label: 'South Africa'),
];

/// The label for a stored code, or the code itself when it is not in the
/// catalogue — a device locale can perfectly well be one this app does not
/// list, and showing `pl` is more honest than showing "Match my device".
String languageLabel(String code) {
  if (code.isEmpty) return languageCatalogue.first.label;
  for (final language in languageCatalogue) {
    if (language.code == code) return language.label;
  }
  return code;
}

String regionLabel(String code) {
  if (code.isEmpty) return regionCatalogue.first.label;
  for (final region in regionCatalogue) {
    if (region.code == code) return region.label;
  }
  return code;
}

/// Falls back to [fallback] when the stored value is empty.
///
/// Both settings default to empty, meaning "whatever the device says", so the
/// app is useful before anyone opens the settings screen — which is the whole
/// point of having a default rather than a required choice.
String resolveCode(String stored, String fallback, String lastResort) {
  final value = stored.trim().isNotEmpty ? stored.trim() : fallback.trim();
  return value.isEmpty ? lastResort : value;
}
