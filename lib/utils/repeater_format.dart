/// Date / clock-skew formatters ported from the web client (`dev/index.php`) so the
/// app's repeater detail sheet matches the web popup text exactly.
///
/// The web stores timestamps as either Unix seconds or milliseconds; values below
/// 2e10 are treated as seconds (mirrors `formatDateOnly` / `calculateDaysAgo`).
library;

DateTime? _toDateTime(num? ts) {
  if (ts == null) return null;
  var v = ts.toDouble();
  if (v <= 0) return null;
  if (v < 20000000000) v = v * 1000; // seconds -> ms (web: `if (ts < 20000000000) ts *= 1000`)
  return DateTime.fromMillisecondsSinceEpoch(v.toInt());
}

/// `MM/DD/YY` (e.g. `06/16/26`). Port of `formatDateOnly` (`dev/index.php:9907`).
String formatDateOnly(num? ts) {
  final d = _toDateTime(ts);
  if (d == null) return 'N/A';
  final mm = d.month.toString().padLeft(2, '0');
  final dd = d.day.toString().padLeft(2, '0');
  final yy = (d.year % 100).toString().padLeft(2, '0');
  return '$mm/$dd/$yy';
}

/// `Today` / `1 day ago` / `N days ago`. Port of `calculateDaysAgo`
/// (`dev/index.php:9931`) — both timestamps compared at local midnight.
String daysAgo(num? ts) {
  final d = _toDateTime(ts);
  if (d == null) return '';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(d.year, d.month, d.day);
  final diff = today.difference(that).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return '1 day ago';
  return '$diff days ago';
}

/// `MM/DD/YY (Today)` style — the date plus its parenthesised age, matching the
/// web's `formatDateOnly(ts) + ' (' + calculateDaysAgo(ts) + ')'`.
String formatDateWithAgo(num? ts) {
  if (ts == null) return 'N/A';
  final ago = daysAgo(ts);
  return ago.isEmpty ? formatDateOnly(ts) : '${formatDateOnly(ts)} ($ago)';
}

/// Human-readable clock skew, e.g. `49.4 minutes ahead`. Port of the warning text
/// in `generateRepeaterPopup` (`dev/index.php:12757`).
///
/// Returns `null` when the offset is null or within the ±120 s tolerance (no
/// warning shown). `offset > 0` ⇒ repeater clock is *behind*; `< 0` ⇒ *ahead*.
String? humanizeClockSkew(int? offsetSecs) {
  if (offsetSecs == null) return null;
  final abs = offsetSecs.abs();
  if (abs <= 120) return null;
  final String mag;
  if (abs >= 86400) {
    mag = '${(abs / 86400).toStringAsFixed(1)} days';
  } else if (abs >= 3600) {
    mag = '${(abs / 3600).toStringAsFixed(1)} hours';
  } else {
    mag = '${(abs / 60).toStringAsFixed(1)} minutes';
  }
  return '$mag ${offsetSecs > 0 ? 'behind' : 'ahead'}';
}
