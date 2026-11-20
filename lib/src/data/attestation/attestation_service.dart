import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'web_formats.dart';
import 'web_runtime.dart';

/// The one way left to HD on every video: ask as the web client, with a
/// proof-of-origin token YouTube's own bot check issued.
///
/// `tool/check_stream_limits.dart` establishes that YouTube serves a
/// byte-range HD track for only the first ~60 seconds unless the request
/// carries a proof-of-origin token; `check_visitor_clients.dart` and
/// `check_signed_in.dart` establish that no other client, no anonymous
/// session id and no signed-in account changes that. The token is minted by
/// running Google's BotGuard in a real browser engine, which is what the
/// hidden WebView in [HiddenWebRuntime] is for. Only *web*-client tokens can
/// be minted that way — the mobile apps attest through their own binaries —
/// so this route also has to take the web client's formats, whose URLs are
/// behind the player's signature and `n` challenges. Those are solved by
/// yt-dlp's `ejs` library, run in the same WebView.
///
/// Three things about how this fails, because it will, periodically:
///
///   * **Everything is optional.** A caller that cannot get a session falls
///     back to the routes that exist without one. Nothing in playback waits
///     on this when it is broken.
///   * **It reports.** [status] is a live, human-readable account of the last
///     attempt — which step, what went wrong — shown in Settings, because the
///     costliest bugs in this project were features that looked on and were
///     silently off.
///   * **The token is cached**, in memory and in preferences, for the
///     lifetime the integrity token was issued with (or six hours, whichever
///     is shorter). A mint takes several seconds and a WebView; one per
///     session is the budget, not one per video.
class WebAttestation extends ChangeNotifier {
  WebAttestation({
    HiddenWebRuntime? runtime,
    http.Client? client,
    Future<SharedPreferences>? prefs,
  })  : _runtime = runtime ?? HiddenWebRuntime(),
        _http = client ?? http.Client(),
        _prefs = prefs ?? SharedPreferences.getInstance();

  final HiddenWebRuntime _runtime;
  final http.Client _http;
  final Future<SharedPreferences> _prefs;

  /// Whether a session can be minted on this platform at all.
  static bool get isSupported => HiddenWebRuntime.isSupported;

  /// The request key BotGuard challenges are created with. The same constant
  /// every open-source client uses; it identifies the YouTube web player.
  static const requestKey = 'O43z0dpjhgX20SCx4KAo';

  static const _prefsKey = 'web_attestation_session';
  static const _maxLifetime = Duration(hours: 6);

  /// yt-dlp's challenge solver, pinned by hash — the same release the
  /// `youtube_explode_dart` dependency carries. The library is a plain JS
  /// bundle; `core` defines `jsc`, which takes a player script and a list of
  /// challenges and returns their answers. Bump both together.
  static const _solverLib = (
    url:
        'https://github.com/yt-dlp/ejs/releases/download/0.8.0/yt.solver.lib.min.js',
    sha256: 'c55987fe697e5b9ee18830163f7af85327e9bb5c3e674b969d38c8d205eaa577',
  );
  static const _solverCore = (
    url:
        'https://github.com/yt-dlp/ejs/releases/download/0.8.0/yt.solver.core.min.js',
    sha256: '18da6ce0758b416e7ae645084f4f8801f9f9d59d6c477c05eaa0ff94ebd8cc00',
  );

  WebSession? _session;
  Future<WebSession?>? _inFlight;
  var _solverLoaded = false;
  Future<void>? _solverLoading;

  String? _playerScriptUrl;
  int? _signatureTimestamp;
  DateTime? _playerFetchedAt;

  /// A plain-language account of the last attempt, for Settings.
  String status = 'Not tried yet';
  DateTime? lastMintAt;
  String? lastError;

  void _report(String text, {bool error = false}) {
    status = text;
    if (error) lastError = text;
    debugPrint('AI BIT attestation: $text');
    notifyListeners();
  }

  /// The current session — visitor id plus the token bound to it — minting
  /// one if there is none or it has expired. Null when it cannot be had.
  Future<WebSession?> session({bool force = false}) async {
    if (!isSupported) return null;
    if (!force) {
      final cached = _session ?? await _restore();
      if (cached != null && !cached.isExpired) return cached;
    }
    // One mint at a time, however many videos are resolving.
    return _inFlight ??= _mint().whenComplete(() => _inFlight = null);
  }

  Future<WebSession?> _restore() async {
    try {
      final raw = (await _prefs).getString(_prefsKey);
      if (raw == null) return null;
      final session = WebSession.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (session.isExpired) return null;
      _session = session;
      status = 'Session from ${session.mintedAt.toLocal()} restored';
      return session;
    } catch (_) {
      return null;
    }
  }

  Future<WebSession?> _mint() async {
    try {
      _report('Getting a visitor id…');
      final visitorData = await _fetchVisitorData();

      _report('Running YouTube\'s bot check…');
      final result = await _runtime.call(
        'mintPoToken',
        [requestKey, visitorData],
        timeout: const Duration(seconds: 90),
      ) as Map;
      final token = result['token'] as String?;
      if (token == null || token.isEmpty) {
        throw StateError('no token in ${jsonEncode(result)}');
      }
      final ttl = result['ttlSeconds'];
      var lifetime = _maxLifetime;
      if (ttl is num && ttl > 60) {
        final issued = Duration(seconds: ttl.toInt());
        if (issued < lifetime) lifetime = issued;
      }
      final session = WebSession(
        visitorData: visitorData,
        poToken: token,
        mintedAt: DateTime.now(),
        expiresAt: DateTime.now().add(lifetime),
      );
      _session = session;
      lastMintAt = session.mintedAt;
      lastError = null;
      (await _prefs).setString(_prefsKey, jsonEncode(session.toJson()));
      _report('Token minted, valid ${lifetime.inHours}h');
      return session;
    } catch (e) {
      _report('Bot check failed: $e', error: true);
      return null;
    }
  }

  /// A fresh anonymous visitor id from the endpoint YouTube's own page uses.
  Future<String> _fetchVisitorData() async {
    final response = await _http
        .post(
          Uri.parse(
            'https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false',
          ),
          headers: _webHeaders,
          body: jsonEncode({
            'context': {
              'client': {
                'clientName': 'WEB',
                'clientVersion': webClientVersion,
                'hl': 'en',
                'gl': 'US',
              },
            },
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode == 200) {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      final visitor = (json is Map)
          ? ((json['responseContext'] as Map?)?['visitorData'] as String?)
          : null;
      if (visitor != null && visitor.isNotEmpty) return visitor;
    }
    // The page config carries one too; this is what the probes read.
    final page = await _http
        .get(Uri.parse('https://www.youtube.com/'), headers: _webHeaders)
        .timeout(const Duration(seconds: 20));
    final match = RegExp(r'"visitorData":"([^"]+)"').firstMatch(page.body);
    if (match != null) return jsonDecode('"${match.group(1)!}"') as String;
    throw StateError('no visitor id from either source');
  }

  static const webClientVersion = '2.20250312.04.00';
  static const webUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const _webHeaders = {
    'Content-Type': 'application/json',
    'Origin': 'https://www.youtube.com',
    'User-Agent': webUserAgent,
    'Accept-Language': 'en-US,en;q=0.9',
  };

  // ------------------------------------------------------- player script

  /// The current player build's script URL and signature timestamp.
  ///
  /// The timestamp has to go on the player request so the signatures it
  /// issues are ones this build's script can solve. Re-read hourly; YouTube
  /// ships a new player every few days.
  Future<({String url, int signatureTimestamp})> player() async {
    final fetchedAt = _playerFetchedAt;
    if (_playerScriptUrl != null &&
        _signatureTimestamp != null &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < const Duration(hours: 1)) {
      return (url: _playerScriptUrl!, signatureTimestamp: _signatureTimestamp!);
    }
    final api = await _http
        .get(Uri.parse('https://www.youtube.com/iframe_api'),
            headers: _webHeaders)
        .timeout(const Duration(seconds: 20));
    final url = playerScriptUrlFromIframeApi(api.body);
    if (url == null) throw StateError('iframe_api names no player build');
    final info = await _runtime.call('playerInfo', [url]) as Map;
    final sts = info['signatureTimestamp'];
    if (sts is! int) throw StateError('player script carries no sts');
    _playerScriptUrl = url;
    _signatureTimestamp = sts;
    _playerFetchedAt = DateTime.now();
    return (url: url, signatureTimestamp: sts);
  }

  // ------------------------------------------------------------- solver

  Future<void> _ensureSolver() async {
    if (_solverLoaded) return;
    return _solverLoading ??= () async {
      final clock = Stopwatch()..start();
      final lib = await _fetchVerified(_solverLib.url, _solverLib.sha256);
      final core = await _fetchVerified(_solverCore.url, _solverCore.sha256);
      debugPrint('AI BIT attestation: solver fetched '
          '(${lib.length + core.length} chars) in ${clock.elapsedMilliseconds}ms');
      await _runtime
          .injectPersistent('$lib\nObject.assign(globalThis, lib);\n$core\n')
          .timeout(const Duration(seconds: 45));
      debugPrint('AI BIT attestation: solver injected at '
          '${clock.elapsedMilliseconds}ms');
      final has = await _runtime.call('hasSolver', const []);
      if (has != true) throw StateError('solver did not define jsc');
      _solverLoaded = true;
    }()
        .whenComplete(() => _solverLoading = null);
  }

  Future<String> _fetchVerified(String url, String sha256Hex) async {
    final response =
        await _http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw StateError('solver module HTTP ${response.statusCode}');
    }
    final digest = sha256.convert(response.bodyBytes).toString();
    if (digest != sha256Hex) {
      throw StateError('solver module hash mismatch for $url');
    }
    return utf8.decode(response.bodyBytes);
  }

  final _solvedCache = <String, String?>{};

  /// Answers for the signature and `n` challenges in [rawFormats].
  Future<({Map<String, String?> n, Map<String, String?> sig})> solve(
    String playerUrl,
    List<Object?> rawFormats,
  ) async {
    final wanted = challengesIn(rawFormats);
    final n = <String, String?>{};
    final sig = <String, String?>{};
    final askN = <String>[];
    final askSig = <String>[];
    for (final c in wanted.n) {
      final key = 'n:$playerUrl:$c';
      if (_solvedCache.containsKey(key)) {
        n[c] = _solvedCache[key];
      } else {
        askN.add(c);
      }
    }
    for (final c in wanted.sig) {
      final key = 'sig:$playerUrl:$c';
      if (_solvedCache.containsKey(key)) {
        sig[c] = _solvedCache[key];
      } else {
        askSig.add(c);
      }
    }
    if (askN.isNotEmpty || askSig.isNotEmpty) {
      await _ensureSolver();
      final result = await _runtime.call(
        'solveChallenges',
        [
          playerUrl,
          [
            if (askN.isNotEmpty) {'type': 'n', 'challenges': askN},
            if (askSig.isNotEmpty) {'type': 'sig', 'challenges': askSig},
          ],
        ],
        timeout: const Duration(seconds: 90),
      ) as Map;
      for (final c in askN) {
        final v = result[c] as String?;
        _solvedCache['n:$playerUrl:$c'] = v;
        n[c] = v;
      }
      for (final c in askSig) {
        final v = result[c] as String?;
        _solvedCache['sig:$playerUrl:$c'] = v;
        sig[c] = v;
      }
    }
    return (n: n, sig: sig);
  }

  /// Does the slow parts ahead of time: the token, the solver and the player
  /// build. Each is cached, so a later request pays only for itself.
  Future<void> warmUp() async {
    if (!isSupported) return;
    try {
      if (await session() == null) return;
      await player();
      await _ensureSolver();
    } catch (e) {
      _report('Warm-up failed: $e', error: true);
    }
  }

  /// Forgets the session so the next request mints a fresh one.
  Future<void> invalidate() async {
    _session = null;
    (await _prefs).remove(_prefsKey);
  }

  @override
  void dispose() {
    _runtime.dispose();
    _http.close();
    super.dispose();
  }
}

/// A visitor id and the proof-of-origin token bound to it.
class WebSession {
  const WebSession({
    required this.visitorData,
    required this.poToken,
    required this.mintedAt,
    required this.expiresAt,
  });

  final String visitorData;
  final String poToken;
  final DateTime mintedAt;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  Map<String, Object?> toJson() => {
        'visitorData': visitorData,
        'poToken': poToken,
        'mintedAt': mintedAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
      };

  factory WebSession.fromJson(Map<String, dynamic> json) => WebSession(
        visitorData: json['visitorData'] as String,
        poToken: json['poToken'] as String,
        mintedAt: DateTime.parse(json['mintedAt'] as String),
        expiresAt: DateTime.parse(json['expiresAt'] as String),
      );
}
