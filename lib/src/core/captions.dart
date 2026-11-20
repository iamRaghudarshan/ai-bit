/// Turns a YouTube WebVTT caption file into the plain WebVTT the player's
/// parser can read.
///
/// YouTube's files carry three things that parser does not handle, each of
/// which was enough to lose every caption (found on an emulator: the track
/// list filled, English was chosen, and nothing ever appeared on screen):
///
///   * a header block — `Kind: captions` / `Language: en` under `WEBVTT` —
///     which the parser reads as a cue and throws on;
///   * cue settings after the end time (`align:start position:0%`), which
///     make the end time unparseable;
///   * inline timing and style tags (`<00:00:01.234><c> word</c>`) in
///     auto-generated tracks, which would be shown as literal text.
///
/// Auto-generated tracks also repeat each line as the next scrolls in; a cue
/// whose text is the same as the one before it is dropped, which is what
/// YouTube's own player shows. Pure, so every rule has a test.
String normaliseYoutubeVtt(String source) {
  final blocks = source.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'));
  final out = <String>[];
  String? previousText;
  for (final block in blocks) {
    final lines = block.split('\n');
    final timing = lines.indexWhere((l) => l.contains('-->'));
    if (timing < 0) continue; // the header, NOTE and STYLE blocks
    final parts = lines[timing].split('-->');
    final start = parts[0].trim().split(RegExp(r'\s+')).first;
    final end = parts.length > 1
        ? parts[1].trim().split(RegExp(r'\s+')).first
        : '';
    if (start.isEmpty || end.isEmpty) continue;
    final text = [
      for (final line in lines.skip(timing + 1))
        line.replaceAll(RegExp(r'<[^>]*>'), '').trim(),
    ].where((l) => l.isNotEmpty).toList();
    if (text.isEmpty) continue;
    final joined = text.join('\n');
    if (joined == previousText) continue;
    previousText = joined;
    out.add('$start --> $end\n$joined');
  }
  return 'WEBVTT\n\n${out.join('\n\n')}\n';
}
