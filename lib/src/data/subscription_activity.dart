import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'recommender.dart' show parseRelativeAgeSeconds;

/// What the Subscriptions tab remembers about each followed channel: when it
/// last uploaded, which upload that was, and which upload the viewer had
/// already seen when they last looked at the channel.
///
/// It exists for two jobs the `subscriptions` table cannot do.
///
/// **Choosing which channels to fetch.** Every channel is its own browse
/// request, so a feed of thirty subscriptions cannot fetch all thirty at
/// once. The tab used to take the first fifteen *alphabetically* — the
/// table's sort order — so a channel named "Zack" was simply never in the
/// feed. Now the channels that upload most recently go first, a rotating
/// slice of the quieter ones joins them on each refresh, and the rest arrive
/// in batches as the feed is scrolled, so every channel is reachable.
///
/// **The unseen-upload dot** under an avatar. It compares video ids, not
/// times: YouTube only says "1 day ago", which re-reads as a different
/// moment on every fetch, and a time comparison would light the dot for an
/// upload the viewer had already seen. An id comparison cannot do that.
///
/// Kept in preferences rather than a new table: it is a cache that rebuilds
/// itself on the next refresh, so losing it costs one feed's ordering and no
/// data, and it spares a schema bump.
class SubscriptionActivity {
  SubscriptionActivity._(this._prefs, this._entries, this.rotation);

  static const _key = 'subs_activity_v1';
  static const _rotationKey = 'subs_rotation_v1';

  final SharedPreferences? _prefs;
  final Map<String, _Entry> _entries;

  /// Bumped once per refresh, so each refresh brings in a different slice of
  /// the quieter channels.
  int rotation;

  static Future<SubscriptionActivity> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = <String, _Entry>{};
      final raw = prefs.getString(_key);
      if (raw != null) {
        final json = jsonDecode(raw);
        if (json is Map) {
          json.forEach((k, v) {
            final e = _Entry.fromJson(v);
            if (k is String && e != null) entries[k] = e;
          });
        }
      }
      return SubscriptionActivity._(prefs, entries, prefs.getInt(_rotationKey) ?? 0);
    } catch (e) {
      // A corrupt or unreadable cache costs ordering only; say so and start
      // empty rather than failing the tab.
      debugPrint('AI BIT: subscription activity unreadable — $e');
      return SubscriptionActivity._(null, {}, 0);
    }
  }

  /// An in-memory instance for tests.
  @visibleForTesting
  factory SubscriptionActivity.memory() => SubscriptionActivity._(null, {}, 0);

  /// Latest upload time per channel, as an estimate in epoch milliseconds.
  Map<String, int> get latestUploads => {
    for (final e in _entries.entries)
      if (e.value.latestAt != null) e.key: e.value.latestAt!,
  };

  /// Records a fetch of [channelId]'s uploads (newest first, as the Videos
  /// tab serves them). The first record of a channel also counts as seen, so
  /// a newly followed channel does not arrive already dotted.
  void recordUploads(String channelId, List<VideoBrief> uploads, DateTime now) {
    if (uploads.isEmpty) return;
    final newest = uploads.first;
    final age = parseRelativeAgeSeconds(newest.uploadRaw);
    final at = newest.uploadDate?.millisecondsSinceEpoch ??
        (age == null ? null : now.millisecondsSinceEpoch - age * 1000);
    final old = _entries[channelId];
    _entries[channelId] = _Entry(
      latestId: newest.id,
      // Same upload as last time: keep the earlier estimate, which is the
      // more precise one ("3 hours ago" beats "1 day ago").
      latestAt: old?.latestId == newest.id && old?.latestAt != null && at != null
          ? (old!.latestAt! < at ? old.latestAt : at)
          : at ?? old?.latestAt,
      seenId: old == null ? newest.id : old.seenId,
    );
  }

  /// The viewer looked at this channel: its current uploads are seen.
  void markViewed(String channelId) {
    final e = _entries[channelId];
    if (e == null) return;
    _entries[channelId] = _Entry(latestId: e.latestId, latestAt: e.latestAt, seenId: e.latestId);
  }

  /// True when the channel has uploaded since the viewer last looked.
  bool hasUnseen(String channelId) {
    final e = _entries[channelId];
    return e != null && e.latestId != null && e.latestId != e.seenId;
  }

  /// Drops channels no longer followed, so the cache cannot grow forever.
  void retainOnly(Iterable<String> channelIds) {
    final keep = channelIds.toSet();
    _entries.removeWhere((k, _) => !keep.contains(k));
  }

  Future<void> save() async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      await prefs.setString(
        _key,
        jsonEncode({for (final e in _entries.entries) e.key: e.value.toJson()}),
      );
      await prefs.setInt(_rotationKey, rotation);
    } catch (e) {
      debugPrint('AI BIT: subscription activity not saved — $e');
    }
  }
}

class _Entry {
  const _Entry({this.latestId, this.latestAt, this.seenId});

  final String? latestId;
  final int? latestAt;
  final String? seenId;

  Map<String, Object?> toJson() => {'v': latestId, 't': latestAt, 's': seenId};

  static _Entry? fromJson(Object? json) {
    if (json is! Map) return null;
    return _Entry(
      latestId: json['v'] as String?,
      latestAt: json['t'] as int?,
      seenId: json['s'] as String?,
    );
  }
}

/// [channels] ordered most recent upload first. Channels with no known
/// upload time keep their incoming order, after every dated one.
List<ChannelInfo> orderByActivity(
  List<ChannelInfo> channels,
  Map<String, int> latestUploads,
) {
  final indexed = [
    for (var i = 0; i < channels.length; i++) (i: i, c: channels[i]),
  ];
  indexed.sort((a, b) {
    final ta = latestUploads[a.c.id];
    final tb = latestUploads[b.c.id];
    if (ta != null && tb != null && ta != tb) return tb.compareTo(ta);
    if (ta != null && tb == null) return -1;
    if (ta == null && tb != null) return 1;
    return a.i.compareTo(b.i);
  });
  return [for (final x in indexed) x.c];
}

/// The order in which the Subscriptions tab fetches channels, in batches of
/// [batchSize].
///
/// The first batch is the [hot] most recently active channels plus a
/// rotating slice of the rest, so a refresh shows the busy channels at once
/// and also, over a few refreshes, every quiet one. Later batches carry on
/// through the rest in that rotated order, which is what scrolling fetches.
/// Every channel appears exactly once across the batches. Pure and tested.
List<List<ChannelInfo>> subscriptionBatches(
  List<ChannelInfo> channels,
  Map<String, int> latestUploads, {
  int rotation = 0,
  int batchSize = 15,
  int hot = 10,
}) {
  if (channels.isEmpty) return const [];
  final ordered = orderByActivity(channels, latestUploads);
  final head = ordered.take(hot).toList();
  final rest = ordered.skip(hot).toList();
  if (rest.isNotEmpty) {
    final step = (batchSize - hot).clamp(1, rest.length);
    final offset = (rotation * step) % rest.length;
    final rotated = [...rest.skip(offset), ...rest.take(offset)];
    rest
      ..clear()
      ..addAll(rotated);
  }
  final sequence = [...head, ...rest];
  return [
    for (var i = 0; i < sequence.length; i += batchSize)
      sequence.sublist(i, (i + batchSize).clamp(0, sequence.length)),
  ];
}

/// Which subscription filter chip is selected.
enum SubsFilter { all, today, videos, shorts, continueWatching, unwatched }

/// The feed rows [filter] keeps. [progress] is each video's watched fraction
/// (absent = never played), [watched] every id in history, and [ageSeconds]
/// reads a row's upload age. "Continue watching" is started but not
/// finished, with the same 92% line the Home shelf uses. Pure and tested.
List<VideoBrief> filterSubscriptionFeed(
  List<VideoBrief> videos,
  SubsFilter filter, {
  Map<String, double> progress = const {},
  Set<String> watched = const {},
  required int? Function(VideoBrief) ageSeconds,
}) {
  switch (filter) {
    case SubsFilter.all:
    case SubsFilter.videos:
      return videos.where((v) => !v.isShort).toList();
    case SubsFilter.shorts:
      return videos.where((v) => v.isShort).toList();
    case SubsFilter.today:
      return videos.where((v) {
        final age = ageSeconds(v);
        return age != null && age < const Duration(days: 1).inSeconds;
      }).toList();
    case SubsFilter.continueWatching:
      return videos.where((v) {
        final p = progress[v.id];
        return p != null && p > 0 && p < 0.92;
      }).toList();
    case SubsFilter.unwatched:
      return videos.where((v) => !watched.contains(v.id) && !v.isShort).toList();
  }
}
