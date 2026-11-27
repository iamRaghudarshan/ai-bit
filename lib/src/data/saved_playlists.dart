import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// YouTube playlists bookmarked with the Save button on a playlist page, so
/// they show up in the You tab beside the local ones.
///
/// A bookmark, not a copy: the playlist is fetched fresh when opened, which
/// is what YouTube's own "Save playlist" does and keeps someone else's
/// playlist current as they add to it. ("Save all to a local playlist" in
/// the page's menu is the copy, for when it must survive being deleted.)
///
/// In preferences rather than a table: a short list of ids and titles that
/// needs no query, and no schema bump. It is not part of the library backup
/// file; that is noted in the report rather than hidden.
class SavedPlaylists {
  SavedPlaylists._();

  static const _key = 'saved_playlists_v1';

  static Future<List<PlaylistBrief>> all() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return const [];
      final json = jsonDecode(raw);
      if (json is! List) return const [];
      return json.map(PlaylistBrief.fromJson).whereType<PlaylistBrief>().toList();
    } catch (e) {
      debugPrint('AI BIT: saved playlists unreadable — $e');
      return const [];
    }
  }

  static Future<bool> contains(String id) async =>
      (await all()).any((p) => p.id == id);

  /// Saves or forgets [playlist]; returns whether it is saved afterwards.
  static Future<bool> toggle(PlaylistBrief playlist) async {
    final list = (await all()).toList();
    final at = list.indexWhere((p) => p.id == playlist.id);
    final saved = at < 0;
    if (saved) {
      list.insert(0, playlist);
    } else {
      list.removeAt(at);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final p in list) p.toJson()]));
    return saved;
  }
}
