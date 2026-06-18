import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/distance_formatter.dart';
import 'package:mesh_mapper/utils/repeater_format.dart';

void main() {
  group('formatDateOnly / daysAgo', () {
    test('formats a date as MM/DD/YY (local)', () {
      final secs = DateTime(2026, 6, 16).millisecondsSinceEpoch ~/ 1000;
      expect(formatDateOnly(secs), '06/16/26');
    });

    test('accepts millisecond timestamps too', () {
      final ms = DateTime(2026, 1, 2).millisecondsSinceEpoch;
      expect(formatDateOnly(ms), '01/02/26');
    });

    test('null / non-positive -> N/A', () {
      expect(formatDateOnly(null), 'N/A');
      expect(formatDateOnly(0), 'N/A');
    });

    test('daysAgo: Today / N days ago', () {
      final now = DateTime.now();
      final today = now.millisecondsSinceEpoch ~/ 1000;
      final twoDays =
          now.subtract(const Duration(days: 2)).millisecondsSinceEpoch ~/ 1000;
      expect(daysAgo(today), 'Today');
      expect(daysAgo(twoDays), '2 days ago');
    });

    test('formatDateWithAgo combines both', () {
      final secs = DateTime(2026, 6, 16).millisecondsSinceEpoch ~/ 1000;
      expect(formatDateWithAgo(secs), startsWith('06/16/26 ('));
    });
  });

  group('humanizeClockSkew', () {
    test('null + within tolerance -> null', () {
      expect(humanizeClockSkew(null), isNull);
      expect(humanizeClockSkew(60), isNull);
      expect(humanizeClockSkew(-120), isNull);
    });

    test('minutes, ahead vs behind', () {
      // -2964 s = 49.4 min ahead (matches the spec example).
      expect(humanizeClockSkew(-2964), '49.4 minutes ahead');
      expect(humanizeClockSkew(2964), '49.4 minutes behind');
    });

    test('hours + days', () {
      expect(humanizeClockSkew(7200), '2.0 hours behind');
      expect(humanizeClockSkew(-172800), '2.0 days ahead');
    });
  });

  group('formatCoverageDistance (web parity)', () {
    test('metric km + m', () {
      expect(formatCoverageDistance(123260), '123.26 km');
      expect(formatCoverageDistance(150), '150 m');
    });

    test('imperial mi + ft', () {
      // 2000 m = 6561.68 ft = 1.2427 mi
      expect(formatCoverageDistance(2000, isImperial: true), '1.24 mi');
      expect(formatCoverageDistance(100, isImperial: true), '328 ft');
    });
  });
}
