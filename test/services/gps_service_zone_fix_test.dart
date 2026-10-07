import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_mapper/services/gps_service.dart';

/// Zone checks and the connect /auth must never send a fix the server will
/// refuse for accuracy (over 50 m). A coarse fix that lands just after a good
/// one must not stand in for it.

final DateTime _now = DateTime(2026, 10, 6, 12);

Position _fix({required double accuracy, required int secondsAgo}) => Position(
      latitude: 45.0,
      longitude: -75.0,
      timestamp: _now.subtract(Duration(seconds: secondsAgo)),
      accuracy: accuracy,
      altitude: 0.0,
      altitudeAccuracy: 0.0,
      heading: 0.0,
      headingAccuracy: 0.0,
      speed: 0.0,
      speedAccuracy: 0.0,
    );

void main() {
  group('isAccurateForZoneCheck', () {
    test('50 m and under passes, over 50 m does not', () {
      expect(
          GpsService.isAccurateForZoneCheck(_fix(accuracy: 30, secondsAgo: 0)),
          isTrue);
      expect(
          GpsService.isAccurateForZoneCheck(_fix(accuracy: 50, secondsAgo: 0)),
          isTrue);
      expect(
          GpsService.isAccurateForZoneCheck(
              _fix(accuracy: 64.8, secondsAgo: 0)),
          isFalse);
    });

    test('age is not part of it (a stationary phone sends an old fix)', () {
      expect(
          GpsService.isAccurateForZoneCheck(
              _fix(accuracy: 10, secondsAgo: 600)),
          isTrue);
    });
  });

  group('pickZoneCheckFix', () {
    test('a 738 m fix after a 20 m fix picks the 20 m one', () {
      final good = _fix(accuracy: 20, secondsAgo: 5);
      final coarse = _fix(accuracy: 738, secondsAgo: 1);
      expect(GpsService.pickZoneCheckFix([good, coarse], _now), same(good));
    });

    test('prefers the newest accurate fix over the most accurate one', () {
      final older = _fix(accuracy: 5, secondsAgo: 30);
      final newer = _fix(accuracy: 40, secondsAgo: 2);
      expect(GpsService.pickZoneCheckFix([older, newer], _now), same(newer));
      expect(GpsService.pickZoneCheckFix([newer, older], _now), same(newer));
    });

    test('ignores accurate fixes older than 60 s', () {
      final stale = _fix(accuracy: 10, secondsAgo: 61);
      expect(GpsService.pickZoneCheckFix([stale], _now), isNull);
    });

    test('null when every fix is coarse', () {
      expect(
          GpsService.pickZoneCheckFix([
            _fix(accuracy: 1300, secondsAgo: 3),
            _fix(accuracy: 65, secondsAgo: 1),
          ], _now),
          isNull);
    });
  });

  group('bestRecentZoneCheckFix', () {
    test('reads the fixes recorded by the service', () {
      final gps = GpsService();
      expect(gps.bestRecentZoneCheckFix(now: _now), isNull);
      final good = _fix(accuracy: 30, secondsAgo: 1);
      gps.recordRecentFix(good);
      gps.recordRecentFix(_fix(accuracy: 64.8, secondsAgo: 0));
      expect(gps.bestRecentZoneCheckFix(now: _now), same(good));
    });

    test('keeps only a bounded history', () {
      final gps = GpsService();
      gps.recordRecentFix(_fix(accuracy: 10, secondsAgo: 50));
      for (var i = 0; i < 40; i++) {
        gps.recordRecentFix(_fix(accuracy: 500, secondsAgo: 0));
      }
      // The one good fix has been pushed out by 40 coarse ones.
      expect(gps.bestRecentZoneCheckFix(now: _now), isNull);
    });
  });
}
