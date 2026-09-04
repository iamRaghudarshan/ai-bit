import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/settings.dart';
import '../data/update_service.dart';
import '../player/playback_controller.dart';
import 'app_lock_page.dart';
import 'data_usage_page.dart';
import 'storage_page.dart';
import 'widgets/library_transfer.dart';

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
              'Keep playing when you leave the app.',
            ),
            onChanged: (value) => settings.backgroundPlayback = value,
          ),
          SwitchListTile(
            value: settings.audioOnly,
            title: const Text('Audio only'),
            subtitle: const Text(
              'Sound only, no picture. Uses much less data.',
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
              'Saves data while the screen is off. Picture returns on unlock.',
            ),
            onChanged: (value) => settings.audioOnlyWhenLocked = value,
          ),
          SwitchListTile(
            value: settings.autoplayNext,
            title: const Text('Autoplay next video'),
            subtitle: const Text(
              'Play the next video in the queue automatically.',
            ),
            onChanged: (value) => settings.autoplayNext = value,
          ),
          // Both platforms now: iOS arms an inline AVPlayerLayer, Android sets
          // setAutoEnterEnabled on the Activity. Different mechanisms, one
          // promise, so it is one setting.
          if (!kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.iOS ||
                  defaultTargetPlatform == TargetPlatform.android))
            SwitchListTile(
              value: settings.autoPip,
              title: const Text('Automatic Picture in Picture'),
              subtitle: const Text(
              'Float the video when you leave the app. New — try it and see.',
            ),
              onChanged: (value) => settings.autoPip = value,
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
              'Always use the lowest quality. Most videos stop at 360p.',
            ),
            onChanged: (value) {
              settings.dataSaver = value;
              if (playback.hasVideo) playback.reloadCurrent();
            },
          ),
          SwitchListTile(
            value: settings.rememberSpeedPerChannel,
            title: const Text('Remember speed per channel'),
            subtitle: const Text(
              'Reuse the speed you last set for each channel.',
            ),
            onChanged: (value) => settings.rememberSpeedPerChannel = value,
          ),
          SwitchListTile(
            value: settings.sponsorBlock,
            title: const Text('Skip sponsors (SponsorBlock)'),
            subtitle: const Text(
              'Skip sponsor segments automatically. No account needed.',
            ),
            onChanged: (value) => settings.sponsorBlock = value,
          ),
          const Divider(),
          const _SectionLabel('Data & battery'),
          SwitchListTile(
            value: settings.mobileDataSaver,
            title: const Text('Data saver on mobile data'),
            subtitle: const Text(
              'Lowest quality only when off Wi-Fi.',
            ),
            onChanged: (value) => settings.mobileDataSaver = value,
          ),
          SwitchListTile(
            value: settings.mobileAudioOnly,
            title: const Text('Audio only on mobile data'),
            subtitle: const Text(
              'Drop the picture when off Wi-Fi. Uses the least data.',
            ),
            onChanged: (value) => settings.mobileAudioOnly = value,
          ),
          SwitchListTile(
            value: settings.batterySaver,
            title: const Text('Battery saver'),
            subtitle: const Text(
              'Lower the quality when the battery gets low.',
            ),
            onChanged: (value) => settings.batterySaver = value,
          ),
          SwitchListTile(
            value: settings.trackDataUsage,
            title: const Text('Track data usage'),
            subtitle: const Text(
              'Count what each channel costs you.',
            ),
            onChanged: (value) => settings.trackDataUsage = value,
          ),
          ListTile(
            leading: const Icon(Icons.data_usage_outlined),
            title: const Text('Data usage'),
            subtitle: const Text(
              'See what you have used, by channel.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DataUsagePage()),
            ),
          ),
          const Divider(),
          const _SectionLabel('Privacy & lock'),
          SwitchListTile(
            value: settings.appLockEnabled,
            title: const Text('App lock'),
            subtitle: Text(
              settings.appLockPinHash.isEmpty
                  ? 'Ask for a PIN before the app opens. No PIN set yet — '
                        'turning this on will ask you to choose one.'
                  : 'Ask for a PIN before the app opens.',
            ),
            isThreeLine: settings.appLockPinHash.isEmpty,
            onChanged: (value) => _toggleAppLock(context, settings, value),
          ),
          ListTile(
            leading: const Icon(Icons.password_outlined),
            title: Text(
              settings.appLockPinHash.isEmpty ? 'Set PIN' : 'Change PIN',
            ),
            subtitle: const Text(
              'Four digits, asked for twice. Only the hash is stored.',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => AppLockPage.setUp(context),
          ),
          SwitchListTile(
            value: settings.appLockBiometric,
            title: const Text('Unlock with biometrics'),
            subtitle: const Text(
              'Use your fingerprint or face instead of the PIN.',
            ),
            // Off limits until there is a PIN behind it: biometrics can be
            // declined or unavailable on the device, and the PIN is the only
            // way back in when they are.
            onChanged:
                settings.appLockEnabled && settings.appLockPinHash.isNotEmpty
                ? (value) => settings.appLockBiometric = value
                : null,
          ),
          SwitchListTile(
            value: settings.incognito,
            title: const Text('Incognito mode'),
            subtitle: const Text(
              'Stop saving what you watch and search.',
            ),
            onChanged: (value) => settings.incognito = value,
          ),
          ListTile(
            leading: const Icon(Icons.auto_delete_outlined),
            title: const Text('Clear history automatically'),
            subtitle: Text(_retentionLabel(settings.historyRetentionDays)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickRetention(context, settings),
          ),
          const Divider(),
          const _SectionLabel('Kids'),
          ListTile(
            leading: const Icon(Icons.lock_person_outlined),
            title: Text(
              settings.kidsPinHash.isEmpty ? 'Set Kids PIN' : 'Change Kids PIN',
            ),
            subtitle: Text(
              settings.kidsPinHash.isEmpty
                  ? 'Without one, Kids mode can be switched off by anyone '
                        'holding the phone.'
                  : 'Asked for before Kids mode can be switched off.',
            ),
            isThreeLine: settings.kidsPinHash.isEmpty,
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _kidsPin(context, settings),
          ),
          ListTile(
            leading: const Icon(Icons.hourglass_bottom_outlined),
            title: const Text('Daily time limit'),
            subtitle: Text(_limitLabel(settings.kidsDailyLimitMinutes)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickKidsLimit(context, settings),
          ),
          const Divider(),
          const _SectionLabel('Storage'),
          ListTile(
            leading: const Icon(Icons.sd_storage_outlined),
            title: const Text('Storage'),
            subtitle: const Text(
              'Downloads, cache and history. Free up space.',
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
              'True black background. Saves battery on OLED screens.',
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
          const _SectionLabel('Import & export'),
          Builder(
            builder: (context) => ListTile(
              leading: const Icon(Icons.drive_folder_upload_outlined),
              title: const Text('Import from Google Takeout'),
              subtitle: const Text(
              'Bring in playlists, subscriptions and history from your Google export. No sign-in.',
            ),
              onTap: () => importFromTakeout(context),
            ),
          ),
          Builder(
            builder: (context) => ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('Export library'),
              subtitle: const Text(
              'Save your playlists, subscriptions and history to a file.',
            ),
              onTap: () => exportLibrary(context),
            ),
          ),
          Builder(
            builder: (context) => ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('Import library'),
              subtitle: const Text(
              'Load a file you saved earlier. Adds to what you have.',
            ),
              onTap: () => restoreLibrary(context),
            ),
          ),
          const Divider(),
          const _SectionLabel('About'),
          // The installed version, always visible — before this the only way
          // to learn what build was running was to tap Check for updates and
          // read it out of the result dialog.
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snapshot) {
              final info = snapshot.data;
              return ListTile(
                leading: const Icon(Icons.verified_outlined),
                title: const Text('Version'),
                subtitle: Text(
                  info == null
                      ? '…'
                      : 'v${info.version} (build ${info.buildNumber})',
                ),
              );
            },
          ),
          Builder(
            builder: (context) => ListTile(
              leading: const Icon(Icons.system_update_outlined),
              title: const Text('Check for updates'),
              subtitle: const Text(
              'See if a newer build is available.',
            ),
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

  /// Turning the lock on with no PIN chosen would arm nothing: an empty hash
  /// never verifies, so [AppLockPage.unlock] treats it as already unlocked and
  /// the switch would be a lie. Collect the PIN first, and leave the switch
  /// off if the setup was abandoned.
  Future<void> _toggleAppLock(
    BuildContext context,
    SettingsService settings,
    bool value,
  ) async {
    if (!value) {
      settings.appLockEnabled = false;
      return;
    }
    if (settings.appLockPinHash.isEmpty) {
      await AppLockPage.setUp(context);
      if (settings.appLockPinHash.isEmpty) return;
    }
    settings.appLockEnabled = true;
  }

  String _retentionLabel(int days) =>
      days <= 0 ? 'Never — history is kept until you clear it' : 'After $days days';

  Future<void> _pickRetention(
    BuildContext context,
    SettingsService settings,
  ) async {
    final choice = await _pickInt(
      context,
      title: 'Clear history automatically',
      current: settings.historyRetentionDays,
      options: const [
        (0, 'Never'),
        (7, 'After 7 days'),
        (30, 'After 30 days'),
        (90, 'After 90 days'),
      ],
    );
    if (choice != null) settings.historyRetentionDays = choice;
  }

  String _limitLabel(int minutes) {
    if (minutes <= 0) return 'Off — Kids mode can be watched all day';
    if (minutes < 60) return '$minutes minutes a day';
    final hours = minutes / 60;
    final label = hours == hours.roundToDouble()
        ? hours.round().toString()
        : hours.toStringAsFixed(1);
    return '$label ${hours == 1 ? 'hour' : 'hours'} a day';
  }

  Future<void> _pickKidsLimit(
    BuildContext context,
    SettingsService settings,
  ) async {
    final choice = await _pickInt(
      context,
      title: 'Daily time limit in Kids mode',
      current: settings.kidsDailyLimitMinutes,
      options: const [
        (0, 'Off'),
        (15, '15 minutes'),
        (30, '30 minutes'),
        (60, '1 hour'),
        (120, '2 hours'),
      ],
    );
    if (choice != null) settings.kidsDailyLimitMinutes = choice;
  }

  /// Set, change or remove the PIN that guards leaving Kids mode.
  Future<void> _kidsPin(BuildContext context, SettingsService settings) async {
    if (settings.kidsPinHash.isEmpty) {
      await AppLockPage.setUpKidsPin(context);
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.password_outlined),
              title: const Text('Change Kids PIN'),
              onTap: () => Navigator.pop(sheet, 'change'),
            ),
            ListTile(
              leading: const Icon(Icons.lock_open_outlined),
              title: const Text('Remove Kids PIN'),
              subtitle: const Text('You will be asked for the current one.'),
              onTap: () => Navigator.pop(sheet, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'change') {
      await AppLockPage.setUpKidsPin(context);
      return;
    }
    // Removing the guard has to be proved, otherwise the child it guards
    // against simply removes it from this screen.
    if (await AppLockPage.confirmKidsPin(context)) settings.kidsPinHash = '';
  }

  /// A one-of-N sheet for the plain integer settings. Both pickers below want
  /// exactly this and nothing more, so they share it rather than each growing
  /// their own copy of the same list.
  Future<int?> _pickInt(
    BuildContext context, {
    required String title,
    required int current,
    required List<(int, String)> options,
  }) => showModalBottomSheet<int>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                title,
                style: Theme.of(sheet).textTheme.titleMedium,
              ),
            ),
          ),
          for (final (value, label) in options)
            ListTile(
              title: Text(label),
              trailing: value == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(sheet, value),
            ),
        ],
      ),
    ),
  );

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
