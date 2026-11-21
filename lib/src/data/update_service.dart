import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// The latest build advertised by the update server.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.build,
    required this.url,
    required this.notes,
    this.minSupportedBuild = 0,
  });

  final String version;
  final int build;
  final String url;
  final String notes;

  /// Builds below this must update before the app can be used. Set in the
  /// manifest (`min_supported_build`) when a release fixes something bad
  /// enough that nobody should stay on the old one; 0 means never forced.
  final int minSupportedBuild;
}

/// The outcome of an update check: what is installed, what the server offers,
/// and whether that is actually newer.
class UpdateResult {
  const UpdateResult({
    required this.currentVersion,
    required this.currentBuild,
    this.latest,
    this.error,
  });

  final String currentVersion;
  final int currentBuild;
  final UpdateInfo? latest;
  final String? error;

  bool get updateAvailable =>
      latest != null && latest!.build > currentBuild;

  /// True when the installed build is older than the server's minimum and a
  /// newer one exists to move to. The second half matters: a manifest whose
  /// minimum is above its own build would otherwise lock everyone out with
  /// nothing to install.
  bool get updateRequired =>
      updateAvailable && currentBuild < latest!.minSupportedBuild;
}

/// Checks a small JSON manifest on the download site for a newer build.
///
/// The build number is the source of truth (the version name can repeat across
/// builds — see the release notes), and it is read from the running package via
/// [PackageInfo], so it always reflects the actual installed build rather than a
/// constant that could drift out of date.
class UpdateService {
  UpdateService({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  /// Lives beside the APK on the download host, so publishing a new build is:
  /// drop the APK in and bump this file. No restart, no deploy.
  ///
  /// CHANGING THIS STRANDS EVERY INSTALL THAT HAS NOT YET UPDATED. A copy on a
  /// phone only ever asks the address compiled into it, so the previous host has
  /// to keep answering until every install has taken a build carrying the new
  /// one. Retiring safenest.raghudarshan.online before that is what stranded a
  /// customer in August; it is the same trap, one layer down.
  ///
  /// `--dart-define=AIBIT_UPDATE_URL=…` overrides it for a local test build
  /// only, so the forced-update screen can be exercised against a throwaway
  /// manifest instead of the live one every install reads.
  static const manifestUrl = String.fromEnvironment(
    'AIBIT_UPDATE_URL',
    defaultValue: 'https://safenesthub.in/ai-bit-latest.json',
  );

  Future<UpdateResult> check() async {
    final info = await PackageInfo.fromPlatform();
    final currentBuild = int.tryParse(info.buildNumber) ?? 0;

    try {
      final resp = await _http
          .get(Uri.parse(manifestUrl))
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        return UpdateResult(
          currentVersion: info.version,
          currentBuild: currentBuild,
          error: 'The update server returned ${resp.statusCode}.',
        );
      }
      final map = jsonDecode(resp.body) as Map<String, dynamic>;
      final latest = UpdateInfo(
        version: '${map['version'] ?? '?'}',
        build: (map['build'] as num?)?.toInt() ?? 0,
        url: '${map['url'] ?? ''}',
        notes: '${map['notes'] ?? ''}',
        minSupportedBuild: (map['min_supported_build'] as num?)?.toInt() ?? 0,
      );
      return UpdateResult(
        currentVersion: info.version,
        currentBuild: currentBuild,
        latest: latest,
      );
    } catch (_) {
      // A neutral message rather than a raw exception — the check is a
      // convenience, not a core feature, and the reason is almost always "no
      // network" or "server not reachable".
      return UpdateResult(
        currentVersion: info.version,
        currentBuild: currentBuild,
        error: 'Could not reach the update server. Check your connection.',
      );
    }
  }

  void close() => _http.close();
}
