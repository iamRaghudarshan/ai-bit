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
  });

  final String version;
  final int build;
  final String url;
  final String notes;
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

  /// Lives in the same no-restart static folder as the APK, so publishing a new
  /// build is: drop the APK in and bump this file.
  static const manifestUrl =
      'https://safenest.raghudarshan.online/ai-bit-latest.json';

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
