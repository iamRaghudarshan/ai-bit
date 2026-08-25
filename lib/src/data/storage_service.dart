import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'download_manager.dart';

/// One measured category of on-device storage.
@immutable
class StorageBucket {
  const StorageBucket({
    required this.label,
    required this.description,
    required this.bytes,
    required this.itemCount,
  });

  final String label;
  final String description;
  final int bytes;

  /// Files or rows behind the figure; shown so "0 B" and "nothing here" are
  /// distinguishable.
  final int itemCount;
}

@immutable
class StorageUsage {
  const StorageUsage({
    required this.downloads,
    required this.cache,
    required this.database,
  });

  final StorageBucket downloads;
  final StorageBucket cache;
  final StorageBucket database;

  int get totalBytes => downloads.bytes + cache.bytes + database.bytes;

  List<StorageBucket> get all => [downloads, cache, database];
}

/// Measures and frees what the app has written to the device.
///
/// This is the "Documents & Data" figure iOS shows in its own storage settings,
/// which it offers no way to clear short of deleting the app. Downloaded videos
/// dominate it, but a long-lived install also accumulates a thumbnail cache
/// that nothing was ever pruning.
class StorageService {
  StorageService(this._db, this._downloads);

  final AppDatabase _db;
  final DownloadManager _downloads;

  Future<StorageUsage> measure() async {
    final downloads = await _measureDownloads();
    final cache = await _measureCache();
    final database = await _measureDatabase();
    return StorageUsage(
      downloads: downloads,
      cache: cache,
      database: database,
    );
  }

  Future<StorageBucket> _measureDownloads() async {
    var bytes = 0;
    var count = 0;
    if (!kIsWeb) {
      final directory = await _downloadDirectory();
      if (directory.existsSync()) {
        await for (final entity in directory.list()) {
          if (entity is File) {
            bytes += await entity.length();
            count++;
          }
        }
      }
    }
    return StorageBucket(
      label: 'Downloaded videos',
      description: 'Videos saved for offline playback.',
      bytes: bytes,
      itemCount: count,
    );
  }

  Future<StorageBucket> _measureCache() async {
    var bytes = 0;
    var count = 0;
    if (!kIsWeb) {
      final directory = await getTemporaryDirectory();
      // Recursive: the image cache keeps its own subdirectory, and the player
      // writes segments alongside it.
      await for (final entity in directory.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            bytes += await entity.length();
            count++;
          } on FileSystemException {
            // Being written to, or already gone. Not worth failing a total for.
          }
        }
      }
    }
    return StorageBucket(
      label: 'Cache',
      description: 'Thumbnails and streaming data. Safe to clear; it comes '
          'back as you browse.',
      bytes: bytes,
      itemCount: count,
    );
  }

  Future<StorageBucket> _measureDatabase() async {
    var bytes = 0;
    if (!kIsWeb) {
      final file = File(await _db.path);
      if (file.existsSync()) bytes = await file.length();
    }
    final history = await _db.historyCount();
    return StorageBucket(
      label: 'History and playlists',
      description: 'Watch history, searches, playlists and subscriptions.',
      bytes: bytes,
      itemCount: history,
    );
  }

  /// Deletes every downloaded file and the rows that point at them.
  ///
  /// Goes through the download manager rather than deleting files directly, so
  /// a transfer in flight is cancelled instead of being left to write into a
  /// file that no longer exists.
  Future<void> clearDownloads() async {
    for (final record in await _db.downloads()) {
      await _downloads.remove(record.video.id);
    }

    // Anything left behind by an interrupted transfer that never got a row.
    if (!kIsWeb) {
      final directory = await _downloadDirectory();
      if (directory.existsSync()) {
        await directory.delete(recursive: true);
      }
    }
  }

  /// Empties the thumbnail and streaming caches.
  Future<void> clearCache() async {
    // The in-memory cache holds decoded bitmaps, which is most of what a long
    // scrolling session costs; clearing files alone would leave those behind.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();

    if (kIsWeb) return;
    final directory = await getTemporaryDirectory();
    if (!directory.existsSync()) return;
    await for (final entity in directory.list()) {
      try {
        await entity.delete(recursive: true);
      } on FileSystemException {
        // In use by the running player; it will be reclaimed on the next start.
      }
    }
  }

  /// Clears watch history, search history and saved positions, leaving
  /// playlists and downloads alone.
  Future<void> clearHistory() async {
    await _db.clearHistory();
    await _db.clearSearchHistory();
  }

  /// Wipes the app's stored *content* on this device — downloads, cache,
  /// history, playlists and subscriptions.
  ///
  /// Settings are deliberately NOT cleared, so this is not quite a fresh
  /// install: the app-lock and Kids PINs survive. Wiping preferences here
  /// would turn the reset button into a way out of Kids mode for whoever the
  /// PIN was meant to stop, which is exactly the person most likely to press
  /// it.
  ///
  /// There is no account and no sync, so this cannot be undone: it is the
  /// "start over" button, kept behind a strong confirmation in the UI.
  Future<void> clearAll() async {
    await clearDownloads();
    await clearCache();
    await clearHistory();
    await _db.clearPlaylists();
    await _db.clearSubscriptions();
  }

  Future<Directory> _downloadDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/downloads');
  }
}

/// `1.2 GB`, matching how the system reports storage.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final decimals = unit == 0 || value >= 100
      ? 0
      : value >= 10
          ? 1
          : 2;
  return '${value.toStringAsFixed(decimals)} ${units[unit]}';
}
