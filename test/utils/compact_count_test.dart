import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/compact_count.dart';

void main() {
  group('formatCompactCount', () {
    test('keeps counts under 1000 as they are', () {
      expect(formatCompactCount(0), '0');
      expect(formatCompactCount(7), '7');
      expect(formatCompactCount(42), '42');
      expect(formatCompactCount(999), '999');
    });

    test('shows one decimal from 1000 up to 9999', () {
      expect(formatCompactCount(1000), '1.0k');
      expect(formatCompactCount(1049), '1.0k');
      expect(formatCompactCount(1400), '1.4k');
      expect(formatCompactCount(1499), '1.4k');
      expect(formatCompactCount(9999), '9.9k');
    });

    test('drops the decimal from 10k', () {
      expect(formatCompactCount(10000), '10k');
      expect(formatCompactCount(12345), '12k');
      expect(formatCompactCount(999999), '999k');
    });

    test('switches to M from one million', () {
      expect(formatCompactCount(1000000), '1.0M');
      expect(formatCompactCount(1234567), '1.2M');
      expect(formatCompactCount(9999999), '9.9M');
      expect(formatCompactCount(12345678), '12M');
    });

    test('never rounds up past the real count', () {
      // Rounding would show 10.0k for 9999 and 1.0M for 999999.
      expect(formatCompactCount(9950), '9.9k');
      expect(formatCompactCount(999950), '999k');
    });

    test('leaves a negative count alone', () {
      expect(formatCompactCount(-5), '-5');
    });
  });
}
