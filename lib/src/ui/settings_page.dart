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
          const Divider(),
          const _SectionLabel('Downloads'),
          SwitchListTile(
            value: settings.downloadHd,
            title: const Text('Download in HD'),
            subtitle: const Text(
              'Saves the best quality available, up to 4K. YouTube serves HD '
              'as separate video and audio, so this fetches both and joins '
              'them — several times the data, and a few seconds at the end.',
            ),
            isThreeLine: true,
            onChanged: (value) => settings.downloadHd = value,
          ),
          SwitchListTile(
            value: settings.downloadMp3,
            title: const Text('Save audio as MP3'),
            subtitle: const Text(
              'For car stereos and older players. YouTube serves AAC, which '
              'everything modern reads, so converting re-encodes it — leave '
              'this off unless something refuses the .m4a files.',
            ),
            isThreeLine: true,
            onChanged: (value) => settings.downloadMp3 = value,
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
