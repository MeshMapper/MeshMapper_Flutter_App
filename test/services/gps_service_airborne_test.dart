import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_mapper/services/gps_service.dart';

/// Airborne block: a fix counts as airborne when its altitude (less the
/// GPS's own vertical error) clears 6,000 m or its ground speed clears
/// 250 km/h. Three consecutive airborne fixes latch, three consecutive
/// ground fixes clear. Unknown altitude and speed arrive as 0.0 from
/// geolocator and must never qualify.

/// Each call is a distinct fix with its own timestamp, the way real fixes
/// arrive one second apart. Pass [timestamp] to hand the same fix over twice.
int _fixSeconds = 0;

Position _pos({
  double altitude = 0.0,
  double altitudeAccuracy = 0.0,
  double speed = 0.0,
  double speedAccuracy = 0.0,
  DateTime? timestamp,
}) =>
    Position(
      latitude: 45.0,
      longitude: -75.0,
      timestamp:
          timestamp ?? DateTime.fromMillisecondsSinceEpoch(1000 * ++_fixSeconds),
      accuracy: 5.0,
      altitude: altitude,
      altitudeAccuracy: altitudeAccuracy,
      heading: 0.0,
      headingAccuracy: 1.0,
      speed: speed,
      speedAccuracy: speedAccuracy,
    );

void main() {
  group('positionLooksAirborne', () {
    test('altitude well above the limit qualifies', () {
      expect(
          GpsService.positionLooksAirborne(
              _pos(altitude: 6100, altitudeAccuracy: 50)),
          isTrue);
    });

    test('altitude inside its own error margin does not qualify', () {
      expect(
          GpsService.positionLooksAirborne(
              _pos(altitude: 6050, altitudeAccuracy: 100)),
          isFalse);
    });

    test('altitude with no vertical accuracy still qualifies', () {
      // Android omits altitude_accuracy when the fix lacks one, even with a
      // valid altitude, so 0.0 accuracy must not mask a real 12 km reading.
      expect(
          GpsService.positionLooksAirborne(
              _pos(altitude: 12000, altitudeAccuracy: 0)),
          isTrue);
    });

    test('speed above 250 km/h qualifies', () {
      expect(GpsService.positionLooksAirborne(_pos(speed: 70)), isTrue);
    });

    test('speed just under 250 km/h does not qualify', () {
      expect(GpsService.positionLooksAirborne(_pos(speed: 69)), isFalse);
    });

    test('unknown altitude and speed never qualify', () {
      expect(GpsService.positionLooksAirborne(_pos()), isFalse);
    });
  });

  group('altitudeOrNull', () {
    test('unknown shape is null', () {
      expect(GpsService.altitudeOrNull(_pos()), isNull);
    });

    test('altitude without accuracy is kept', () {
      expect(GpsService.altitudeOrNull(_pos(altitude: 150)), 150.0);
    });

    test('altitude with accuracy is kept', () {
      expect(
          GpsService.altitudeOrNull(_pos(altitude: 150, altitudeAccuracy: 5)),
          150.0);
    });
  });

  group('speedOrNull', () {
    test('unknown shape is null', () {
      expect(GpsService.speedOrNull(_pos()), isNull);
    });

    test('speed without accuracy is kept', () {
      expect(GpsService.speedOrNull(_pos(speed: 12)), 12.0);
    });

    test('a known zero speed is kept', () {
      expect(GpsService.speedOrNull(_pos(speed: 0, speedAccuracy: 1)), 0.0);
    });
  });

  group('airborne latch', () {
    late GpsService gps;

    setUp(() => gps = GpsService());
    tearDown(() => gps.dispose());

    test('two airborne fixes do not latch, the third does', () {
      gps.trackAirborne(_pos(altitude: 9000, altitudeAccuracy: 20));
      gps.trackAirborne(_pos(altitude: 9100, altitudeAccuracy: 20));
      expect(gps.isAirborne, isFalse);

      gps.trackAirborne(_pos(altitude: 9200, altitudeAccuracy: 20));
      expect(gps.isAirborne, isTrue);
      expect(gps.airborneGate, AirborneGate.altitude);
      expect(gps.airborneAltitude, 9200.0);
      expect(gps.airborneSpeed, isNull,
          reason: 'the fix carried no speed, so none is reported');
    });

    test('altitude gate also records the speed of the fix that latched', () {
      // The server tells a plane from a train by seeing BOTH readings.
      for (var i = 0; i < 3; i++) {
        gps.trackAirborne(
            _pos(altitude: 9200, altitudeAccuracy: 20, speed: 60));
      }
      expect(gps.airborneGate, AirborneGate.altitude);
      expect(gps.airborneAltitude, 9200.0);
      expect(gps.airborneSpeed, 60.0);
    });

    test('a ground fix in between restarts the airborne streak', () {
      gps.trackAirborne(_pos(altitude: 9000, altitudeAccuracy: 20));
      gps.trackAirborne(_pos(altitude: 9000, altitudeAccuracy: 20));
      gps.trackAirborne(_pos(altitude: 100, altitudeAccuracy: 20));
      gps.trackAirborne(_pos(altitude: 9000, altitudeAccuracy: 20));
      gps.trackAirborne(_pos(altitude: 9000, altitudeAccuracy: 20));
      expect(gps.isAirborne, isFalse);

      gps.trackAirborne(_pos(altitude: 9000, altitudeAccuracy: 20));
      expect(gps.isAirborne, isTrue);
    });

    test('speed gate records the gate, the speed and the altitude', () {
      for (var i = 0; i < 3; i++) {
        gps.trackAirborne(_pos(speed: 80, altitude: 300, altitudeAccuracy: 5));
      }
      expect(gps.isAirborne, isTrue);
      expect(gps.airborneGate, AirborneGate.speed);
      expect(gps.airborneSpeed, 80.0);
      expect(gps.airborneAltitude, 300.0);
    });

    test('speed gate with an unknown altitude reports none', () {
      for (var i = 0; i < 3; i++) {
        gps.trackAirborne(_pos(speed: 80));
      }
      expect(gps.airborneGate, AirborneGate.speed);
      expect(gps.airborneAltitude, isNull);
    });

    test('one ground fix does not clear, three do', () {
      for (var i = 0; i < 3; i++) {
        gps.trackAirborne(_pos(altitude: 9000, altitudeAccuracy: 20));
      }
      expect(gps.isAirborne, isTrue);

      gps.trackAirborne(_pos(altitude: 100, altitudeAccuracy: 20));
      gps.trackAirborne(_pos(altitude: 100, altitudeAccuracy: 20));
      expect(gps.isAirborne, isTrue);

      gps.trackAirborne(_pos(altitude: 100, altitudeAccuracy: 20));
      expect(gps.isAirborne, isFalse);
      expect(gps.airborneGate, isNull);
      expect(gps.airborneAltitude, isNull);
      expect(gps.airborneSpeed, isNull);
    });

    test('flips are reported once each, including a reset', () {
      final flips = <bool>[];
      gps.onAirborneChanged = flips.add;

      for (var i = 0; i < 3; i++) {
        gps.trackAirborne(_pos(altitude: 9000, altitudeAccuracy: 20));
      }
      expect(flips, [true]);

      gps.trackAirborne(_pos(altitude: 100, altitudeAccuracy: 20));
      gps.trackAirborne(_pos(altitude: 100, altitudeAccuracy: 20));
      expect(flips, [true], reason: 'two ground fixes are not a flip');

      gps.trackAirborne(_pos(altitude: 100, altitudeAccuracy: 20));
      expect(flips, [true, false]);

      gps.resetAirborne();
      expect(flips, [true, false], reason: 'resetting a clear latch is silent');

      for (var i = 0; i < 3; i++) {
        gps.trackAirborne(_pos(altitude: 9000, altitudeAccuracy: 20));
      }
      gps.resetAirborne();
      expect(flips, [true, false, true, false],
          reason: 'resetting a set latch reports the clear');
    });

    test('the same fix handed over twice counts once', () {
      // The stream and getFreshPosition() can both deliver one physical fix;
      // the streak must still need three distinct fixes.
      final first = _pos(altitude: 9000, altitudeAccuracy: 20);
      gps.trackAirborne(first);
      gps.trackAirborne(_pos(
          altitude: 9000, altitudeAccuracy: 20, timestamp: first.timestamp));
      gps.trackAirborne(_pos(altitude: 9100, altitudeAccuracy: 20));
      expect(gps.isAirborne, isFalse,
          reason: 'two distinct fixes plus a repeat is not three');

      gps.trackAirborne(_pos(altitude: 9200, altitudeAccuracy: 20));
      expect(gps.isAirborne, isTrue);
    });

    test('resetAirborne clears the latch and the streaks', () {
      for (var i = 0; i < 3; i++) {
        gps.trackAirborne(_pos(altitude: 9000, altitudeAccuracy: 20));
      }
      expect(gps.isAirborne, isTrue);

      gps.resetAirborne();
      expect(gps.isAirborne, isFalse);

      // A fresh streak is needed again after a reset.
      gps.trackAirborne(_pos(altitude: 9000, altitudeAccuracy: 20));
      expect(gps.isAirborne, isFalse);
    });
  });
}
