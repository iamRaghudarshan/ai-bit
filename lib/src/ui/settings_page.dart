import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/settings.dart';
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
            title: const Text('Default quality'),
            subtitle: Text(settings.preferredQuality),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickQuality(context, settings),
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
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Personal build'),
            subtitle: Text(
              'Streams are resolved directly from YouTube, so no ads are ever '
              'requested. Everything you save stays on this device. Intended '
              'for personal use only — do not redistribute.',
            ),
            isThreeLine: true,
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
