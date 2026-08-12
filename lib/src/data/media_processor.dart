import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';

/// Post-processing a finished download needs.
///
/// An interface rather than a concrete class so the heavy native dependency
/// stays replaceable. FFmpeg is ~70-100 MB of the installed app and is the
/// only reason it is there; if a lighter remuxer appears, or the feature is
/// dropped, only the implementation changes. [DownloadManager] never names
/// FFmpeg — it asks for a processor and reports what it could not do.
///
/// Implementations must not throw. A download that has already transferred is
/// worth keeping even when the processing step fails, so every method returns
/// a bool and leaves the input untouched on failure.
abstract class MediaProcessor {
  /// Whether this processor can do anything on the current platform.
  bool get isSupported;

  /// Combines separate video and audio files into one at [outputPath].
  Future<bool> mux({
    required String videoPath,
    required String audioPath,
    required String outputPath,
  });

  /// Re-encodes an audio file to MP3.
  Future<bool> toMp3({
    required String sourcePath,
    required String outputPath,
  });
}

/// A processor that declines everything.
///
/// Used on platforms with no native library, and by tests that must not touch
/// the filesystem. Downloads fall back to the combined 360p stream, which is
/// exactly the behaviour before any of this existed.
class UnavailableMediaProcessor implements MediaProcessor {
  const UnavailableMediaProcessor();

  @override
  bool get isSupported => false;

  @override
  Future<bool> mux({
    required String videoPath,
    required String audioPath,
    required String outputPath,
  }) async => false;

  @override
  Future<bool> toMp3({
    required String sourcePath,
    required String outputPath,
  }) async => false;
}

/// Joins separate video and audio files, and converts audio to MP3.
///
/// YouTube retired combined streams above 360p: 1080p and 4K exist only as
/// video-only tracks that need an audio track alongside them. Downloading in
/// HD therefore means fetching two files and combining them, which is what
/// this does.
///
/// The video and audio are *copied*, not re-encoded — the streams are already
/// in the right formats for an MP4 container, so the join is a remux that
/// takes seconds and loses no quality. MP3 is the exception: it is a different
/// codec to the AAC YouTube serves, so it genuinely has to be re-encoded.
class FfmpegMediaProcessor implements MediaProcessor {
  const FfmpegMediaProcessor();

  /// True on the platforms the native library ships for.
  @override
  bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  /// Combines [videoPath] and [audioPath] into [outputPath].
  ///
  /// Returns false rather than throwing, so a failed join can fall back to
  /// keeping the video-only file instead of losing the whole download.
  @override
  Future<bool> mux({
    required String videoPath,
    required String audioPath,
    required String outputPath,
  }) async {
    if (!isSupported) return false;
    // -c copy: no re-encode. -shortest: end with whichever track runs out
    // first, so a truncated download cannot produce a file with a long tail of
    // silence or a frozen frame.
    return _run(
      '-y -i ${_arg(videoPath)} -i ${_arg(audioPath)} '
      '-c copy -shortest -movflags +faststart ${_arg(outputPath)}',
      outputPath,
    );
  }

  /// Re-encodes [sourcePath] to MP3 at [outputPath].
  @override
  Future<bool> toMp3({
    required String sourcePath,
    required String outputPath,
  }) async {
    if (!isSupported) return false;
    // -q:a 2 is variable bitrate around 190 kbps: past the point where the
    // difference from the source is audible, without doubling the file size.
    return _run(
      '-y -i ${_arg(sourcePath)} -vn -c:a libmp3lame -q:a 2 ${_arg(outputPath)}',
      outputPath,
    );
  }

  Future<bool> _run(String command, String outputPath) async {
    try {
      // Bounded, so a stuck FFmpeg process cannot leave a download reporting
      // "loading" forever. A remux of even a long video is seconds; five
      // minutes is far past any legitimate run and short enough that a hang
      // surfaces as a failed post-process rather than a frozen queue.
      final session = await FFmpegKit.execute(command)
          .timeout(const Duration(minutes: 5));
      final code = await session.getReturnCode();
      if (ReturnCode.isSuccess(code)) return true;

      debugPrint('AI BIT: ffmpeg failed (${code?.getValue()}) — '
          '${await session.getFailStackTrace()}');
      // Half-written output is worse than none: it would be saved as a
      // playable download and then refuse to open.
      final partial = File(outputPath);
      if (partial.existsSync()) await partial.delete();
      return false;
    } on TimeoutException {
      debugPrint('AI BIT: ffmpeg timed out — keeping the pre-processed file');
      final partial = File(outputPath);
      if (partial.existsSync()) await partial.delete();
      return false;
    } catch (e) {
      debugPrint('AI BIT: ffmpeg threw — $e');
      return false;
    }
  }

  /// Paths come from the app's own directories, but they can still contain
  /// spaces, and FFmpegKit parses the command as a string.
  static String _arg(String path) => "'${path.replaceAll("'", r"\'")}'";
}
