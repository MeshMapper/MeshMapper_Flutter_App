import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_mapper/services/fix_altitude.dart';

/// The one rule that decides whether an altitude may be uploaded and what
/// reference it carries. A wrong label is worse than none, so every path that
/// cannot PROVE the reference answers unknown.

Position _pos({
  double lat = 45.0,
  double lon = -75.0,
  int timeMs = 1760000000000,
  double altitude = 84.0,
  double altitudeAccuracy = 6.0,
  bool isMocked = false,
}) =>
    Position(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime.fromMillisecondsSinceEpoch(timeMs, isUtc: true),
      accuracy: 5.0,
      altitude: altitude,
      altitudeAccuracy: altitudeAccuracy,
      heading: 0.0,
      headingAccuracy: 1.0,
      speed: 0.0,
      speedAccuracy: 0.0,
      isMocked: isMocked,
    );

NativeFixDescription _fix({
  int timeMs = 1760000000000,
  double lat = 45.0,
  double lon = -75.0,
  bool hasAltitude = true,
  double altitude = 120.0,
  bool hasVerticalAccuracy = true,
  double verticalAccuracy = 8.0,
  bool hasMsl = false,
  double msl = 0.0,
  bool hasMslAccuracy = false,
  double mslAccuracy = 0.0,
  bool isMock = false,
}) =>
    NativeFixDescription(
      source: 'fused',
      timeMs: timeMs,
      lat: lat,
      lon: lon,
      hasAltitude: hasAltitude,
      altitude: altitude,
      hasVerticalAccuracy: hasVerticalAccuracy,
      verticalAccuracy: verticalAccuracy,
      hasMsl: hasMsl,
      msl: msl,
      hasMslAccuracy: hasMslAccuracy,
      mslAccuracy: mslAccuracy,
      isMock: isMock,
    );

NativeAltitudeAnswer _android14(List<NativeFixDescription> fixes) =>
    NativeAltitudeAnswer(sdk: 34, fixes: fixes);

void main() {
  group('FixAltitude', () {
    test('unknown carries nothing', () {
      const u = FixAltitude.unknown();
      expect(u.isKnown, isFalse);
      expect(u.meters, isNull);
      expect(u.reference, isNull);
      expect(u.accuracy, isNull);
      expect(u.wireReference, isNull);
    });

    test('known sanitizes its accuracy', () {
      expect(
          FixAltitude.known(
                  meters: 10, reference: AltitudeReference.msl, accuracy: 0.0)
              .accuracy,
          isNull);
      expect(
          FixAltitude.known(
                  meters: 10,
                  reference: AltitudeReference.msl,
                  accuracy: double.infinity)
              .accuracy,
          isNull);
      expect(
          FixAltitude.known(
                  meters: 10,
                  reference: AltitudeReference.msl,
                  accuracy: double.nan)
              .accuracy,
          isNull);
      expect(
          FixAltitude.known(
                  meters: 10, reference: AltitudeReference.msl, accuracy: 0.4)
              .accuracy,
          0.4);
      expect(
          FixAltitude.known(meters: 10, reference: AltitudeReference.ellipsoid)
              .wireReference,
          'ellipsoid');
    });
  });

  group('reportedAltitudeOrNull', () {
    test('the 0/0 pair means unknown, anything else is a reading', () {
      expect(reportedAltitudeOrNull(_pos(altitude: 0, altitudeAccuracy: 0)),
          isNull);
      expect(reportedAltitudeOrNull(_pos(altitude: 0, altitudeAccuracy: 3)), 0);
      expect(reportedAltitudeOrNull(_pos(altitude: 12, altitudeAccuracy: 0)),
          12);
    });
  });

  group('resolveFixAltitude: simulator, mock, missing', () {
    test('a simulated fix is unknown on every platform', () {
      for (final p in AltitudePlatform.values) {
        final r = resolveFixAltitude(
            platform: p, position: _pos(), simulated: true);
        expect(r.altitude.isKnown, isFalse, reason: '$p');
        expect(r.reason, 'simulated');
      }
    });

    test('a mocked fix is unknown', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.ios,
          position: _pos(isMocked: true),
          simulated: false);
      expect(r.altitude.isKnown, isFalse);
      expect(r.reason, 'mocked');
    });

    test('a fix with no altitude is unknown (Review Focus 2)', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.ios,
          position: _pos(altitude: 0, altitudeAccuracy: 0),
          simulated: false);
      expect(r.altitude.isKnown, isFalse);
      expect(r.reason, 'no_altitude');
    });

    test('a NaN altitude is unknown (Review Focus 3)', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.ios,
          position: _pos(altitude: double.nan),
          simulated: false);
      expect(r.altitude.isKnown, isFalse);
      expect(r.reason, 'no_altitude');
    });

    test('an infinite accuracy is dropped but the altitude stays (Review Focus 3)',
        () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.ios,
          position: _pos(altitudeAccuracy: double.infinity),
          simulated: false);
      expect(r.altitude.isKnown, isTrue);
      expect(r.altitude.accuracy, isNull);
    });

    test('an unknown platform is unknown', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.other, position: _pos(), simulated: false);
      expect(r.altitude.isKnown, isFalse);
      expect(r.reason, 'other_platform');
    });
  });

  group('resolveFixAltitude: iOS and web', () {
    test('iOS is sea level with the fix accuracy', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.ios, position: _pos(), simulated: false);
      expect(r.altitude.meters, 84.0);
      expect(r.altitude.reference, AltitudeReference.msl);
      expect(r.altitude.accuracy, 6.0);
      expect(r.reason, 'ios');
    });

    test('web is ellipsoid with no accuracy', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.web, position: _pos(), simulated: false);
      expect(r.altitude.meters, 84.0);
      expect(r.altitude.reference, AltitudeReference.ellipsoid);
      expect(r.altitude.accuracy, isNull);
      expect(r.reason, 'web');
    });
  });

  group('resolveFixAltitude: Android', () {
    test('no native answer is unknown', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(),
          simulated: false);
      expect(r.altitude.isKnown, isFalse);
      expect(r.reason, 'no_native');
    });

    test('below Android 14 is ellipsoid from the fix, no read needed', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(),
          simulated: false,
          native: const NativeAltitudeAnswer(sdk: 33, fixes: []));
      expect(r.altitude.meters, 84.0);
      expect(r.altitude.reference, AltitudeReference.ellipsoid);
      expect(r.altitude.accuracy, 6.0);
      expect(r.reason, 'android_legacy');
    });

    test('Android 14 with no fixes read is unknown', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(),
          simulated: false,
          native: _android14(const []));
      expect(r.altitude.isKnown, isFalse);
      expect(r.reason, 'no_fix');
    });

    test('Android 14 matched fix carrying sea level, plugin delivered it',
        () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(altitude: 84.0, altitudeAccuracy: 4.0),
          simulated: false,
          native: _android14([
            _fix(
                altitude: 120.0,
                hasMsl: true,
                msl: 84.0,
                hasMslAccuracy: true,
                mslAccuracy: 4.0)
          ]));
      expect(r.altitude.meters, 84.0);
      expect(r.altitude.reference, AltitudeReference.msl);
      expect(r.altitude.accuracy, 4.0);
      expect(r.reason, 'android_msl');
    });

    test('Android 14 sea level without its own accuracy sends none', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(altitude: 84.0, altitudeAccuracy: 8.0),
          simulated: false,
          native: _android14([
            _fix(altitude: 120.0, hasMsl: true, msl: 84.0)
          ]));
      expect(r.altitude.reference, AltitudeReference.msl);
      expect(r.altitude.accuracy, isNull);
    });

    test('Android 14 matched fix without sea level, plugin delivered ellipsoid',
        () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(altitude: 120.0, altitudeAccuracy: 8.0),
          simulated: false,
          native: _android14([_fix(altitude: 120.0)]));
      expect(r.altitude.meters, 120.0);
      expect(r.altitude.reference, AltitudeReference.ellipsoid);
      expect(r.altitude.accuracy, 8.0);
      expect(r.reason, 'android_ellipsoid');
    });

    test('Android 14 ellipsoid fix with no vertical accuracy sends none', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(altitude: 120.0, altitudeAccuracy: 0.0),
          simulated: false,
          native: _android14(
              [_fix(altitude: 120.0, hasVerticalAccuracy: false)]));
      expect(r.altitude.reference, AltitudeReference.ellipsoid);
      expect(r.altitude.accuracy, isNull);
    });

    test('Android 14 delivered value matching neither is unknown', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(altitude: 99.0),
          simulated: false,
          native: _android14([_fix(altitude: 120.0, hasMsl: true, msl: 84.0)]));
      expect(r.altitude.isKnown, isFalse);
      expect(r.reason, 'value_differs');
    });

    test('Android 14 newer last fix is unknown (Review Focus 1)', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(timeMs: 1760000000000),
          simulated: false,
          native: _android14([_fix(timeMs: 1760000001000, altitude: 84.0)]));
      expect(r.altitude.isKnown, isFalse);
      expect(r.reason, 'time_differs');
    });

    test('Android 14 same time, different coordinate is unknown', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(lat: 45.0),
          simulated: false,
          native: _android14([_fix(lat: 45.0001, altitude: 84.0)]));
      expect(r.altitude.isKnown, isFalse);
      expect(r.reason, 'coord_differs');
    });

    test('Android 14 native fix marked mock is unknown', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(altitude: 120.0),
          simulated: false,
          native: _android14([_fix(altitude: 120.0, isMock: true)]));
      expect(r.altitude.isKnown, isFalse);
      expect(r.reason, 'native_mock');
    });

    test('Android 14 picks the matching fix out of several manager candidates',
        () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(altitude: 120.0),
          simulated: false,
          native: _android14([
            _fix(timeMs: 1759999990000, altitude: 50.0),
            _fix(altitude: 120.0),
          ]));
      expect(r.altitude.reference, AltitudeReference.ellipsoid);
    });
  });

  group('resolveFixAltitude: Android, the approved matching rule', () {
    test('an exact ellipsoid match is accepted even when the fix also carries '
        'sea level (the plugin only swaps when the fix has extras)', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(altitude: 120.0, altitudeAccuracy: 8.0),
          simulated: false,
          native: _android14([
            _fix(altitude: 120.0, hasMsl: true, msl: 84.0)
          ]));
      expect(r.altitude.reference, AltitudeReference.ellipsoid);
      expect(r.altitude.accuracy, 8.0);
      expect(r.reason, 'android_ellipsoid');
    });

    test('two candidates share time and coordinates, only the second matches '
        'the delivered value', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(altitude: 120.0),
          simulated: false,
          native: _android14([
            _fix(altitude: 50.0),
            _fix(altitude: 120.0),
          ]));
      expect(r.altitude.reference, AltitudeReference.ellipsoid);
    });

    test('a mock candidate does not hide a genuine match beside it', () {
      final r = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(altitude: 120.0),
          simulated: false,
          native: _android14([
            _fix(altitude: 120.0, isMock: true),
            _fix(altitude: 120.0),
          ]));
      expect(r.altitude.isKnown, isTrue);
    });
  });

  group('NativeAltitudeAnswer.tryFromMap', () {
    Map<String, Object?> fixMap({Object? timeMs = 1760000000000}) => {
          'source': 'fused',
          'timeMs': timeMs,
          'lat': 45.0,
          'lon': -75,
          'hasAltitude': true,
          'altitude': 120,
          'hasVerticalAccuracy': true,
          'verticalAccuracy': 8.0,
          'hasMsl': true,
          'msl': 84.5,
          'hasMslAccuracy': false,
          'mslAccuracy': 0.0,
          'isMock': false,
        };

    test('parses the channel shape and tolerates int-typed doubles', () {
      final a = NativeAltitudeAnswer.tryFromMap({'sdk': 34, 'fixes': [fixMap()]});
      expect(a!.sdk, 34);
      expect(a.fixes.single.lon, -75.0);
      expect(a.fixes.single.altitude, 120.0);
      expect(a.fixes.single.msl, 84.5);
      expect(a.fixes.single.hasMslAccuracy, isFalse);
    });

    test('a missing, zero, negative or non-integer sdk is no answer at all', () {
      expect(NativeAltitudeAnswer.tryFromMap(const {}), isNull);
      expect(NativeAltitudeAnswer.tryFromMap({'sdk': 0, 'fixes': []}), isNull);
      expect(NativeAltitudeAnswer.tryFromMap({'sdk': -1, 'fixes': []}), isNull);
      expect(NativeAltitudeAnswer.tryFromMap({'sdk': 34.5, 'fixes': []}), isNull);
      expect(NativeAltitudeAnswer.tryFromMap('nope'), isNull);
    });

    test('a valid sdk with no fixes list is an answer with no fixes', () {
      final a = NativeAltitudeAnswer.tryFromMap({'sdk': 33});
      expect(a!.sdk, 33);
      expect(a.fixes, isEmpty);
    });

    test('a malformed fix entry is skipped, the answer survives', () {
      final a = NativeAltitudeAnswer.tryFromMap({
        'sdk': 34,
        'fixes': ['garbage', {'timeMs': 'x'}, fixMap()],
      });
      expect(a!.fixes, hasLength(1));
    });

    test('a fractional timestamp is skipped, never truncated', () {
      final a = NativeAltitudeAnswer.tryFromMap({
        'sdk': 34,
        'fixes': [fixMap(timeMs: 1760000000000.5)],
      });
      expect(a!.fixes, isEmpty);
    });

    test('a flag without its value is skipped', () {
      final m = fixMap()..remove('msl');
      final a = NativeAltitudeAnswer.tryFromMap({'sdk': 34, 'fixes': [m]});
      expect(a!.fixes, isEmpty);
    });

    test('a missing isMock is skipped, never assumed false', () {
      final m = fixMap()..remove('isMock');
      final a = NativeAltitudeAnswer.tryFromMap({'sdk': 34, 'fixes': [m]});
      expect(a!.fixes, isEmpty);
    });
    test('a non-finite accuracy is dropped, the altitude is still proved', () {
      final msl = fixMap()
        ..['hasMslAccuracy'] = true
        ..['mslAccuracy'] = double.nan;
      final a = NativeAltitudeAnswer.tryFromMap({'sdk': 34, 'fixes': [msl]});
      expect(a!.fixes.single.hasMslAccuracy, isFalse);
      final r = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(altitude: 84.5),
          simulated: false,
          native: a);
      expect(r.altitude.reference, AltitudeReference.msl);
      expect(r.altitude.meters, 84.5);
      expect(r.altitude.accuracy, isNull);

      final ell = fixMap()
        ..['hasMsl'] = false
        ..['verticalAccuracy'] = double.infinity;
      final b = NativeAltitudeAnswer.tryFromMap({'sdk': 34, 'fixes': [ell]});
      expect(b!.fixes.single.hasVerticalAccuracy, isFalse);
      final r2 = resolveFixAltitude(
          platform: AltitudePlatform.android,
          position: _pos(altitude: 120.0),
          simulated: false,
          native: b);
      expect(r2.altitude.reference, AltitudeReference.ellipsoid);
      expect(r2.altitude.meters, 120.0);
      expect(r2.altitude.accuracy, isNull);
    });

    test('a missing accuracy behind a true flag is no accuracy, not a reject',
        () {
      final m = fixMap()..remove('verticalAccuracy');
      final a = NativeAltitudeAnswer.tryFromMap({'sdk': 34, 'fixes': [m]});
      expect(a!.fixes.single.hasVerticalAccuracy, isFalse);
    });
  });
}
