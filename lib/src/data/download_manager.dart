import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'db.dart';
import 'models.dart';
import 'media_processor.dart';
import 'yt_repository.dart';

/// Saves videos to device storage and keeps the UI informed about progress.
///
/// Transfers run one at a time: YouTube throttles concurrent downloads from a
/// single manifest, and a serial queue keeps the progress numbers honest.
class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required YtRepository repository,
    required AppDatabase database,
    MediaProcessor? processor,
  })  : _repo = repository,
        _db = database,
        // Injected so the native dependency can be swapped or stubbed; the
        // manager only ever talks to the interface.
        _processor = processor ?? const FfmpegMediaProcessor();

  final YtRepository _repo;
  final AppDatabase _db;
  final MediaProcessor _processor;

  /// Written to disk every ~1MB rather than every chunk — SQLite writes are
  /// cheap but not free, and the bar only needs to move smoothly.
  static const _progressWriteInterval = 1024 * 1024;

  final _records = <String, DownloadRecord>{};
  final _pending = <String>[];

  bool _busy = false;
  String? _activeId;
  StreamSubscription<List<int>>? _activeSubscription;

  /// The active transfer's completer, so pause can end it cleanly.
  Completer<void>? _activeCompleter;

  /// Ids paused mid-transfer, so the catch block keeps the partial file and
  /// marks the record paused instead of failed.
  final _paused = <String>{};

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
  /// Whether HD joins and MP3 conversion are possible on this platform, so the
  /// picker can offer or gray them out.
  bool get canProcess => _processor.isSupported;

  /// Queues [video] at the chosen [quality] — one of the specs from
  /// [YtRepository.downloadOptions]: `360p`, `1080p`, `Audio`, `MP3`.
  Future<void> enqueue(
    VideoBrief video, {
    bool audioOnly = false,
    String quality = '360p',
  }) async {
    final existing = _records[video.id];
    if (existing != null && existing.isComplete) return;
    if (existing != null && isActive(video.id)) return;

    final directory = await _downloadDirectory();
    final record = DownloadRecord(
      video: video,
      // Extension is corrected once the rendition is known.
      filePath: '${directory.path}/${video.id}.tmp',
      // The requested spec is stored here so the transfer — and a later retry
      // or a restore after restart — knows exactly what to fetch.
      quality: quality,
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
      final spec = queued.quality;
      final wantMp3 = queued.audioOnly && spec == 'MP3';
      final height = int.tryParse(spec.replaceAll(RegExp('[^0-9]'), ''));
      final wantHd = !queued.audioOnly &&
          height != null &&
          height > 360 &&
          _processor.isSupported;
      // Bounded: downloads resolve through youtube_explode's getManifest,
      // which can hang on a device when YouTube changes its player. Without a
      // limit the row spins at 0% forever with no way to tell why. On timeout
      // it fails visibly instead.
      final target = await _repo
          .downloadTarget(
            id,
            audioOnly: queued.audioOnly,
            hd: wantHd,
            toMp3: wantMp3 && _processor.isSupported,
            requestedHeight: wantHd ? height : null,
          )
          .timeout(
            const Duration(seconds: 45),
            onTimeout: () => throw TimeoutException(
              'Could not resolve this video for download.',
            ),
          );
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
        totalBytes: target.downloadBytes,
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

      // Fails the download if no bytes arrive for a stretch, so a stalled
      // connection surfaces as an error rather than an endless spinner. Reset
      // on every chunk.
      Timer? stall;
      void armStall() {
        stall?.cancel();
        stall = Timer(const Duration(seconds: 40), () {
          if (!completer.isCompleted) {
            completer.completeError(
              TimeoutException('Download stalled — no data received.'),
            );
          }
        });
      }

      armStall();
      _activeCompleter = completer;
      _activeSubscription = _repo.downloadBytes(target).listen(
        (chunk) {
          sink!.add(chunk);
          received += chunk.length;
          armStall();
          // Update on the first chunk too, so the bar moves off zero at once
          // rather than only after the first megabyte.
          if (lastWrite == 0 || received - lastWrite >= _progressWriteInterval) {
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

      try {
        await completer.future;
      } finally {
        stall?.cancel();
      }
      await sink.flush();
      await sink.close();
      sink = null;

      // HD arrives as two files; join them before the download counts as done.
      if (target.needsMux) {
        received = await _fetchAndJoin(
          id: id,
          target: target,
          videoPath: file.path,
          received: received,
        );
      } else if (target.toMp3) {
        received = await _convertToMp3(id: id, videoPath: file.path);
      }

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
      // Paused, not failed: keep the partial file and the record so it can
      // resume, and stop here without the failure cleanup below.
      if (e is _PauseSignal) {
        _update(_records[id]!.copyWith(status: DownloadStatus.paused));
        await _db.updateDownloadStatus(id, DownloadStatus.paused);
        _activeSubscription = null;
        _activeCompleter = null;
        return;
      }
      // A partial file is worse than none — it would play as a truncated video.
      if (file != null && await file.exists()) {
        await file.delete().catchError((_) => file!);
      }
      // Carry the real reason so a hang that now times out reads as a
      // timeout, not a vague "check your connection".
      final message = switch (e) {
        StreamResolutionException() =>
          'YouTube would not serve this video for download.',
        TimeoutException(:final message?) => message,
        TimeoutException() => 'Download timed out.',
        _ => 'Download failed. Check your connection and retry.',
      };
      _update(
        _records[id]!.copyWith(status: DownloadStatus.failed, error: message),
      );
      await _db.updateDownloadStatus(id, DownloadStatus.failed, error: message);
      debugPrint('AI BIT: download failed for $id — $e');
    } finally {
      _activeSubscription = null;
      _activeCompleter = null;
    }
  }

  /// Pauses a queued or running download, keeping its partial file.
  Future<void> pause(String videoId) async {
    final record = _records[videoId];
    if (record == null || record.isComplete) return;
    _pending.remove(videoId);
    if (_activeId == videoId) {
      _paused.add(videoId);
      await _activeSubscription?.cancel();
      _activeSubscription = null;
      // End the awaiting transfer through the pause path.
      if (!(_activeCompleter?.isCompleted ?? true)) {
        _activeCompleter?.completeError(const _PauseSignal());
      }
    } else {
      _update(record.copyWith(status: DownloadStatus.paused));
      await _db.updateDownloadStatus(videoId, DownloadStatus.paused);
    }
    _paused.remove(videoId);
  }

  /// Resumes a paused download. It re-fetches from the start — resuming a
  /// partial byte range is not possible once the signed URL has expired — but
  /// picks up without the user re-choosing anything.
  Future<void> resume(String videoId) async {
    final record = _records[videoId];
    if (record == null || record.isComplete) return;
    _update(record.copyWith(status: DownloadStatus.queued, receivedBytes: 0));
    await _db.updateDownloadStatus(videoId, DownloadStatus.queued);
    if (!_pending.contains(videoId)) _pending.add(videoId);
    unawaited(_drain());
  }

  /// Moves a still-pending download within the queue.
  void reorderPending(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _pending.length) return;
    final id = _pending.removeAt(oldIndex);
    final target = newIndex.clamp(0, _pending.length);
    _pending.insert(target, id);
    notifyListeners();
  }

  /// The ids still waiting, in order, for a reorderable list.
  List<String> get pendingOrder => List.unmodifiable(_pending);

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
  /// Downloads the audio track next to an already-fetched video file and
  /// combines them, returning the byte count to report.
  ///
  /// A failed join keeps the video-only file rather than throwing the whole
  /// download away — a silent 1080p video is a poor result, but losing a
  /// finished transfer over a remux is worse.
  Future<int> _fetchAndJoin({
    required String id,
    required DownloadTarget target,
    required String videoPath,
    required int received,
  }) async {
    final audioPath = '$videoPath.audio';
    final audioFile = File(audioPath);
    final sink = audioFile.openWrite();
    var total = received;

    try {
      await for (final chunk in _repo.downloadBytes(target, audio: true)) {
        sink.add(chunk);
        total += chunk.length;
        _update(_records[id]!.copyWith(receivedBytes: total));
      }
      await sink.flush();
      await sink.close();

      final merged = '$videoPath.merged.mp4';
      final ok = await _processor.mux(
        videoPath: videoPath,
        audioPath: audioPath,
        outputPath: merged,
      );
      if (ok) {
        await File(videoPath).delete();
        await File(merged).rename(videoPath);
      }
    } catch (e) {
      debugPrint('AI BIT: HD join failed for $id — $e');
      await sink.close();
    } finally {
      if (audioFile.existsSync()) await audioFile.delete();
    }
    return total;
  }

  /// Re-encodes a downloaded audio track to MP3 in place.
  Future<int> _convertToMp3({
    required String id,
    required String videoPath,
  }) async {
    final source = '$videoPath.src';
    await File(videoPath).rename(source);
    final ok = await _processor.toMp3(sourcePath: source, outputPath: videoPath);
    if (!ok) {
      // Put the original back, so a failed conversion still leaves something
      // playable behind — everything reads AAC anyway.
      await File(source).rename(videoPath);
    } else if (File(source).existsSync()) {
      await File(source).delete();
    }
    return await File(videoPath).length();
  }

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

/// Thrown internally to unwind a running transfer for a pause, distinct from a
/// real failure so the partial file and record are kept.
class _PauseSignal implements Exception {
  const _PauseSignal();
}
