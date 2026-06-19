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
}
