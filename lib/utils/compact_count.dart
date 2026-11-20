/// A count short enough for a status bar chip.
///
/// Under 1000 the count is shown as it is. From 1000 it becomes `k` and from
/// one million `M`, with one decimal while the leading part is a single digit
/// ("1.4k", "9.9M") and none above ("12k", "999k", "12M"). The decimal is
/// truncated, never rounded, so the chip never reads higher than the real
/// count (rounding would turn 9999 into "10.0k" and 999999 into "1000k").
String formatCompactCount(int count) {
  if (count < 1000) return '$count';
  if (count < 1000000) return _scaled(count, 1000, 'k');
  return _scaled(count, 1000000, 'M');
}

String _scaled(int count, int unit, String suffix) {
  final whole = count ~/ unit;
  if (whole >= 10) return '$whole$suffix';
  final tenth = (count % unit) * 10 ~/ unit;
  return '$whole.$tenth$suffix';
}
