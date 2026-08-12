import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';

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
class MediaMuxer {
  const MediaMuxer();

  /// True on the platforms the native library ships for.
  bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  /// Combines [videoPath] and [audioPath] into [outputPath].
  ///
  /// Returns false rather than throwing, so a failed join can fall back to
  /// keeping the video-only file instead of losing the whole download.
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
      final session = await FFmpegKit.execute(command);
      final code = await session.getReturnCode();
      if (ReturnCode.isSuccess(code)) return true;

      debugPrint('AI BIT: ffmpeg failed (${code?.getValue()}) — '
          '${await session.getFailStackTrace()}');
      // Half-written output is worse than none: it would be saved as a
      // playable download and then refuse to open.
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
