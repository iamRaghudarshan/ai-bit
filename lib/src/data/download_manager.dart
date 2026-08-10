import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'db.dart';
import 'models.dart';
import 'yt_repository.dart';

/// Saves videos to device storage and keeps the UI informed about progress.
///
/// Transfers run one at a time: YouTube throttles concurrent downloads from a
/// single manifest, and a serial queue keeps the progress numbers honest.
class DownloadManager extends ChangeNotifier {
  DownloadManager({required YtRepository repository, required AppDatabase database})
    : _repo = repository,
      _db = database;

  final YtRepository _repo;
  final AppDatabase _db;

  /// Written to disk every ~1MB rather than every chunk — SQLite writes are
  /// cheap but not free, and the bar only needs to move smoothly.
  static const _progressWriteInterval = 1024 * 1024;

  final _records = <String, DownloadRecord>{};
  final _pending = <String>[];

  bool _busy = false;
  String? _activeId;
  StreamSubscription<List<int>>? _activeSubscription;

  /// Newest first, matching the downloads list order.
  List<DownloadRecord> get all => _records.values.toList().reversed.toList();

  DownloadRecord? recordFor(String videoId) => _records[videoId];

  bool isDownloaded(String videoId) => _records[videoId]?.isComplete ?? false;

  bool isActive(String videoId) =>
      _records[videoId]?.status == DownloadStatus.running ||
      _records[videoId]?.status == DownloadStatus.queued;

  /// Loads persisted downloads at startup. Anything left mid-transfer by a
  /// previous run is marked failed so it can be retried deliberately rather
  /// than resuming into a half-written file.
  Future<void> restore() async {
    final stored = await _db.downloads();
    for (final record in stored.reversed) {
      final resolved = record.status == DownloadStatus.completed
          ? record
          : record.copyWith(
              status: DownloadStatus.failed,
              error: 'Interrupted — tap to retry',
            );
      if (resolved.status == DownloadStatus.failed &&
          record.status != DownloadStatus.failed) {
        await _db.updateDownloadStatus(
          record.video.id,
          DownloadStatus.failed,
          error: resolved.error,
        );
      }
      _records[record.video.id] = resolved;
    }
    notifyListeners();
  }

  /// Queues [video] for download. Re-queuing something already downloaded is a
  /// no-op; re-queuing a failed one retries it.
  Future<void> enqueue(VideoBrief video, {bool audioOnly = false}) async {
    final existing = _records[video.id];
    if (existing != null && existing.isComplete) return;
    if (existing != null && isActive(video.id)) return;

    final directory = await _downloadDirectory();
    final record = DownloadRecord(
      video: video,
      // Extension is corrected once the rendition is known.
      filePath: '${directory.path}/${video.id}.tmp',
      quality: audioOnly ? 'Audio' : '',
      audioOnly: audioOnly,
      totalBytes: 0,
      receivedBytes: 0,
      status: DownloadStatus.queued,
    );
    _records[video.id] = record;
    await _db.saveDownload(record);
    _pending.add(video.id);
    notifyListeners();

    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_busy) return;
    _busy = true;
    try {
      while (_pending.isNotEmpty) {
        final id = _pending.removeAt(0);
        final record = _records[id];
        if (record == null || record.isComplete) continue;
        await _run(record);
      }
    } finally {
      _busy = false;
      _activeId = null;
    }
  }

  Future<void> _run(DownloadRecord queued) async {
    final id = queued.video.id;
    _activeId = id;
    _update(queued.copyWith(status: DownloadStatus.running, receivedBytes: 0));

    IOSink? sink;
    File? file;
    try {
      final target = await _repo.downloadTarget(id, audioOnly: queued.audioOnly);
      final directory = await _downloadDirectory();
      final path = '${directory.path}/$id.${target.fileExtension}';
      file = File(path);
      if (await file.exists()) await file.delete();

      var record = queued.copyWith(
        status: DownloadStatus.running,
        totalBytes: target.totalBytes,
        receivedBytes: 0,
      );
      // filePath and quality are only known now, so rewrite the whole row.
      record = DownloadRecord(
        video: queued.video,
        filePath: path,
        quality: target.quality,
        audioOnly: target.audioOnly,
        totalBytes: target.totalBytes,
        receivedBytes: 0,
        status: DownloadStatus.running,
      );
      _records[id] = record;
      await _db.saveDownload(record);
      notifyListeners();

      sink = file.openWrite();
      var received = 0;
      var lastWrite = 0;

      final completer = Completer<void>();
      _activeSubscription = _repo.downloadBytes(target).listen(
        (chunk) {
          sink!.add(chunk);
          received += chunk.length;
          if (received - lastWrite >= _progressWriteInterval) {
            lastWrite = received;
            _update(_records[id]!.copyWith(receivedBytes: received));
            unawaited(
              _db.updateDownloadProgress(id, receivedBytes: received),
            );
          }
        },
        onDone: completer.complete,
        onError: completer.completeError,
        cancelOnError: true,
      );

      await completer.future;
      await sink.flush();
      await sink.close();
      sink = null;

      _update(
        _records[id]!.copyWith(
          receivedBytes: received,
          totalBytes: received,
          status: DownloadStatus.completed,
        ),
      );
      await _db.saveDownload(_records[id]!);
    } catch (e) {
      await sink?.close();
      // A partial file is worse than none — it would play as a truncated video.
      if (file != null && await file.exists()) {
        await file.delete().catchError((_) => file!);
      }
      final message = e is StreamResolutionException
          ? 'YouTube would not serve this video for download.'
          : 'Download failed. Check your connection and retry.';
      _update(
        _records[id]!.copyWith(status: DownloadStatus.failed, error: message),
      );
      await _db.updateDownloadStatus(id, DownloadStatus.failed, error: message);
      debugPrint('AI BIT: download failed for $id — $e');
    } finally {
      _activeSubscription = null;
    }
  }

  /// Stops the in-flight transfer, if [videoId] is the one running.
  Future<void> cancel(String videoId) async {
    _pending.remove(videoId);
    if (_activeId == videoId) {
      await _activeSubscription?.cancel();
      _activeSubscription = null;
    }
    await remove(videoId);
  }

  /// Deletes the record and its file.
  Future<void> remove(String videoId) async {
    final record = _records.remove(videoId);
    if (record != null) {
      final file = File(record.filePath);
      if (await file.exists()) {
        await file.delete().catchError((_) => file);
      }
    }
    await _db.deleteDownload(videoId);
    notifyListeners();
  }

  /// Copies a finished video download into the system photo library.
  ///
  /// Downloads live in the app's private storage, which the Photos app and the
  /// file browser cannot see. This is what puts a saved video where the user
  /// expects to find it.
  Future<void> saveToGallery(String videoId) async {
    final record = _records[videoId];
    if (record == null || !record.isComplete) {
      throw StateError('That download has not finished.');
    }
    if (record.audioOnly) {
      throw StateError('Photos only accepts video. Use Export for audio.');
    }
    if (!await File(record.filePath).exists()) {
      throw StateError('The downloaded file is missing.');
    }
    if (!await Gal.hasAccess(toAlbum: true)) {
      await Gal.requestAccess(toAlbum: true);
    }
    await Gal.putVideo(record.filePath, album: 'AI BIT');
  }

  /// Hands a finished download to the system share sheet, which is how a file
  /// reaches the Files app, another player, or a messaging app. iOS has no
  /// third-party-writable music library, so this is the audio equivalent of
  /// saving to Photos.
  Future<void> exportDownload(String videoId) async {
    final record = _records[videoId];
    if (record == null || !record.isComplete) {
      throw StateError('That download has not finished.');
    }
    final file = File(record.filePath);
    if (!await file.exists()) throw StateError('The downloaded file is missing.');

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(record.filePath)],
        text: record.video.title,
        subject: record.video.title,
      ),
    );
  }

  /// Total bytes on disk across finished downloads.
  int get storageUsed => _records.values
      .where((r) => r.isComplete)
      .fold(0, (sum, r) => sum + r.receivedBytes);

  void _update(DownloadRecord record) {
    _records[record.video.id] = record;
    notifyListeners();
  }

  /// Downloads live in Application Support, not Documents — they are app data
  /// the user manages through this screen, not files to expose over iTunes
  /// file sharing.
  Future<Directory> _downloadDirectory() async {
    final base = await getApplicationSupportDirectory();
    final directory = Directory('${base.path}/downloads');
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  @override
  void dispose() {
    _activeSubscription?.cancel();
    super.dispose();
  }
}

/// Human-readable byte size for the downloads UI.
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  const mb = 1024 * 1024;
  if (bytes < mb) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * mb)).toStringAsFixed(2)} GB';
}
