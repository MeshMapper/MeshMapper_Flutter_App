import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/geo_validation.dart';

void main() {
  group('isValidLatLng', () {
    test('accepts normal coordinates', () {
      expect(isValidLatLng(45.4215, -75.6972), isTrue); // Ottawa
      expect(isValidLatLng(0, 0), isTrue);
      expect(isValidLatLng(-33.8688, 151.2093), isTrue); // Sydney
    });

    test('accepts exact domain edges', () {
      expect(isValidLatLng(90, 180), isTrue);
      expect(isValidLatLng(-90, -180), isTrue);
    });

    test('rejects NaN', () {
      expect(isValidLatLng(double.nan, 0), isFalse);
      expect(isValidLatLng(0, double.nan), isFalse);
      expect(isValidLatLng(double.nan, double.nan), isFalse);
    });

    test('rejects infinity', () {
      expect(isValidLatLng(double.infinity, 0), isFalse);
      expect(isValidLatLng(0, double.negativeInfinity), isFalse);
    });

    test('rejects out-of-range latitude', () {
      expect(isValidLatLng(91, 0), isFalse);
      expect(isValidLatLng(-91, 0), isFalse);
      expect(isValidLatLng(200, 0), isFalse);
    });

    test('rejects out-of-range longitude', () {
      expect(isValidLatLng(0, 181), isFalse);
      expect(isValidLatLng(0, -181), isFalse);
      expect(isValidLatLng(0, 200), isFalse);
    });
  });

  group('isDegenerateBounds', () {
    test('true for identical / coincident points', () {
      expect(isDegenerateBounds(45.0, 45.0, -75.0, -75.0), isTrue);
      // Sub-0.1m jitter still counts as degenerate.
      expect(isDegenerateBounds(45.0, 45.0000001, -75.0, -75.0000001), isTrue);
    });

    test('false for a real spread', () {
      expect(isDegenerateBounds(45.0, 45.1, -75.0, -75.1), isFalse);
      // Degenerate on one axis only is still a fit-able line.
      expect(isDegenerateBounds(45.0, 45.0, -75.0, -75.1), isFalse);
      expect(isDegenerateBounds(45.0, 45.1, -75.0, -75.0), isFalse);
    });
  });

  group('clampFitPadding', () {
    test('passes through padding that fits', () {
      final p = clampFitPadding(60, 60, 60, 60, 400, 800);
      expect(p.left, 60);
      expect(p.top, 60);
      expect(p.right, 60);
      expect(p.bottom, 60);
    });

    test('shrinks oversized vertical padding to keep the map visible', () {
      // bottom alone exceeds the height budget (the reported crash shape).
      final p = clampFitPadding(60, 60, 60, 1000, 400, 800);
      expect(p.top + p.bottom, lessThanOrEqualTo(800 - 40));
      expect(p.top, greaterThan(0));
      expect(p.bottom, greaterThan(0));
      // Horizontal axis untouched.
      expect(p.left, 60);
      expect(p.right, 60);
    });

    test('zero/negative budget yields no padding on that axis', () {
      final p = clampFitPadding(60, 60, 60, 60, 400, 30);
      expect(p.top, 0);
      expect(p.bottom, 0);
    });

    test('unknown/zero viewport returns small safe defaults', () {
      final p = clampFitPadding(60, 60, 60, 1000, 0, 0);
      expect(p.left, 8);
      expect(p.top, 8);
      expect(p.right, 8);
      expect(p.bottom, 8);
    });

    test('non-finite padding is treated as zero', () {
      final p = clampFitPadding(double.nan, 60, double.infinity, 60, 400, 800);
      expect(p.left, 0);
      expect(p.right, 0);
      expect(p.top, 60);
      expect(p.bottom, 60);
    });
  });
}
