import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme.dart';
import '../data/update_service.dart';
import 'widgets/library_transfer.dart';

/// Checks for a newer build once per launch and tells the user, the way the
/// store apps do — before this, an update was only found by someone who
/// happened to open Settings → About → Check for updates.
///
/// Two strengths, both driven by `ai-bit-latest.json`:
///
///  * **Required** — the installed build is below `min_supported_build`. A
///    full screen that cannot be dismissed or backed out of, with only a
///    Download button. For a release that fixes something bad enough that
///    nobody should stay behind.
///  * **Available** — a dialog with Later, shown once per new build so it does
///    not nag on every launch.
///
/// Android only: iOS updates through TestFlight, which notifies by itself.
class UpdatePrompt {
  static const _dismissedKey = 'updateDismissedBuild';

  static Future<void> checkOnLaunch(BuildContext Function() context) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final service = UpdateService();
    final UpdateResult result;
    try {
      result = await service.check();
    } finally {
      service.close();
    }
    // Offline or the host is down: say nothing. A launch check that shows an
    // error dialog every time the phone has no signal is worse than none.
    final latest = result.latest;
    if (latest == null || !result.updateAvailable) {
      if (result.error != null) {
        debugPrint('AI BIT: launch update check failed - ${result.error}');
      }
      return;
    }
    debugPrint('AI BIT: build ${latest.build} available '
        '(installed ${result.currentBuild}, minimum ${latest.minSupportedBuild})');

    final ctx = context();
    if (!ctx.mounted) return;
    if (result.updateRequired) {
      await Navigator.of(ctx).push(
        PageRouteBuilder<void>(
          settings: const RouteSettings(name: 'update-required'),
          pageBuilder: (_, _, _) => _RequiredUpdatePage(result: result),
        ),
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getInt(_dismissedKey) == latest.build) return;
    final again = context();
    if (!again.mounted) return;
    final later = await showDialog<bool>(
      context: again,
      builder: (dialog) => AlertDialog(
        title: const Text('Update available'),
        content: _UpdateDetails(result: result),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialog, false);
              _download(latest.url);
            },
            child: const Text('Download'),
          ),
        ],
      ),
    );
    if (later ?? true) await prefs.setInt(_dismissedKey, latest.build);
  }

  static Future<bool> _download(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)
          .catchError((Object _) => false);
}

class _UpdateDetails extends StatelessWidget {
  const _UpdateDetails({required this.result});

  final UpdateResult result;

  @override
  Widget build(BuildContext context) {
    final latest = result.latest!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Installed: v${result.currentVersion} (build ${result.currentBuild})'),
        const SizedBox(height: 4),
        Text(
          'Latest: v${latest.version} (build ${latest.build})',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        if (latest.notes.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(latest.notes),
        ],
      ],
    );
  }
}

class _RequiredUpdatePage extends StatelessWidget {
  const _RequiredUpdatePage({required this.result});

  final UpdateResult result;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(),
                const Icon(Icons.system_update, size: 56, color: AppColors.brand),
                const SizedBox(height: 20),
                Text(
                  'Update required',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                const Text(
                  'This version has a problem that the new one fixes. '
                  'Install the update to keep using AI BIT.',
                ),
                const SizedBox(height: 16),
                _UpdateDetails(result: result),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      final ok = await UpdatePrompt._download(result.latest!.url);
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Could not open the download link.'),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.download),
                    label: const Text('Download update'),
                  ),
                ),
                const SizedBox(height: 8),
                // Here, not in Settings: this screen blocks Settings, and the
                // uninstall the note below may call for erases the library.
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => exportLibrary(context),
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Back up my library first'),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'If Android says "App not installed", back up your library '
                  'with the button above, uninstall AI BIT, install the '
                  'download, then restore it in Settings → Import & export.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
