import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/settings.dart';
import '../data/update_service.dart';
import '../player/playback_controller.dart';
import 'storage_page.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final playback = context.read<PlaybackController>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionLabel('Playback'),
          SwitchListTile(
            value: settings.backgroundPlayback,
            title: const Text('Background playback'),
            subtitle: const Text(
              'Keep audio going when the app is minimised or the screen is off. '
              'Takes effect on the next video.',
            ),
            onChanged: (value) => settings.backgroundPlayback = value,
          ),
          SwitchListTile(
            value: settings.audioOnly,
            title: const Text('Audio only'),
            subtitle: const Text(
              'Stream just the audio track. Uses far less data when you are '
              'mostly listening.',
            ),
            onChanged: (value) {
              settings.audioOnly = value;
              if (playback.hasVideo) playback.reloadCurrent();
            },
          ),
          SwitchListTile(
            value: settings.audioOnlyWhenLocked,
            title: const Text('Drop video when the screen is off'),
            subtitle: const Text(
              'Drops to the smallest size while the screen is off and restores '
              'it on unlock, without interrupting playback. Videos offered in '
              'only one size are unaffected.',
            ),
            onChanged: (value) => settings.audioOnlyWhenLocked = value,
          ),
          SwitchListTile(
            value: settings.autoplayNext,
            title: const Text('Autoplay next video'),
            subtitle: const Text('Continue with the up-next queue when a video ends.'),
            onChanged: (value) => settings.autoplayNext = value,
          ),
          ListTile(
            enabled: !settings.dataSaver,
            title: const Text('Default quality'),
            subtitle: Text(
              settings.dataSaver
                  ? 'Overridden by Data saver (lowest)'
                  : settings.preferredQuality,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: settings.dataSaver
                ? null
                : () => _pickQuality(context, settings),
          ),
          SwitchListTile(
            value: settings.dataSaver,
            title: const Text('Data saver'),
            subtitle: const Text(
              'Always stream the lowest quality a video offers, to use as '
              'little data as possible. Many videos only offer 360p as a '
              'playable stream, so that is the floor; pair with Audio only for '
              'the least data.',
            ),
            isThreeLine: true,
            onChanged: (value) {
              settings.dataSaver = value;
              if (playback.hasVideo) playback.reloadCurrent();
            },
          ),
          SwitchListTile(
            value: settings.rememberSpeedPerChannel,
            title: const Text('Remember speed per channel'),
            subtitle: const Text(
              'Reapply the playback speed you last used for a channel when '
              'another of its videos plays.',
            ),
            onChanged: (value) => settings.rememberSpeedPerChannel = value,
          ),
          SwitchListTile(
            value: settings.sponsorBlock,
            title: const Text('Skip sponsors (SponsorBlock)'),
            subtitle: const Text(
              'Automatically skip sponsor and self-promo segments, using the '
              'community SponsorBlock database. No account needed.',
            ),
            isThreeLine: true,
            onChanged: (value) => settings.sponsorBlock = value,
          ),
          const Divider(),
          const _SectionLabel('Storage'),
          ListTile(
            leading: const Icon(Icons.sd_storage_outlined),
            title: const Text('Storage'),
            subtitle: const Text(
              'See what downloads, cache and history are using, and clear any '
              'of them.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const StoragePage()),
            ),
          ),
          const Divider(),
          const _SectionLabel('Appearance'),
          RadioGroup<ThemeMode>(
            groupValue: settings.themeMode,
            onChanged: (value) {
              if (value != null) settings.themeMode = value;
            },
            child: const Column(
              children: [
                RadioListTile<ThemeMode>(
                  value: ThemeMode.dark,
                  title: Text('Dark'),
                ),
                RadioListTile<ThemeMode>(
                  value: ThemeMode.light,
                  title: Text('Light'),
                ),
                RadioListTile<ThemeMode>(
                  value: ThemeMode.system,
                  title: Text('Match system'),
                ),
              ],
            ),
          ),
          SwitchListTile(
            value: settings.amoledBlack,
            title: const Text('AMOLED black'),
            subtitle: const Text(
              'Pure-black backgrounds in dark mode, which switch OLED pixels '
              'fully off to save battery.',
            ),
            onChanged: (value) => settings.amoledBlack = value,
          ),
          ListTile(
            title: const Text('Accent colour'),
            subtitle: const Text('Used for highlights and the brand tint.'),
            trailing: CircleAvatar(
              radius: 12,
              backgroundColor: Color(settings.accentColor),
            ),
            onTap: () => _pickAccent(context, settings),
          ),
          const Divider(),
          const _SectionLabel('About'),
          Builder(
            builder: (context) => ListTile(
              leading: const Icon(Icons.system_update_outlined),
              title: const Text('Check for updates'),
              subtitle: const Text('See whether a newer build is available.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _checkForUpdates(context),
            ),
          ),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Personal build'),
            subtitle: Text(
              'Streams are resolved directly from the source, so no ads are '
              'ever requested. Everything you save stays on this device. '
              'Intended for personal use only — do not redistribute.',
            ),
            isThreeLine: true,
          ),
        ],
      ),
    );
  }

  Future<void> _checkForUpdates(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final service = UpdateService();
    final result = await service.check();
    service.close();
    if (!context.mounted) return;
    Navigator.of(context).pop(); // dismiss the spinner

    // A reachability failure — say so plainly.
    if (result.latest == null) {
      _showInfo(context, 'Update check failed',
          result.error ?? 'Something went wrong.');
      return;
    }

    if (!result.updateAvailable) {
      _showInfo(
        context,
        'Up to date',
        "You're on the latest version — v${result.currentVersion} "
            '(build ${result.currentBuild}).',
      );
      return;
    }

    // Newer build offered. On Android the download is a plain APK the user
    // installs; iOS cannot sideload, so it updates through TestFlight instead.
    final latest = result.latest!;
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update available'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Installed: v${result.currentVersion} '
                '(build ${result.currentBuild})'),
            const SizedBox(height: 4),
            Text(
              'Latest: v${latest.version} (build ${latest.build})',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (latest.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(latest.notes),
            ],
            if (!isAndroid) ...[
              const SizedBox(height: 12),
              const Text(
                'On iOS, install the update through TestFlight.',
                style: TextStyle(fontStyle: FontStyle.italic),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later'),
          ),
          if (isAndroid)
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final uri = Uri.parse(latest.url);
                final ok = await launchUrl(
                  uri,
                  mode: LaunchMode.externalApplication,
                );
                if (!ok) {
                  messenger.showSnackBar(
                    const SnackBar(
                        content: Text('Could not open the download link.')),
                  );
                }
              },
              child: const Text('Download'),
            ),
        ],
      ),
    );
  }

  void _showInfo(BuildContext context, String title, String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _pickAccent(BuildContext context, SettingsService settings) {
    // A small palette rather than a full colour wheel: enough to personalise,
    // simple to tap.
    const options = <(String, int)>[
      ('Red', 0xFFFF0033),
      ('Blue', 0xFF3B82F6),
      ('Green', 0xFF22C55E),
      ('Purple', 0xFF8B5CF6),
      ('Orange', 0xFFF97316),
      ('Pink', 0xFFEC4899),
      ('Teal', 0xFF14B8A6),
      ('Amber', 0xFFF59E0B),
    ];
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (final (name, value) in options)
                GestureDetector(
                  onTap: () {
                    settings.accentColor = value;
                    Navigator.pop(context);
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: Color(value),
                        child: settings.accentColor == value
                            ? const Icon(Icons.check, color: Colors.white)
                            : null,
                      ),
                      const SizedBox(height: 4),
                      Text(name, style: const TextStyle(fontSize: 11)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _pickQuality(BuildContext context, SettingsService settings) {
    // The full ladder, not just what happens to be loaded.
    //
    // This used to list only the current video's renditions, so opening
    // Settings while a progressive video was playing offered "Auto" and
    // "360p" and nothing else — as though the app could not do better. This
    // setting is a preference for every video, and the player already picks
    // the nearest rendition at or below it, so a video that tops out lower
    // simply plays lower.
    //
    // The on-video picker is the one that should list only what this video
    // actually has.
    final playback = context.read<PlaybackController>();
    final options = <String>{
      SettingsService.autoQuality,
      '2160p',
      '1440p',
      '1080p',
      '720p',
      '480p',
      '360p',
      '240p',
      '144p',
      // Anything unusual the loaded video offers that the standard ladder
      // does not, such as the 320p some channels serve.
      ...playback.qualities,
    }.toList()
      ..sort((a, b) {
        if (a == SettingsService.autoQuality) return -1;
        if (b == SettingsService.autoQuality) return 1;
        int height(String l) =>
            int.tryParse(l.replaceAll(RegExp('[^0-9]'), '')) ?? 0;
        return height(b).compareTo(height(a));
      });

    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in options)
              ListTile(
                title: Text(option),
                subtitle: option == SettingsService.autoQuality
                    ? const Text('Adjusts to your connection')
                    : (playback.qualities.contains(option)
                          ? const Text('Available on this video')
                          : null),
                trailing: settings.preferredQuality == option
                    ? const Icon(Icons.check)
                    : null,
                onTap: () {
                  // Through the controller, so a video already playing changes
                  // now rather than at the next one. It records the preference
                  // as part of the same call.
                  playback.setQuality(option);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
    child: Text(
      label.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        letterSpacing: 1,
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
