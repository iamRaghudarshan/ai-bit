import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/interests.dart';
import '../data/settings.dart';

/// Where the user says what they want to see, rather than being inferred from.
///
/// Everything else in the recommender watches behaviour and draws conclusions.
/// This is the other half, and it earns its place on the one occasion
/// inference cannot help at all: a fresh install has no behaviour to infer
/// from, and the feed stayed generic until enough history built up to displace
/// the evergreen filler. Asking takes ten seconds and skips that entirely.
///
/// Selections apply immediately rather than behind a Save button. There is no
/// invalid state to guard against — any set of chips is a legitimate answer,
/// including none — and a Save button on a screen that cannot be got wrong is
/// a step that exists only to be forgotten.
class InterestsPage extends StatefulWidget {
  const InterestsPage({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const InterestsPage()),
      );

  @override
  State<InterestsPage> createState() => _InterestsPageState();
}

class _InterestsPageState extends State<InterestsPage> {
  late Set<String> _chosen;

  @override
  void initState() {
    super.initState();
    _chosen = context.read<SettingsService>().interestTopics.toSet();
  }

  void _toggle(String id) {
    setState(() {
      if (!_chosen.remove(id)) _chosen.add(id);
    });
    // Written through on every tap. The feed reads this on its next load, so
    // there is no moment where the screen and the setting disagree.
    context.read<SettingsService>().interestTopics =
        // Stored in catalogue order, not tap order: tap order is an artefact
        // of which chip was nearest and would make the stored value differ
        // between two users who chose exactly the same things.
        [
      for (final interest in interestCatalogue)
        if (_chosen.contains(interest.id)) interest.id,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Your interests')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'Pick what you want recommended. This shapes your home feed and '
            'Shorts straight away, and keeps counting alongside what you '
            'actually watch.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _chosen.isEmpty
                // Says what happens rather than nagging. Choosing nothing is a
                // legitimate answer and the app worked that way for its whole
                // life before this screen existed.
                ? 'Nothing picked — your feed is built from what you watch and '
                    'search for.'
                : '${_chosen.length} selected',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final interest in interestCatalogue)
                FilterChip(
                  label: Text(interest.label),
                  selected: _chosen.contains(interest.id),
                  onSelected: (_) => _toggle(interest.id),
                ),
            ],
          ),
          if (_chosen.isNotEmpty) ...[
            const SizedBox(height: 24),
            TextButton.icon(
              onPressed: () {
                setState(_chosen.clear);
                context.read<SettingsService>().interestTopics = const [];
              },
              icon: const Icon(Icons.clear_all),
              label: const Text('Clear all'),
            ),
          ],
        ],
      ),
    );
  }
}

/// The language and region the app asks YouTube for.
///
/// Two settings rather than one, because YouTube treats them as two questions
/// and they genuinely differ: `gl` decides what is popular and what is even
/// available, `hl` decides what the text comes back as. Somebody in India who
/// reads English wants India and English, and a single combined "locale"
/// setting gets that person the wrong feed.
///
/// Both default to the device's own, so this screen is optional rather than a
/// gate — the app was hardcoded to en/US before, which quietly asked America
/// what was worth watching.
class ContentLocalePage extends StatelessWidget {
  const ContentLocalePage({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ContentLocalePage()),
      );

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final device = View.of(context).platformDispatcher.locale;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Language & region')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'What language videos come back in, and which country’s YouTube '
              'to ask. They are separate on purpose — you might want India’s '
              'recommendations in English.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const _GroupLabel('Language'),
          // RadioGroup rather than per-tile groupValue/onChanged, which
          // Flutter deprecated after 3.32.
          RadioGroup<String>(
            groupValue: settings.contentLanguage,
            onChanged: (value) => settings.contentLanguage = value ?? '',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final language in languageCatalogue)
                  RadioListTile<String>(
                    value: language.code,
                    title: Text(language.label),
                    subtitle: language.code.isEmpty
                        ? Text('Currently ${device.languageCode}')
                        : null,
                  ),
              ],
            ),
          ),
          const Divider(),
          const _GroupLabel('Region'),
          RadioGroup<String>(
            groupValue: settings.contentRegion,
            onChanged: (value) => settings.contentRegion = value ?? '',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final region in regionCatalogue)
                  RadioListTile<String>(
                    value: region.code,
                    title: Text(region.label),
                    subtitle: region.code.isEmpty
                        ? Text('Currently ${device.countryCode ?? 'unknown'}')
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 1.2,
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      );
}
