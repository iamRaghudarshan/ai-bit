import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// One skippable stretch of a video, from the SponsorBlock community database.
@immutable
class SponsorSegment {
  const SponsorSegment({
    required this.category,
    required this.start,
    required this.end,
  });

  /// `sponsor`, `intro`, `outro`, `selfpromo`, `interaction`, `music_offtopic`.
  final String category;
  final Duration start;
  final Duration end;

  /// A human label for a "Skipped …" toast.
  String get label => switch (category) {
        'sponsor' => 'sponsor',
        'selfpromo' => 'self-promo',
        'intro' => 'intro',
        'outro' => 'outro',
        'interaction' => 'interaction reminder',
        'music_offtopic' => 'non-music section',
        _ => category,
      };
}

/// Fetches skippable segments for a video from SponsorBlock.
///
/// SponsorBlock is a community-maintained public API — no key, no account. It
/// returns HTTP 404 for a video that has no submitted segments, which is a
/// normal empty result here, not an error.
class SponsorBlockClient {
  SponsorBlockClient([http.Client? client]) : _http = client ?? http.Client();

  final http.Client _http;

  static const _host = 'sponsor.ajay.app';

  /// The segment categories fetched. Chapters and highlights are left out —
  /// only the parts a viewer would skip.
  static const _categories = [
    'sponsor',
    'selfpromo',
    'intro',
    'outro',
    'interaction',
    'music_offtopic',
  ];

  /// Segments for [videoId], sorted by start. Empty on 404 (none submitted) or
  /// any failure — a missing skip is never worth an error.
  Future<List<SponsorSegment>> segments(String videoId) async {
    final uri = Uri.https(_host, '/api/skipSegments', {
      'videoID': videoId,
      'categories': jsonEncode(_categories),
    });
    try {
      final response =
          await _http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return const [];

      final list = jsonDecode(response.body);
      if (list is! List) return const [];

      final out = <SponsorSegment>[];
      for (final item in list) {
        if (item is! Map) continue;
        if (item['actionType'] != 'skip') continue; // ignore mute/poi/full
        final seg = item['segment'];
        if (seg is! List || seg.length < 2) continue;
        final start = (seg[0] as num).toDouble();
        final end = (seg[1] as num).toDouble();
        if (end <= start) continue;
        out.add(SponsorSegment(
          category: '${item['category']}',
          start: Duration(milliseconds: (start * 1000).round()),
          end: Duration(milliseconds: (end * 1000).round()),
        ));
      }
      out.sort((a, b) => a.start.compareTo(b.start));
      return out;
    } catch (_) {
      return const [];
    }
  }

  void close() => _http.close();
}
