/// Small display formatters shared across the UI.
library;

/// `1234567` -> `1.2M`. Returns an empty string for null so callers can just
/// drop it into a text run without a null guard.
String compactCount(int? n) {
  if (n == null || n < 0) return '';
  if (n < 1000) return '$n';
  if (n < 1000000) return '${_trim(n / 1000)}K';
  if (n < 1000000000) return '${_trim(n / 1000000)}M';
  return '${_trim(n / 1000000000)}B';
}

String _trim(double v) {
  final s = v.toStringAsFixed(v < 10 ? 1 : 0);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// `0:00` / `1:02:03`. Used for both the thumbnail badge and the seek bar.
String clockLabel(Duration? d) {
  if (d == null) return '';
  final total = d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : m.toString();
  return h > 0
      ? '$h:$mm:${s.toString().padLeft(2, '0')}'
      : '$mm:${s.toString().padLeft(2, '0')}';
}

/// `2 days ago`. YouTube already hands us a pre-rendered string for search
/// results (`uploadDateRaw`), so prefer that when present.
String timeAgo(DateTime? date, {String? raw}) {
  if (raw != null && raw.isNotEmpty && raw != 'null') return raw;
  if (date == null) return '';
  final diff = DateTime.now().difference(date);
  if (diff.inDays >= 365) return _plural(diff.inDays ~/ 365, 'year');
  if (diff.inDays >= 30) return _plural(diff.inDays ~/ 30, 'month');
  if (diff.inDays >= 7) return _plural(diff.inDays ~/ 7, 'week');
  if (diff.inDays >= 1) return _plural(diff.inDays, 'day');
  if (diff.inHours >= 1) return _plural(diff.inHours, 'hour');
  if (diff.inMinutes >= 1) return _plural(diff.inMinutes, 'minute');
  return 'just now';
}

String _plural(int n, String unit) => '$n ${n == 1 ? unit : '${unit}s'} ago';

/// Joins the non-empty parts of a metadata line with the usual dot separator.
String metaLine(Iterable<String> parts) =>
    parts.where((p) => p.trim().isNotEmpty).join(' • ');
