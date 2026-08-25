import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/data_usage_service.dart';
import '../data/db.dart';
import '../data/settings.dart';
import '../data/storage_service.dart' show formatBytes;

/// How far back the screen looks.
///
/// "All time" is expressed as an absurd number of days rather than a separate
/// query path: [DataUsageService] turns days into a day index, and a start
/// index far below any real one selects everything without a second SQL
/// branch to keep in step with the first.
enum _Range {
  week(7, '7 days'),
  month(30, '30 days'),
  all(100000, 'All time');

  const _Range(this.days, this.label);

  final int days;
  final String label;
}

/// What each channel cost in data, split by how it was spent.
///
/// Streaming numbers here are **estimates** and downloads are **exact** — see
/// [DataUsageService]. That distinction is stated on the screen too, because
/// the obvious next thing a user does with this page is hold it up against a
/// carrier bill, and the streaming half will not match.
class DataUsagePage extends StatefulWidget {
  const DataUsagePage({super.key});

  @override
  State<DataUsagePage> createState() => _DataUsagePageState();
}

class _DataUsagePageState extends State<DataUsagePage> {
  late final DataUsageService _service;

  _Range _range = _Range.month;
  bool _loading = true;
  List<_ChannelUsage> _channels = const [];
  int _total = 0;
  int _streamed = 0;
  int _downloaded = 0;

  @override
  void initState() {
    super.initState();
    // Built here rather than taken from a provider: the service holds no state
    // of its own, it is a thin query wrapper over the database and settings,
    // both of which are provided app-wide. A second instance costs nothing and
    // the screen does not depend on a provider registration to exist.
    _service = DataUsageService(
      database: context.read<AppDatabase>(),
      settings: context.read<SettingsService>(),
    );
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final days = _range.days;
    final rows = await _service.byChannel(days: days);
    final total = await _service.total(days: days);
    final streamed = await _service.total(days: days, kind: 'stream');
    final downloaded = await _service.total(days: days, kind: 'download');
    if (!mounted) return;
    setState(() {
      _channels = _merge(rows);
      _total = total;
      _streamed = streamed;
      _downloaded = downloaded;
      _loading = false;
    });
  }

  /// byChannel returns one row per channel *per kind*, because the two costs
  /// are worth telling apart. The list wants one row per channel with both
  /// halves on it, heaviest channel first.
  static List<_ChannelUsage> _merge(List<DataUsageRow> rows) {
    final byId = <String, _ChannelUsage>{};
    for (final row in rows) {
      final entry = byId.putIfAbsent(
        row.channelId,
        () => _ChannelUsage(
          // A channel whose title was never recorded still has to be nameable.
          row.channelTitle.isEmpty ? 'Unknown channel' : row.channelTitle,
        ),
      );
      if (row.kind == 'download') {
        entry.downloaded += row.bytes;
      } else {
        entry.streamed += row.bytes;
      }
    }
    final merged = byId.values.toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    return merged;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tracking = context.watch<SettingsService>().trackDataUsage;
    final heaviest = _channels.isEmpty ? 0 : _channels.first.total;

    return Scaffold(
      appBar: AppBar(title: const Text('Data usage')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // The previous range's totals stay up while the next range
                  // loads, so the number changes once instead of dropping to
                  // 0 B and climbing back. Only the very first load has
                  // nothing to show.
                  _loading && _channels.isEmpty ? '…' : formatBytes(_total),
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  _range == _Range.all
                      ? 'since tracking began'
                      : 'over the last ${_range.days} days',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: SegmentedButton<_Range>(
              segments: [
                for (final range in _Range.values)
                  ButtonSegment<_Range>(value: range, label: Text(range.label)),
              ],
              selected: {_range},
              showSelectedIcon: false,
              onSelectionChanged: (selection) {
                setState(() => _range = selection.first);
                _load();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: _Stat(
                    label: 'Streaming',
                    value: formatBytes(_streamed),
                    note: 'estimated',
                    icon: Icons.play_circle_outline,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _Stat(
                    label: 'Downloads',
                    value: formatBytes(_downloaded),
                    note: 'exact',
                    icon: Icons.download_outlined,
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: _EstimateNote(),
          ),
          if (!tracking)
            const ListTile(
              leading: Icon(Icons.pause_circle_outline),
              title: Text('Tracking is off'),
              subtitle: Text(
                'These totals stopped growing when you turned off Track data '
                'usage in Settings. What was already recorded is kept.',
              ),
              isThreeLine: true,
            ),
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              'BY CHANNEL',
              style: theme.textTheme.labelSmall?.copyWith(
                letterSpacing: 1,
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_channels.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 32),
              child: Text(
                'Nothing recorded for this period yet. Watch or download '
                'something and it will show up here.',
              ),
            )
          else
            for (final channel in _channels)
              _ChannelTile(usage: channel, heaviest: heaviest),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// One channel's two costs. Mutable because [_DataUsagePageState._merge]
/// accumulates into it as it folds the per-kind rows together.
class _ChannelUsage {
  _ChannelUsage(this.title);

  final String title;
  int streamed = 0;
  int downloaded = 0;

  int get total => streamed + downloaded;
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({required this.usage, required this.heaviest});

  final _ChannelUsage usage;

  /// The largest channel's total, so every bar is drawn against the same
  /// scale and the list reads as a ranking at a glance.
  final int heaviest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parts = <String>[
      if (usage.streamed > 0) '${formatBytes(usage.streamed)} streamed',
      if (usage.downloaded > 0) '${formatBytes(usage.downloaded)} downloaded',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  usage.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(formatBytes(usage.total), style: theme.textTheme.bodyMedium),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: heaviest == 0 ? 0 : usage.total / heaviest,
              minHeight: 6,
              backgroundColor: theme.colorScheme.onSurface.withValues(
                alpha: 0.08,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            parts.join(' • '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.note,
    required this.icon,
  });

  final String label;
  final String value;
  final String note;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text(label, style: theme.textTheme.labelMedium),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            note,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// Says plainly which half of the numbers can be trusted.
///
/// Not a footnote: the native player opens the stream URL itself, so no Dart
/// code ever sees those bytes and the streaming figure is watched-time times
/// an assumed bitrate. A user comparing this screen against a carrier bill has
/// to know that before they conclude the app is lying.
class _EstimateNote extends StatelessWidget {
  const _EstimateNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline,
          size: 16,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Streaming figures are an estimate — the system player fetches the '
            'video itself, so the app can only work them out from how long you '
            'watched and at what quality. Download figures are exact, counted '
            'byte by byte. Expect the streaming half to differ from your '
            "carrier's numbers.",
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      ],
    );
  }
}
