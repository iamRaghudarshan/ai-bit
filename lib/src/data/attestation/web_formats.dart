/// Pure helpers for the web client's stream formats.
///
/// The web client is the only one a proof-of-origin token can be minted for
/// without an official app's attestation (see `po_token_service.dart`), and
/// its formats arrive in a different shape from the mobile clients':
///
///   * Most carry a `signatureCipher` instead of a `url`: the real URL plus a
///     scrambled signature `s` that must be unscrambled by the player's own
///     JavaScript and appended under the name `sp` (usually `sig`).
///   * Every URL carries an `n` parameter that must likewise be transformed
///     by the player JS. Left alone, the stream is throttled to a crawl.
///   * The token itself goes on every URL as `pot`.
///
/// Both transformations are **challenges** solved by yt-dlp's `ejs` solver
/// running in the WebView (`web_challenge_solver.dart`). This file only
/// takes the formats apart and puts them back together, so every step of
/// that can be tested without a network or a browser.
library;

/// The challenges a list of raw formats needs solved, by type.
///
/// Deduplicated: the `n` value is shared across every format of a response,
/// so a 40-format response is one `n` challenge, not forty.
({List<String> n, List<String> sig}) challengesIn(List<Object?> rawFormats) {
  final n = <String>{};
  final sig = <String>{};
  for (final raw in rawFormats) {
    if (raw is! Map) continue;
    final cipher = _cipherOf(raw);
    final s = cipher?['s'];
    if (s != null && s.isNotEmpty) sig.add(s);
    final url = cipher?['url'] ?? raw['url']?.toString();
    final nValue = nParam(url);
    if (nValue != null) n.add(nValue);
  }
  return (n: n.toList(), sig: sig.toList());
}

/// The `n` parameter of a stream URL, or null when there is none.
String? nParam(String? url) {
  if (url == null || url.isEmpty) return null;
  final value = Uri.tryParse(url)?.queryParameters['n'];
  return (value == null || value.isEmpty) ? null : value;
}

/// The format with its real, usable `url` filled in, or null when it cannot
/// be made usable.
///
/// [solvedN] and [solvedSig] map each challenge to its answer; a challenge
/// whose answer is missing or null leaves the format unusable, and that is
/// reported as null rather than as a URL that will 403 — a half-resolved
/// manifest fails exactly like a fully broken one, only later.
Map<String, Object?>? resolveFormat(
  Map raw, {
  required Map<String, String?> solvedN,
  required Map<String, String?> solvedSig,
  required String poToken,
}) {
  final cipher = _cipherOf(raw);
  String? url;
  if (cipher != null) {
    final base = cipher['url'];
    final s = cipher['s'];
    final sp = cipher['sp'] ?? 'sig';
    if (base == null || s == null) return null;
    final sig = solvedSig[s];
    if (sig == null) return null;
    url = _withParam(base, sp, sig);
  } else {
    final plain = raw['url'];
    if (plain is! String || plain.isEmpty) return null;
    url = plain;
  }

  final n = nParam(url);
  if (n != null) {
    final solved = solvedN[n];
    if (solved == null) return null;
    url = _withParam(url, 'n', solved);
  }

  return {
    for (final e in raw.entries) e.key.toString(): e.value,
    'url': withPoToken(url, poToken),
  }..remove('signatureCipher');
}

/// [url] with the proof-of-origin token attached as `pot`.
///
/// Replaces an existing `pot` rather than adding a second: a URL stamped
/// twice carries the older token first, and googlevideo reads the first.
String withPoToken(String url, String token) => _withParam(url, 'pot', token);

/// The `base.js` URL named by `https://www.youtube.com/iframe_api`, or null.
///
/// The iframe API script is a few kilobytes and names the current player
/// build, which is the cheapest way to find it without loading a watch page.
/// The body is JavaScript with the slashes escaped (`\/`), hence the optional
/// backslashes in the pattern.
String? playerScriptUrlFromIframeApi(String body) {
  final match = RegExp(r'player\\?/([0-9a-f]{8})\\?/').firstMatch(body);
  if (match == null) return null;
  return 'https://www.youtube.com/s/player/${match.group(1)}/player_ias.vflset/en_US/base.js';
}

/// The `signatureTimestamp` embedded in a player script, which the player
/// endpoint must be told so that it issues signatures that script can solve.
int? signatureTimestampOf(String playerScript) {
  final match = RegExp(r'(?:signatureTimestamp|sts):(\d{5})')
      .firstMatch(playerScript);
  return match == null ? null : int.tryParse(match.group(1)!);
}

Map<String, String>? _cipherOf(Map raw) {
  final value = raw['signatureCipher'] ?? raw['cipher'];
  if (value is! String || value.isEmpty) return null;
  return Uri.splitQueryString(value);
}

/// [url] with [name] set to [value], replacing any existing value.
///
/// Done on the raw string rather than through `Uri.replace`, which would
/// re-encode every other parameter — and a googlevideo URL's parameters are
/// signed as written.
String _withParam(String url, String name, String value) {
  final encoded = Uri.encodeQueryComponent(value);
  final pattern = RegExp('([?&])${RegExp.escape(name)}=[^&]*');
  if (pattern.hasMatch(url)) {
    // replaceFirstMapped, not replaceFirst: Dart's String replacement has no
    // `$1` group references, it would insert the four characters literally.
    return url.replaceFirstMapped(
      pattern,
      (m) => '${m.group(1)}$name=$encoded',
    );
  }
  final separator = url.contains('?') ? '&' : '?';
  return '$url$separator$name=$encoded';
}
